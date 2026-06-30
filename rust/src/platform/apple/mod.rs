//! Apple 端（iOS / macOS）视频硬编：VideoToolbox + AVAssetReader。
//!
//! - [`reader`] — AVAssetReader 解码 seam
//! - [`encode`] — VideoToolbox 硬编 + 输出回调
//! - [`metadata`] — 尺寸探测（MP4 / AVFoundation）

mod encode;
mod metadata;
mod reader;

pub(crate) use metadata::probe_dimensions;

pub(crate) fn backend_name() -> &'static str {
    "VideoToolbox"
}

pub(crate) fn compress_video(
    input: &crate::video_input::VideoInput,
    output_path: &str,
    opts: &crate::api::traits::VideoOptions,
) -> Result<crate::api::traits::VideoResult, crate::api::traits::MediaError> {
    encode::run(input, output_path, opts)
}
