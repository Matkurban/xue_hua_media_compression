# xue_hua_media_compression_linux

The Linux implementation of [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression).
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的 Linux 实现。

Image compression uses libvips; video uses FFmpeg with VAAPI for H.264 / H.265
MP4 (no audio).

图片走 libvips；视频走 FFmpeg VAAPI，输出无音轨 H.264 / H.265 MP4。

Building requires the corresponding development headers:
构建需要安装对应开发包：

```bash
sudo apt install libvips-dev libavcodec-dev libavfilter-dev libva-dev
```

## Usage / 用法

This package is [endorsed](https://flutter.dev/to/endorsed-federated-plugin),
which means you can simply use `xue_hua_media_compression` normally. This
package will be automatically included in your app when you do, so you do not
need to add it to your `pubspec.yaml`.

本包是 `xue_hua_media_compression` 的官方背书实现：直接依赖
`xue_hua_media_compression` 即可自动引入，无需在 `pubspec.yaml` 中单独添加。
