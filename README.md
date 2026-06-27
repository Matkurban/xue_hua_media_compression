# xue_hua_media_compression

**Version:** 1.1.0 · [中文文档](README.zh-CN.md) · [Changelog](CHANGELOG.md)

A cross-platform Flutter FFI plugin for **image and video compression**, powered by Rust and [flutter_rust_bridge](https://codelabs.flutter.dev/codelabs/flutter-ffigen). Image compression runs entirely in Rust on all platforms; video compression uses each platform's native **hardware encoder** and muxes the result into standard MP4.

---

## Table of Contents

- [Features](#features)
- [Platform Support](#platform-support)
- [Requirements](#requirements)
- [Installation](#installation)
- [Building & Compilation](#building--compilation)
- [Permissions](#permissions)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Error Handling](#error-handling)
- [Example App](#example-app)
- [Project Structure](#project-structure)
- [Optional: HEIC Support](#optional-heic-support)
- [License](#license)

---

## Features

| Capability | Description |
|---|---|
| **Image compression** | JPEG, PNG, WebP, GIF, AVIF; optional HEIC (build-time feature) |
| **Image input** | JPEG, PNG, WebP, GIF, HEIC/HEIF (when enabled), AVIF |
| **Video compression** | H.264 / H.265 (HEVC), output as MP4 |
| **Video input** | MP4 / MOV containers (hardware decode per platform) |
| **Scaling** | Optional max-dimension downscale for images and video |
| **Hardware encoding** | Platform-native backends — no bundled FFmpeg |
| **API style** | Facade namespace: `XueHuaMediaCompression.image` / `.video` |

---

## Platform Support

| Platform | Image | Video (HW encode) | Backend |
|---|---|---|---|
| **Android** | ✅ | ✅ | AMediaCodec (NDK) |
| **iOS** | ✅ | ✅ | VideoToolbox |
| **macOS** | ✅ | ✅ | VideoToolbox |
| **Windows** | ✅ | ✅ | Media Foundation |
| **Linux** | ✅ | ✅ | VA-API |

> Video compression is **not available** on unsupported platforms; calls return `MediaError.hardwareUnavailable`.

---

## Requirements

### Common

| Tool | Version |
|---|---|
| Flutter | ≥ 3.3.0 |
| Dart SDK | ≥ 3.12.2 |
| Rust toolchain | stable (via [rustup](https://rustup.rs/)) |

### Per Platform

| Platform | Additional requirements |
|---|---|
| **Android** | Android SDK, NDK (version declared in your app's `android/app/build.gradle`) |
| **iOS / macOS** | Xcode, CocoaPods |
| **Windows** | Visual Studio with C++ desktop development, CMake |
| **Linux** | CMake, VA-API drivers (`libva`, GPU/driver with H.264/H.265 encode support) |

---

## Installation

Add the dependency to your app's `pubspec.yaml`:

```yaml
dependencies:
  xue_hua_media_compression: ^1.1.0
```

For local development (monorepo / path dependency):

```yaml
dependencies:
  xue_hua_media_compression:
    path: ../xue_hua_media_compression
```

Then fetch packages:

```bash
flutter pub get
```

No extra Gradle or CocoaPods steps are required beyond a normal Flutter plugin — native Rust libraries are built automatically via [Cargokit](https://matejknopp.com/post/flutter_plugin_in_rust_with_no_prebuilt_binaries/) during `flutter build` / `flutter run`.

---

## Building & Compilation

### Run the example app

```bash
cd example
flutter pub get
flutter run
```

### Build release APK (Android)

```bash
cd example
flutter build apk --release
```

### Build for other platforms

```bash
flutter build ios --release
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

### How native code is built

This plugin is an **FFI plugin** (`ffiPlugin: true`). Cargokit invokes `cargo` for each target:

| Platform | Build system | Config location |
|---|---|---|
| Android | Gradle + NDK | `android/build.gradle` |
| iOS / macOS | Xcode + CocoaPods | `ios/xue_hua_media_compression.podspec`, `macos/xue_hua_media_compression.podspec` |
| Linux / Windows | CMake | `linux/CMakeLists.txt`, `windows/CMakeLists.txt` |

Rust source lives in `rust/`. The first build may take several minutes while dependencies compile (e.g. `rav1e` for AVIF).

### Regenerate Dart ↔ Rust bindings

After changing Rust API annotations:

```bash
flutter_rust_bridge_codegen generate
```

---

## Permissions

The plugin **does not declare storage or media permissions** in its own manifest — your app must request them when picking or saving user files.

### Android

Add to `android/app/src/main/AndroidManifest.xml` as needed:

```xml
<!-- Android 13+ (API 33+) -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- Android 12 and below -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

Also request runtime permissions in Dart (e.g. with [`permission_handler`](https://pub.dev/packages/permission_handler)) before opening the gallery or file picker.

**File picker paths:** Pass `xFile.path` from `file_selector` directly to `compressFile` / `video.compress`. Rust reads the file by path (video uses native streaming APIs; Android `content://` URIs are opened via JNI fd — no Dart-side copy or `readAsBytes`).

**macOS sandbox:** Enable `com.apple.security.files.user-selected.read-write` (or read-only) in your entitlements so Rust can read user-picked files during the picker session.

### iOS / macOS

If you access the photo library, add to `ios/Runner/Info.plist` (and macOS equivalent):

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Need access to photos for compression.</string>
```

For saving to the photo library:

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Need permission to save compressed media.</string>
```

### Desktop (Windows / Linux / macOS)

File access is typically handled by the system file picker (`file_selector`); no extra manifest entries are usually required.

---

## Quick Start

Initialize once at app startup, then call image or video APIs:

```dart
import 'dart:typed_data';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await XueHuaMediaCompression.initialize();
  runApp(const MyApp());
}

Future<Uint8List> compressImage(Uint8List input) {
  return XueHuaMediaCompression.image.compress(
    input: input,
    format: ImageFormat.jpeg,
    quality: 80,
    maxDimension: 1920,
  );
}

Future<VideoResult> compressVideo(String inputPath, String outputPath) {
  return XueHuaMediaCompression.video.compress(
    inputPath: inputPath,
    outputPath: outputPath,
    codec: VideoCodec.h264,
    bitrate: 2_000_000, // 2 Mbps
  );
}
```

Check the active video encoder backend (diagnostics / UI):

```dart
final backend = await XueHuaMediaCompression.videoBackendName();
// e.g. "AMediaCodec", "VideoToolbox", "MediaFoundation", "VA-API"
```

---

## API Reference

### Initialization

| Method | Description |
|---|---|
| `XueHuaMediaCompression.initialize()` | Load Rust library and run init. Idempotent — safe to call multiple times. |
| `XueHuaMediaCompression.videoBackendName()` | Returns the platform hardware video encoder name. |

### Image — `XueHuaMediaCompression.image`

#### `compress`

In-memory compression.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `input` | `Uint8List` | required | Raw image bytes |
| `format` | `ImageFormat` | `jpeg` | Output format |
| `quality` | `int` | `80` | 0–100, for lossy formats |
| `maxDimension` | `int?` | `null` | Max edge length; proportional downscale |
| `speed` | `int?` | `null` | AVIF/HEIC speed 0–10; WebP method; PNG oxipng level 1–10 |

**Supported output formats:** `jpeg`, `png`, `webP`, `gif`, `avif`, `heic` (requires HEIC build feature).

#### `compressFile`

File-to-file compression. Returns output file size in bytes. Rust reads `inputPath` directly (normalizes `file://` prefixes). Pass the path from your file picker as-is.

#### Image compression with file picker

```dart
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

final xFile = await openFile(/* ... */);
if (xFile == null) return;

// `Directory.systemTemp` avoids extra native deps in the example; apps may use path_provider instead.
final tmpDir = Directory.systemTemp;
await XueHuaMediaCompression.image.compressFile(
  inputPath: xFile.path,
  outputPath: '${tmpDir.path}/out.jpg',
  format: ImageFormat.jpeg,
  quality: 80,
);
```

#### `compressWith`

Same as `compress` but accepts a pre-built `ImageOptions` object.

### Video — `XueHuaMediaCompression.video`

#### `compress`

File-to-file video compression. Output is always **MP4**.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `inputPath` | `String` | required | Source video path (local, readable) |
| `outputPath` | `String` | required | Destination `.mp4` path |
| `codec` | `VideoCodec` | `h264` | `h264` or `h265` |
| `bitrate` | `int` | `2000000` | Target average bitrate (bps) |
| `fps` | `int?` | `null` | Target FPS; `null` keeps source FPS |
| `maxDimension` | `int?` | `null` | Max edge length for downscale |
| `keyframeInterval` | `int?` | `null` | GOP size in frames |

Returns `VideoResult`:

| Field | Description |
|---|---|
| `outputPath` | Output file path |
| `sizeBytes` | Output file size |
| `backend` | Encoder used (e.g. `"VideoToolbox"`) |
| `width`, `height` | Output dimensions |

#### Video compression

With a file picker, pass `xFile.path` directly:

```dart
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

final xFile = await openFile(/* ... */);
if (xFile == null) return;

// `Directory.systemTemp` avoids extra native deps in the example; apps may use path_provider instead.
final tmpDir = Directory.systemTemp;
final result = await XueHuaMediaCompression.video.compress(
  inputPath: xFile.path,
  outputPath: '${tmpDir.path}/out.mp4',
  codec: VideoCodec.h264,
  bitrate: 2_000_000,
);
```

On Android, `content://` URIs are opened in Rust via `ContentResolver` (streaming fd, no full-file copy in Dart).

---

## Error Handling

Errors are thrown as `MediaError`:

| Variant | Meaning |
|---|---|
| `unsupportedFormat` | Input or output format not supported |
| `decode` | Failed to decode input |
| `encode` | Failed to encode output |
| `hardwareUnavailable` | No HW encoder on this platform / device |
| `mux` | MP4 muxing failed |
| `io` | File I/O error |
| `native` | Platform API error (`code`, `msg`) |

Example:

```dart
try {
  await XueHuaMediaCompression.image.compress(input: bytes);
} on MediaError catch (e) {
  print(e);
}
```

---

## Example App

The `example/` directory contains a full demo with image and video compression UI:

```bash
cd example
flutter run
```

Features demonstrated:

- Image format selection (JPEG / PNG / WebP / AVIF)
- Quality slider and before/after preview
- Video codec and bitrate selection
- Direct `xFile.path` → `compressFile` / `video.compress` (no Dart-side cache copy)
- Live display of `videoBackendName()`

---

## Project Structure

```
xue_hua_media_compression/
├── lib/                    # Dart public API & FRB generated bindings
│   └── src/
│       ├── media_compression.dart   # Facade (XueHuaMediaCompression)
│       ├── file_input.rs            # Path normalization (Rust)
│       └── rust/                    # flutter_rust_bridge generated code
├── rust/                   # Rust implementation (image + platform video)
│   └── src/api/
│       ├── image.rs        # Pure-Rust image compression
│       ├── media.rs        # FRB entry points
│       └── platform/       # Per-OS hardware video encoders
├── android/ ios/ macos/ linux/ windows/   # Platform build glue
├── cargokit/               # Rust ↔ Flutter build integration
└── example/                # Demo application
```

---

## Optional: HEIC Support

HEIC/HEIF encode and decode requires the Rust `heic` feature and **libheif** on the build host / target:

```toml
# rust/Cargo.toml — already defined, disabled by default
[features]
heic = ["dep:libheif-rs"]
```

To enable, configure Cargokit / cargo build with `--features heic` and install libheif (e.g. `brew install libheif` on macOS). Without this feature, `ImageFormat.heic` returns `MediaError.encode` / `MediaError.decode`.

---

## License

See [LICENSE](LICENSE).

---

**[中文文档 →](README.zh-CN.md)** · **[更新日志 / Changelog →](CHANGELOG.md)**
