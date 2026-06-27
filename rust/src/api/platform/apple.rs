//! Apple 端（iOS / macOS）视频硬编：VideoToolbox + AVAssetReader。

use std::ffi::c_void;
use std::ptr;

use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation_sys::base::{kCFAllocatorDefault, CFRelease, CFRetain, CFTypeRef, OSStatus};
use core_foundation_sys::dictionary::CFDictionaryRef;
use core_foundation_sys::string::CFStringRef;
use core_media_sys::CMTime;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{msg_send, AnyThread};
use objc2_av_foundation::{AVAssetReader, AVAssetReaderTrackOutput, AVMediaTypeVideo, AVURLAsset};
use objc2_core_media::CMSampleBuffer;
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSURL};
use video_toolbox_sys::codecs::video::{H264, HEVC};
use video_toolbox_sys::compression::{
    kVTCompressionPropertyKey_AverageBitRate, kVTCompressionPropertyKey_MaxKeyFrameInterval,
    kVTCompressionPropertyKey_ProfileLevel, kVTCompressionPropertyKey_RealTime,
    kVTEncodeInfo_FrameDropped, kVTProfileLevel_H264_High_AutoLevel,
    kVTProfileLevel_HEVC_Main_AutoLevel,
    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
    VTCompressionSessionCompleteFrames, VTCompressionSessionCreate,
    VTCompressionSessionEncodeFrame, VTCompressionSessionInvalidate,
    VTCompressionSessionPrepareToEncodeFrames, VTCompressionSessionRef, VTEncodeInfoFlags,
};
use video_toolbox_sys::cv_types::CVPixelBufferRef;
use video_toolbox_sys::session::VTSessionSetProperty;

use crate::api::traits::{MediaError, VideoCodec, VideoCompressor, VideoOptions, VideoResult};
use crate::api::video::{mux_to_mp4, EncodedFrame, MuxParams};
use crate::api::video_common::{avcc_to_annex_b, scale_dims};

#[flutter_rust_bridge::frb(opaque)]
pub(crate) struct AppleVideoCompressor;

impl AppleVideoCompressor {
    pub(crate) fn backend_name() -> &'static str {
        "VideoToolbox"
    }
}

impl VideoCompressor for AppleVideoCompressor {
    fn compress(
        input_path: &str,
        output_path: &str,
        opts: &VideoOptions,
    ) -> Result<VideoResult, MediaError> {
        encode_with_video_toolbox(input_path, output_path, opts)
    }
}

struct EncodeSink {
    frames: Vec<EncodedFrame>,
    vps: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    frame_duration: u32,
    codec: VideoCodec,
}

