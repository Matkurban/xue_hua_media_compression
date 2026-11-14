/// 规范化 picker / 文件系统路径后再下发给原生。
///
/// Normalizes picker / filesystem paths before sending them to native code.
///
/// - `content://` 原样保留（仅 Android 能打开）。
///   `content://` is kept as-is (Android only).
/// - `file://` 解码为平台路径。
///   `file://` is decoded to a platform path.
/// - 其它字符串 trim 后原样返回。
///   Any other string is trimmed and returned.
String normalizeInputPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  if (trimmed.startsWith('content://')) {
    return trimmed;
  }
  if (trimmed.startsWith('file://')) {
    return Uri.parse(trimmed).toFilePath();
  }
  return trimmed;
}

/// Per-job `@FlutterApi` suffix (`messageChannelSuffix` / registrar name).
String jobFlutterApiSuffix(int id) => 'job_$id';
