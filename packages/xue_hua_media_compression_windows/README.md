# xue_hua_media_compression_windows

The Windows implementation of [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression).
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的 Windows 实现。

Image compression uses WIC; video uses Media Foundation `MediaTranscoder` for
H.264 / H.265 MP4 (no audio).

图片走 WIC；视频走 Media Foundation `MediaTranscoder`，输出无音轨 H.264 /
H.265 MP4。

## Usage / 用法

This package is [endorsed](https://flutter.dev/to/endorsed-federated-plugin),
which means you can simply use `xue_hua_media_compression` normally. This
package will be automatically included in your app when you do, so you do not
need to add it to your `pubspec.yaml`.

本包是 `xue_hua_media_compression` 的官方背书实现：直接依赖
`xue_hua_media_compression` 即可自动引入，无需在 `pubspec.yaml` 中单独添加。
