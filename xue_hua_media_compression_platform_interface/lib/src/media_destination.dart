/// 媒体输出位置：内存或文件路径。
///
/// Where compressed media is written: memory or a file path.
sealed class MediaDestination {
  const MediaDestination._();

  /// 将结果留在内存，由 [ImageCompressResult.bytes] 返回。
  ///
  /// Keep the result in memory, returned as [ImageCompressResult.bytes].
  factory MediaDestination.bytes() = MediaDestinationBytes;

  /// 写入文件。
  ///
  /// **接收 / Receives**
  /// [path]: 输出文件的本地绝对路径。父目录若不存在由原生创建。
  /// Absolute local output path. Native code creates missing parent directories.
  ///
  /// **返回 / Returns**
  /// 一个 [MediaDestination]；成功后 [ImageCompressResult.outputPath] 为该路径。
  /// A [MediaDestination]; on success [ImageCompressResult.outputPath] is this path.
  factory MediaDestination.path(String path) = MediaDestinationPath;
}

/// 内存输出。
///
/// In-memory destination.
final class MediaDestinationBytes extends MediaDestination {
  /// 见 [MediaDestination.bytes]。
  ///
  /// See [MediaDestination.bytes].
  const MediaDestinationBytes() : super._();
}

/// 文件输出。
///
/// File-path destination.
final class MediaDestinationPath extends MediaDestination {
  /// 见 [MediaDestination.path]。
  ///
  /// See [MediaDestination.path].
  const MediaDestinationPath(this.path) : super._();

  /// 输出文件绝对路径。
  ///
  /// Absolute output file path.
  final String path;
}
