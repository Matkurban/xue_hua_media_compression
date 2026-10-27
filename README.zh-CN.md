# xue_hua_media_compression

[English](README.md)

Flutter 插件，提供**图片与视频压缩**。各端使用系统硬编管线。**不支持 Web**。

## 能力矩阵

|                        | Android            | iOS / macOS   | Windows         | Linux              |
|------------------------|--------------------|---------------|-----------------|--------------------|
| JPEG / PNG             | 是                  | 是             | 是               | 是                  |
| WebP 编码              | 是                  | ImageIO 支持时  | 有 WIC 才支持     | libvips 含 webp 才支持 |
| HEIC 编码              | API 28+ 且有 HEVC   | 是             | 有 HEIF 扩展才支持 | 否                  |
| AVIF / GIF 编码        | 否                  | 否             | 否               | 否                  |
| H.264 / H.265 MP4      | MediaCodec HW/SW   | AVAssetWriter | Media Foundation | GStreamer HW/SW   |
| `content://` 输入      | 是                  | 否             | 否               | 否                  |

视频输出始终为 MP4。`VideoCompressOptions.keepAudio` 默认 `true`（AAC 透传或转码）。Android 对 AAC 透传，其它音轨转成 AAC。Android、Windows 与 Linux 在源片有音轨但没有 AAC 编码器时抛 `unsupported`。

运行时先调用 `queryCapabilities()`，用 `outputFormats` / `codecs` 填选项。缺能力抛 `MediaCompressionException.unsupported` 或 `hardwareUnavailable`，禁止静默改格式。

GIF 输入只解码首帧。AVIF / GIF 在所有已支持平台上都不能编码。

## 环境

|             |                                                                               |
|-------------|-------------------------------------------------------------------------------|
| Flutter     | ≥ 3.44.0                                                                      |
| Dart        | ≥ 3.12.0                                                                      |
| Android     | minSdk 23，MediaCodec / MediaMuxer / Bitmap / ImageDecoder（不使用 FFmpeg） |
| iOS / macOS | iOS 12 / macOS 10.15                                                          |
| Windows     | Windows 10+，Media Foundation（不使用 FFmpeg）                                |
| Linux       | `libvips-dev`、`libgstreamer1.0-dev`、`libgstreamer-plugins-base1.0-dev` 以及 GStreamer base/good/bad/ugly 插件 |

## 安装

```yaml
dependencies:
  xue_hua_media_compression: ^2.3.2
```

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

## 用法

`compress` **立即**返回 `CompressionSession`。监听 `progress` 获得 0.0–1.0。新的订阅者会先收到已经产生的最新进度，再收到后续更新。然后 `await session.result`，最后 `await session.dispose()`。

### 图片

默认：JPEG、quality 80、不缩放、不保留元数据。PNG 忽略 `quality`。设置 `maxDimension` 时必须 `> 0`，编码前等比缩小。`keepMetadata` 在 Windows/Linux 上忽略；Android 上 HEIC 输出不保留 EXIF。

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

内存进出：

```dart
final session = XueHuaMediaCompression.image.compress(
  source: MediaSource.bytes(bytes),
  destination: MediaDestination.bytes(),
);
final result = await session.result;
await session.dispose();
// result.bytes 非空；result.outputPath 为 null
```

### 视频

只用文件路径（`inputPath` / `outputPath`），没有 `MediaSource`。`bitrate` 单位是 **bps**（默认 `2000000`）。`file://` 在 Dart 侧规范化；`content://` 仅 Android。

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

`await session.cancel()` 中止任务；随后 `session.result` 抛 `MediaCompressionException.cancelled`。`cancel` 与 `dispose` 均可重复调用。

Windows 的 Media Foundation H.264 / HEVC 编码器拒绝小于 64×64 的画面（`MF_E_INVALIDMEDIATYPE`）。偶数对齐之后只要有一边小于 64，压缩抛 `unsupported`，并且不写输出文件。

## 错误

进入原生之前，下列情况在 Dart 侧抛 `ArgumentError`：

- 路径（trim 后）为空，或图片字节为空
- `quality` 不在 1–100
- 已设置的 `bitrate` / `fps` / `maxDimension` / `keyframeInterval` `<= 0`

