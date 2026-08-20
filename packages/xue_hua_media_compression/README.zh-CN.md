# xue_hua_media_compression

**版本：** 2.0.1 · [English](README.md) · [Changelog](CHANGELOG.md)

联合 Flutter 插件，提供**图片与视频压缩**。各端使用系统硬编管线。**不支持 Web**。

## 能力矩阵

| | Android | iOS / macOS | Windows | Linux |
|---|---|---|---|---|
| JPEG / PNG | 立即 | 立即 | 立即 | 立即 |
| WebP 编码 | 立即 | 不可能 | 有 WIC 才立即 | libvips 含 webp 才立即 |
| HEIC 编码 | API 28+ | 立即 | 有 HEIF 扩展才立即 | 不可能 |
| AVIF / GIF 编码 | 不可能 | 不可能 | 不可能 | 不可能 |
| H.264 / H.265 MP4（无音轨） | Media3 Transformer | AVAssetWriter | MediaTranscoder | FFmpeg VAAPI |
| `content://` 输入 | 立即 | 不可能 | 不可能 | 不可能 |

做不到的能力抛 `MediaCompressionException.unsupported` 或 `hardwareUnavailable`，禁止静默改格式。

## 环境

| | |
|---|---|
| Flutter | ≥ 3.44.0 |
| Dart | ≥ 3.12.0 |
| Android | minSdk 23 |
| iOS / macOS | iOS 12 / macOS 10.15 |
| Linux | `libvips-dev` `libavcodec-dev` `libavfilter-dev` `libva-dev` 以及 VAAPI 驱动 |

## 安装

```yaml
dependencies:
  xue_hua_media_compression: ^2.0.0
```

## 用法

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

视频 `compress` 同样立即返回会话；输出始终为无音轨 MP4。先 `queryCapabilities()` 再填格式下拉。

非法参数在 Dart 抛 `ArgumentError`；平台失败抛 `MediaCompressionException`。

## 许可

见 [LICENSE](LICENSE)。
