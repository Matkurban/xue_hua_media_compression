//! Android 端视频硬编：NDK `AMediaCodec` + `AMediaExtractor`。

use std::ffi::{c_char, CStr, CString};
use std::fs::File;
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::path::Path;
use std::ptr::null_mut;
use std::slice;

use crate::api::traits::{MediaError, VideoCodec, VideoCompressor, VideoOptions, VideoResult};
use crate::api::video::{mux_to_mp4, EncodedFrame, MuxParams};
use crate::api::video_common::{
    extract_param_sets_for_codec, read_mp4_video_metadata, scale_dims, scale_nv12,
};

#[flutter_rust_bridge::frb(opaque)]
pub(crate) struct AndroidVideoCompressor;

impl AndroidVideoCompressor {
    pub(crate) fn backend_name() -> &'static str {
        "AMediaCodec"
    }
}

impl VideoCompressor for AndroidVideoCompressor {
    fn compress(
        input_path: &str,
        output_path: &str,
        opts: &VideoOptions,
    ) -> Result<VideoResult, MediaError> {
        unsafe { encode_with_media_codec(input_path, output_path, opts) }
    }
}

type RawPtr = *mut std::ffi::c_void;

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct BufferInfo {
    offset: i32,
    size: i32,
    presentation_time_us: i64,
    flags: i32,
}

const AMEDIA_OK: isize = 0;
const AMEDIACODEC_CONFIGURE_FLAG_ENCODE: u32 = 1;
const AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG: i32 = 2;
const AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM: i32 = 4;
const AMEDIACODEC_BUFFER_FLAG_KEY_FRAME: i32 = 1;
const AMEDIACODEC_INFO_TRY_AGAIN_LATER: isize = -1;
const COLOR_FORMAT_YUV420_FLEXIBLE: i32 = 0x7F420888;
const TIMEOUT_US: i64 = 10_000;

struct EncoderSink<'a> {
    codec: VideoCodec,
    frame_duration: u32,
    frames: &'a mut Vec<EncodedFrame>,
    vps: &'a mut Vec<u8>,
    sps: &'a mut Vec<u8>,
    pps: &'a mut Vec<u8>,
}

#[link(name = "mediandk")]
extern "C" {
    fn AMediaExtractor_new() -> RawPtr;
    fn AMediaExtractor_delete(extractor: RawPtr) -> isize;
    fn AMediaExtractor_setDataSource(extractor: RawPtr, location: *const c_char) -> isize;
    fn AMediaExtractor_setDataSourceFd(
        extractor: RawPtr,
        fd: i32,
        offset: i64,
        length: i64,
    ) -> isize;
    fn AMediaExtractor_getTrackCount(extractor: RawPtr) -> usize;
    fn AMediaExtractor_getTrackFormat(extractor: RawPtr, index: usize) -> RawPtr;
    fn AMediaExtractor_selectTrack(extractor: RawPtr, index: usize) -> isize;
    fn AMediaExtractor_readSampleData(extractor: RawPtr, buffer: *mut u8, capacity: usize)
        -> isize;
    fn AMediaExtractor_getSampleTime(extractor: RawPtr) -> i64;
    fn AMediaExtractor_advance(extractor: RawPtr) -> bool;

    fn AMediaFormat_new() -> RawPtr;
    fn AMediaFormat_delete(fmt: RawPtr) -> isize;
    fn AMediaFormat_getInt32(fmt: RawPtr, name: *const c_char, out: *mut i32) -> bool;
    fn AMediaFormat_getString(fmt: RawPtr, name: *const c_char, out: *mut *mut c_char) -> bool;
    fn AMediaFormat_setInt32(fmt: RawPtr, name: *const c_char, value: i32) -> bool;
    fn AMediaFormat_setString(fmt: RawPtr, name: *const c_char, value: *const c_char) -> bool;

    fn AMediaCodec_createDecoderByType(mime: *const c_char) -> RawPtr;
    fn AMediaCodec_createEncoderByType(mime: *const c_char) -> RawPtr;
    fn AMediaCodec_delete(codec: RawPtr) -> isize;
    fn AMediaCodec_configure(
        codec: RawPtr,
        fmt: RawPtr,
        surface: RawPtr,
        crypto: RawPtr,
        flags: u32,
    ) -> isize;
    fn AMediaCodec_start(codec: RawPtr) -> isize;
    fn AMediaCodec_stop(codec: RawPtr) -> isize;
    fn AMediaCodec_dequeueInputBuffer(codec: RawPtr, timeout_us: i64) -> isize;
    fn AMediaCodec_getInputBuffer(codec: RawPtr, index: usize, out_size: *mut usize) -> *mut u8;
    fn AMediaCodec_queueInputBuffer(
        codec: RawPtr,
        index: usize,
        offset: usize,
        size: usize,
        time_us: u64,
        flags: u32,
    ) -> isize;
    fn AMediaCodec_dequeueOutputBuffer(
        codec: RawPtr,
        info: *mut BufferInfo,
        timeout_us: i64,
    ) -> isize;
    fn AMediaCodec_getOutputBuffer(codec: RawPtr, index: usize, out_size: *mut usize) -> *mut u8;
    fn AMediaCodec_releaseOutputBuffer(codec: RawPtr, index: usize, render: bool) -> isize;
}

