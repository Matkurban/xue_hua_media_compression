//! 纯 Rust 图片压缩实现（全平台通用）。
//!
//! - JPEG / PNG / GIF: 走 `image` crate 编解码；WebP 有损编码走 `zenwebp`；PNG→PNG 时用 `oxipng` 做无损优化。
//! - AVIF: 用 `ravif`（rav1e）编码。
//! - HEIC/HEIF: 用 `libheif-rs`（封装 C++ libheif），仅在打开 `heic` feature 时启用
//!   （需目标平台存在系统 libheif；移动端构建用 `--features heic`）。
//!
//! 设计为无状态：实现 [`ImageCompressor`] 这个 Trait 的静态方法。

use std::io::Cursor;

use image::{DynamicImage, ImageReader};

use crate::api::traits::{ImageCompressor, ImageFormat, ImageOptions, MediaError};

/// 全平台通用图片压缩器。
#[flutter_rust_bridge::frb(opaque)]
pub(crate) struct GenericImageCompressor;

impl ImageCompressor for GenericImageCompressor {
    fn compress(input: &[u8], opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
        // 快路径：PNG 输入 → PNG 输出且无缩放，直接 oxipng 优化，避免 decode/re-encode。
        if opts.format == ImageFormat::Png
            && opts.max_dimension.is_none()
            && is_png(input)
        {
            return optimize_png_bytes(input, opts);
        }

        // 1) 解码（HEIC 输入需先单独处理，因为 `image` 不支持 HEIC 解码）。
        let mut img = decode_any(input)?;

        // 2) 可选等比缩放。
        if let Some(max) = opts.max_dimension {
            img = downscale_to_max(img, max);
        }

        // 3) 按目标格式编码。
        match opts.format {
            ImageFormat::Jpeg => encode_jpeg(&img, opts.quality),
            ImageFormat::Png => encode_png(&img),
            ImageFormat::WebP => encode_webp(&img, opts),
            ImageFormat::Gif => encode_gif(&img),
            ImageFormat::Avif => encode_avif(&img, opts),
            ImageFormat::Heic => encode_heic(&img, opts),
        }
    }
}

// ============================================================================
// 解码
// ============================================================================

/// 尝试解码任意受支持的输入字节。优先用 `image`，失败再尝试 HEIC。
fn decode_any(input: &[u8]) -> Result<DynamicImage, MediaError> {
    // `image` 能根据魔数自动识别 JPEG/PNG/WebP/GIF 等。
    match ImageReader::new(Cursor::new(input))
        .with_guessed_format()
        .map_err(|e| MediaError::Decode(e.to_string()))?
        .decode()
    {
        Ok(img) => Ok(img),
        Err(_) => decode_heic(input),
    }
}

// ============================================================================
// 通用格式编码（image / oxipng）
// ============================================================================

fn encode_jpeg(img: &DynamicImage, quality: u8) -> Result<Vec<u8>, MediaError> {
    use image::codecs::jpeg::JpegEncoder;
    let rgb = img.to_rgb8();
    let mut out = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut out, quality.clamp(1, 100));
    enc.encode(
        rgb.as_raw(),
        rgb.width(),
        rgb.height(),
        image::ExtendedColorType::Rgb8,
    )
    .map_err(|e| MediaError::Encode(e.to_string()))?;
    Ok(out)
}

fn encode_png(img: &DynamicImage) -> Result<Vec<u8>, MediaError> {
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    Ok(out)
}

fn is_png(input: &[u8]) -> bool {
    input.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

fn oxipng_options(opts: &ImageOptions) -> oxipng::Options {
    // 复用 speed 字段（1=慢/小，10=快/大），映射到 oxipng preset 1~4。
    let preset = match opts.speed.unwrap_or(6) {
        1..=3 => 4,
        4..=6 => 2,
        _ => 1,
    };
    oxipng::Options::from_preset(preset)
}

fn optimize_png_bytes(input: &[u8], opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    oxipng::optimize_from_memory(input, &oxipng_options(opts))
        .map_err(|e| MediaError::Encode(format!("oxipng: {e}")))
}

fn webp_method_from_speed(speed: Option<u8>) -> u8 {
    let s = speed.unwrap_or(6).clamp(1, 10);
    // speed 10 → method 0；speed 6 → method 4；speed 1 → method 6
    ((10 - s) as u16 * 6 / 9) as u8
}

fn encode_webp(img: &DynamicImage, opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    use zenwebp::{EncodeRequest, LossyConfig, PixelLayout};

    let quality = opts.quality.clamp(1, 100) as f32;
    let config = LossyConfig::new()
        .with_quality(quality)
        .with_method(webp_method_from_speed(opts.speed));

    if img.color().has_alpha() {
        let rgba = img.to_rgba8();
        EncodeRequest::lossy(
            &config,
            rgba.as_raw(),
            PixelLayout::Rgba8,
            rgba.width(),
            rgba.height(),
        )
        .encode()
    } else {
        let rgb = img.to_rgb8();
        EncodeRequest::lossy(
            &config,
            rgb.as_raw(),
            PixelLayout::Rgb8,
            rgb.width(),
            rgb.height(),
        )
        .encode()
    }
    .map_err(|e| MediaError::Encode(format!("zenwebp: {e}")))
}

fn encode_gif(img: &DynamicImage) -> Result<Vec<u8>, MediaError> {
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), image::ImageFormat::Gif)
        .map_err(|e| MediaError::Encode(e.to_string()))?;
    Ok(out)
}

