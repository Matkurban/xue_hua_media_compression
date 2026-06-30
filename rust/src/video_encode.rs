//! 视频编码 prelude / epilogue：统一 scale、fps、GOP、frame_duration 与 mux 收尾。

use crate::api::traits::{MediaError, VideoOptions, VideoResult};
use crate::video::{finalize_to_mp4, frame_duration_for_fps, EncodedFrame};
use crate::video_input::VideoInput;
use crate::video_scale::scale_dims;

/// 平台 encode 前的统一计划（尺寸、帧率、GOP、时间基）。
pub(crate) struct EncodePlan {
    pub src_w: u32,
    pub src_h: u32,
    pub src_fps: u32,
    pub out_w: u32,
    pub out_h: u32,
    pub fps: u32,
    pub frame_duration: u32,
    pub keyframe_interval: u32,
}

pub(crate) fn plan_encode(
    input: &VideoInput,
    opts: &VideoOptions,
) -> Result<EncodePlan, MediaError> {
    let (src_w, src_h, src_fps) = input.dimensions()?;
    let (out_w, out_h) = scale_dims(src_w, src_h, opts.max_dimension);
    let fps = opts.fps.unwrap_or(src_fps).max(1);
    let frame_duration = frame_duration_for_fps(fps);
    let keyframe_interval = opts.keyframe_interval.unwrap_or(60).max(1);
    Ok(EncodePlan {
        src_w,
        src_h,
        src_fps,
        out_w,
        out_h,
        fps,
        frame_duration,
        keyframe_interval,
    })
}

pub(crate) fn finalize_encoded(
    output_path: &str,
    opts: &VideoOptions,
    plan: &EncodePlan,
    backend: &str,
    frames: &[EncodedFrame],
    vps: &[u8],
    sps: &[u8],
    pps: &[u8],
) -> Result<VideoResult, MediaError> {
    finalize_to_mp4(
        output_path,
        opts.codec,
        plan.out_w,
        plan.out_h,
        backend,
        frames,
        vps,
        sps,
        pps,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::video::TIMESCALE;

    #[test]
    fn frame_duration_matches_timescale() {
        assert_eq!(frame_duration_for_fps(30), TIMESCALE / 30);
        assert_eq!(frame_duration_for_fps(0), TIMESCALE);
    }
}