fn validate_input_path(input_path: &str) -> Result<(), MediaError> {
    if input_path.starts_with("content://") {
        #[cfg(target_os = "android")]
        {
            return Ok(());
        }
        #[cfg(not(target_os = "android"))]
        {
            return Err(MediaError::Decode(
                "无法打开视频文件: content:// URI 仅 Android 支持".into(),
            ));
        }
    }
    if !Path::new(input_path).exists() {
        return Err(MediaError::Decode(format!(
            "无法打开视频文件: 路径不存在 ({input_path})"
        )));
    }
    Ok(())
}

fn file_open_diagnostics(input_path: &str) -> String {
    match std::fs::metadata(input_path) {
        Ok(meta) => {
            let size = meta.len();
            let mut header = [0u8; 8];
            if let Ok(mut file) = File::open(input_path) {
                let _ = file.read(&mut header);
            }
            let hex = header
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("size={size} bytes, header={hex}")
        }
        Err(e) => format!("metadata error: {e}"),
    }
}

fn try_set_data_source_fd(extractor: RawPtr, input_path: &str) -> Result<(), String> {
    let file = File::open(input_path).map_err(|e| format!("File::open: {e}"))?;
    let len = file.metadata().map_err(|e| format!("metadata: {e}"))?.len() as i64;
    let fd = file.as_raw_fd();
    try_set_data_source_fd_raw(extractor, fd, len)
}

fn try_set_data_source_fd_raw(extractor: RawPtr, fd: i32, len: i64) -> Result<(), String> {
    unsafe {
        if AMediaExtractor_setDataSourceFd(extractor, fd, 0, len) != AMEDIA_OK {
            return Err("AMediaExtractor_setDataSourceFd 失败".into());
        }
    }
    Ok(())
}

fn open_extractor_from_content_uri(uri: &str) -> Result<RawPtr, MediaError> {
    let (fd, len) = super::android_file::open_content_uri_fd(uri)?;
    unsafe {
        let extractor = AMediaExtractor_new();
        if extractor.is_null() {
            return Err(MediaError::HardwareUnavailable(
                "AMediaExtractor_new 失败".into(),
            ));
        }
        if let Err(e) = try_set_data_source_fd_raw(extractor, fd, len) {
            AMediaExtractor_delete(extractor);
            return Err(MediaError::Decode(format!(
                "无法打开 content URI ({uri}): {e}"
            )));
        }
        Ok(extractor)
    }
}

fn open_extractor_data_source(input_path: &str) -> Result<RawPtr, MediaError> {
    if input_path.starts_with("content://") {
        return open_extractor_from_content_uri(input_path);
    }

    validate_input_path(input_path)?;
    let diagnostics = file_open_diagnostics(input_path);
    unsafe {
        let extractor = AMediaExtractor_new();
        if extractor.is_null() {
            return Err(MediaError::HardwareUnavailable(
                "AMediaExtractor_new 失败".into(),
            ));
        }
        let path = CString::new(input_path).map_err(|e| MediaError::Io(e.to_string()))?;
        if AMediaExtractor_setDataSource(extractor, path.as_ptr()) == AMEDIA_OK {
            return Ok(extractor);
        }
        match try_set_data_source_fd(extractor, input_path) {
            Ok(()) => Ok(extractor),
            Err(fd_err) => {
                AMediaExtractor_delete(extractor);
                Err(MediaError::Decode(format!(
                    "无法打开视频文件 ({input_path}): \
                     路径方式与 fd 方式均失败 ({fd_err})。{diagnostics} \
                     请确认文件为完整 MP4/MOV 且路径可读"
                )))
            }
        }
    }
}

