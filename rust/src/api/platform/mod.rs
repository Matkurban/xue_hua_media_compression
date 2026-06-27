//! 平台视频硬编路由。
//!
//! 这里用 `#[cfg(target_os = "...")]` 把 5 个平台的实现隔离开，并对外统一暴露
//! 一个类型别名 [`PlatformVideoCompressor`]。上层 `api::media` 只认这个别名，
//! 完全不感知具体平台。
//!
//! 每个平台模块都实现 [`crate::api::traits::VideoCompressor`]，
//! 并额外提供一个 `backend_name()` 关联函数用于诊断展示。

// ---------------------------------------------------------------------------
// Windows -> Media Foundation
// ---------------------------------------------------------------------------
#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub(crate) use windows::WindowsVideoCompressor as PlatformVideoCompressor;

// ---------------------------------------------------------------------------
// Apple (iOS / macOS) -> VideoToolbox
// ---------------------------------------------------------------------------
#[cfg(any(target_os = "ios", target_os = "macos"))]
#[path = "apple.rs"]
pub mod apple;
#[cfg(not(any(target_os = "ios", target_os = "macos")))]
#[path = "apple_stub.rs"]
pub mod apple;
#[cfg(any(target_os = "ios", target_os = "macos"))]
pub(crate) use apple::AppleVideoCompressor as PlatformVideoCompressor;

// ---------------------------------------------------------------------------
// Android -> AMediaCodec (libmediandk)
// ---------------------------------------------------------------------------
#[cfg(target_os = "android")]
pub mod android;
#[cfg(target_os = "android")]
mod android_context;
#[cfg(target_os = "android")]
mod android_file;
#[cfg(target_os = "android")]
pub(crate) use android::AndroidVideoCompressor as PlatformVideoCompressor;

// ---------------------------------------------------------------------------
// Linux -> VA-API
// ---------------------------------------------------------------------------
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub(crate) use linux::LinuxVideoCompressor as PlatformVideoCompressor;

// ---------------------------------------------------------------------------
// 兜底：其它/未知平台，提供一个总是返回错误的实现，保证全平台可编译。
// ---------------------------------------------------------------------------
#[cfg(not(any(
    target_os = "windows",
    target_os = "ios",
    target_os = "macos",
    target_os = "android",
    target_os = "linux",
)))]
mod unsupported {
    use crate::api::traits::{MediaError, VideoCompressor, VideoOptions, VideoResult};

    #[flutter_rust_bridge::frb(opaque)]
    pub(crate) struct UnsupportedVideoCompressor;

    impl UnsupportedVideoCompressor {
        pub(crate) fn backend_name() -> &'static str {
            "unsupported"
        }
    }

    impl VideoCompressor for UnsupportedVideoCompressor {
        fn compress(
            _input_path: &str,
            _output_path: &str,
            _opts: &VideoOptions,
        ) -> Result<VideoResult, MediaError> {
            Err(MediaError::HardwareUnavailable(
                "当前平台没有可用的硬件视频编码后端".into(),
            ))
        }
    }
}

#[cfg(not(any(
    target_os = "windows",
    target_os = "ios",
    target_os = "macos",
    target_os = "android",
    target_os = "linux",
)))]
pub(crate) use unsupported::UnsupportedVideoCompressor as PlatformVideoCompressor;
