//! 暴露给 flutter_rust_bridge 的顶层公共函数。
//!
//! FRB 只能导出扁平的自由函数，无法直接生成 `XueHua.image.xxx` 这种命名空间，
//! 因此这里导出 `rust_compress_image` / `rust_compress_video` 等扁平函数，
//! 由 Dart 侧的门面类 `XueHuaMediaCompression` 再包装成 `.image` / `.video` 命名空间。
//!
//! 路由逻辑：
//! - 图片：纯 Rust 实现 [`crate::api::image::GenericImageCompressor`]，全平台一致。
//! - 视频：根据编译目标用 `cfg` 绑定到对应平台的硬件编码器
//!   [`crate::api::platform::PlatformVideoCompressor`]。

use crate::api::file_input::{normalize_input_path, prepare_output_path};
use crate::api::image::GenericImageCompressor;
use crate::api::platform::PlatformVideoCompressor;
use crate::api::traits::{
    ImageCompressor, ImageOptions, MediaError, VideoCompressor, VideoOptions, VideoResult,
};

// ============================================================================
// 初始化
// ============================================================================

/// FRB 初始化钩子。Dart 端 `XueHuaMediaCompression.initialize()` 会触发它。
#[flutter_rust_bridge::frb(init)]
pub fn rust_init() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 返回当前平台所用的视频硬编后端名称，便于 Dart 侧诊断与展示。
pub fn rust_video_backend_name() -> String {
    PlatformVideoCompressor::backend_name().to_string()
}

// ============================================================================
// 图片：对外公共函数
// ============================================================================

/// 压缩图片。输入/输出均为内存字节。
///
/// - `input`: 原始图片字节（任意受支持的输入格式）。
/// - `opts` : 目标格式与质量等参数。
pub fn rust_compress_image(input: Vec<u8>, opts: ImageOptions) -> Result<Vec<u8>, MediaError> {
    GenericImageCompressor::compress(&input, &opts)
}

/// 便捷封装：直接读文件 -> 压缩 -> 写文件，返回输出文件字节数。
pub fn rust_compress_image_file(
    input_path: String,
    output_path: String,
    opts: ImageOptions,
) -> Result<u64, MediaError> {
    let input_path = normalize_input_path(&input_path)?;
    let bytes = std::fs::read(&input_path).map_err(|e| {
        MediaError::Io(format!(
            "无法读取输入图片 ({input_path}): {e}。\
             请确认路径可读（macOS 沙盒需通过文件选择器选取并配置 user-selected entitlement）"
        ))
    })?;
    let out = GenericImageCompressor::compress(&bytes, &opts)?;
    let output_path = prepare_output_path(&output_path)?;
    std::fs::write(&output_path, &out).map_err(|e| {
        MediaError::Io(format!("无法写入输出图片 ({output_path}): {e}"))
    })?;
    Ok(out.len() as u64)
}

// ============================================================================
// 视频：对外公共函数
// ============================================================================

/// 压缩视频：读取 `input_path`，用平台硬件编码器编码并封装为 MP4 写到 `output_path`。
pub fn rust_compress_video(
    input_path: String,
    output_path: String,
    opts: VideoOptions,
) -> Result<VideoResult, MediaError> {
    let input_path = normalize_input_path(&input_path)?;
    let output_path = prepare_output_path(&output_path)?;
    PlatformVideoCompressor::compress(&input_path, &output_path, &opts)
}

// ============================================================================
// 给 FRB 生成构造器的辅助函数（让 Dart 侧能方便地构造枚举/选项）
// ============================================================================

/// 构造默认图片选项（Dart 侧可直接拿到带默认值的结构体）。
pub fn rust_default_image_options() -> ImageOptions {
    ImageOptions::default()
}

/// 构造默认视频选项。
pub fn rust_default_video_options() -> VideoOptions {
    VideoOptions::default()
}
