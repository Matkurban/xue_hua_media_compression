import 'package:xue_hua_media_compression_platform_interface/xue_hua_media_compression_platform_interface.dart';

/// 雪花媒体压缩插件入口。
///
/// Entry point for the XueHua media compression plugin.
///
/// 应用只依赖本门面。不支持 Web。
/// Apps depend on this facade only. Web is not supported.
abstract final class XueHuaMediaCompression {
  /// 图片压缩入口。
  ///
  /// Still-image compression entry point.
  static const XueHuaImageCompression image = XueHuaImageCompression();

  /// 视频压缩入口。
  ///
  /// Video compression entry point.
  static const XueHuaVideoCompression video = XueHuaVideoCompression();
}

/// 图片压缩 API。
///
/// Still-image compression API.
final class XueHuaImageCompression {
  /// 由 [XueHuaMediaCompression.image] 使用。
  ///
  /// Used by [XueHuaMediaCompression.image].
  const XueHuaImageCompression();

  /// 查询当前平台能解码 / 编码的图片格式。
  ///
  /// Queries which image formats this platform can decode / encode.
  ///
  /// **接收 / Receives**
  /// 无参数。探测发生在调用当下的设备与系统版本。
  /// No parameters. Detection uses the current device and OS version.
  ///
  /// **返回 / Returns**
  /// [ImageCompressionCapabilities]：`inputFormats` 为可解码集合，`outputFormats` 为可写出集合。
  /// [ImageCompressionCapabilities] with decode (`inputFormats`) and encode (`outputFormats`) sets.
  ///
  /// **抛出 / Throws**
  /// [MediaCompressionException] 当平台探测失败。
  /// [MediaCompressionException] if probing fails.
  Future<ImageCompressionCapabilities> queryCapabilities() {
    return MediaCompressionPlatform.instance.queryImageCapabilities();
  }

  /// 压缩一张静帧图片。
  ///
  /// Compresses a still image.
  ///
  /// **接收 / Receives**
  /// 从 [source] 读取原始图像，按 [options] 编码后写入 [destination]。
  /// Reads the image from [source], encodes it using [options], writes to [destination].
  ///
  /// **参数 / Parameters**
  /// - [source]: 内存字节或路径 / Android `content://`。
  ///   In-memory bytes, or a filesystem path / Android `content://` URI.
  /// - [destination]: `bytes()` 返回内存；`path()` 写文件并创建缺失的父目录。
  ///   `bytes()` returns memory; `path()` writes a file (parent dirs created).
  /// - [options]: 输出格式、质量 1–100、可选最大边长、可选保留 EXIF 元数据。
  ///   默认 JPEG / quality 80 / 不缩放 / 不保留元数据。
  ///   Output format, quality 1–100, optional max edge, optional EXIF
  ///   preservation. Defaults: JPEG, 80, no scale, metadata stripped.
  ///
  /// **返回 / Returns**
  /// 立即返回 [CompressionSession]。`await session.result` 得到 [ImageCompressResult]；
  /// `session.progress` 为 0.0–1.0，由原生产推。
  /// Returns a [CompressionSession] immediately. Await `session.result`; listen to `session.progress`.
  ///
  /// **抛出 / Throws**
  /// - [ArgumentError]: 空路径、空字节、quality 不在 1–100、`maxDimension <= 0`。
  /// - [MediaCompressionException.cancelled]: 调用了 [CompressionSession.cancel]。
  /// - [MediaCompressionException.unsupported]: 当前平台不能写出 [ImageCompressOptions.format]。
  /// - [MediaCompressionException.decode] / [encode] / [io] / [notFound]
  ///
  /// **平台 / Platforms**
  /// 编码能力见 README 矩阵。`quality` 对 PNG 忽略。`maxDimension` 在编码前立即生效。
  /// See the README matrix. `quality` is ignored for PNG. `maxDimension` applies before encode.
  CompressionSession<ImageCompressResult> compress({
    required MediaSource source,
    required MediaDestination destination,
    ImageCompressOptions options = const ImageCompressOptions(),
  }) {
    return MediaCompressionPlatform.instance.compressImage(
      source: source,
      destination: destination,
      options: options,
    );
  }
}

