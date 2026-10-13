# xue_hua_media_compression_linux

The Linux implementation of [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression).
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的 Linux 实现。

Image compression uses libvips. Video uses **GStreamer** (H.264 / H.265 in
MP4): hardware encoders are preferred (`va` → `vaapi` → `nvcodec`) and the
plugin falls back automatically to software (`x264enc` / `openh264enc` for
H.264, `x265enc` for H.265) when no hardware encoder exists or it fails at
runtime. Decoding uses `decodebin` (hardware decoders when available). With
`keepAudio` the audio track is re-encoded to AAC (`fdkaacenc` / `voaacenc`).
gst-libav (`avdec_*` / `avenc_*`) is never used, even if installed.

图片走 libvips；视频走 **GStreamer**（MP4 内 H.264 / H.265）：优先硬件编码
（`va` → `vaapi` → `nvcodec`），没有硬件编码器或运行时失败时自动回退到软件编码
（H.264：`x264enc` / `openh264enc`；H.265：`x265enc`）。解码用 `decodebin`
（有硬件解码器时自动使用）。`keepAudio` 时音频转码为 AAC（`fdkaacenc` / `voaacenc`）。
任何情况下都不会使用 gst-libav（`avdec_*` / `avenc_*`）。

### Build dependencies / 构建依赖

Debian / Ubuntu:

```bash
sudo apt install libvips-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

Fedora / RHEL (RHEL needs EPEL + RPM Fusion for x264/x265/openh264):

```bash
sudo dnf install vips-devel gstreamer1-devel gstreamer1-plugins-base-devel
```

### Runtime GStreamer plugins / 运行时插件

| Purpose | Debian / Ubuntu | Fedora / RHEL |
|---|---|---|
| Core, `decodebin`, `videoconvert`, `videoscale`, `audioconvert` | `gstreamer1.0-plugins-base` | `gstreamer1-plugins-base` |
| `mp4mux`, `qtdemux` | `gstreamer1.0-plugins-good` | `gstreamer1-plugins-good` |
| `h264parse`, `h265parse`, `va` HW encoders/decoders, `nvcodec`, `openh264enc/dec`, `voaacenc`, `faad` | `gstreamer1.0-plugins-bad` | `gstreamer1-plugins-bad-free` (+ `gstreamer1-plugins-bad-freeworld` from RPM Fusion, `gstreamer1-plugin-openh264`) |
| `x264enc` (H.264 SW) | `gstreamer1.0-plugins-ugly` | `gstreamer1-plugins-ugly` (RPM Fusion) |
| `x265enc` (H.265 SW) | `gstreamer1.0-plugins-bad` | `gstreamer1-plugins-bad-freeworld` (RPM Fusion) |
| Legacy `vaapih264enc` (optional) | `gstreamer1.0-vaapi` | `gstreamer1-vaapi` |
| VA-API drivers (HW path) | `intel-media-va-driver` / `mesa-va-drivers` | `intel-media-driver` / `mesa-va-drivers` |

Do **not** install `gstreamer1.0-libav` / `gstreamer1-libav` for this plugin;
it is not needed and is ignored if present.

## Usage / 用法

This package is [endorsed](https://flutter.dev/to/endorsed-federated-plugin),
which means you can simply use `xue_hua_media_compression` normally. This
package will be automatically included in your app when you do, so you do not
need to add it to your `pubspec.yaml`.

本包是 `xue_hua_media_compression` 的官方背书实现：直接依赖
`xue_hua_media_compression` 即可自动引入，无需在 `pubspec.yaml` 中单独添加。
