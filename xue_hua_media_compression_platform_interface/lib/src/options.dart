import 'image_format.dart';
import 'video_codec.dart';

/// 图片压缩参数。可变旋钮只放在本对象中。
///
/// Image compression parameters. Tunables live only on this object.
final class ImageCompressOptions {
  /// 创建图片选项。
  ///
  /// Creates image options.
  ///
  /// **参数 / Parameters**
  /// - [format]: 输出格式，默认 [ImageFormat.jpeg]。
  ///   Output format, default [ImageFormat.jpeg].
  /// - [quality]: 1–100，有损格式立即生效；PNG 忽略。默认 80。
  ///   1–100, applied immediately for lossy formats; ignored for PNG. Default 80.
  /// - [maxDimension]: 最长边像素；null 表示不缩放。必须 > 0。
  ///   Max edge in pixels; null means no scale. Must be > 0 when set.
  const ImageCompressOptions({
    this.format = ImageFormat.jpeg,
    this.quality = 80,
    this.maxDimension,
  });

  /// 目标输出格式。
  ///
  /// Target output format.
  final ImageFormat format;

  /// 质量 1–100。PNG 忽略。
  ///
  /// Quality 1–100. Ignored for PNG.
  final int quality;

  /// 等比缩放的最大边长（像素）。null 不缩放。
  ///
  /// Max edge length in pixels for proportional downscale. Null means no scale.
  final int? maxDimension;
}

/// 视频压缩参数。可变旋钮只放在本对象中。
///
/// Video compression parameters. Tunables live only on this object.
final class VideoCompressOptions {
  /// 创建视频选项。
  ///
  /// Creates video options.
  ///
  /// **参数 / Parameters**
  /// - [codec]: 默认 [VideoCodec.h264]。
  ///   Default [VideoCodec.h264].
  /// - [bitrate]: 目标平均视频码率，单位 bps，默认 2_000_000。必须 > 0。
  ///   Target average video bitrate in bps, default 2_000_000. Must be > 0.
  /// - [fps]: 目标帧率；null 沿用源帧率。必须 > 0。
  ///   Target frame rate; null keeps the source rate. Must be > 0 when set.
  /// - [maxDimension]: 最长边像素；null 不缩放。必须 > 0。
  ///   Max edge in pixels; null means no scale. Must be > 0 when set.
  /// - [keyframeInterval]: GOP（帧）；null 使用平台默认。必须 > 0。
  ///   GOP size in frames; null uses the platform default. Must be > 0 when set.
  const VideoCompressOptions({
    this.codec = VideoCodec.h264,
    this.bitrate = 2000000,
    this.fps,
    this.maxDimension,
    this.keyframeInterval,
  });

  /// 目标编码。
  ///
  /// Target codec.
  final VideoCodec codec;

  /// 目标平均码率（bps）。
  ///
  /// Target average bitrate in bits per second.
  final int bitrate;

  /// 目标帧率。null 表示沿用源。
  ///
  /// Target FPS. Null keeps the source FPS.
  final int? fps;

  /// 等比缩放最大边长。null 不缩放。
  ///
  /// Max edge for proportional downscale. Null means no scale.
  final int? maxDimension;

  /// 关键帧间隔（帧）。null 为平台默认。
  ///
  /// Keyframe interval in frames. Null uses the platform default.
  final int? keyframeInterval;
}