// ============================================================================
// AVIF 编码（ravif）
// ============================================================================

fn encode_avif(img: &DynamicImage, opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    use ravif::{Encoder, Img};
    use rgb::FromSlice;

    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);

    let encoded = Encoder::new()
        .with_quality(opts.quality as f32)
        .with_speed(opts.speed.unwrap_or(6).clamp(1, 10))
        .encode_rgba(Img::new(rgba.as_raw().as_rgba(), w, h))
        .map_err(|e| MediaError::Encode(format!("ravif: {e}")))?;

    Ok(encoded.avif_file)
}

// ============================================================================
// HEIC/HEIF 编码与解码（libheif-rs，仅移动端 + macOS）
// ============================================================================

#[cfg(feature = "heic")]
fn decode_heic(input: &[u8]) -> Result<DynamicImage, MediaError> {
    use libheif_rs::{ColorSpace, HeifContext, LibHeif, RgbChroma};

    let lib_heif = LibHeif::new();
    let ctx = HeifContext::read_from_bytes(input)
        .map_err(|e| MediaError::Decode(format!("libheif read: {e}")))?;
    let handle = ctx
        .primary_image_handle()
        .map_err(|e| MediaError::Decode(format!("libheif handle: {e}")))?;

    let image = lib_heif
        .decode(&handle, ColorSpace::Rgb(RgbChroma::Rgba), None)
        .map_err(|e| MediaError::Decode(format!("libheif decode: {e}")))?;

    let planes = image.planes();
    let interleaved = planes
        .interleaved
        .ok_or_else(|| MediaError::Decode("libheif: 缺少 interleaved plane".into()))?;

    let width = interleaved.width;
    let height = interleaved.height;
    let stride = interleaved.stride;
    let data = interleaved.data;

    // 去掉行 padding，拷贝成紧凑的 RGBA buffer。
    let mut buf = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height as usize {
        let row = &data[y * stride..y * stride + (width as usize) * 4];
        buf.extend_from_slice(row);
    }

    let rgba = image::RgbaImage::from_raw(width, height, buf)
        .ok_or_else(|| MediaError::Decode("libheif: RGBA 构造失败".into()))?;
    Ok(DynamicImage::ImageRgba8(rgba))
}

#[cfg(not(feature = "heic"))]
fn decode_heic(_input: &[u8]) -> Result<DynamicImage, MediaError> {
    Err(MediaError::UnsupportedFormat(
        "HEIC 解码未启用：请在构建时打开 `heic` feature（需系统 libheif）".into(),
    ))
}

#[cfg(feature = "heic")]
fn encode_heic(img: &DynamicImage, opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    use libheif_rs::{
        Channel, ColorSpace, CompressionFormat, EncoderQuality, HeifContext, Image, LibHeif,
        RgbChroma,
    };

    let lib_heif = LibHeif::new();
    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());

    let mut heif_img = Image::new(w, h, ColorSpace::Rgb(RgbChroma::Rgba))
        .map_err(|e| MediaError::Encode(format!("libheif new image: {e}")))?;
    heif_img
        .create_plane(Channel::Interleaved, w, h, 8)
        .map_err(|e| MediaError::Encode(format!("libheif plane: {e}")))?;

    {
        let planes = heif_img.planes_mut();
        let plane = planes
            .interleaved
            .ok_or_else(|| MediaError::Encode("libheif: 无 interleaved plane".into()))?;
        let stride = plane.stride;
        let dst = plane.data;
        for y in 0..h as usize {
            let src = &rgba.as_raw()[y * (w as usize) * 4..(y + 1) * (w as usize) * 4];
            dst[y * stride..y * stride + (w as usize) * 4].copy_from_slice(src);
        }
    }

    let mut ctx =
        HeifContext::new().map_err(|e| MediaError::Encode(format!("libheif ctx: {e}")))?;
    let mut encoder = lib_heif
        .encoder_for_format(CompressionFormat::Hevc)
        .map_err(|e| MediaError::Encode(format!("libheif encoder: {e}")))?;
    encoder
        .set_quality(EncoderQuality::Lossy(opts.quality))
        .map_err(|e| MediaError::Encode(format!("libheif quality: {e}")))?;

    ctx.encode_image(&heif_img, &mut encoder, None)
        .map_err(|e| MediaError::Encode(format!("libheif encode: {e}")))?;

    ctx.write_to_bytes()
        .map_err(|e| MediaError::Encode(format!("libheif write: {e}")))
}

