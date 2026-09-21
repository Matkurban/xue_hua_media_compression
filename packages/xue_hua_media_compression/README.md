# xue_hua_media_compression

[中文文档](README.zh-CN.md)

Federated Flutter plugin for **image and video compression**. Each OS uses its
native hardware pipeline. **Web is not supported.**

## Platform matrix

|                              | Android            | iOS / macOS   | Windows           | Linux           |
|------------------------------|--------------------|---------------|-------------------|-----------------|
| JPEG / PNG                   | yes                | yes           | yes               | yes             |
| WebP encode                  | yes                | no            | if WIC present    | if libvips webp |
| HEIC encode                  | API 28+            | yes           | if HEIF extension | no              |
| AVIF / GIF encode            | no                 | no            | no                | no              |
| H.264 / H.265 MP4            | Media3 Transformer | AVAssetWriter | MediaTranscoder   | FFmpeg VAAPI    |
| `content://` input           | yes                | no            | no                | no              |

Video output is always MP4. `VideoCompressOptions.keepAudio` defaults to
`true` (AAC passthrough or transcode). Windows and Linux ignore `keepAudio`.

Call `queryCapabilities()` at runtime and use `outputFormats` / `codecs`.
Missing capability → `MediaCompressionException.unsupported` or
`hardwareUnavailable`. Nothing is silently rewritten to another format.

GIF input decodes the first frame only. AVIF and GIF cannot be encoded on any
supported platform.

## Requirements

|             |                                                                               |
|-------------|-------------------------------------------------------------------------------|
| Flutter     | ≥ 3.44.0                                                                      |
| Dart        | ≥ 3.12.0                                                                      |
| Android     | minSdk 23, Media3 Transformer                                                 |
| iOS / macOS | iOS 12 / macOS 10.15                                                          |
| Windows     | Windows 10+, C++/WinRT                                                        |
| Linux       | `libvips-dev`, `libavcodec-dev`, `libavfilter-dev`, `libva-dev`, VAAPI driver |

## Install

```yaml
dependencies:
  xue_hua_media_compression: ^2.0.5
```

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

## Quick start

`compress` returns a `CompressionSession` immediately. Listen to `progress`
right away (the stream does not replay missed events), then `await
session.result`, then `await session.dispose()`.

### Image

Defaults: JPEG, quality 80, no scale, metadata stripped. `quality` is ignored
for PNG. `maxDimension` (when set) must be `> 0` and downscales
proportionally before encode. `keepMetadata` is ignored on Windows/Linux;
HEIC output on Android does not preserve EXIF.

```dart
final caps = await XueHuaMediaCompression.image.queryCapabilities();
final format = caps.outputFormats.contains(ImageFormat.jpeg)
    ? ImageFormat.jpeg
    : caps.outputFormats.first;

final session = XueHuaMediaCompression.image.compress(
  source: MediaSource.path(inputPath),
  destination: MediaDestination.path(outputPath),
  options: ImageCompressOptions(format: format, quality: 80),
);
session.progress.listen(print);
final result = await session.result;
await session.dispose();
```

In-memory:

```dart
final session = XueHuaMediaCompression.image.compress(
  source: MediaSource.bytes(bytes),
  destination: MediaDestination.bytes(),
);
final result = await session.result;
await session.dispose();
// result.bytes is non-null; result.outputPath is null
```

### Video

Uses file paths only (`inputPath` / `outputPath`), not `MediaSource`.
`bitrate` is in **bps** (default `2000000`). `file://` is normalized in Dart;
`content://` is Android-only.

```dart
final caps = await XueHuaMediaCompression.video.queryCapabilities();
final codec = caps.codecs.contains(VideoCodec.h264)
    ? VideoCodec.h264
    : caps.codecs.first;

final session = XueHuaMediaCompression.video.compress(
  inputPath: inputPath,
  outputPath: outputPath,
  options: VideoCompressOptions(
    codec: codec,
    bitrate: 2000000,
    keepAudio: true,
  ),
);
session.progress.listen(print);
final result = await session.result;
await session.dispose();
```

`await session.cancel()` aborts the job; `session.result` then throws
`MediaCompressionException.cancelled`. `cancel` and `dispose` are idempotent.

## Errors

Dart throws `ArgumentError` before native work when:

- a path is empty (after trim) or image bytes are empty
- `quality` is not in 1–100
- `bitrate`, `fps`, `maxDimension`, or `keyframeInterval` is `<= 0` (when set)

Native failures throw `MediaCompressionException`. Compare `error.code` to the
constants on that class (`cancelled`, `unsupported`, `hardwareUnavailable`,
…).

## Package skills

This package ships agent skills for image and video compression. After adding
the dependency, install them into your coding agent:

```bash
dart run skills@ get
# or non-interactive:
dart run skills@ get --all
```

## License

See [LICENSE](LICENSE).