原生失败抛 `MediaCompressionException`。用该类上的常量比较 `error.code`（`cancelled`、`unsupported`、`hardwareUnavailable` 等）。

## Package skills

本包随附图片与视频压缩的 agent skills。添加依赖后安装到编码助手：

```bash
dart run skills@ get
# 或非交互安装全部：
dart run skills@ get --all
```

## 开发

在包根目录执行：

```bash
flutter analyze
flutter test
dart run pigeon --input pigeons/messages.dart
```

Linux 图片 / 视频压缩（GStreamer + libvips，不要安装 `gstreamer1.0-libav`）：

```bash
# libvips-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
# gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-tools
cd example
xvfb-run -a flutter test integration_test/driver_test.dart -d linux
xvfb-run -a flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/driver_test.dart \
  -d linux
flutter build linux
```

Windows 图片与视频（WIC + Media Foundation，不用 FFmpeg）。机器需要 Media Foundation 的 H.264 编码器（桌面版 Windows 自带；部分 Server 镜像要装 Media Feature Pack）：

```bash
cd example
flutter test integration_test/driver_test.dart -d windows
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/driver_test.dart \
  -d windows
flutter build windows
```

macOS 与 iOS（共用 Darwin 源码：ImageIO + AVFoundation / VideoToolbox，不用 FFmpeg）。在 Apple Silicon Mac，或 iOS 模拟器 / 真机上，用示例工程的 Flutter SDK 运行：

```bash
cd example
flutter test integration_test/macos_driver_test.dart -d macos
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/macos_driver_test.dart \
  -d macos
flutter build macos

# iOS 模拟器或已连接的 iPhone。设备 id 用 flutter devices 查看。
flutter test integration_test/ios_driver_test.dart -d <device-id>
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/ios_driver_test.dart \
  -d <device-id>
```

有硬编时 `queryVideoCapabilities().encoderName` 为 `VideoToolboxHW`，模拟器上为 null。压缩结果是 `VideoToolbox:H264` 或 `VideoToolboxHW:H264`（H.265 同理）。

确认 macOS 插件二进制没有 FFmpeg：

```bash
BIN=$(find example/build/macos/Build/Products -type f \( -name '*.debug.dylib' -o -name 'xue_hua_media_compression_darwin' -o -name 'xue_hua_media_compression' \) ! -path '*/App.framework/*' ! -path '*/flutter_assets/*' | head -n 1)
strings "$BIN" | grep -E 'libavcodec|libavformat|libavutil|ffmpeg|gst-libav' && exit 1 || true
```

确认插件没有链接 FFmpeg：

```bash
SO=example/build/linux/x64/release/bundle/lib/libxue_hua_media_compression_plugin.so
readelf -d "$SO" | grep NEEDED
ldd "$SO"
strings "$SO" | grep -E 'libavcodec|libavformat|libavutil|libswscale|libswresample|libpostproc|avdec_|avenc_'
```

Android 图片 / 视频压缩（MediaCodec + MediaMuxer，不用 FFmpeg）。维护者的 Mac 上 `Pixel_8_Pro` 是 API 34，设备号为 `emulator-5554`。不要启动 `Bgdl_API_35` 或 `Bgdl_API_36`（那是其它项目的模拟器）。其它 API 可以并行跑，把 `flutter devices` 里各自的 id 传进去。

```bash
flutter emulators --launch Pixel_8_Pro
cd example
flutter test integration_test/android_driver_test.dart -d emulator-5554
```

```bash
flutter test integration_test/android_driver_test.dart -d emulator-5554   # API 34，Pixel_8_Pro
flutter test integration_test/android_driver_test.dart -d emulator-XXXX   # API 26
flutter test integration_test/android_driver_test.dart -d emulator-XXXX   # API 30
flutter test integration_test/android_driver_test.dart -d emulator-XXXX   # API 36
```

API 26 走 BitmapFactory，API 28+ 走 ImageDecoder。也可以用 `flutter drive`：

```bash
cd example
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/android_driver_test.dart \
  -d emulator-5554
```

## 许可

见 [LICENSE](LICENSE)。
