---
name: xue-hua-media-compression-image
description: >-
  Compress still images with xue_hua_media_compression: queryCapabilities,
  ImageCompressOptions, MediaSource, MediaDestination, CompressionSession
  progress/result/cancel/dispose, ImageFormat, ImageCompressResult, and
  MediaCompressionException codes.
---

# Image compression

Import only:

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

Web is not supported. Apps call `XueHuaMediaCompression.image`. Do not import
`xue_hua_media_compression_platform_interface`.

Read [references/api.md](references/api.md) for every exported type, constructor,
method, field, enum value, and error code.

## Guidelines

* Call `queryCapabilities()` and pick `options.format` from `outputFormats`.
  Encoding a format that is not in that set throws `MediaCompressionException.unsupported`.
* `compress` returns `CompressionSession<ImageCompressResult>` immediately. It
  is not a `Future`.
* Listen to `session.progress` before awaiting `session.result`. The stream is
  broadcast and does not replay missed events.
* After `result` completes (success or error), `await session.dispose()`.
* Build sources with `MediaSource.bytes` / `MediaSource.path` and destinations
  with `MediaDestination.bytes` / `MediaDestination.path`.
* Default options are JPEG, quality 80, no scale, metadata stripped.
* `quality` applies to lossy formats only. PNG ignores `quality`.
* `maxDimension`, when set, must be `> 0`. It proportionally downscales before
  encode. `null` means no scale.
* `keepMetadata` defaults to `false`. Windows and Linux ignore it. Android HEIC
  output does not preserve EXIF.
* GIF input decodes the first frame only. `ImageFormat.avif` and
  `ImageFormat.gif` cannot be encoded on any supported platform.
* Dart throws `ArgumentError` synchronously from `compress` for empty bytes,
  empty paths, `quality` outside 1–100, or `maxDimension <= 0`. Native failures
  complete `session.result` with `MediaCompressionException`.
* Compare `error.code` to constants on `MediaCompressionException` (for example
  `MediaCompressionException.cancelled`). Do not use raw code strings.
* Missing capability is an exception. Do not silently switch format.
* `content://` input is Android-only. `file://` paths are normalized in Dart.

## Examples

### Path to path

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<ImageCompressResult> compressJpegFile({
  required String inputPath,
  required String outputPath,
}) async {
  final caps = await XueHuaMediaCompression.image.queryCapabilities();
  final format = caps.outputFormats.contains(ImageFormat.jpeg)
      ? ImageFormat.jpeg
      : caps.outputFormats.first;

  final session = XueHuaMediaCompression.image.compress(
    source: MediaSource.path(inputPath),
    destination: MediaDestination.path(outputPath),
    options: ImageCompressOptions(format: format, quality: 80),
  );
  session.progress.listen((value) {
    // value is 0.0–1.0
  });
  try {
    return await session.result;
  } finally {
    await session.dispose();
  }
}
```

### Bytes to bytes

```dart
import 'dart:typed_data';

import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<Uint8List> compressJpegBytes(Uint8List input) async {
  final session = XueHuaMediaCompression.image.compress(
    source: MediaSource.bytes(input),
    destination: MediaDestination.bytes(),
    options: const ImageCompressOptions(
      format: ImageFormat.jpeg,
      quality: 80,
    ),
  );
  try {
    final result = await session.result;
    return result.bytes!;
  } finally {
    await session.dispose();
  }
}
```

### Cancel

```dart
final session = XueHuaMediaCompression.image.compress(
  source: MediaSource.path(inputPath),
  destination: MediaDestination.path(outputPath),
);
await session.cancel();
try {
  await session.result;
} on MediaCompressionException catch (error) {
  if (error.code != MediaCompressionException.cancelled) {
    rethrow;
  }
} finally {
  await session.dispose();
}
```
