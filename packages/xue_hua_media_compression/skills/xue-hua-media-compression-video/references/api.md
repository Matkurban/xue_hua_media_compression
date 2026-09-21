# Video API reference

Source of truth: `package:xue_hua_media_compression/xue_hua_media_compression.dart`
(re-exports listed below). Signatures and defaults match package 2.0.5.

Required import:

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

Do not import `package:xue_hua_media_compression_platform_interface/...`.

## `XueHuaMediaCompression`

`abstract final class`. Not constructible. App entry point. Web is not supported.

### `static const XueHuaImageCompression image`

Still-image API. See skill `xue-hua-media-compression-image`.

### `static const XueHuaVideoCompression video`

Video API. Use `XueHuaMediaCompression.video`.

## `XueHuaVideoCompression`

`final class`. `const XueHuaVideoCompression()` exists for the facade; app code
uses `XueHuaMediaCompression.video`.

Output is always MP4. Audio is kept by default (AAC passthrough or transcode)
and can be disabled with `VideoCompressOptions.keepAudio`.

### `Future<VideoCompressionCapabilities> queryCapabilities()`

No parameters.

Returns `VideoCompressionCapabilities`:

- `encoderName`: hardware encoder name; `null` when HW encode is unavailable
- `codecs`: codecs that can be hardware-encoded now
- `acceptsContentUri`: `true` only on Android

Throws `MediaCompressionException` if probing fails.

### `CompressionSession<VideoCompressResult> compress({...})`

```dart
CompressionSession<VideoCompressResult> compress({
  required String inputPath,
  required String outputPath,
  VideoCompressOptions options = const VideoCompressOptions(),
})
```

Reads `inputPath`, hardware-encodes with `options`, writes `outputPath`.

Not `MediaSource` / `MediaDestination`. No bytes destination.

Returns a `CompressionSession<VideoCompressResult>` **immediately**. Await
`session.result` for `VideoCompressResult`.

Path handling before native:

- trim
- `content://` kept as-is (Android only)
- `file://` decoded with `Uri.parse(path).toFilePath()`
- otherwise the trimmed string

Throws **synchronously** `ArgumentError` when:

- `inputPath` is empty after trim (`name`: `inputPath`)
- `outputPath` is empty after trim (`name`: `outputPath`)
- `options.bitrate <= 0` (`name`: `options.bitrate`)
- `options.fps != null && options.fps <= 0`
- `options.maxDimension != null && options.maxDimension <= 0`
- `options.keyframeInterval != null && options.keyframeInterval <= 0`

`session.result` completes with `MediaCompressionException` when:

- `cancelled` — `session.cancel()` aborted the job
- `unsupported` / `hardwareUnavailable`
- `decode` / `encode` / `mux` / `io` / `notFound`
- other codes on `MediaCompressionException` as reported by the platform

Default options: H.264, 2 Mbps (`2000000` bps), audio kept. Bitrate and scale
for this call apply immediately. Native code creates parent directories of
`outputPath`.

## `VideoCompressOptions`

`final class`. All video tunables live here.

```dart
const VideoCompressOptions({
  this.codec = VideoCodec.h264,
  this.bitrate = 2000000,
  this.fps,
  this.maxDimension,
  this.keyframeInterval,
  this.keepAudio = true,
});
```

### `final VideoCodec codec`

Target codec. Default `VideoCodec.h264`. Must be in
`queryCapabilities().codecs` or native work fails (`unsupported` /
`hardwareUnavailable`).

### `final int bitrate`

Target average **video** bitrate in **bits per second**. Default `2000000`.
Must be `> 0`.

### `final int? fps`

Target frame rate. `null` (default) keeps the source FPS. When set, must be
`> 0`.

### `final int? maxDimension`

Max edge in pixels for proportional downscale. `null` (default) means no
scale. When set, must be `> 0`.

### `final int? keyframeInterval`

GOP size in frames. `null` (default) uses the platform default. When set,
must be `> 0`.

### `final bool keepAudio`

Keep the audio track (passthrough or transcode to AAC). Default `true`.
Ignored on Windows and Linux.

## `VideoCompressResult`

Successful video result. Constructed by the plugin; app code reads fields.

