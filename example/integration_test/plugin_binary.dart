/// True for a native image that actually contains the Darwin plugin.
///
/// Flutter SPM macOS links the plugin into the app's companion
/// `*.debug.dylib` next to the executable. CocoaPods builds may still emit
/// `xue_hua_media_compression.framework` or
/// `xue_hua_media_compression_darwin.framework`. Dart kernel blobs are never
/// native images, even when the project directory name appears in their path.
///
/// 认真正链进插件的原生镜像。Flutter SPM 的 macOS 把插件链进可执行文件旁边的
/// `*.debug.dylib`。CocoaPods 仍可能产出 framework。工程目录名出现在路径里
/// 也不能把 `kernel_blob.bin` 当成原生库。
bool isDarwinPluginMachO(String path) {
  final segments = _pathSegments(path);
  if (segments.isEmpty || _isBundleAsset(segments)) {
    return false;
  }
  final name = segments.last;
  final lower = name.toLowerCase();
  if (lower.endsWith('.debug.dylib')) {
    return true;
  }
  if (name == 'libxue_hua_media_compression.dylib') {
    return true;
  }
  const binaries = <String, String>{
    'xue_hua_media_compression.framework': 'xue_hua_media_compression',
    'xue_hua_media_compression_darwin.framework':
        'xue_hua_media_compression_darwin',
  };
  for (final entry in binaries.entries) {
    if (segments.contains(entry.key) && name == entry.value) {
      return true;
    }
  }
  return false;
}

/// Bundle resources that must not be scanned for linked codecs.
///
/// 不能拿来查链接库的包内资源。
bool isDarwinBundleAsset(String path) {
  final segments = _pathSegments(path);
  return segments.isEmpty || _isBundleAsset(segments);
}

List<String> _pathSegments(String path) {
  return path
      .split(RegExp(r'[/\\]'))
      .where((String segment) => segment.isNotEmpty)
      .toList();
}

bool _isBundleAsset(List<String> segments) {
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
      return true;
    }
  }
  return false;
}
