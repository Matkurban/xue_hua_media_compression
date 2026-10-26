/// True for the plugin Mach-O, not for Dart kernel blobs that merely live
/// under a path containing the project name.
///
/// 只认插件自己的 Mach-O。工程目录名里就有插件名，不能靠子串去扫
/// `kernel_blob.bin` 这类 Dart 产物。
bool isDarwinPluginMachO(String path) {
  final segments = path
      .split(RegExp(r'[/\\]'))
      .where((String segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    return false;
  }
  const blocked = <String>{
    'app.framework',
    'flutter_assets',
    'kernel_blob.bin',
    'resources',
    'headers',
    'modules',
  };
  for (final segment in segments) {
    final lower = segment.toLowerCase();
    if (blocked.contains(lower) || lower.endsWith('.bin')) {
      return false;
    }
  }
  final name = segments.last;
  if (name == 'libxue_hua_media_compression.dylib') {
    return true;
  }
  return segments.contains('xue_hua_media_compression.framework') &&
      name == 'xue_hua_media_compression';
}
