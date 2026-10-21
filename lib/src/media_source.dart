import 'dart:typed_data';

/// 媒体输入位置：内存字节或路径。图片与视频共用这一套类型。
///
/// Where media is read from: in-memory bytes or a path. One type for both directions of "input".
sealed class MediaSource {
  const MediaSource._();

  /// 从内存字节读取。
  ///
  /// **接收 / Receives**
  /// [bytes]: 完整的原始媒体字节。不能为空。
  /// The complete raw media bytes. Must not be empty.
  ///
  /// **返回 / Returns**
  /// 一个 [MediaSource] 实例，压缩时由原生解码这些字节。
  /// A [MediaSource] that native code will decode from these bytes.
  factory MediaSource.bytes(Uint8List bytes) = MediaSourceBytes;

  /// 从路径读取。
  ///
  /// **接收 / Receives**
  /// [path]: 本地绝对路径、`file://` URI，或 Android 上的 `content://` URI。
  /// A local absolute path, a `file://` URI, or on Android a `content://` URI.
  ///
  /// **返回 / Returns**
  /// 一个 [MediaSource] 实例。非 Android 平台对 `content://` 会抛 `unsupported`。
  /// A [MediaSource]. Non-Android platforms throw `unsupported` for `content://`.
  factory MediaSource.path(String path) = MediaSourcePath;
}

/// 内存字节输入。
///
/// In-memory byte source.
final class MediaSourceBytes extends MediaSource {
  /// 见 [MediaSource.bytes]。
  ///
  /// See [MediaSource.bytes].
  const MediaSourceBytes(this.bytes) : super._();

  /// 原始字节。不得为空。
  ///
  /// Raw bytes. Must not be empty.
  final Uint8List bytes;
}

/// 路径输入。
///
/// Path / URI source.
final class MediaSourcePath extends MediaSource {
  /// 见 [MediaSource.path]。
  ///
  /// See [MediaSource.path].
  const MediaSourcePath(this.path) : super._();

  /// 本地路径、`file://` 或 Android `content://`。
  ///
  /// Local path, `file://`, or Android `content://`.
  final String path;
}
