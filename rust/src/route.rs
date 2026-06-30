//! 压缩路由：连接 external seam（`api::media`）与内部 implementation。

use crate::api::traits::{ImageOptions, MediaError, VideoOptions, VideoResult};

pub(crate) fn compress_image(input: &[u8], opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    crate::image::compress(input, opts)
}

pub(crate) fn compress_video(
    input_path: &str,
    output_path: &str,
    opts: &VideoOptions,
) -> Result<VideoResult, MediaError> {
    let input = crate::video_input::VideoInput::open(input_path)?;
    crate::platform::compress_video(&input, output_path, opts)
}

pub(crate) fn video_backend_name() -> String {
    crate::platform::video_backend_name().to_string()
}
