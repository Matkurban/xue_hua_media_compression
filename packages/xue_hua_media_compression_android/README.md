# xue_hua_media_compression_android

The Android implementation of [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression).
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的 Android 实现。

Image compression uses `ImageDecoder` / `Bitmap`; video uses Media3 Transformer
for H.264 / H.265 MP4 (no audio). `content://` URIs are accepted.

图片走 `ImageDecoder` / `Bitmap`；视频走 Media3 Transformer，输出无音轨 H.264 /
H.265 MP4。支持 `content://` 输入。

## Usage / 用法

This package is [endorsed](https://flutter.dev/to/endorsed-federated-plugin),
which means you can simply use `xue_hua_media_compression` normally. This
package will be automatically included in your app when you do, so you do not
need to add it to your `pubspec.yaml`.

本包是 `xue_hua_media_compression` 的官方背书实现：直接依赖
`xue_hua_media_compression` 即可自动引入，无需在 `pubspec.yaml` 中单独添加。