unsafe fn encode_with_media_codec(
    input_path: &str,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let (src_w, src_h, src_fps) = read_source_dimensions(input_path)?;
    let (out_w, out_h) = scale_dims(src_w, src_h, opts.max_dimension);
    let fps = opts.fps.unwrap_or(src_fps).max(1);
    let frame_duration = 90_000 / fps;
    let needs_scale = out_w != src_w || out_h != src_h;

    let (decoder, encoder, extractor, dec_fmt, enc_fmt) =
        create_codecs(input_path, opts, out_w, out_h, fps)?;

    let mut frames: Vec<EncodedFrame> = Vec::new();
    let mut vps = Vec::new();
    let mut sps = Vec::new();
    let mut pps = Vec::new();
    let mut sink = EncoderSink {
        codec: opts.codec,
        frame_duration,
        frames: &mut frames,
        vps: &mut vps,
        sps: &mut sps,
        pps: &mut pps,
    };

    let mut input_done = false;
    let mut decoder_done = false;
    let mut encoder_output_eos = false;

    while !encoder_output_eos {
        if !input_done {
            feed_decoder_input(decoder, extractor, &mut input_done)?;
        }

        if !decoder_done {
            loop {
                let mut dec_info = BufferInfo::default();
                let dec_out = AMediaCodec_dequeueOutputBuffer(decoder, &mut dec_info, 0);
                if dec_out == AMEDIACODEC_INFO_TRY_AGAIN_LATER {
                    break;
                }
                if dec_out < 0 {
                    break;
                }

                if dec_info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0 {
                    queue_encoder_eos(encoder, &mut sink)?;
                    decoder_done = true;
                } else if dec_info.size > 0 {
                    let mut cap = 0usize;
                    let out_buf = AMediaCodec_getOutputBuffer(decoder, dec_out as usize, &mut cap);
                    if !out_buf.is_null() {
                        let src_ptr = out_buf.add(dec_info.offset as usize);
                        let src_len = dec_info.size as usize;
                        let pts = dec_info.presentation_time_us.max(0) as u64;
                        if needs_scale {
                            let yuv = slice::from_raw_parts(src_ptr, src_len).to_vec();
                            let scaled = scale_nv12(&yuv, src_w, src_h, out_w, out_h);
                            queue_yuv_to_encoder(
                                encoder,
                                scaled.as_ptr(),
                                scaled.len(),
                                pts,
                                &mut sink,
                            )?;
                        } else {
                            queue_yuv_to_encoder(encoder, src_ptr, src_len, pts, &mut sink)?;
                        }
                    }
                }
                AMediaCodec_releaseOutputBuffer(decoder, dec_out as usize, false);
            }
        }

        let drain_timeout = if decoder_done { TIMEOUT_US } else { 0 };
        if drain_encoder(encoder, &mut sink, drain_timeout)? {
            encoder_output_eos = true;
        }
    }

    AMediaCodec_stop(decoder);
    AMediaCodec_delete(decoder);
    AMediaCodec_stop(encoder);
    AMediaCodec_delete(encoder);
    AMediaFormat_delete(dec_fmt);
    AMediaFormat_delete(enc_fmt);
    AMediaExtractor_delete(extractor);

    if frames.is_empty() {
        return Err(MediaError::Encode("AMediaCodec 未产出编码帧".into()));
    }

    let params = MuxParams {
        codec: opts.codec,
        width: out_w as u16,
        height: out_h as u16,
        timescale: 90_000,
        vps: if vps.is_empty() {
            None
        } else {
            Some(vps.as_slice())
        },
        sps: &sps,
        pps: &pps,
    };
    let size = mux_to_mp4(output_path, &params, &frames)?;

    Ok(VideoResult {
        output_path: output_path.to_string(),
        size_bytes: size,
        backend: AndroidVideoCompressor::backend_name().to_string(),
        width: out_w,
        height: out_h,
    })
}

unsafe fn feed_decoder_input(
    decoder: RawPtr,
    extractor: RawPtr,
    input_done: &mut bool,
) -> Result<(), MediaError> {
    let in_idx = AMediaCodec_dequeueInputBuffer(decoder, TIMEOUT_US);
    if in_idx < 0 {
        return Ok(());
    }
    let mut cap = 0usize;
    let buf = AMediaCodec_getInputBuffer(decoder, in_idx as usize, &mut cap);
    if buf.is_null() {
        return Ok(());
    }
    let read = AMediaExtractor_readSampleData(extractor, buf, cap);
    if read < 0 {
        AMediaCodec_queueInputBuffer(
            decoder,
            in_idx as usize,
            0,
            0,
            0,
            AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM as u32,
        );
        *input_done = true;
    } else {
        let pts = AMediaExtractor_getSampleTime(extractor).max(0) as u64;
        AMediaCodec_queueInputBuffer(decoder, in_idx as usize, 0, read as usize, pts, 0);
        AMediaExtractor_advance(extractor);
    }
    Ok(())
}