fn encode_with_video_toolbox(
    input_path: &str,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let (src_w, src_h, src_fps) = read_source_dimensions(input_path)?;
    let (out_w, out_h) = scale_dims(src_w, src_h, opts.max_dimension);
    let fps = opts.fps.unwrap_or(src_fps).max(1);
    let frame_duration = 90_000 / fps;

    let mut sink = EncodeSink {
        frames: Vec::new(),
        vps: Vec::new(),
        sps: Vec::new(),
        pps: Vec::new(),
        frame_duration,
        codec: opts.codec,
    };

    let pixel_buffers = decode_source_frames(input_path, out_w, out_h)?;

    let codec_fourcc = match opts.codec {
        VideoCodec::H264 => H264,
        VideoCodec::H265 => HEVC,
    };

    unsafe {
        let hw_key = CFString::wrap_under_get_rule(
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as CFStringRef,
        );
        let encoder_spec = CFDictionary::from_CFType_pairs(&[(
            hw_key.as_CFType(),
            CFBoolean::true_value().as_CFType(),
        )]);

        let mut session: VTCompressionSessionRef = ptr::null_mut();
        let status = VTCompressionSessionCreate(
            kCFAllocatorDefault,
            out_w as i32,
            out_h as i32,
            codec_fourcc,
            encoder_spec.as_concrete_TypeRef() as CFDictionaryRef,
            ptr::null(),
            kCFAllocatorDefault,
            compression_output_callback,
            &mut sink as *mut EncodeSink as *mut c_void,
            &mut session,
        );
        if status != 0 {
            return Err(MediaError::Native {
                code: status as i64,
                msg: "VTCompressionSessionCreate".into(),
            });
        }

        let profile_key =
            CFString::wrap_under_get_rule(kVTCompressionPropertyKey_ProfileLevel as CFStringRef);
        let profile_value = match opts.codec {
            VideoCodec::H264 => {
                CFString::wrap_under_get_rule(kVTProfileLevel_H264_High_AutoLevel as CFStringRef)
            }
            VideoCodec::H265 => {
                CFString::wrap_under_get_rule(kVTProfileLevel_HEVC_Main_AutoLevel as CFStringRef)
            }
        };
        VTSessionSetProperty(
            session,
            profile_key.as_concrete_TypeRef() as CFStringRef,
            profile_value.as_concrete_TypeRef() as CFTypeRef,
        );

        let bitrate_key =
            CFString::wrap_under_get_rule(kVTCompressionPropertyKey_AverageBitRate as CFStringRef);
        VTSessionSetProperty(
            session,
            bitrate_key.as_concrete_TypeRef() as CFStringRef,
            CFNumber::from(opts.bitrate as i64).as_concrete_TypeRef() as CFTypeRef,
        );

        let keyframe_key = CFString::wrap_under_get_rule(
            kVTCompressionPropertyKey_MaxKeyFrameInterval as CFStringRef,
        );
        VTSessionSetProperty(
            session,
            keyframe_key.as_concrete_TypeRef() as CFStringRef,
            CFNumber::from(opts.keyframe_interval.unwrap_or(60) as i32).as_concrete_TypeRef()
                as CFTypeRef,
        );

        let realtime_key =
            CFString::wrap_under_get_rule(kVTCompressionPropertyKey_RealTime as CFStringRef);
        VTSessionSetProperty(
            session,
            realtime_key.as_concrete_TypeRef() as CFStringRef,
            CFBoolean::false_value().as_concrete_TypeRef() as CFTypeRef,
        );

        let prep = VTCompressionSessionPrepareToEncodeFrames(session);
        if prep != 0 {
            VTCompressionSessionInvalidate(session);
            CFRelease(session as CFTypeRef);
            return Err(MediaError::Native {
                code: prep as i64,
                msg: "VTCompressionSessionPrepareToEncodeFrames".into(),
            });
        }

        for (i, pb) in pixel_buffers.iter().enumerate() {
            let pts = CMTime {
                value: i as i64,
                timescale: fps as i32,
                flags: 1,
                epoch: 0,
            };
            let dur = CMTime {
                value: 1,
                timescale: fps as i32,
                flags: 1,
                epoch: 0,
            };
            let mut info_flags: VTEncodeInfoFlags = 0;
            let st = VTCompressionSessionEncodeFrame(
                session,
                *pb as CVPixelBufferRef,
                pts,
                dur,
                ptr::null(),
                ptr::null_mut(),
                &mut info_flags,
            );
            if st != 0 {
                VTCompressionSessionInvalidate(session);
                CFRelease(session as CFTypeRef);
                return Err(MediaError::Native {
                    code: st as i64,
                    msg: format!("VTCompressionSessionEncodeFrame frame {i}"),
                });
            }
            CFRelease(*pb as CFTypeRef);
        }

        VTCompressionSessionCompleteFrames(
            session,
            CMTime {
                value: i64::MAX / 2,
                timescale: 1,
                flags: 1,
                epoch: 0,
            },
        );
        VTCompressionSessionInvalidate(session);
        CFRelease(session as CFTypeRef);
    }

    if sink.frames.is_empty() {
        return Err(MediaError::Encode("VideoToolbox 未产出编码帧".into()));
    }

    let params = MuxParams {
        codec: opts.codec,
        width: out_w as u16,
        height: out_h as u16,
        timescale: 90_000,
        vps: if sink.vps.is_empty() {
            None
        } else {
            Some(sink.vps.as_slice())
        },
        sps: &sink.sps,
        pps: &sink.pps,
    };
    let size = mux_to_mp4(output_path, &params, &sink.frames)?;

    Ok(VideoResult {
        output_path: output_path.to_string(),
        size_bytes: size,
        backend: AppleVideoCompressor::backend_name().to_string(),
        width: out_w,
        height: out_h,
    })
}

