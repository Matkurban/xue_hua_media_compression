import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/capabilities.dart';
import 'src/compression_session.dart';
import 'src/media_destination.dart';
import 'src/media_source.dart';
import 'src/options.dart';
import 'src/results.dart';
import 'xue_hua_media_compression_method_channel.dart';

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
