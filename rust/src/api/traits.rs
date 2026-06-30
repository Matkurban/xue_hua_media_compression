//! 统一的压缩接口与跨语言共享的数据类型。
//!
//! 图片压缩由 `image::compress`、视频压缩由各 `platform::*::compress_video` free function 实现。
//! 上层 FRB 公共函数只经 `api::media` + `route` 路由，不导出实现类型到 Dart。

use thiserror::Error;

// ============================================================================
// 错误类型
// ============================================================================

/// 压缩过程中可能出现的错误。会被 FRB 自动映射为 Dart 端异常。
#[derive(Debug, Error)]
pub enum MediaError {
    #[error("不支持的格式: {0}")]
    UnsupportedFormat(String),

    #[error("解码失败: {0}")]
    Decode(String),

    #[error("编码失败: {0}")]
    Encode(String),

    #[error("当前平台不支持该硬件编码能力: {0}")]
    HardwareUnavailable(String),

    #[error("封装(MP4 mux)失败: {0}")]
    Mux(String),

    #[error("IO 错误: {0}")]
    Io(String),

    #[error("底层原生 API 调用失败 (code={code}): {msg}")]
    Native { code: i64, msg: String },
}

impl From<std::io::Error> for MediaError {
    fn from(e: std::io::Error) -> Self {
        MediaError::Io(e.to_string())
    }
}

// ============================================================================
// 图片相关类型
// ============================================================================

/// 目标图片格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Jpeg,
    Png,
    WebP,
    Gif,
    Heic,
    Avif,
}

/// 图片压缩参数。
#[derive(Debug, Clone)]
pub struct ImageOptions {
    /// 目标输出格式。
    pub format: ImageFormat,
    /// 质量 0-100（对有损格式 JPEG/WebP/AVIF/HEIC 有效）。
    pub quality: u8,
    /// 可选：等比缩放到的最大边长（像素）。`None` 表示不缩放。
    pub max_dimension: Option<u32>,
    /// 编码速度档位 1-10（对 AVIF/HEIC 为编码速度；对 WebP 为 method 档位，
    /// 越大越快、体积略大；对 PNG 输入→PNG 输出时为 oxipng 优化档位）。
    pub speed: Option<u8>,
}

impl Default for ImageOptions {
    fn default() -> Self {
        Self {
            format: ImageFormat::Jpeg,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        }
    }
}

// ============================================================================
// 视频相关类型
// ============================================================================

/// 目标视频编码。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264,
    H265,
}

/// 视频压缩参数。
#[derive(Debug, Clone)]
pub struct VideoOptions {
    /// 目标编码（H.264 / H.265）。
    pub codec: VideoCodec,
    /// 目标平均码率（bps）。
    pub bitrate: u32,
    /// 目标帧率。`None` 表示沿用源帧率。
    pub fps: Option<u32>,
    /// 可选：等比缩放到的最大边长（像素）。
    pub max_dimension: Option<u32>,
    /// 关键帧间隔（GOP，单位为帧）。
    pub keyframe_interval: Option<u32>,
}

impl Default for VideoOptions {
    fn default() -> Self {
        Self {
            codec: VideoCodec::H264,
            bitrate: 2_000_000,
            fps: None,
            max_dimension: None,
            keyframe_interval: Some(60),
        }
    }
}

/// 视频压缩结果。
#[derive(Debug, Clone)]
pub struct VideoResult {
    /// 输出文件路径。
    pub output_path: String,
    /// 输出文件大小（字节）。
    pub size_bytes: u64,
    /// 实际使用的编码后端（如 "MediaFoundation" / "VideoToolbox"）。
    pub backend: String,
    /// 输出视频宽高。
    pub width: u32,
    pub height: u32,
}
