//! VideoToolbox 硬编：VTCompressionSession + 输出回调。

use std::ffi::c_void;
use std::ptr;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString as CfString;
use core_foundation_sys::base::{kCFAllocatorDefault, CFGetTypeID, CFRelease, CFTypeRef, OSStatus};
use core_foundation_sys::dictionary::CFDictionaryRef;
use core_foundation_sys::string::CFStringRef;
use core_media_sys::CMTime;
use objc2::rc::Retained;
use objc2::{msg_send, AnyThread};
use objc2_core_foundation::CFRetained;
use objc2_core_media::{
    CMSampleBuffer, CMVideoFormatDescriptionGetH264ParameterSetAtIndex,
    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex,
};
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

use crate::api::traits::{MediaError, VideoCodec, VideoOptions, VideoResult};
use crate::video_bitstream::avcc_to_annex_b;
use crate::video_encode::{finalize_encoded, plan_encode};
use crate::video_frame_collector::EncodedFrameCollector;
use crate::video_input::VideoInput;

/// RealTime=false 时 VT 可延迟回调；限制在途帧数避免内存无限增长。
const MAX_IN_FLIGHT: u64 = 8;

const CALLBACK_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

struct EncodeSinkInner {
    output: EncodedFrameCollector,
    /// 已成功调用 VTCompressionSessionEncodeFrame 的次数。
    frames_submitted: u64,
    /// VT 输出回调完成次数（含 dropped / error），用于与主线程同步。
    callbacks_completed: u64,
}

struct EncodeSink {
    inner: Mutex<EncodeSinkInner>,
    cv: Condvar,
}

impl EncodeSink {
    fn new(frame_duration: u32, codec: VideoCodec) -> Self {
        Self {
            inner: Mutex::new(EncodeSinkInner {
                output: EncodedFrameCollector::new(codec, frame_duration),
                frames_submitted: 0,
                callbacks_completed: 0,
            }),
            cv: Condvar::new(),
        }
    }

    fn in_flight(guard: &EncodeSinkInner) -> u64 {
        guard
            .frames_submitted
            .saturating_sub(guard.callbacks_completed)
    }

    /// EncodeFrame 成功后递增 submitted，并在在途帧超窗时等待回调。
    fn on_frame_submitted(&self) -> Result<(), MediaError> {
        {
            let mut guard = self
                .inner
                .lock()
                .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
            guard.frames_submitted += 1;
        }
        self.wait_while_in_flight_above(MAX_IN_FLIGHT)
    }

    fn wait_while_in_flight_above(&self, max: u64) -> Result<(), MediaError> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
        while Self::in_flight(&guard) > max {
            let submitted = guard.frames_submitted;
            let completed = guard.callbacks_completed;
            let (g, timeout) = self
                .cv
                .wait_timeout(guard, CALLBACK_WAIT_TIMEOUT)
                .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
            guard = g;
            if timeout.timed_out() {
                return Err(MediaError::Encode(format!(
                    "VideoToolbox 编码回调超时（在途 {}/{}，已提交 {completed}）",
                    submitted - completed,
                    max
                )));
            }
        }
        Ok(())
    }

    /// CompleteFrames 后等待所有已提交帧的回调完成。
    fn wait_until_drained(&self) -> Result<(), MediaError> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
        while guard.callbacks_completed < guard.frames_submitted {
            let submitted = guard.frames_submitted;
            let completed = guard.callbacks_completed;
            let (g, timeout) = self
                .cv
                .wait_timeout(guard, CALLBACK_WAIT_TIMEOUT)
                .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
            guard = g;
            if timeout.timed_out() {
                return Err(MediaError::Encode(format!(
                    "VideoToolbox 编码未完成 drain（{completed}/{submitted}）"
                )));
            }
        }
        Ok(())
    }

    fn frames_submitted(&self) -> u64 {
        self.inner.lock().map(|g| g.frames_submitted).unwrap_or(0)
    }

    /// 回调结束：递增计数并 notify（回调内绝不阻塞）。
    fn finish_callback(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.callbacks_completed += 1;
            drop(guard);
            self.cv.notify_all();
        }
    }
}