#[cfg(not(feature = "heic"))]
fn encode_heic(_img: &DynamicImage, _opts: &ImageOptions) -> Result<Vec<u8>, MediaError> {
    Err(MediaError::UnsupportedFormat(
        "HEIC 编码未启用：请在构建时打开 `heic` feature（需系统 libheif）".into(),
    ))
}

// ============================================================================
// 工具
// ============================================================================

/// 把图片等比缩放，使其最长边不超过 `max`。
fn downscale_to_max(img: DynamicImage, max: u32) -> DynamicImage {
    let (w, h) = (img.width(), img.height());
    if w.max(h) <= max {
        return img;
    }
    img.resize(max, max, image::imageops::FilterType::Lanczos3)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn make_jpeg_bytes() -> Vec<u8> {
        let img = image::RgbaImage::from_fn(64, 64, |x, y| {
            image::Rgba([
                (x * 4) as u8,
                (y * 4) as u8,
                128,
                255,
            ])
        });
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85)
            .encode(
                DynamicImage::ImageRgba8(img).to_rgb8().as_raw(),
                64,
                64,
                image::ExtendedColorType::Rgb8,
            )
            .unwrap();
        out
    }

    fn make_png_bytes() -> Vec<u8> {
        let img = image::RgbaImage::from_fn(64, 64, |x, y| {
            image::Rgba([
                (x * 4) as u8,
                (y * 4) as u8,
                128,
                255,
            ])
        });
        let mut out = Vec::new();
        DynamicImage::ImageRgba8(img)
            .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
            .unwrap();
        out
    }

    #[test]
    fn is_png_detects_magic_bytes() {
        assert!(is_png(&make_png_bytes()));
        assert!(!is_png(&make_jpeg_bytes()));
        assert!(!is_png(&[]));
    }

    #[test]
    fn jpeg_to_png_completes_quickly() {
        let input = make_jpeg_bytes();
        let opts = ImageOptions {
            format: ImageFormat::Png,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };

        let start = Instant::now();
        let out = GenericImageCompressor::compress(&input, &opts).unwrap();
        assert!(start.elapsed().as_secs() < 5);
        assert!(is_png(&out));
    }

    #[test]
    fn png_to_png_optimized_not_larger() {
        let input = make_png_bytes();
        let opts = ImageOptions {
            format: ImageFormat::Png,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };

        let out = GenericImageCompressor::compress(&input, &opts).unwrap();
        assert!(is_png(&out));
        assert!(out.len() <= input.len());
    }

    fn is_webp(bytes: &[u8]) -> bool {
        bytes.len() >= 12
            && &bytes[0..4] == b"RIFF"
            && &bytes[8..12] == b"WEBP"
    }

    #[test]
    fn jpeg_to_webp_output_is_webp() {
        let input = make_jpeg_bytes();
        let opts = ImageOptions {
            format: ImageFormat::WebP,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };

        let out = GenericImageCompressor::compress(&input, &opts).unwrap();
        assert!(is_webp(&out));
    }

    #[test]
    fn jpeg_to_webp_smaller_than_input() {
        let input = make_jpeg_bytes();
        let opts = ImageOptions {
            format: ImageFormat::WebP,
            quality: 80,
            max_dimension: None,
            speed: Some(6),
        };

        let out = GenericImageCompressor::compress(&input, &opts).unwrap();
        assert!(out.len() < input.len());
    }

    #[test]
    fn jpeg_to_webp_respects_quality() {
        let input = make_jpeg_bytes();
        let low = ImageOptions {
            format: ImageFormat::WebP,
            quality: 30,
            max_dimension: None,
            speed: Some(6),
        };
        let high = ImageOptions {
            format: ImageFormat::WebP,
            quality: 90,
            max_dimension: None,
            speed: Some(6),
        };

        let out_low = GenericImageCompressor::compress(&input, &low).unwrap();
        let out_high = GenericImageCompressor::compress(&input, &high).unwrap();
        assert!(out_low.len() < out_high.len());
    }
}
