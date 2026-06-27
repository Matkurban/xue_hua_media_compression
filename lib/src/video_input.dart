import 'dart:io';
import 'dart:typed_data';

/// 将可能不可直接访问的输入路径转为本地可读路径。
///
/// Android 上通过 [file_selector] 等 picker 返回的 [inputPath] 常为
/// `content://` URI 或 NDK `AMediaExtractor` 无法直接打开的路径。
/// 此时应提供 [openStream]（例如 `() => xFile.openRead()`），函数会
/// 流式复制到 [cacheDirectory] 后再返回绝对路径。
///
/// 应用内已有可读文件时，仅传 [inputPath] 即可（不传 [openStream]）。
///
/// [expectedBytes] 为源文件大小（如 `xFile.length()`），复制后会校验
/// 缓存文件大小是否一致，避免截断或空文件进入 NDK。
Future<String> ensureLocalVideoInput({
  required String inputPath,
  required String cacheDirectory,
  Future<Stream<List<int>>> Function()? openStream,
  String? fileName,
  int? expectedBytes,
}) async {
  if (openStream == null) {
    final normalized = _normalizePath(inputPath);
    if (normalized.isNotEmpty && File(normalized).existsSync()) {
      await _validateVideoFile(File(normalized), expectedBytes: expectedBytes);
      return normalized;
    }
    throw ArgumentError(
      '无法访问视频路径 "$inputPath"。'
      '请提供 openStream（如 () => xFile.openRead()）以复制到缓存目录，'
      '或传入应用内可读的绝对路径。',
    );
  }

  final ext = _extensionFromName(fileName ?? inputPath);
  final dest = File(
    '$cacheDirectory/xh_video_input_${DateTime.now().millisecondsSinceEpoch}$ext',
  );
  final stream = await openStream();
  final sink = dest.openWrite();
  try {
    await stream.pipe(sink);
    await sink.flush();
  } finally {
    await sink.close();
  }

  await _validateVideoFile(dest, expectedBytes: expectedBytes);
  return dest.path;
}

/// 校验复制后的视频文件：非空、大小匹配、MP4/MOV 容器魔数。
Future<void> _validateVideoFile(
  File file, {
  int? expectedBytes,
}) async {
  final length = await file.length();
  if (length == 0) {
    throw StateError('视频复制后文件为空 (${file.path})');
  }
  if (expectedBytes != null && length != expectedBytes) {
    throw StateError(
      '视频复制后大小不符：期望 $expectedBytes 字节，实际 $length 字节 (${file.path})',
    );
  }

  final header = Uint8List(12);
  final raf = await file.open();
  try {
    final read = await raf.readInto(header);
    if (read < 8) {
      throw StateError(
        '视频文件过短或已损坏（仅 $read 字节可读，${file.path}）',
      );
    }
  } finally {
    await raf.close();
  }

  if (!_looksLikeMp4OrMov(header)) {
    final hex = header
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    throw StateError(
      '视频文件不是 MP4/MOV 容器（文件头: $hex，${file.path}）。'
      '请确认选择的是相册中的 MP4/MOV 视频。',
    );
  }
}

/// MP4/MOV：`....ftyp` 出现在偏移 4–7，或旧式 `moov`/`mdat` 在偏移 4。
bool _looksLikeMp4OrMov(Uint8List header) {
  if (header.length < 8) return false;
  final boxType = String.fromCharCodes(header.sublist(4, 8));
  if (boxType == 'ftyp' || boxType == 'moov' || boxType == 'mdat') {
    return true;
  }
  return false;
}

String _normalizePath(String path) {
  if (path.startsWith('file://')) {
    return Uri.parse(path).toFilePath();
  }
  return path;
}

String _extensionFromName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot >= name.length - 1) {
    return '.mp4';
  }
  return name.substring(dot);
}
