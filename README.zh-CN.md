# xue_hua_media_compression

**版本：** 1.2.0 · [English](README.md) · [更新日志](CHANGELOG.md)

跨平台 Flutter FFI 插件，提供**图片与视频压缩**能力。核心逻辑由 Rust 实现，通过 [flutter_rust_bridge](https://codelabs.flutter.dev/codelabs/flutter-ffigen) 与 Dart 互通。图片压缩在全平台统一走纯 Rust 管线；视频压缩调用各平台原生**硬件编码器**，并封装为标准 MP4。

---

## 目录

- [功能特性](#功能特性)
- [平台支持](#平台支持)
- [环境要求](#环境要求)
- [安装](#安装)
- [编译与构建](#编译与构建)
- [权限配置](#权限配置)
- [快速开始](#快速开始)
- [API 参考](#api-参考)
- [错误处理](#错误处理)
- [示例应用](#示例应用)
- [项目结构](#项目结构)
- [可选：HEIC 支持](#可选heic-支持)
- [许可证](#许可证)

---

## 功能特性

| 能力 | 说明 |
|---|---|
| **图片压缩** | 支持 JPEG、PNG、WebP、GIF、AVIF；可选 HEIC（需构建时开启 feature） |
| **图片输入** | JPEG、PNG、WebP、GIF、HEIC/HEIF（启用时）、AVIF |
| **视频压缩** | H.264 / H.265 (HEVC)，输出 MP4 |
| **视频输入** | MP4 / MOV 容器（各平台硬件解码） |
| **缩放** | 图片与视频均可选最大边长等比缩放 |
| **硬件编码** | 各平台原生后端，不捆绑 FFmpeg |
| **API 风格** | 门面命名空间：`XueHuaMediaCompression.image` / `.video` |

---

## 平台支持

| 平台 | 图片 | 视频（硬编） | 后端 |
|---|---|---|---|
| **Android** | ✅ | ✅ | AMediaCodec (NDK) |
| **iOS** | ✅ | ✅ | VideoToolbox |
| **macOS** | ✅ | ✅ | VideoToolbox |
| **Windows** | ✅ | ✅ | Media Foundation |
| **Linux** | ✅ | ✅ | VA-API |

> 不支持的平台无法使用视频压缩，调用会返回 `MediaError.hardwareUnavailable`。

---

## 环境要求

### 通用

| 工具 | 版本 |
|---|---|
| Flutter | ≥ 3.3.0 |
| Dart SDK | ≥ 3.12.2 |
| Rust 工具链 | stable（通过 [rustup](https://rustup.rs/) 安装） |

### 各平台额外依赖

| 平台 | 额外要求 |
|---|---|
| **Android** | Android SDK、NDK（版本由宿主 App 的 `android/app/build.gradle` 指定） |
| **iOS / macOS** | Xcode、CocoaPods |
| **Windows** | Visual Studio（含 C++ 桌面开发）、CMake |
| **Linux** | CMake、VA-API 驱动（`libva`，GPU/驱动需支持 H.264/H.265 编码） |

---

## 安装

在 App 的 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  xue_hua_media_compression: ^1.2.0
```

本地开发（路径依赖）：

```yaml
dependencies:
  xue_hua_media_compression:
    path: ../xue_hua_media_compression
```

拉取依赖：

```bash
flutter pub get
```

除常规 Flutter 插件流程外，无需额外手动配置 Gradle 或 CocoaPods —— 原生 Rust 库会在 `flutter build` / `flutter run` 时由 [Cargokit](https://matejknopp.com/post/flutter_plugin_in_rust_with_no_prebuilt_binaries/) 自动编译。

---

## 编译与构建

### 运行示例应用

```bash
cd example
flutter pub get
flutter run
```

### 构建 Android Release APK

```bash
cd example
flutter build apk --release
```

### 其他平台

```bash
flutter build ios --release
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

### 原生代码如何编译

本插件为 **FFI 插件**（`ffiPlugin: true`）。Cargokit 会为各目标平台调用 `cargo`：

| 平台 | 构建系统 | 配置文件 |
|---|---|---|
| Android | Gradle + NDK | `android/build.gradle` |
| iOS / macOS | Xcode + CocoaPods | `ios/xue_hua_media_compression.podspec`、`macos/xue_hua_media_compression.podspec` |
| Linux / Windows | CMake | `linux/CMakeLists.txt`、`windows/CMakeLists.txt` |

Rust 源码位于 `rust/`。首次编译可能耗时较长（例如 AVIF 依赖 `rav1e`）。

### 重新生成 Dart ↔ Rust 绑定

修改 Rust API 注解后执行：

```bash
flutter_rust_bridge_codegen generate
```

---

## 权限配置

插件自身 **不在 Manifest 中声明存储或媒体权限** —— 当 App 需要选取或保存用户文件时，由宿主 App 自行声明并申请。

### Android

按需添加到 `android/app/src/main/AndroidManifest.xml`：

```xml
<!-- Android 13+ (API 33+) -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- Android 12 及以下 -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

在 Dart 中还需请求运行时权限（例如使用 [`permission_handler`](https://pub.dev/packages/permission_handler)），再打开相册或文件选择器。

**文件选择器路径：** 将 `file_selector` 返回的 `xFile.path` 直接传给 `compressFile` / `video.compress`。Rust 按路径读文件（视频走原生流式 API；Android `content://` 通过 JNI 取 fd 打开，无需在 Dart 侧复制或 `readAsBytes`）。

**macOS 沙盒：** 在 entitlements 中启用 `com.apple.security.files.user-selected.read-write`（或 read-only），以便 Rust 在 picker 会话期间读取用户选中的文件。

### iOS / macOS

若访问相册，在 `ios/Runner/Info.plist`（及 macOS 对应文件）中添加：

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>需要访问相册以压缩媒体文件。</string>
```

若需保存到相册：

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>需要权限以保存压缩后的媒体文件。</string>
```

### 桌面端（Windows / Linux / macOS）

通常由系统文件选择器（如 `file_selector`）处理访问，一般无需额外 Manifest 配置。

---

## 快速开始

在 App 启动时初始化一次，然后调用图片或视频 API：

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

查询当前平台视频硬编后端（诊断 / UI 展示）：

```dart
final backend = await XueHuaMediaCompression.videoBackendName();
// 例如 "AMediaCodec"、"VideoToolbox"、"MediaFoundation"、"VA-API"
```

---

## API 参考

> **公开 API 边界：** 集成方仅应使用 `XueHuaMediaCompression` 及其 re-export 的类型（`ImageOptions`、`MediaError` 等）。请勿 deep import `lib/src/rust/`——内部 FRB 绑定不是稳定公开 interface。详见 [CONTEXT.md](CONTEXT.md)。

### 初始化

| 方法 | 说明 |
|---|---|
| `XueHuaMediaCompression.initialize()` | 加载 Rust 动态库并执行初始化。幂等，可重复调用。 |
| `XueHuaMediaCompression.videoBackendName()` | 返回当前平台硬件视频编码器名称。 |

### 图片 — `XueHuaMediaCompression.image`

#### `compress`

内存到内存压缩。

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `input` | `Uint8List` | 必填 | 原始图片字节 |
| `format` | `ImageFormat` | `jpeg` | 输出格式 |
| `quality` | `int` | `80` | 0–100，对有损格式有效 |
| `maxDimension` | `int?` | `null` | 最大边长，等比缩放 |
| `speed` | `int?` | `null` | AVIF/HEIC 速度 0–10；WebP method；PNG oxipng 档位 1–10 |

**支持的输出格式：** `jpeg`、`png`、`webP`、`gif`、`avif`、`heic`（需 HEIC 构建 feature）。

#### `compressFile`

文件到文件压缩，返回输出文件字节数。Rust 直接读取 `inputPath`（会自动规范化 `file://` 前缀）。将文件选择器返回的路径原样传入即可。

#### 文件选择器下的图片压缩

```dart
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

final xFile = await openFile(/* ... */);
if (xFile == null) return;

// 示例使用 `Directory.systemTemp` 以减少原生依赖；业务 App 也可使用 path_provider。
final tmpDir = Directory.systemTemp;
await XueHuaMediaCompression.image.compressFile(
  inputPath: xFile.path,
  outputPath: '${tmpDir.path}/out.jpg',
  format: ImageFormat.jpeg,
  quality: 80,
);
```

#### `compressWith`

与 `compress` 相同，但传入完整的 `ImageOptions` 对象。

### 视频 — `XueHuaMediaCompression.video`

#### `compress`

文件到文件视频压缩，输出始终为 **MP4**。

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `inputPath` | `String` | 必填 | 源视频路径（本地可读） |
| `outputPath` | `String` | 必填 | 目标 `.mp4` 路径 |
| `codec` | `VideoCodec` | `h264` | `h264` 或 `h265` |
| `bitrate` | `int` | `2000000` | 目标平均码率（bps） |
| `fps` | `int?` | `null` | 目标帧率；`null` 沿用源帧率 |
| `maxDimension` | `int?` | `null` | 最大边长等比缩放 |
| `keyframeInterval` | `int?` | `null` | GOP 关键帧间隔（帧数） |

返回 `VideoResult`：

| 字段 | 说明 |
|---|---|
| `outputPath` | 输出文件路径 |
| `sizeBytes` | 输出文件大小 |
| `backend` | 实际使用的编码器（如 `"VideoToolbox"`） |
| `width`、`height` | 输出宽高 |

#### 视频压缩

使用文件选择器时，直接传入 `xFile.path`：

```dart
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

final xFile = await openFile(/* ... */);
if (xFile == null) return;

// 示例使用 `Directory.systemTemp` 以减少原生依赖；业务 App 也可使用 path_provider。
final tmpDir = Directory.systemTemp;
final result = await XueHuaMediaCompression.video.compress(
  inputPath: xFile.path,
  outputPath: '${tmpDir.path}/out.mp4',
  codec: VideoCodec.h264,
  bitrate: 2_000_000,
);
```

Android 上 `content://` URI 由 Rust 通过 `ContentResolver` 打开（流式 fd，不在 Dart 侧整文件复制）。

---

## 错误处理

错误以 `MediaError` 形式抛出：

| 变体 | 含义 |
|---|---|
| `unsupportedFormat` | 不支持输入或输出格式 |
| `decode` | 解码失败 |
| `encode` | 编码失败 |
| `hardwareUnavailable` | 当前平台/设备无可用硬件编码 |
| `mux` | MP4 封装失败 |
| `io` | 文件 I/O 错误 |
| `native` | 平台原生 API 错误（`code`、`msg`） |

示例：

```dart
try {
  await XueHuaMediaCompression.image.compress(input: bytes);
} on MediaError catch (e) {
  print(e);
}
```

---

## 示例应用

`example/` 目录包含完整的图片与视频压缩 Demo：

```bash
cd example
flutter run
```

演示内容：

- 图片格式选择（JPEG / PNG / WebP / AVIF）
- 质量滑块与压缩前后预览
- 视频编码格式与码率选择
- 文件选择器路径直接传给 Rust（无 Dart 侧缓存复制）
- 实时展示 `videoBackendName()`

---

## 项目结构

```
xue_hua_media_compression/
├── lib/                    # Dart 公开 API（门面 + FRB 生成绑定）
│   └── src/
│       ├── media_compression.dart   # 门面类 XueHuaMediaCompression（唯一公开入口）
│       └── rust/                    # flutter_rust_bridge 生成代码（勿 deep import）
├── rust/                   # Rust 实现
│   └── src/
│       ├── api/media.rs    # FRB external seam
│       ├── route.rs        # 内部压缩路由
│       ├── image.rs        # 纯 Rust 图片压缩
│       └── platform/       # 各 OS 硬件视频编码
├── android/ ios/ macos/ linux/ windows/   # 平台构建胶水
├── cargokit/               # Rust ↔ Flutter 构建集成
├── CONTEXT.md              # 领域术语与 seam 定义
└── example/                # 示例应用
```

---

## 可选：HEIC 支持

HEIC/HEIF 编解码需要 Rust `heic` feature 以及构建环境中的 **libheif**：

```toml
# rust/Cargo.toml — 已定义，默认关闭
[features]
heic = ["dep:libheif-rs"]
```

启用时需在 Cargokit / cargo 构建中传入 `--features heic`，并安装 libheif（如 macOS 上 `brew install libheif`）。未启用时，`ImageFormat.heic` 会返回 `MediaError.encode` / `MediaError.decode`。

---

## 许可证

见 [LICENSE](LICENSE)。

---

**[English →](README.md)** · **[Changelog / 更新日志 →](CHANGELOG.md)**