```dart
const VideoCompressResult({
  required this.outputPath,
  required this.sizeBytes,
  required this.encoderName,
  required this.codec,
  required this.width,
  required this.height,
});
```

### `final String outputPath`

Output MP4 path.

### `final int sizeBytes`

Output size in bytes.

### `final String encoderName`

Encoder that actually ran (examples from dartdoc: `Media3Transformer`,
`VideoToolbox`).

### `final VideoCodec codec`

Codec that was actually used.

### `final int width`

Output width in pixels.

### `final int height`

Output height in pixels.

## `VideoCompressionCapabilities`

Snapshot from `queryCapabilities()`.

```dart
const VideoCompressionCapabilities({
  required this.encoderName,
  required this.codecs,
  required this.acceptsContentUri,
});
```

### `final String? encoderName`

Hardware encoder name. `null` when hardware encode is unavailable.

### `final Set<VideoCodec> codecs`

Codecs that can be hardware-encoded on this device/OS right now.

Typical pipelines (runtime `queryCapabilities()` is authoritative):

- Android: Media3 Transformer
- iOS / macOS: AVAssetWriter
- Windows: MediaTranscoder
- Linux: FFmpeg VAAPI

### `final bool acceptsContentUri`

Whether Android `content://` input is accepted. `true` only on Android.

## `VideoCodec`

```dart
enum VideoCodec { h264, h265 }
```

Use the enum values, not wire strings.

### `h264`

H.264 / AVC, muxed into MP4.

### `h265`

H.265 / HEVC, muxed into MP4. Throws `hardwareUnavailable` when no hardware
encoder is available. Do not silently substitute `h264`.

## `CompressionSession<TResult>`

`abstract interface class`. For video, `TResult` is `VideoCompressResult`.

Returned immediately by `compress`. Native work is already started.

### `Stream<double> get progress`

Broadcast stream of progress in `0.0`–`1.0`, pushed from native code (not
polled). Values are clamped. On success the implementation also emits `1.0`
then closes the stream. There is **no replay buffer**: subscribe immediately
after `compress` returns.

### `Future<TResult> get result`

Completes with the result on success. Completes with
`MediaCompressionException` on native failure or cancel.

### `Future<void> cancel()`

Requests abort. Completes when the cancel request has been delivered to native
code. Idempotent if the job already finished. After `dispose()`, `cancel()`
returns immediately.

This method does not throw `cancelled`. `result` throws
`MediaCompressionException.cancelled` when cancel succeeds.

If the native job id is already gone (`instanceNotFound`), `cancel` returns
without throwing.

### `Future<void> dispose()`

Releases the native session. Idempotent. Completes when released; returns
immediately if already disposed.

Call after `result` settles. Implementation does not throw `StateError` after
dispose.

## `MediaCompressionException`

`final class implements Exception`. Native / plugin failures.

```dart
const MediaCompressionException(this.code, this.message, {this.details});
```

### Constructor parameters

- `code` (`String`): one of the constants on this class
- `message` (`String`): human-readable description
- `details` (`String?`): optional platform extra

### Fields

- `final String code`
- `final String message`
- `final String? details`

### `String toString()`

`MediaCompressionException($code, $message)` when `details` is null or empty;
otherwise `MediaCompressionException($code, $message, details: $details)`.

### Error code constants

Compare with `error.code == MediaCompressionException.<name>`.

| Constant | Value | Meaning |
| --- | --- | --- |
| `instanceNotFound` | `'instanceNotFound'` | Native job id is gone while the Dart session is still used |
| `cancelled` | `'cancelled'` | Aborted by `CompressionSession.cancel` |
| `unsupported` | `'unsupported'` | Current platform does not provide this capability |
| `invalidState` | `'invalidState'` | Capability exists but current state forbids it |
| `notFound` | `'notFound'` | Path or resource does not exist |
| `unsupportedFormat` | `'unsupportedFormat'` | Input or output format is not supported |
| `decode` | `'decode'` | Decoding failed |
| `encode` | `'encode'` | Encoding failed |
| `hardwareUnavailable` | `'hardwareUnavailable'` | No hardware encoder is available |
| `mux` | `'mux'` | Muxing the MP4 container failed |
| `io` | `'io'` | File I/O failed |
