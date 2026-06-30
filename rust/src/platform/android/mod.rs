//! Android 端视频硬编：NDK `AMediaCodec` + `AMediaExtractor`。
//!
//! - [`ndk`] — NDK FFI 与常量
//! - [`extractor`] — 容器打开与尺寸探测
//! - [`pipeline`] — 解码/编码 drain 循环

mod extractor;
mod ndk;
mod pipeline;

pub(crate) use extractor::probe_dimensions;

pub(crate) fn backend_name() -> &'static str {
    "AMediaCodec"
}

pub(crate) fn compress_video(
    input: &crate::video_input::VideoInput,
    output_path: &str,
    opts: &crate::api::traits::VideoOptions,
) -> Result<crate::api::traits::VideoResult, crate::api::traits::MediaError> {
    unsafe { pipeline::run(input, output_path, opts) }
}
