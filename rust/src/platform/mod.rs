//! 平台视频硬编路由（free function dispatch，不在 FRB 扫描范围内）。

use crate::api::traits::{MediaError, VideoOptions, VideoResult};
use crate::video_input::VideoInput;

#[cfg(target_os = "android")]
pub(crate) mod android;
#[cfg(target_os = "android")]
pub(crate) mod android_file;
#[cfg(any(target_os = "ios", target_os = "macos"))]
pub(crate) mod apple;
#[cfg(target_os = "linux")]
pub(crate) mod linux;
#[cfg(target_os = "windows")]
pub(crate) mod windows;

pub(crate) fn compress_video(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    #[cfg(all(test, not(feature = "platform-tests")))]
    {
        return mock_compress_video(input, output_path, opts);
    }
    #[cfg(any(not(test), feature = "platform-tests"))]
    compress_video_platform(input, output_path, opts)
}

#[cfg(any(not(test), feature = "platform-tests"))]
fn compress_video_platform(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    #[cfg(target_os = "windows")]
    {
        return windows::compress_video(input, output_path, opts);
    }
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        return apple::compress_video(input, output_path, opts);
    }
    #[cfg(target_os = "android")]
    {
        return android::compress_video(input, output_path, opts);
    }
    #[cfg(target_os = "linux")]
    {
        return linux::compress_video(input, output_path, opts);
    }
    #[cfg(not(any(
        target_os = "windows",
        target_os = "ios",
        target_os = "macos",
        target_os = "android",
        target_os = "linux",
    )))]
    {
        Err(MediaError::HardwareUnavailable(
            "当前平台没有可用的硬件视频编码后端".into(),
        ))
    }
}

#[cfg(test)]
fn mock_compress_video(
    input: &VideoInput,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    use crate::video::frame_duration_for_fps;
    use crate::video_encode::{finalize_encoded, plan_encode, EncodePlan};
    use crate::video_frame_collector::EncodedFrameCollector;

    let plan = plan_encode(input, opts).unwrap_or_else(|_| {
        let (out_w, out_h) = opts
            .max_dimension
            .map(|d| (d & !1, d & !1))
            .unwrap_or((640, 480));
        let fps = opts.fps.unwrap_or(30).max(1);
        EncodePlan {
            src_w: out_w,
            src_h: out_h,
            src_fps: fps,
            out_w,
            out_h,
            fps,
            frame_duration: frame_duration_for_fps(fps),
            keyframe_interval: opts.keyframe_interval.unwrap_or(60).max(1),
        }
    });
    let mut collector = EncodedFrameCollector::new(opts.codec, plan.frame_duration);
    collector.push_access_unit(vec![0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00], true);
    let sps = [0u8, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f];
    let pps = [0u8, 0, 0, 1, 0x68, 0xce];
    collector.set_param_sets(Vec::new(), sps.to_vec(), pps.to_vec());
    let (frames, vps, sps_out, pps_out) = collector.finish();
    finalize_encoded(
        output_path,
        opts,
        &plan,
        "mock",
        &frames,
        &vps,
        &sps_out,
        &pps_out,
    )
}

pub(crate) fn probe_dimensions(input: &VideoInput) -> Result<(u32, u32, u32), MediaError> {
    #[cfg(target_os = "windows")]
    {
        return windows::probe_dimensions(input);
    }
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        return apple::probe_dimensions(input);
    }
    #[cfg(target_os = "android")]
    {
        return android::probe_dimensions(input);
    }
    #[cfg(target_os = "linux")]
    {
        return linux::probe_dimensions(input);
    }
    #[cfg(not(any(
        target_os = "windows",
        target_os = "ios",
        target_os = "macos",
        target_os = "android",
        target_os = "linux",
    )))]
    {
        Err(MediaError::Decode("当前平台不支持视频输入".into()))
    }
}

pub(crate) fn video_backend_name() -> &'static str {
    #[cfg(all(test, not(feature = "platform-tests")))]
    {
        return "mock";
    }
    #[cfg(any(not(test), feature = "platform-tests"))]
    video_backend_name_platform()
}

#[cfg(any(not(test), feature = "platform-tests"))]
fn video_backend_name_platform() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        return windows::backend_name();
    }
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        return apple::backend_name();
    }
    #[cfg(target_os = "android")]
    {
        return android::backend_name();
    }
    #[cfg(target_os = "linux")]
    {
        return linux::backend_name();
    }
    #[cfg(not(any(
        target_os = "windows",
        target_os = "ios",
        target_os = "macos",
        target_os = "android",
        target_os = "linux",
    )))]
    {
        "unsupported"
    }
}
