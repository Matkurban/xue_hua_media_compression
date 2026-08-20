# xue_hua_media_compression_darwin

The iOS and macOS implementation of [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression).
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的 iOS 与 macOS 实现（共享 Swift 源码）。

Image compression uses ImageIO; video uses `AVAssetWriter` for H.264 / H.265
MP4 (no audio).

图片走 ImageIO；视频走 `AVAssetWriter`，输出无音轨 H.264 / H.265 MP4。

## Usage / 用法

This package is [endorsed](https://flutter.dev/to/endorsed-federated-plugin),
which means you can simply use `xue_hua_media_compression` normally. This
package will be automatically included in your app when you do, so you do not
need to add it to your `pubspec.yaml`.

本包是 `xue_hua_media_compression` 的官方背书实现：直接依赖
`xue_hua_media_compression` 即可自动引入，无需在 `pubspec.yaml` 中单独添加。
