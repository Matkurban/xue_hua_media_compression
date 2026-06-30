//! 暴露给 flutter_rust_bridge 的顶层公共函数。
//!
//! FRB 只能导出扁平的自由函数，无法直接生成 `XueHua.image.xxx` 这种命名空间，
//! 因此这里导出 `rust_compress_image` / `rust_compress_video` 等扁平函数，
//! 由 Dart 侧的门面类 `XueHuaMediaCompression` 再包装成 `.image` / `.video` 命名空间。
//!
//! 内部路由见 [`crate::route`]（不在 FRB 扫描范围内）。

use crate::api::traits::{ImageOptions, MediaError, VideoOptions, VideoResult};
use crate::file_input::{normalize_input_path, prepare_output_path};

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
    crate::route::video_backend_name()
}

// ============================================================================
// 图片：对外公共函数
// ============================================================================

/// 压缩图片。输入/输出均为内存字节。
///
/// - `input`: 原始图片字节（任意受支持的输入格式）。
/// - `opts` : 目标格式与质量等参数。
pub fn rust_compress_image(input: Vec<u8>, opts: ImageOptions) -> Result<Vec<u8>, MediaError> {
    crate::route::compress_image(&input, &opts)
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
    let out = crate::route::compress_image(&bytes, &opts)?;
    let output_path = prepare_output_path(&output_path)?;
    std::fs::write(&output_path, &out)
        .map_err(|e| MediaError::Io(format!("无法写入输出图片 ({output_path}): {e}")))?;
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
    crate::route::compress_video(&input_path, &output_path, &opts)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::traits::{ImageFormat, VideoCodec};

    fn make_jpeg_bytes() -> Vec<u8> {
        let img = image::RgbaImage::from_fn(32, 32, |x, y| {
            image::Rgba([(x * 8) as u8, (y * 8) as u8, 128, 255])
        });
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85)
            .encode(
                image::DynamicImage::ImageRgba8(img).to_rgb8().as_raw(),
                32,
                32,
                image::ExtendedColorType::Rgb8,
            )
            .unwrap();
        out
    }

    fn is_webp(bytes: &[u8]) -> bool {
        bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP"
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("xue_media_seam_{name}_{}.bin", std::process::id()))
    }

    #[test]
    fn default_image_options_match_trait_default() {
        let opts = rust_default_image_options();
        assert_eq!(opts.format, ImageFormat::Jpeg);
        assert_eq!(opts.quality, 80);
        assert_eq!(opts.max_dimension, None);
        assert_eq!(opts.speed, Some(6));
    }

    #[test]
    fn default_video_options_match_trait_default() {
        let opts = rust_default_video_options();
        assert_eq!(opts.codec, VideoCodec::H264);
        assert_eq!(opts.bitrate, 2_000_000);
        assert_eq!(opts.fps, None);
        assert_eq!(opts.max_dimension, None);
        assert_eq!(opts.keyframe_interval, Some(60));
    }

    #[test]
    fn video_backend_name_uses_test_mock() {
        assert_eq!(rust_video_backend_name(), "mock");
    }

    #[test]
    fn compress_image_through_seam() {
        let input = make_jpeg_bytes();
        let opts = ImageOptions {
            format: ImageFormat::WebP,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };
        let out = rust_compress_image(input, opts).unwrap();
        assert!(is_webp(&out));
    }

    #[test]
    fn compress_image_file_through_seam() {
        let input_path = temp_path("in.jpg");
        let output_path = temp_path("out.webp");
        let _ = std::fs::remove_file(&input_path);
        let _ = std::fs::remove_file(&output_path);
        std::fs::write(&input_path, make_jpeg_bytes()).unwrap();

        let opts = ImageOptions {
            format: ImageFormat::WebP,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };
        let size = rust_compress_image_file(
            input_path.to_string_lossy().into_owned(),
            output_path.to_string_lossy().into_owned(),
            opts,
        )
        .unwrap();
        assert!(size > 0);
        let out = std::fs::read(&output_path).unwrap();
        assert!(is_webp(&out));

        let _ = std::fs::remove_file(input_path);
        let _ = std::fs::remove_file(output_path);
    }

    #[test]
    fn compress_video_through_seam_with_mock_backend() {
        let input_path = temp_path("in.mp4");
        let output_path = temp_path("out.mp4");
        let _ = std::fs::remove_file(&input_path);
        let _ = std::fs::remove_file(&output_path);
        std::fs::write(&input_path, b"not a real mp4").unwrap();

        let result = rust_compress_video(
            input_path.to_string_lossy().into_owned(),
            output_path.to_string_lossy().into_owned(),
            VideoOptions {
                max_dimension: Some(720),
                ..VideoOptions::default()
            },
        )
        .unwrap();

        assert_eq!(result.backend, "mock");
        assert_eq!(result.width, 720);
        assert_eq!(result.height, 720);
        assert!(result.size_bytes > 0);
        assert!(output_path.exists());

        let _ = std::fs::remove_file(input_path);
        let _ = std::fs::remove_file(output_path);
    }

    #[test]
    fn compress_video_missing_input_returns_decode_error() {
        let err = rust_compress_video(
            "/nonexistent/xue_media_seam_video.mp4".into(),
            temp_path("out.mp4").to_string_lossy().into_owned(),
            VideoOptions::default(),
        )
        .unwrap_err();
        assert!(matches!(err, MediaError::Decode(_)));
    }
}
