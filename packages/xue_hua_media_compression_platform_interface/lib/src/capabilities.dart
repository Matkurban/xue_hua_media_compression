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

/// 当前平台的视频硬编能力。
///
/// Hardware video-encode capabilities of the current platform.
final class VideoCompressionCapabilities {
  /// 创建能力快照。
  ///
  /// Creates a capability snapshot.
  const VideoCompressionCapabilities({
    required this.encoderName,
    required this.codecs,
    required this.acceptsContentUri,
  });

  /// 硬件编码器名称；无法硬编时为 null。
  ///
  /// Hardware encoder name; null when HW encode is unavailable.
  final String? encoderName;

  /// 当前能硬编的编码集合。
  ///
  /// Codecs that can be hardware-encoded right now.
  final Set<VideoCodec> codecs;

  /// 是否接受 Android `content://` 输入。仅 Android 为 true。
  ///
  /// Whether Android `content://` input is accepted. True only on Android.
  final bool acceptsContentUri;
}