extern "C" fn compression_output_callback(
    refcon: *mut c_void,
    _src_ref: *mut c_void,
    status: OSStatus,
    info_flags: VTEncodeInfoFlags,
    sample: *mut c_void,
) {
    if status != 0 || sample.is_null() {
        return;
    }
    if (info_flags & kVTEncodeInfo_FrameDropped) != 0 {
        return;
    }
    let sink = unsafe { &mut *(refcon as *mut EncodeSink) };
    unsafe {
        let is_key = sample_is_keyframe(sample);
        if is_key {
            extract_format_param_sets(sample, sink);
        }
        let mut total = 0usize;
        let mut data_ptr: *mut i8 = ptr::null_mut();
        let block = CMSampleBufferGetDataBuffer(sample);
        if block.is_null() {
            return;
        }
        if CMBlockBufferGetDataPointer(block, 0, ptr::null_mut(), &mut total, &mut data_ptr) != 0 {
            return;
        }
        let avcc = std::slice::from_raw_parts(data_ptr as *const u8, total).to_vec();
        sink.frames.push(EncodedFrame {
            data: avcc_to_annex_b(&avcc),
            is_keyframe: is_key,
            duration: sink.frame_duration,
        });
    }
}

/// VT 输出帧：`NotSync` 附件缺失或为 false 时表示关键帧。
unsafe fn sample_is_keyframe(sample: *mut c_void) -> bool {
    let c = std::ffi::CString::new("NotSync").unwrap();
    let key = core_foundation_sys::string::CFStringCreateWithCString(
        kCFAllocatorDefault,
        c.as_ptr(),
        core_foundation_sys::string::kCFStringEncodingUTF8,
    );
    let att = CMGetAttachment(sample as CFTypeRef, key, ptr::null_mut());
    CFRelease(key as CFTypeRef);
    if att.is_null() {
        return true;
    }
    let is_not_sync: bool = CFBoolean::wrap_under_get_rule(att as _).into();
    !is_not_sync
}

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMGetAttachment(
        target: CFTypeRef,
        key: CFStringRef,
        attachment_mode_out: *mut u32,
    ) -> CFTypeRef;
    fn CMSampleBufferGetFormatDescription(sample: *const c_void) -> *const c_void;
    fn CMSampleBufferGetDataBuffer(sample: *const c_void) -> *const c_void;
    fn CMSampleBufferGetImageBuffer(sample: *const c_void) -> CVPixelBufferRef;
    fn CMBlockBufferGetDataPointer(
        block: *const c_void,
        offset: i64,
        length_at_offset: *mut usize,
        total_length: *mut usize,
        data_pointer: *mut *mut i8,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        desc: *const c_void,
        index: usize,
        param_set: *mut *const u8,
        param_set_size: *mut usize,
        param_set_count: *mut usize,
        nal_unit_header_length: *mut i32,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        desc: *const c_void,
        index: usize,
        param_set: *mut *const u8,
        param_set_size: *mut usize,
        param_set_count: *mut usize,
        nal_unit_header_length: *mut i32,
    ) -> OSStatus;
}

unsafe fn extract_format_param_sets(sample: *mut c_void, sink: &mut EncodeSink) {
    let fmt = CMSampleBufferGetFormatDescription(sample);
    if fmt.is_null() {
        return;
    }
    match sink.codec {
        VideoCodec::H264 if sink.sps.is_empty() => {
            let mut ptr: *const u8 = ptr::null();
            let mut len = 0usize;
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt,
                0,
                &mut ptr,
                &mut len,
                ptr::null_mut(),
                ptr::null_mut(),
            ) == 0
                && !ptr.is_null()
            {
                let mut sps = vec![0u8, 0, 0, 1];
                sps.extend_from_slice(std::slice::from_raw_parts(ptr, len));
                sink.sps = sps;
            }
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt,
                1,
                &mut ptr,
                &mut len,
                ptr::null_mut(),
                ptr::null_mut(),
            ) == 0
                && !ptr.is_null()
            {
                let mut pps = vec![0u8, 0, 0, 1];
                pps.extend_from_slice(std::slice::from_raw_parts(ptr, len));
                sink.pps = pps;
            }
        }
        VideoCodec::H265 if sink.sps.is_empty() => {
            let mut ptr: *const u8 = ptr::null();
            let mut len = 0usize;
            for (idx, target) in [(0, &mut sink.vps), (1, &mut sink.sps), (2, &mut sink.pps)] {
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt,
                    idx,
                    &mut ptr,
                    &mut len,
                    ptr::null_mut(),
                    ptr::null_mut(),
                ) == 0
                    && !ptr.is_null()
                {
                    let mut nal = vec![0u8, 0, 0, 1];
                    nal.extend_from_slice(std::slice::from_raw_parts(ptr, len));
                    *target = nal;
                }
            }
        }
        _ => {}
    }
}