/// 排空编码器输出。返回 `true` 表示已收到 EOS。
unsafe fn drain_encoder(
    encoder: RawPtr,
    sink: &mut EncoderSink<'_>,
    timeout_us: i64,
) -> Result<bool, MediaError> {
    loop {
        let mut info = BufferInfo::default();
        let out_idx = AMediaCodec_dequeueOutputBuffer(encoder, &mut info, timeout_us);
        if out_idx == AMEDIACODEC_INFO_TRY_AGAIN_LATER {
            return Ok(false);
        }
        if out_idx < 0 {
            return Ok(false);
        }

        let mut cap = 0usize;
        let buf = AMediaCodec_getOutputBuffer(encoder, out_idx as usize, &mut cap);
        if !buf.is_null() && info.size > 0 {
            let nal =
                slice::from_raw_parts(buf.add(info.offset as usize), info.size as usize).to_vec();
            if info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG != 0 {
                let (v, s, p) = extract_param_sets_for_codec(sink.codec, &nal);
                if let Some(vv) = v {
                    *sink.vps = vv;
                }
                *sink.sps = s;
                *sink.pps = p;
            } else {
                sink.frames.push(EncodedFrame {
                    data: nal,
                    is_keyframe: info.flags & AMEDIACODEC_BUFFER_FLAG_KEY_FRAME != 0,
                    duration: sink.frame_duration,
                });
            }
        }
        let eos = info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0;
        AMediaCodec_releaseOutputBuffer(encoder, out_idx as usize, false);
        if eos {
            return Ok(true);
        }
    }
}

unsafe fn queue_yuv_to_encoder(
    encoder: RawPtr,
    src: *const u8,
    len: usize,
    pts: u64,
    sink: &mut EncoderSink<'_>,
) -> Result<(), MediaError> {
    loop {
        let in_idx = AMediaCodec_dequeueInputBuffer(encoder, TIMEOUT_US);
        if in_idx >= 0 {
            let mut cap = 0usize;
            let buf = AMediaCodec_getInputBuffer(encoder, in_idx as usize, &mut cap);
            if !buf.is_null() {
                let copy_len = len.min(cap);
                std::ptr::copy_nonoverlapping(src, buf, copy_len);
                AMediaCodec_queueInputBuffer(encoder, in_idx as usize, 0, copy_len, pts, 0);
                return Ok(());
            }
        }
        if drain_encoder(encoder, sink, 0)? {
            return Err(MediaError::Encode("编码器已结束，无法继续写入帧".into()));
        }
    }
}

unsafe fn queue_encoder_eos(encoder: RawPtr, sink: &mut EncoderSink<'_>) -> Result<(), MediaError> {
    loop {
        let in_idx = AMediaCodec_dequeueInputBuffer(encoder, TIMEOUT_US);
        if in_idx >= 0 {
            AMediaCodec_queueInputBuffer(
                encoder,
                in_idx as usize,
                0,
                0,
                0,
                AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM as u32,
            );
            return Ok(());
        }
        if drain_encoder(encoder, sink, 0)? {
            return Ok(());
        }
    }
}

