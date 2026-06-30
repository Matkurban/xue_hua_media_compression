//! AMediaCodec 解码/编码管线。

use std::ffi::CString;
use std::ptr::null_mut;
use std::slice;

use crate::api::traits::{MediaError, VideoCodec, VideoOptions, VideoResult};
use crate::video_encode::{finalize_encoded, plan_encode};
use crate::video_frame_collector::EncodedFrameCollector;
use crate::video_input::VideoInput;
use crate::video_scale::scale_nv12;

use super::extractor::open_extractor;
use super::ndk::*;

struct EncoderSink<'a> {
    collector: &'a mut EncodedFrameCollector,
}

pub(super) unsafe fn run(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let plan = plan_encode(input, opts)?;
    let needs_scale = plan.out_w != plan.src_w || plan.out_h != plan.src_h;

    let (decoder, encoder, extractor, dec_fmt, enc_fmt) =
        create_codecs(input, opts, plan.out_w, plan.out_h, plan.fps)?;

    let mut collector = EncodedFrameCollector::new(opts.codec, plan.frame_duration);
    let mut sink = EncoderSink {
        collector: &mut collector,
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
                            let scaled =
                                scale_nv12(&yuv, plan.src_w, plan.src_h, plan.out_w, plan.out_h);
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

    let (frames, vps, sps, pps) = collector.finish();

    finalize_encoded(
        output_path,
        opts,
        &plan,
        super::backend_name(),
        &frames,
        &vps,
        &sps,
        &pps,
    )
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
                sink.collector.push_codec_config(&nal);
            } else {
                sink.collector
                    .push_access_unit(nal, info.flags & AMEDIACODEC_BUFFER_FLAG_KEY_FRAME != 0);
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
    input: &VideoInput,
    opts: &VideoOptions,
    out_w: u32,
    out_h: u32,
    fps: u32,
) -> Result<(RawPtr, RawPtr, RawPtr, RawPtr, RawPtr), MediaError> {
    let extractor = open_extractor(input)?;

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
    let gop_secs = (opts.keyframe_interval.unwrap_or(60) as f64 / fps.max(1) as f64).max(1.0);
    AMediaFormat_setInt32(enc_fmt, key_gop.as_ptr(), gop_secs as i32);
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
