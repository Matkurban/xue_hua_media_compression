/// 压缩参数默认值与门面选项组装（单一来源，供 facade / 单测 / 文档对齐）。
library;

import 'rust/api/traits.dart';

/// 门面与 Rust `Default` / encode-time fallback 的默认常量。
abstract final class CompressionDefaults {
  /// 图片默认质量（0–100）。
  static const int imageQuality = 80;

  /// 图片默认输出格式。
  static const ImageFormat imageFormat = ImageFormat.jpeg;

  /// 视频默认编码。
  static const VideoCodec videoCodec = VideoCodec.h264;

  /// 视频默认码率（bps）。
  static const int videoBitrate = 2000000;

  /// Rust `ImageOptions::default().speed` 与 encode `unwrap_or(6)`。
  static const int rustImageSpeed = 6;

  /// Rust `VideoOptions::default().keyframe_interval` 与 encode `unwrap_or(60)`。
  static const int rustVideoKeyframeInterval = 60;
}

/// 门面默认参数组装（与 [XueHuaImageApi.compress] 一致；单测可断言同一映射）。
ImageOptions facadeImageOptions({
  ImageFormat format = CompressionDefaults.imageFormat,
  int quality = CompressionDefaults.imageQuality,
  int? maxDimension,
  int? speed,
}) {
  return ImageOptions(
    format: format,
    quality: quality,
    maxDimension: maxDimension,
    speed: speed,
  );
}

/// 门面默认参数组装（与 [XueHuaVideoApi.compress] 一致；单测可断言同一映射）。
VideoOptions facadeVideoOptions({
  VideoCodec codec = CompressionDefaults.videoCodec,
  int bitrate = CompressionDefaults.videoBitrate,
  int? fps,
  int? maxDimension,
  int? keyframeInterval,
}) {
  return VideoOptions(
    codec: codec,
    bitrate: bitrate,
    fps: fps,
    maxDimension: maxDimension,
    keyframeInterval: keyframeInterval,
  );
}