unsafe fn create_codecs(
    input_path: &str,
    opts: &VideoOptions,
    out_w: u32,
    out_h: u32,
    fps: u32,
) -> Result<(RawPtr, RawPtr, RawPtr, RawPtr, RawPtr), MediaError> {
    let extractor = open_extractor_data_source(input_path)?;

    let track_count = AMediaExtractor_getTrackCount(extractor);
    let mut dec_fmt: RawPtr = null_mut();
    let mut input_mime = CString::new("video/avc").unwrap();
    for i in 0..track_count {
        let fmt = AMediaExtractor_getTrackFormat(extractor, i);
        let mut mime_ptr: *mut c_char = null_mut();
        if AMediaFormat_getString(fmt, CString::new("mime").unwrap().as_ptr(), &mut mime_ptr) {
            let mime = c_ptr_to_string(mime_ptr);
            if mime.starts_with("video/") {
                dec_fmt = fmt;
                input_mime = CString::new(mime).map_err(|e| MediaError::Io(e.to_string()))?;
                AMediaExtractor_selectTrack(extractor, i);
                break;
            }
        }
        AMediaFormat_delete(fmt);
    }
    if dec_fmt.is_null() {
        AMediaExtractor_delete(extractor);
        return Err(MediaError::Decode("无视频轨".into()));
    }

    let decoder = AMediaCodec_createDecoderByType(input_mime.as_ptr());
    if decoder.is_null() {
        return Err(MediaError::HardwareUnavailable("创建解码器失败".into()));
    }
    if AMediaCodec_configure(decoder, dec_fmt, null_mut(), null_mut(), 0) != AMEDIA_OK {
        return Err(MediaError::Decode("解码器 configure 失败".into()));
    }
    AMediaCodec_start(decoder);

    let enc_mime = match opts.codec {
        VideoCodec::H264 => "video/avc",
        VideoCodec::H265 => "video/hevc",
    };
    let encoder = AMediaCodec_createEncoderByType(CString::new(enc_mime).unwrap().as_ptr());
    if encoder.is_null() {
        return Err(MediaError::HardwareUnavailable("创建编码器失败".into()));
    }
    let enc_fmt = AMediaFormat_new();
    let enc_mime_c = CString::new(enc_mime).unwrap();
    let key_mime = CString::new("mime").unwrap();
    let key_width = CString::new("width").unwrap();
    let key_height = CString::new("height").unwrap();
    let key_bitrate = CString::new("bitrate").unwrap();
    let key_fps = CString::new("frame-rate").unwrap();
    let key_gop = CString::new("i-frame-interval").unwrap();
    let key_color = CString::new("color-format").unwrap();
    AMediaFormat_setString(enc_fmt, key_mime.as_ptr(), enc_mime_c.as_ptr());
    AMediaFormat_setInt32(enc_fmt, key_width.as_ptr(), out_w as i32);
    AMediaFormat_setInt32(enc_fmt, key_height.as_ptr(), out_h as i32);
    AMediaFormat_setInt32(enc_fmt, key_bitrate.as_ptr(), opts.bitrate as i32);
    AMediaFormat_setInt32(enc_fmt, key_fps.as_ptr(), fps as i32);
    AMediaFormat_setInt32(
        enc_fmt,
        key_gop.as_ptr(),
        (opts.keyframe_interval.unwrap_or(60) / fps.max(1)) as i32,
    );
    AMediaFormat_setInt32(enc_fmt, key_color.as_ptr(), COLOR_FORMAT_YUV420_FLEXIBLE);

    if AMediaCodec_configure(
        encoder,
        enc_fmt,
        null_mut(),
        null_mut(),
        AMEDIACODEC_CONFIGURE_FLAG_ENCODE,
    ) != AMEDIA_OK
    {
        return Err(MediaError::Encode("编码器 configure 失败".into()));
    }
    AMediaCodec_start(encoder);

    Ok((decoder, encoder, extractor, dec_fmt, enc_fmt))
}

fn read_source_dimensions(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    match read_mp4_video_metadata(input_path) {
        Ok(dims) => return Ok(dims),
        Err(mp4_err) => unsafe {
            let extractor = open_extractor_data_source(input_path).map_err(|ndk_err| {
                let diagnostics = file_open_diagnostics(input_path);
                MediaError::Decode(format!(
                    "无法读取视频元数据: MP4 解析失败 ({mp4_err}); \
                     NDK 打开失败 ({ndk_err})。{diagnostics}"
                ))
            })?;
            let count = AMediaExtractor_getTrackCount(extractor);
            for i in 0..count {
                let fmt = AMediaExtractor_getTrackFormat(extractor, i);
                let mut mime_ptr: *mut c_char = null_mut();
                if AMediaFormat_getString(
                    fmt,
                    CString::new("mime").unwrap().as_ptr(),
                    &mut mime_ptr,
                ) {
                    let mime = c_ptr_to_string(mime_ptr);
                    if mime.starts_with("video/") {
                        let mut w = 0i32;
                        let mut h = 0i32;
                        let mut fps = 30i32;
                        AMediaFormat_getInt32(fmt, CString::new("width").unwrap().as_ptr(), &mut w);
                        AMediaFormat_getInt32(
                            fmt,
                            CString::new("height").unwrap().as_ptr(),
                            &mut h,
                        );
                        AMediaFormat_getInt32(
                            fmt,
                            CString::new("frame-rate").unwrap().as_ptr(),
                            &mut fps,
                        );
                        AMediaFormat_delete(fmt);
                        AMediaExtractor_delete(extractor);
                        return Ok((w as u32, h as u32, fps.max(1) as u32));
                    }
                }
                AMediaFormat_delete(fmt);
            }
            AMediaExtractor_delete(extractor);
            Err(MediaError::Decode("无视频轨".into()))
        },
    }
}

unsafe fn c_ptr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}
