# xue_hua_media_compression

**Version:** 2.0.1 · [中文文档](README.zh-CN.md) · [Changelog](packages/xue_hua_media_compression/CHANGELOG.md)

Federated Flutter plugin for **image and video compression**. Each OS uses its
native hardware pipeline. **Web is not supported.**

## Platform matrix

| | Android | iOS / macOS | Windows | Linux |
|---|---|---|---|---|
| JPEG / PNG | yes | yes | yes | yes |
| WebP encode | yes | no | if WIC present | if libvips webp |
| HEIC encode | API 28+ | yes | if HEIF extension | no |
| AVIF / GIF encode | no | no | no | no |
| H.264 / H.265 MP4 (no audio) | Media3 Transformer | AVAssetWriter | MediaTranscoder | FFmpeg VAAPI |
| `content://` input | yes | no | no | no |

Missing capability → `MediaCompressionException.unsupported` or
`hardwareUnavailable`. Nothing is silently rewritten to another format.

## Requirements

| | |
|---|---|
| Flutter | ≥ 3.44.0 |
| Dart | ≥ 3.12.0 |
| Android | minSdk 23, Media3 Transformer |
| iOS / macOS | iOS 12 / macOS 10.15 |
| Windows | Windows 10+, C++/WinRT |
| Linux | `libvips-dev`, `libavcodec-dev`, `libavfilter-dev`, `libva-dev`, VAAPI driver |

## Install

```yaml
dependencies:
  xue_hua_media_compression: ^2.0.0
```

## Quick start

```dart
final session = XueHuaMediaCompression.image.compress(
  source: MediaSource.path(inputPath),
  destination: MediaDestination.path(outputPath),
  options: const ImageCompressOptions(format: ImageFormat.jpeg, quality: 80),
);
session.progress.listen(print);
final result = await session.result;
await session.dispose();
```

```dart
final session = XueHuaMediaCompression.video.compress(
  inputPath: inputPath,
  outputPath: outputPath,
  options: const VideoCompressOptions(codec: VideoCodec.h264, bitrate: 2000000),
);
await session.cancel(); // optional
```

Call `queryCapabilities()` first to fill UI from `outputFormats` / `codecs`.

Illegal arguments (`quality` not in 1–100, empty path) throw `ArgumentError`
in Dart. Native failures throw `MediaCompressionException`.

## License

See [LICENSE](LICENSE).
