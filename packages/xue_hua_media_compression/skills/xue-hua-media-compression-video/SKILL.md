---
name: xue-hua-media-compression-video
description: >-
  Compress video to MP4 with xue_hua_media_compression: queryCapabilities,
  VideoCompressOptions (bitrate in bps, keepAudio), VideoCodec, file paths,
  CompressionSession progress/result/cancel/dispose, VideoCompressResult, and
  MediaCompressionException codes.
---

# Video compression

Import only:

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

Web is not supported. Apps call `XueHuaMediaCompression.video`. Do not import
`xue_hua_media_compression_platform_interface`.

Read [references/api.md](references/api.md) for every exported type, constructor,
method, field, enum value, and error code.

## Guidelines

* Call `queryCapabilities()` and pick `options.codec` from `codecs`. Encoding a
  codec that is not available throws `unsupported` or `hardwareUnavailable`.
* `compress` takes **`String inputPath` and `String outputPath`**. It does not
  take `MediaSource` / `MediaDestination` and has no in-memory destination.
* Output container is always MP4. Write a `.mp4` path. Native code creates
  missing parent directories.
* `compress` returns `CompressionSession<VideoCompressResult>` immediately. It
  is not a `Future`.
* Listen to `session.progress` before awaiting `session.result`. The stream is
  broadcast and does not replay missed events.
* After `result` completes, `await session.dispose()`.
* `bitrate` is **bits per second**, default `2000000`. Do not pass kbps/Mbps
  numbers without converting (`2` Mbps → `2000000`).
* `keepAudio` defaults to `true` (AAC passthrough or transcode). Set `false` to
  drop audio. Windows and Linux **ignore** `keepAudio`.
* `fps`, `maxDimension`, and `keyframeInterval` are optional. When set, each
  must be `> 0`. `null` keeps the source FPS / no scale / platform GOP default.
* `file://` is normalized in Dart. `content://` is Android-only
  (`acceptsContentUri` is true only on Android).
* Dart throws `ArgumentError` synchronously from `compress` for empty paths,
  `bitrate <= 0`, or `fps` / `maxDimension` / `keyframeInterval <= 0` when set.
  Native failures complete `session.result` with `MediaCompressionException`.
* Compare `error.code` to constants on `MediaCompressionException`.
* `VideoCodec.h265` without a hardware encoder throws `hardwareUnavailable`.
  Do not silently fall back to H.264.

## Examples

### H.264 at 2 Mbps

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<VideoCompressResult> compressMp4({
  required String inputPath,
  required String outputPath,
}) async {
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

### Drop audio and set GOP

```dart
final session = XueHuaMediaCompression.video.compress(
  inputPath: inputPath,
  outputPath: outputPath,
  options: const VideoCompressOptions(
    codec: VideoCodec.h264,
    bitrate: 2000000,
    keyframeInterval: 30,
    keepAudio: false,
  ),
);
```

Windows and Linux ignore `keepAudio`; the flag still validates and is sent,
but those platforms do not apply it.

### Empty path throws before native work

```dart
XueHuaMediaCompression.video.compress(
  inputPath: '',
  outputPath: '/tmp/out.mp4',
); // throws ArgumentError
```

### Cancel

```dart
final session = XueHuaMediaCompression.video.compress(
  inputPath: inputPath,
  outputPath: outputPath,
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
