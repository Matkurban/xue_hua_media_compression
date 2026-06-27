/// XueHuaMediaCompression 门面（Facade）。
///
/// flutter_rust_bridge 只能导出扁平的自由函数（如 `rustCompressImage`），
/// 这里把它们包装成符合插件命名规范的命名空间：
///   - `XueHuaMediaCompression.initialize()`            初始化
///   - `XueHuaMediaCompression.image.compress(...)`     图片压缩
///   - `XueHuaMediaCompression.video.compress(...)`     视频压缩
///
/// 用法：
/// ```dart
/// await XueHuaMediaCompression.initialize();
/// final out = await XueHuaMediaCompression.image.compress(
///   input: bytes,
///   format: ImageFormat.avif,
///   quality: 70,
/// );
/// ```
library;

import 'dart:typed_data';

export 'video_input.dart' show ensureLocalVideoInput;

import 'rust/api/media.dart' as rust;
import 'rust/api/traits.dart';
import 'rust/frb_generated.dart';

export 'rust/api/traits.dart'
    show
        ImageFormat,
        ImageOptions,
        VideoCodec,
        VideoOptions,
        VideoResult,
        MediaError;

/// 插件统一入口门面类。
class XueHuaMediaCompression {
  XueHuaMediaCompression._();

  static bool _initialized = false;

  /// 图片相关压缩方法的命名空间。
  static const XueHuaImageApi image = XueHuaImageApi._();

  /// 视频相关压缩方法的命名空间。
  static const XueHuaVideoApi video = XueHuaVideoApi._();

  /// 初始化插件（加载 Rust 动态库并执行 Rust 侧 init）。
  ///
  /// 幂等：重复调用只会初始化一次。
  static Future<void> initialize() async {
    if (_initialized) return;
    await RustLib.init();
    _initialized = true;
  }

  /// 当前平台所使用的视频硬件编码后端名称（诊断用）。
  static Future<String> videoBackendName() => rust.rustVideoBackendName();
}

/// 图片压缩命名空间：`XueHuaMediaCompression.image.xxx`。
class XueHuaImageApi {
  const XueHuaImageApi._();

  /// 内存到内存压缩图片。
  ///
  /// - [input] 原始图片字节。
  /// - [format] 目标输出格式。
  /// - [quality] 0-100，有损格式有效。
  /// - [maxDimension] 等比缩放的最大边长，null 表示不缩放。
  /// - [speed] AVIF/HEIC 编码速度；WebP method 档位；PNG→PNG oxipng 档位（1-10，越大越快）。
  Future<Uint8List> compress({
    required Uint8List input,
    ImageFormat format = ImageFormat.jpeg,
    int quality = 80,
    int? maxDimension,
    int? speed,
  }) {
    final opts = ImageOptions(
      format: format,
      quality: quality,
      maxDimension: maxDimension,
      speed: speed,
    );
    return rust.rustCompressImage(input: input, opts: opts);
  }

  /// 直接用一个 [ImageOptions] 压缩。
  Future<Uint8List> compressWith({
    required Uint8List input,
    required ImageOptions options,
  }) {
    return rust.rustCompressImage(input: input, opts: options);
  }

  /// 文件到文件压缩，返回输出文件字节数。
  Future<int> compressFile({
    required String inputPath,
    required String outputPath,
    ImageFormat format = ImageFormat.jpeg,
    int quality = 80,
    int? maxDimension,
    int? speed,
  }) async {
    final opts = ImageOptions(
      format: format,
      quality: quality,
      maxDimension: maxDimension,
      speed: speed,
    );
    final bytes = await rust.rustCompressImageFile(
      inputPath: inputPath,
      outputPath: outputPath,
      opts: opts,
    );
    return bytes.toInt();
  }
}

/// 视频压缩命名空间：`XueHuaMediaCompression.video.xxx`。
class XueHuaVideoApi {
  const XueHuaVideoApi._();

  /// 文件到文件压缩视频，使用平台原生硬件编码并封装为 MP4。
  ///
  /// - [inputPath] 源视频路径。
  /// - [outputPath] 输出 .mp4 路径。
  /// - [codec] 目标编码（H.264 / H.265）。
  /// - [bitrate] 目标平均码率（bps）。
  /// - [fps] 目标帧率，null 表示沿用源帧率。
  /// - [maxDimension] 等比缩放最大边长。
  /// - [keyframeInterval] GOP（帧）。
  Future<VideoResult> compress({
    required String inputPath,
    required String outputPath,
    VideoCodec codec = VideoCodec.h264,
    int bitrate = 2000000,
    int? fps,
    int? maxDimension,
    int? keyframeInterval,
  }) {
    final opts = VideoOptions(
      codec: codec,
      bitrate: bitrate,
      fps: fps,
      maxDimension: maxDimension,
      keyframeInterval: keyframeInterval,
    );
    return rust.rustCompressVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      opts: opts,
    );
  }

  /// 直接用一个 [VideoOptions] 压缩。
  Future<VideoResult> compressWith({
    required String inputPath,
    required String outputPath,
    required VideoOptions options,
  }) {
    return rust.rustCompressVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      opts: options,
    );
  }
}
