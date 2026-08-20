/// 插件抛出的结构化异常。
///
/// Structured exception thrown by this plugin.
///
/// **错误码 / Error codes**（均为本类上的常量，禁止散落字符串）
///
/// - [instanceNotFound]: 会话 id 在原生侧已不存在。
///   The native job id is gone.
/// - [cancelled]: 调用方取消了会话。
///   The session was cancelled.
/// - [unsupported]: 当前平台没有该能力。
///   The current platform cannot perform this operation.
/// - [invalidState]: 能力存在，但当前状态不允许。
///   The capability exists but the current state forbids it.
/// - [notFound]: 路径或资源不存在。
///   The path or resource does not exist.
/// - [unsupportedFormat]: 输入或输出格式不受支持。
///   The input or output format is not supported.
/// - [decode]: 解码失败。
///   Decoding failed.
/// - [encode]: 编码失败。
///   Encoding failed.
/// - [hardwareUnavailable]: 没有可用的硬件编码器。
///   No hardware encoder is available.
/// - [mux]: 封装 MP4 失败。
///   Muxing the MP4 container failed.
/// - [io]: 文件读写失败。
///   File I/O failed.
final class MediaCompressionException implements Exception {
  /// 原生会话 id 已释放，但 Dart 会话仍在使用。
  ///
  /// The native job id has been released while the Dart session is still used.
  static const String instanceNotFound = 'instanceNotFound';

  /// 会话已被 [CompressionSession.cancel] 中止。
  ///
  /// The session was aborted by [CompressionSession.cancel].
  static const String cancelled = 'cancelled';

  /// 当前平台根本没有这条能力。
  ///
  /// The current platform does not provide this capability.
  static const String unsupported = 'unsupported';

  /// 能力有，但当前状态不允许。
  ///
  /// The capability exists but is not allowed in the current state.
  static const String invalidState = 'invalidState';

  /// 文件或资源不存在。
  ///
  /// The file or resource does not exist.
  static const String notFound = 'notFound';

  /// 输入或输出格式不受支持。
  ///
  /// The input or output format is not supported.
  static const String unsupportedFormat = 'unsupportedFormat';

  /// 解码失败。
  ///
  /// Decoding failed.
  static const String decode = 'decode';

  /// 编码失败。
  ///
  /// Encoding failed.
  static const String encode = 'encode';

  /// 没有可用的硬件视频编码器。
  ///
  /// No hardware video encoder is available.
  static const String hardwareUnavailable = 'hardwareUnavailable';

  /// MP4 封装失败。
  ///
  /// MP4 muxing failed.
  static const String mux = 'mux';

  /// 文件读写失败。
  ///
  /// File I/O failed.
  static const String io = 'io';

  /// 创建异常。
  ///
  /// Creates an exception.
  ///
  /// **参数 / Parameters**
  /// - [code]: 必须是本类上的常量之一。
  ///   Must be one of the constants on this class.
  /// - [message]: 人类可读说明（中或英均可）。
  ///   Human-readable description.
  /// - [details]: 可选平台细节。
  ///   Optional platform-specific details.
  const MediaCompressionException(this.code, this.message, {this.details});

  /// 稳定错误码。
  ///
  /// Stable error code.
  final String code;

  /// 说明文字。
  ///
  /// Description.
  final String message;

  /// 可选的平台附加信息。
  ///
  /// Optional platform extra.
  final String? details;

  @override
  String toString() {
    if (details == null || details!.isEmpty) {
      return 'MediaCompressionException($code, $message)';
    }
    return 'MediaCompressionException($code, $message, details: $details)';
  }
}