fn read_source_dimensions(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    crate::api::video_common::read_mp4_video_metadata(input_path)
        .or_else(|_| read_source_dimensions_avfoundation(input_path))
}

fn read_source_dimensions_avfoundation(input_path: &str) -> Result<(u32, u32, u32), MediaError> {
    let media_type = unsafe { AVMediaTypeVideo.unwrap() };
    let path = NSString::from_str(input_path);
    let url = unsafe { NSURL::fileURLWithPath(&path) };
    let asset = unsafe { AVURLAsset::initWithURL_options(AVURLAsset::alloc(), &url, None) };
    let tracks = unsafe { asset.tracksWithMediaType(media_type) };
    if tracks.count() == 0 {
        return Err(MediaError::Decode("未找到视频轨".into()));
    }
    let track = unsafe { tracks.objectAtIndex(0) };
    let size = unsafe { track.naturalSize() };
    let fps = unsafe { track.nominalFrameRate() };
    Ok((
        size.width.abs() as u32 & !1,
        size.height.abs() as u32 & !1,
        if fps > 0.0 { fps.round() as u32 } else { 30 }.max(1),
    ))
}

fn decode_source_frames(
    input_path: &str,
    out_w: u32,
    out_h: u32,
) -> Result<Vec<*mut c_void>, MediaError> {
    let media_type = unsafe { AVMediaTypeVideo.unwrap() };
    let path = NSString::from_str(input_path);
    let url = unsafe { NSURL::fileURLWithPath(&path) };
    let asset = unsafe { AVURLAsset::initWithURL_options(AVURLAsset::alloc(), &url, None) };
    let reader = unsafe {
        AVAssetReader::assetReaderWithAsset_error(&asset)
            .map_err(|e| MediaError::Decode(format!("AVAssetReader 创建失败: {e:?}")))?
    };
    let tracks = unsafe { asset.tracksWithMediaType(media_type) };
    if tracks.count() == 0 {
        return Err(MediaError::Decode("未找到视频轨".into()));
    }
    let track = unsafe { tracks.objectAtIndex(0) };

    let pf_key = NSString::from_str("kCVPixelBufferPixelFormatTypeKey");
    let w_key = NSString::from_str("Width");
    let h_key = NSString::from_str("Height");
    let nv12 = NSNumber::new_i32(0x34323076i32);
    let w_num = NSNumber::new_i32(out_w as i32);
    let h_num = NSNumber::new_i32(out_h as i32);
    let dict = unsafe {
        NSDictionary::from_slices(
            &[&*pf_key, &*w_key, &*h_key],
            &[
                &*(&*nv12 as *const NSNumber as *const AnyObject),
                &*(&*w_num as *const NSNumber as *const AnyObject),
                &*(&*h_num as *const NSNumber as *const AnyObject),
            ],
        )
    };

    let output = unsafe {
        AVAssetReaderTrackOutput::initWithTrack_outputSettings(
            AVAssetReaderTrackOutput::alloc(),
            &track,
            Some(&dict),
        )
    };
    unsafe {
        reader.addOutput(&output);
        if !reader.startReading() {
            return Err(MediaError::Decode("AVAssetReader startReading 失败".into()));
        }
    }

    let mut buffers = Vec::new();
    loop {
        let sample: Option<Retained<CMSampleBuffer>> =
            unsafe { msg_send![&*output, copyNextSampleBuffer] };
        match sample {
            Some(_sb) => {
                let sb_ptr = Retained::as_ptr(&_sb) as *const c_void;
                let pb = unsafe { CMSampleBufferGetImageBuffer(sb_ptr) };
                if !pb.is_null() {
                    unsafe { CFRetain(pb as CFTypeRef) };
                    buffers.push(pb as *mut c_void);
                }
            }
            None => break,
        }
    }

    if buffers.is_empty() {
        return Err(MediaError::Decode("未能解码任何视频帧".into()));
    }
    Ok(buffers)
}
