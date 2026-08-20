import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'capabilities.dart';
import 'compression_session.dart';
import 'image_format.dart';
import 'media_compression_exception.dart';
import 'media_destination.dart';
import 'media_source.dart';
import 'method_channel_media_compression.dart';
import 'options.dart';
import 'results.dart';
import 'video_codec.dart';

/// 平台接口。新方法默认抛 [UnimplementedError]。
///
/// Platform interface. New methods throw [UnimplementedError] by default.
abstract class MediaCompressionPlatform extends PlatformInterface {
  /// 构造子类时传入 token。
  ///
  /// Passes the token when constructing a subclass.
  MediaCompressionPlatform() : super(token: _token);

  static final Object _token = Object();

  static MediaCompressionPlatform _instance = MethodChannelMediaCompression();

  /// 当前平台实现。测试可替换。
  ///
  /// The current platform implementation. Tests may replace this.
  static MediaCompressionPlatform get instance => _instance;

  static set instance(MediaCompressionPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// 查询当前平台的图片编解码能力。
  ///
  /// Queries still-image encode/decode capabilities of this platform.
  ///
  /// **接收 / Receives** 无参数。No parameters.
  ///
  /// **返回 / Returns** [ImageCompressionCapabilities]。
  ///
  /// **抛出 / Throws** [MediaCompressionException] 当探测失败。
  Future<ImageCompressionCapabilities> queryImageCapabilities() {
    throw UnimplementedError(
      'queryImageCapabilities() has not been implemented.',
    );
  }

  /// 开始一次图片压缩会话。
  ///
  /// Starts a still-image compression session.
  ///
  /// **接收 / Receives**
  /// [source]、[destination]、[options]，含义见门面 [XueHuaImageCompression.compress]。
  ///
  /// **返回 / Returns** 立即返回 [CompressionSession]。
  CompressionSession<ImageCompressResult> compressImage({
    required MediaSource source,
    required MediaDestination destination,
    required ImageCompressOptions options,
  }) {
    throw UnimplementedError('compressImage() has not been implemented.');
  }

  /// 查询当前平台的视频硬编能力。
  ///
  /// Queries hardware video-encode capabilities of this platform.
  Future<VideoCompressionCapabilities> queryVideoCapabilities() {
    throw UnimplementedError(
      'queryVideoCapabilities() has not been implemented.',
    );
  }

  /// 开始一次视频压缩会话。
  ///
  /// Starts a video compression session.
  CompressionSession<VideoCompressResult> compressVideo({
    required String inputPath,
    required String outputPath,
    required VideoCompressOptions options,
  }) {
    throw UnimplementedError('compressVideo() has not been implemented.');
  }
}

/// 校验图片参数；非法时抛 [ArgumentError]。
///
/// Validates image arguments; throws [ArgumentError] when invalid.
void validateImageArgs({
  required MediaSource source,
  required MediaDestination destination,
  required ImageCompressOptions options,
}) {
  if (options.quality < 1 || options.quality > 100) {
    throw ArgumentError.value(
      options.quality,
      'options.quality',
      'must be in 1–100',
    );
  }
  final maxDimension = options.maxDimension;
  if (maxDimension != null && maxDimension <= 0) {
    throw ArgumentError.value(
      maxDimension,
      'options.maxDimension',
      'must be > 0',
    );
  }
  switch (source) {
    case MediaSourceBytes(:final bytes):
      if (bytes.isEmpty) {
        throw ArgumentError.value(bytes, 'source.bytes', 'must not be empty');
      }
    case MediaSourcePath(:final path):
      if (path.trim().isEmpty) {
        throw ArgumentError.value(path, 'source.path', 'must not be empty');
      }
  }
  switch (destination) {
    case MediaDestinationBytes():
      break;
    case MediaDestinationPath(:final path):
      if (path.trim().isEmpty) {
        throw ArgumentError.value(
          path,
          'destination.path',
          'must not be empty',
        );
      }
  }
}

/// 校验视频参数；非法时抛 [ArgumentError]。
///
/// Validates video arguments; throws [ArgumentError] when invalid.
void validateVideoArgs({
  required String inputPath,
  required String outputPath,
  required VideoCompressOptions options,
}) {
  if (inputPath.trim().isEmpty) {
    throw ArgumentError.value(inputPath, 'inputPath', 'must not be empty');
  }
  if (outputPath.trim().isEmpty) {
    throw ArgumentError.value(outputPath, 'outputPath', 'must not be empty');
  }
  if (options.bitrate <= 0) {
    throw ArgumentError.value(
      options.bitrate,
      'options.bitrate',
      'must be > 0',
    );
  }
  final fps = options.fps;
  if (fps != null && fps <= 0) {
    throw ArgumentError.value(fps, 'options.fps', 'must be > 0');
  }
  final maxDimension = options.maxDimension;
  if (maxDimension != null && maxDimension <= 0) {
    throw ArgumentError.value(
      maxDimension,
      'options.maxDimension',
      'must be > 0',
    );
  }
  final keyframeInterval = options.keyframeInterval;
  if (keyframeInterval != null && keyframeInterval <= 0) {
    throw ArgumentError.value(
      keyframeInterval,
      'options.keyframeInterval',
      'must be > 0',
    );
  }
}

/// 将 [PlatformException] 译为 [MediaCompressionException]。
///
/// Translates a [PlatformException] into [MediaCompressionException].
MediaCompressionException exceptionFromPlatform(Object error) {
  if (error is MediaCompressionException) {
    return error;
  }
  if (error is PlatformException) {
    return MediaCompressionException(
      error.code,
      error.message ?? error.code,
      details: error.details?.toString(),
    );
  }
  return MediaCompressionException(
    MediaCompressionException.encode,
    error.toString(),
  );
}

/// 从 EventChannel 完成 payload 解析图片结果。
///
/// Parses an image result from an EventChannel completion payload.
ImageCompressResult imageResultFromMap(Map<Object?, Object?> map) {
  final formatName = map['format'] as String? ?? 'jpeg';
  final format = ImageFormatWire.tryParse(formatName) ?? ImageFormat.jpeg;
  final bytes = map['bytes'];
  return ImageCompressResult(
    bytes: bytes is Uint8List ? bytes : null,
    outputPath: map['outputPath'] as String?,
    sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    format: format,
    width: (map['width'] as num?)?.toInt() ?? 0,
    height: (map['height'] as num?)?.toInt() ?? 0,
  );
}

/// 从 EventChannel 完成 payload 解析视频结果。
///
/// Parses a video result from an EventChannel completion payload.
VideoCompressResult videoResultFromMap(Map<Object?, Object?> map) {
  final codecName = map['codec'] as String? ?? 'h264';
  final codec = VideoCodecWire.tryParse(codecName) ?? VideoCodec.h264;
  return VideoCompressResult(
    outputPath: map['outputPath'] as String? ?? '',
    sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    encoderName: map['encoderName'] as String? ?? '',
    codec: codec,
    width: (map['width'] as num?)?.toInt() ?? 0,
    height: (map['height'] as num?)?.toInt() ?? 0,
  );
}

/// 把线格式名列表译成枚举集合。
///
/// Parses a list of wire format names into an enum set.
Set<ImageFormat> imageFormatsFromWire(List<Object?> names) {
  return {
    for (final name in names)
      if (name is String) ImageFormatWire.tryParse(name),
  }.whereType<ImageFormat>().toSet();
}

/// 把线编码名列表译成枚举集合。
///
/// Parses a list of wire codec names into an enum set.
Set<VideoCodec> videoCodecsFromWire(List<Object?> names) {
  return {
    for (final name in names)
      if (name is String) VideoCodecWire.tryParse(name),
  }.whereType<VideoCodec>().toSet();
}
