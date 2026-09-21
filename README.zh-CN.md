# xue_hua_media_compression

[English](README.md)

联合 Flutter 插件，提供**图片与视频压缩**。各端使用系统硬编管线。**不支持 Web**。

## 能力矩阵

|                        | Android            | iOS / macOS   | Windows         | Linux              |
|------------------------|--------------------|---------------|-----------------|--------------------|
| JPEG / PNG             | 是                  | 是             | 是               | 是                  |
| WebP 编码              | 是                  | 否             | 有 WIC 才支持     | libvips 含 webp 才支持 |
| HEIC 编码              | API 28+            | 是             | 有 HEIF 扩展才支持 | 否                  |
| AVIF / GIF 编码        | 否                  | 否             | 否               | 否                  |
| H.264 / H.265 MP4      | Media3 Transformer | AVAssetWriter | MediaTranscoder | FFmpeg VAAPI       |
| `content://` 输入      | 是                  | 否             | 否               | 否                  |

视频输出始终为 MP4。`VideoCompressOptions.keepAudio` 默认 `true`（AAC 透传或转码）。Windows / Linux 忽略 `keepAudio`。

运行时先调用 `queryCapabilities()`，用 `outputFormats` / `codecs` 填选项。缺能力抛 `MediaCompressionException.unsupported` 或 `hardwareUnavailable`，禁止静默改格式。

GIF 输入只解码首帧。AVIF / GIF 在所有已支持平台上都不能编码。

## 环境

|             |                                                                               |
|-------------|-------------------------------------------------------------------------------|
| Flutter     | ≥ 3.44.0                                                                      |
| Dart        | ≥ 3.12.0                                                                      |
| Android     | minSdk 23, Media3 Transformer                                                 |
| iOS / macOS | iOS 12 / macOS 10.15                                                          |
| Windows     | Windows 10+, C++/WinRT                                                        |
| Linux       | `libvips-dev`、`libavcodec-dev`、`libavfilter-dev`、`libva-dev` 以及 VAAPI 驱动 |

## 安装

```yaml
dependencies:
  xue_hua_media_compression: ^2.0.5
```

```dart
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
```

## 用法

`compress` **立即**返回 `CompressionSession`。立刻监听 `progress`（流不会重放错过的事件），再 `await session.result`，最后 `await session.dispose()`。

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

## 许可

见 [LICENSE](LICENSE)。
