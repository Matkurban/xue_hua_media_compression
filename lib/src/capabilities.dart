import 'image_format.dart';
import 'video_codec.dart';

/// 当前平台的图片编解码能力。
///
/// Still-image encode/decode capabilities of the current platform.
final class ImageCompressionCapabilities {
  /// 创建能力快照。
  ///
  /// Creates a capability snapshot.
  const ImageCompressionCapabilities({
    required this.inputFormats,
    required this.outputFormats,
  });

  /// 当前能解码的输入格式。
  ///
  /// Formats that can be decoded right now.
  final Set<ImageFormat> inputFormats;

  /// 当前能编码写出的格式。不在集合内的 format 调用 compress 会抛 `unsupported`。
  ///
  /// Formats that can be encoded. Compressing with any other format throws `unsupported`.
  final Set<ImageFormat> outputFormats;
}

/// 当前平台的视频编码能力。
///
/// Video-encode capabilities of the current platform.
final class VideoCompressionCapabilities {
  /// 创建能力快照。
  ///
  /// Creates a capability snapshot.
  const VideoCompressionCapabilities({
    required this.encoderName,
    required this.codecs,
    required this.acceptsContentUri,
  });

  /// 硬件编码器名称；没有硬编时为 null。软编仍可出现在 [codecs] 里。
  ///
  /// Hardware encoder name; null when no hardware encoder is available.
  /// Software encoders still appear in [codecs].
  final String? encoderName;

  /// 当前能编码的集合，包含可用的硬编和软编。
  ///
  /// Codecs that can be encoded right now, including software encoders.
  final Set<VideoCodec> codecs;

  /// 是否接受 Android `content://` 输入。仅 Android 为 true。
  ///
  /// Whether Android `content://` input is accepted. True only on Android.
  final bool acceptsContentUri;
}