pub(super) fn run(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let input_path = input
        .file_path()
        .ok_or_else(|| MediaError::Decode("Apple 视频编码仅支持本地文件路径".into()))?;
    let plan = plan_encode(input, opts)?;

    let sink = EncodeSink::new(plan.frame_duration, opts.codec);

    let codec_fourcc = match opts.codec {
        VideoCodec::H264 => H264,
        VideoCodec::H265 => HEVC,
    };

    unsafe {
        let hw_key = CfString::wrap_under_get_rule(
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as CFStringRef,
        );
        let encoder_spec = CFDictionary::from_CFType_pairs(&[(
            hw_key.as_CFType(),
            CFBoolean::true_value().as_CFType(),
        )]);

        let mut session: VTCompressionSessionRef = ptr::null_mut();
        let status = VTCompressionSessionCreate(
            kCFAllocatorDefault,
            plan.out_w as i32,
            plan.out_h as i32,
            codec_fourcc,
            encoder_spec.as_concrete_TypeRef() as CFDictionaryRef,
            ptr::null(),
            kCFAllocatorDefault,
            compression_output_callback,
            &sink as *const EncodeSink as *mut c_void,
            &mut session,
        );
        if status != 0 {
            return Err(MediaError::Native {
                code: status as i64,
                msg: "VTCompressionSessionCreate".into(),
            });
        }

        let profile_key =
            CfString::wrap_under_get_rule(kVTCompressionPropertyKey_ProfileLevel as CFStringRef);
        let profile_value = match opts.codec {
            VideoCodec::H264 => {
                CfString::wrap_under_get_rule(kVTProfileLevel_H264_High_AutoLevel as CFStringRef)
            }
            VideoCodec::H265 => {
                CfString::wrap_under_get_rule(kVTProfileLevel_HEVC_Main_AutoLevel as CFStringRef)
            }
        };
        VTSessionSetProperty(
            session,
            profile_key.as_concrete_TypeRef() as CFStringRef,
            profile_value.as_concrete_TypeRef() as CFTypeRef,
        );

        let bitrate_key =
            CfString::wrap_under_get_rule(kVTCompressionPropertyKey_AverageBitRate as CFStringRef);
        VTSessionSetProperty(
            session,
            bitrate_key.as_concrete_TypeRef() as CFStringRef,
            CFNumber::from(opts.bitrate as i64).as_concrete_TypeRef() as CFTypeRef,
        );

        let keyframe_key = CfString::wrap_under_get_rule(
            kVTCompressionPropertyKey_MaxKeyFrameInterval as CFStringRef,
        );
        VTSessionSetProperty(
            session,
            keyframe_key.as_concrete_TypeRef() as CFStringRef,
            CFNumber::from(opts.keyframe_interval.unwrap_or(60) as i32).as_concrete_TypeRef()
                as CFTypeRef,
        );

        let realtime_key =
            CfString::wrap_under_get_rule(kVTCompressionPropertyKey_RealTime as CFStringRef);
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

        let (reader, output) =
            super::reader::open_video_reader(input_path, plan.out_w, plan.out_h)?;
        if !reader.startReading() {
            VTCompressionSessionInvalidate(session);
            CFRelease(session as CFTypeRef);
            return Err(MediaError::Decode("AVAssetReader startReading 失败".into()));
        }

        let mut frame_index = 0usize;
        loop {
            let sample: Option<Retained<CMSampleBuffer>> =
                msg_send![&*output, copyNextSampleBuffer];
            let Some(sample_buf) = sample else {
                break;
            };

            let Some(pb) = (unsafe { sample_buf.image_buffer() }) else {
                continue;
            };
            let pb = CFRetained::as_ptr(&pb).as_ptr() as CVPixelBufferRef;

            let pts = CMTime {
                value: frame_index as i64,
                timescale: plan.fps as i32,
                flags: 1,
                epoch: 0,
            };
            let dur = CMTime {
                value: 1,
                timescale: plan.fps as i32,
                flags: 1,
                epoch: 0,
            };
            let mut info_flags: VTEncodeInfoFlags = 0;
            let st = VTCompressionSessionEncodeFrame(
                session,
                pb,
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
                    msg: format!(
                        "VTCompressionSessionEncodeFrame frame {frame_index} (info_flags=0x{info_flags:x})"
                    ),
                });
            }
            sink.on_frame_submitted()?;
            frame_index += 1;
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
        sink.wait_until_drained()?;

        VTCompressionSessionInvalidate(session);
        CFRelease(session as CFTypeRef);
    }

    if sink.frames_submitted() == 0 {
        return Err(MediaError::Decode("未能解码任何视频帧".into()));
    }

    let (frames, vps, sps, pps) = {
        let mut guard = sink
            .inner
            .lock()
            .map_err(|_| MediaError::Encode("VideoToolbox 编码状态锁失败".into()))?;
        let codec = guard.output.codec();
        let frame_duration = guard.output.frame_duration();
        std::mem::replace(
            &mut guard.output,
            EncodedFrameCollector::new(codec, frame_duration),
        )
        .finish()
    };

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

