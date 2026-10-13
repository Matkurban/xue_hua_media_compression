## 2.1.0

- **Video backend rewritten on GStreamer.** The previous codec-library backend is removed
  entirely; the plugin now links only GStreamer core/pbutils/video and libvips.
  视频后端改为 GStreamer，移除原有编解码库依赖。
- Hardware encoders preferred (`vah264enc`/`vah265enc`, `vaapih26xenc`, `nvh26xenc`),
  automatic software fallback (`x264enc`, `openh264enc`, `x265enc`) when HW is missing
  or fails at runtime. H.265 now works without hardware via `x265enc`.
  优先硬件编码，失败或缺失时自动回退软件编码；H.265 无硬件时也可用。
- gst-libav elements are never auto-plugged, even if installed.
- `keepAudio` is now honoured on Linux (AAC via `fdkaacenc` / `voaacenc`).
- Output is 8-bit 4:2:0; `encoderName` is now `GStreamer:<element>`; capabilities report
  `GStreamerHW` / `GStreamerSoftware`.
- New system dependencies, see README. 新的系统依赖见 README。

## 2.0.3

- Fix Linux build failure with `-Werror` (`-Wunused-result`) in the VAAPI video backend: check muxer/IO return values with proper error reporting and resource cleanup.

## 2.0.2

- update package version

## 2.0.1

- Align README Flutter requirement with pubspec (`>= 3.44.0`).
  README 的 Flutter 版本要求与 pubspec 对齐。

## 2.0.0

- Initial federated release: libvips image compression and VAAPI
  video (H.264 / H.265 MP4, no audio).
  联合插件首个 Linux 实现：libvips 图片与 VAAPI 视频压缩。
