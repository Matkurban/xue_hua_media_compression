//! Non-Apple stub so `frb_generated` can reference `platform::apple` on every target.

use crate::api::traits::{MediaError, VideoCompressor, VideoOptions, VideoResult};

#[flutter_rust_bridge::frb(opaque)]
pub(crate) struct AppleVideoCompressor;

impl AppleVideoCompressor {
    pub(crate) fn backend_name() -> &'static str {
        "VideoToolbox"
    }

    pub(crate) fn compress(
        _input_path: &str,
        _output_path: &str,
        _opts: &VideoOptions,
    ) -> Result<VideoResult, MediaError> {
        Err(MediaError::HardwareUnavailable(
            "VideoToolbox is only available on iOS and macOS".into(),
        ))
    }
}

impl VideoCompressor for AppleVideoCompressor {
    fn compress(
        input_path: &str,
        output_path: &str,
        opts: &VideoOptions,
    ) -> Result<VideoResult, MediaError> {
        Self::compress(input_path, output_path, opts)
    }
}
