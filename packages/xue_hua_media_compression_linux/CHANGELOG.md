## 2.0.3

- Fix Linux build failure with `-Werror` (`-Wunused-result`) in `video_vaapi.cc`: check return values of `avformat_write_header`, `avio_open`, `av_interleaved_write_frame`, `av_write_trailer`, `avio_closep`, `avformat_alloc_output_context2`, `avformat_new_stream`, `avcodec_parameters_from_context`, with proper error reporting and resource cleanup.

## 2.0.2

- update package version

## 2.0.1

- Align README Flutter requirement with pubspec (`>= 3.44.0`).
  README 的 Flutter 版本要求与 pubspec 对齐。

## 2.0.0

- Initial federated release: libvips image compression and FFmpeg VAAPI
  video (H.264 / H.265 MP4, no audio).
  联合插件首个 Linux 实现：libvips 图片与 FFmpeg VAAPI 视频压缩。
