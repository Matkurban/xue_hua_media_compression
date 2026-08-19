import 'dart:typed_data';

import 'image_format.dart';
import 'video_codec.dart';

/// 图片压缩成功结果。
///
/// Successful still-image compression result.
final class ImageCompressResult {
  /// 创建结果。
  ///
  /// Creates a result.
  ///
  /// [bytes] 与 [outputPath] 按 destination 二选一非空。
  /// Exactly one of [bytes] or [outputPath] is non-null, matching the destination.
  const ImageCompressResult({
    this.bytes,
    this.outputPath,
    required this.sizeBytes,
    required this.format,
    required this.width,
    required this.height,
  });

  /// 内存输出时的压缩后字节；文件输出时为 null。
  ///
  /// Compressed bytes when the destination was memory; null for file output.
  final Uint8List? bytes;

  /// 文件输出路径；内存输出时为 null。
  ///
  /// Output file path; null for in-memory output.
  final String? outputPath;

  /// 输出体积（字节）。
  ///
  /// Output size in bytes.
  final int sizeBytes;

  /// 实际写出的格式。
  ///
  /// Format that was actually written.
  final ImageFormat format;

  /// 输出宽度（像素）。
  ///
  /// Output width in pixels.
  final int width;

  /// 输出高度（像素）。
  ///
  /// Output height in pixels.
  final int height;
}

/// 视频压缩成功结果。
///
/// Successful video compression result.
final class VideoCompressResult {
  /// 创建结果。
  ///
  /// Creates a result.
  const VideoCompressResult({
    required this.outputPath,
    required this.sizeBytes,
    required this.encoderName,
    required this.codec,
    required this.width,
    required this.height,
  });

  /// 输出 MP4 路径。
  ///
  /// Output MP4 path.
  final String outputPath;

  /// 输出体积（字节）。
  ///
  /// Output size in bytes.
  final int sizeBytes;

  /// 实际使用的编码器名称（如 `Media3Transformer`、`AVAssetWriter`）。
  ///
  /// Encoder that actually ran (e.g. `Media3Transformer`, `AVAssetWriter`).
  final String encoderName;

  /// 实际使用的编码。
  ///
  /// Codec that was actually used.
  final VideoCodec codec;

  /// 输出宽度（像素）。
  ///
  /// Output width in pixels.
  final int width;

  /// 输出高度（像素）。
  ///
  /// Output height in pixels.
  final int height;
}