extern "C" fn compression_output_callback(
    refcon: *mut c_void,
    _src_ref: *mut c_void,
    status: OSStatus,
    info_flags: VTEncodeInfoFlags,
    sample: *mut c_void,
) {
    let sink = unsafe { &*(refcon as *const EncodeSink) };

    if status != 0 || sample.is_null() || (info_flags & kVTEncodeInfo_FrameDropped) != 0 {
        sink.finish_callback();
        return;
    }

    let sbuf = unsafe { &*(sample as *const CMSampleBuffer) };

    if let Ok(mut inner) = sink.inner.lock() {
        let is_key = sample_is_keyframe(sbuf);
        if is_key {
            extract_format_param_sets(sbuf, &mut inner.output);
        }

        if let Some(block) = unsafe { sbuf.data_buffer() } {
            let mut total = 0usize;
            let mut data_ptr: *mut i8 = ptr::null_mut();
            let st = unsafe { block.data_pointer(0, ptr::null_mut(), &mut total, &mut data_ptr) };
            if st == 0 && !data_ptr.is_null() && total > 0 {
                let avcc =
                    unsafe { std::slice::from_raw_parts(data_ptr as *const u8, total).to_vec() };
                inner
                    .output
                    .push_access_unit(avcc_to_annex_b(&avcc), is_key);
            }
        }
    }

    sink.finish_callback();
}

/// VT 输出帧：`NotSync` 附件缺失或为 false 时表示关键帧。
fn sample_is_keyframe(sample: &CMSampleBuffer) -> bool {
    let key = CfString::new("NotSync");
    let att = unsafe {
        CMGetAttachment(
            sample as *const CMSampleBuffer as CFTypeRef,
            key.as_concrete_TypeRef(),
            ptr::null_mut(),
        )
    };
    if att.is_null() {
        return true;
    }
    let is_key = unsafe {
        if CFGetTypeID(att) != CFBoolean::type_id() {
            true
        } else {
            let is_not_sync: bool = CFBoolean::wrap_under_get_rule(att as _).into();
            !is_not_sync
        }
    };
    unsafe { CFRelease(att) };
    is_key
}

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMGetAttachment(
        target: CFTypeRef,
        key: CFStringRef,
        attachment_mode_out: *mut u32,
    ) -> CFTypeRef;
}

fn extract_format_param_sets(sample: &CMSampleBuffer, output: &mut EncodedFrameCollector) {
    let Some(fmt) = (unsafe { sample.format_description() }) else {
        return;
    };
    let fmt = fmt.as_ref();

    match output.codec() {
        VideoCodec::H264 if !output.param_sets_ready() => {
            let mut sps = Vec::new();
            let mut pps = Vec::new();
            let mut ptr: *const u8 = ptr::null();
            let mut len = 0usize;
            if unsafe {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt,
                    0,
                    &mut ptr,
                    &mut len,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            } == 0
                && !ptr.is_null()
            {
                sps.extend_from_slice(&[0u8, 0, 0, 1]);
                sps.extend_from_slice(unsafe { std::slice::from_raw_parts(ptr, len) });
            }
            if unsafe {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt,
                    1,
                    &mut ptr,
                    &mut len,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            } == 0
                && !ptr.is_null()
            {
                pps.extend_from_slice(&[0u8, 0, 0, 1]);
                pps.extend_from_slice(unsafe { std::slice::from_raw_parts(ptr, len) });
            }
            output.set_param_sets(Vec::new(), sps, pps);
        }
        VideoCodec::H265 if !output.param_sets_ready() => {
            let mut vps = Vec::new();
            let mut sps = Vec::new();
            let mut pps = Vec::new();
            let mut ptr: *const u8 = ptr::null();
            let mut len = 0usize;
            for (idx, target) in [(0, &mut vps), (1, &mut sps), (2, &mut pps)] {
                if unsafe {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt,
                        idx,
                        &mut ptr,
                        &mut len,
                        ptr::null_mut(),
                        ptr::null_mut(),
                    )
                } == 0
                    && !ptr.is_null()
                {
                    target.extend_from_slice(&[0u8, 0, 0, 1]);
                    target.extend_from_slice(unsafe { std::slice::from_raw_parts(ptr, len) });
                }
            }
            output.set_param_sets(vps, sps, pps);
        }
        _ => {}
    }
}
