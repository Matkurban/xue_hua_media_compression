# Image API reference

Source of truth: `package:xue_hua_media_compression/xue_hua_media_compression.dart`
(re-exports listed below). Signatures and defaults match package 2.0.5.

Required import:

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

Do not import `package:xue_hua_media_compression_platform_interface/...`.
Do not construct `MediaSourceBytes` / `MediaSourcePath` /
`MediaDestinationBytes` / `MediaDestinationPath` by name (not in the main
package `show` list). Use the factories on `MediaSource` and `MediaDestination`.

## `XueHuaMediaCompression`

`abstract final class`. Not constructible. App entry point. Web is not supported.

### `static const XueHuaImageCompression image`

Still-image API. Use `XueHuaMediaCompression.image`.

### `static const XueHuaVideoCompression video`

Video API. See skill `xue-hua-media-compression-video`.

## `XueHuaImageCompression`

`final class`. `const XueHuaImageCompression()` exists for the facade; app code
uses `XueHuaMediaCompression.image`.

### `Future<ImageCompressionCapabilities> queryCapabilities()`

No parameters. Probes the current device and OS.

Returns `ImageCompressionCapabilities`:

- `inputFormats`: formats this platform can decode now
- `outputFormats`: formats this platform can encode now

Throws `MediaCompressionException` if probing fails.

### `CompressionSession<ImageCompressResult> compress({...})`

```dart
CompressionSession<ImageCompressResult> compress({
  required MediaSource source,
  required MediaDestination destination,
  ImageCompressOptions options = const ImageCompressOptions(),
})
```

Reads `source`, encodes with `options`, writes `destination`.

Returns a `CompressionSession<ImageCompressResult>` **immediately**. Await
`session.result` for `ImageCompressResult`. Listen to `session.progress`
(0.0–1.0) as soon as `compress` returns.

Throws **synchronously** `ArgumentError` when:

- `options.quality` is not in 1–100 (`name`: `options.quality`)
- `options.maxDimension != null && options.maxDimension <= 0`
- `MediaSource.bytes` payload is empty (`name`: `source.bytes`)
- `MediaSource.path` is empty after trim (`name`: `source.path`)
- `MediaDestination.path` is empty after trim (`name`: `destination.path`)

`session.result` completes with `MediaCompressionException` when:

- `cancelled` — `session.cancel()` aborted the job
- `unsupported` — platform cannot encode `options.format`
- `decode` / `encode` / `io` / `notFound` — native failure
- other codes on `MediaCompressionException` as reported by the platform

`quality` is ignored for PNG. `maxDimension` applies (proportional downscale)
before encode. Parent directories for a path destination are created natively.

## `MediaSource`

`sealed class`. Image input. Construct only via factories.

### `factory MediaSource.bytes(Uint8List bytes)`

In-memory source. `bytes` must be the complete image payload and must not be
empty (`ArgumentError` from `compress` if empty).

### `factory MediaSource.path(String path)`

Filesystem path, `file://` URI (normalized to a platform path in Dart), or
Android `content://` URI. Empty/whitespace path → `ArgumentError`.
Non-Android `content://` → `MediaCompressionException.unsupported` from
`session.result`.

## `MediaDestination`

`sealed class`. Image output. Construct only via factories.

### `factory MediaDestination.bytes()`

Keep output in memory. On success `ImageCompressResult.bytes` is non-null and
`outputPath` is null.

### `factory MediaDestination.path(String path)`

Write a local file. Native code creates missing parent directories. Empty path
→ `ArgumentError`. On success `ImageCompressResult.outputPath` is the written
file path and `bytes` is null.

Path normalization (`file://` → file path, `content://` kept, others trimmed)
is applied before the native call.

## `ImageCompressOptions`

`final class`. All image tunables live here.

```dart
const ImageCompressOptions({
  this.format = ImageFormat.jpeg,
  this.quality = 80,
  this.maxDimension,
  this.keepMetadata = false,
});
```

### `final ImageFormat format`

Target output format. Default `ImageFormat.jpeg`. Must be in
`queryCapabilities().outputFormats` or `session.result` throws `unsupported`.

### `final int quality`

Range 1–100. Default `80`. Applied for lossy formats. Ignored for PNG.
Outside 1–100 → `ArgumentError` from `compress`.

### `final int? maxDimension`

Max edge length in pixels for proportional downscale. `null` (default) means no
scale. When set, must be `> 0` or `compress` throws `ArgumentError`.

### `final bool keepMetadata`

Preserve EXIF (GPS, capture info, …). Default `false`. Ignored on Windows and
Linux. HEIC output on Android does not preserve metadata.

## `ImageCompressResult`

Successful still-image result. Constructed by the plugin; app code reads fields.

```dart
const ImageCompressResult({
  this.bytes,
  this.outputPath,
  required this.sizeBytes,
  required this.format,
  required this.width,
  required this.height,
});
```

Exactly one of `bytes` or `outputPath` is non-null, matching the destination.

### `final Uint8List? bytes`

Compressed bytes for `MediaDestination.bytes()`; `null` for file output.

### `final String? outputPath`

Output file path for `MediaDestination.path`; `null` for in-memory output.

### `final int sizeBytes`

Output size in bytes.

### `final ImageFormat format`

Format that was actually written.

### `final int width`

Output width in pixels.

### `final int height`

Output height in pixels.

## `ImageCompressionCapabilities`

Snapshot from `queryCapabilities()`.

```dart
const ImageCompressionCapabilities({
  required this.inputFormats,
  required this.outputFormats,
});
```

### `final Set<ImageFormat> inputFormats`

Formats that can be decoded on this device/OS right now.

### `final Set<ImageFormat> outputFormats`

Formats that can be encoded. Compressing with any other `ImageFormat` throws
`MediaCompressionException.unsupported`.

Typical encode support (runtime `queryCapabilities()` is authoritative):

- JPEG / PNG: Android, iOS, macOS, Windows, Linux
- WebP: Android; Windows if WIC present; Linux if libvips has webp; not iOS/macOS
- HEIC: Android API 28+; iOS/macOS; Windows if HEIF extension; not Linux
- AVIF / GIF: encode impossible on all supported platforms

## `ImageFormat`

```dart
enum ImageFormat { jpeg, png, webp, heic, avif, gif }
```

Use the enum values, not wire strings.

### `jpeg`

Lossy. `quality` applies.

### `png`

Lossless. `quality` is ignored.

### `webp`

Encode support is platform-specific. Confirm with `outputFormats`.

### `heic`

HEIC/HEIF. Encode support is platform-specific. Confirm with `outputFormats`.

### `avif`

Encoding is currently impossible on all supported platforms. Compressing with
this format throws `unsupported`.

### `gif`

Output is impossible. Input decodes the first frame only.

## `CompressionSession<TResult>`

`abstract interface class`. For images, `TResult` is `ImageCompressResult`.

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