/// 视频压缩 API。输出始终为 MP4；默认保留音轨（AAC 透传或转码），
/// 可通过 [VideoCompressOptions.keepAudio] 关闭。
///
/// Video compression API. Output is always MP4; the audio track is kept by
/// default (AAC passthrough or transcode) and can be disabled via
/// [VideoCompressOptions.keepAudio].
final class XueHuaVideoCompression {
  /// 由 [XueHuaMediaCompression.video] 使用。
  ///
  /// Used by [XueHuaMediaCompression.video].
  const XueHuaVideoCompression();

  /// 查询当前平台的硬件视频编码能力。
  ///
  /// Queries hardware video-encode capabilities of this platform.
  ///
  /// **接收 / Receives**
  /// 无参数。
  /// No parameters.
  ///
  /// **返回 / Returns**
  /// [VideoCompressionCapabilities]：`encoderName` 无硬编时为 null；`codecs` 为可硬编集合；
  /// `acceptsContentUri` 仅 Android 为 true。
  /// [VideoCompressionCapabilities] with encoder name, codec set, and whether `content://` is accepted.
  ///
  /// **抛出 / Throws**
  /// [MediaCompressionException] 当探测失败。
  Future<VideoCompressionCapabilities> queryCapabilities() {
    return MediaCompressionPlatform.instance.queryVideoCapabilities();
  }

  /// 压缩一段视频为 MP4（默认保留音轨，可用 keepAudio 关闭）。
  ///
  /// Compresses a video to MP4 (audio kept by default, disable with
  /// keepAudio).
  ///
  /// **接收 / Receives**
  /// 从 [inputPath] 读取源视频，按 [options] 硬编后写入 [outputPath]。
  /// Reads the source from [inputPath], hardware-encodes with [options], writes [outputPath].
  ///
  /// **参数 / Parameters**
  /// - [inputPath]: 本地可读路径，或 Android `content://`。`file://` 会在 Dart 侧规范化。
  ///   A readable local path, or Android `content://`. `file://` is normalized in Dart.
  /// - [outputPath]: 目标 `.mp4` 路径。父目录由原生创建。
  ///   Destination `.mp4` path. Native code creates parent directories.
  /// - [options]: 编码、码率、可选帧率 / 最大边长 / GOP / 音轨保留。
  ///   默认 H.264 / 2 Mbps / 保留音轨。
  ///   Codec, bitrate, optional fps / max edge / GOP / audio retention.
  ///   Defaults: H.264, 2 Mbps, audio kept.
  ///
  /// **返回 / Returns**
  /// 立即返回 [CompressionSession]。`await session.result` 得到 [VideoCompressResult]。
  /// Returns a [CompressionSession] immediately. Await `session.result` for [VideoCompressResult].
  ///
  /// **抛出 / Throws**
  /// - [ArgumentError]: 空路径、bitrate / fps / maxDimension / keyframeInterval 非法。
  /// - [MediaCompressionException.cancelled]
  /// - [MediaCompressionException.unsupported] / [hardwareUnavailable]
  /// - [MediaCompressionException.decode] / [encode] / [mux] / [io] / [notFound]
  ///
  /// **平台 / Platforms**
  /// 各端硬编管线见 README。本次 compress 的码率 / 缩放立即生效。不支持 Web。
  /// See the README for per-platform pipelines. Bitrate / scale apply for this compress. No Web.
  CompressionSession<VideoCompressResult> compress({
    required String inputPath,
    required String outputPath,
    VideoCompressOptions options = const VideoCompressOptions(),
  }) {
    return MediaCompressionPlatform.instance.compressVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      options: options,
    );
  }
}
