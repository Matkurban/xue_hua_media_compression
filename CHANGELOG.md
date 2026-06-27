# Changelog / 更新日志

All notable changes to this project will be documented in this file.  
本项目的所有重要变更均记录于此。

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

**Documentation / 文档:** [English](README.md) · [中文](README.zh-CN.md)

---

## [1.0.0] - 2025-06-27

First public release.  
首次公开发布。

### Added / 新增

- **Image compression / 图片压缩** — Pure Rust pipeline on all platforms; output JPEG, PNG, WebP, GIF, AVIF; optional HEIC (build-time feature). Supports quality, max-dimension downscale, and format-specific speed options.  
  全平台纯 Rust 图片压缩管线；支持输出 JPEG、PNG、WebP、GIF、AVIF；可选 HEIC（构建时 feature）。支持质量、最大边长缩放及格式相关速度参数。

- **Video compression / 视频压缩** — Platform-native hardware encoding with MP4 muxing:  
  各平台原生硬件编码并封装 MP4：
  - Android — AMediaCodec (NDK)
  - iOS / macOS — VideoToolbox
  - Windows — Media Foundation
  - Linux — VA-API

- **Dart facade API / Dart 门面 API** — `XueHuaMediaCompression.initialize()`, `.image.*`, `.video.*`, and `videoBackendName()` for diagnostics.  
  `XueHuaMediaCompression.initialize()`、`.image.*`、`.video.*` 及诊断用 `videoBackendName()`。

- **`ensureLocalVideoInput` helper / 辅助函数** — Copies picker `content://` or inaccessible paths to a local cache file on Android (with size and container validation).  
  在 Android 上将选择器 `content://` 或不可直接访问的路径复制到本地缓存（含大小与容器校验）。

- **Example app / 示例应用** — Interactive demo for image and video compression in `example/`.  
  `example/` 目录下的图片与视频压缩交互式 Demo。

- **Multi-platform FFI plugin / 多平台 FFI 插件** — Android, iOS, macOS, Windows, Linux via Cargokit + flutter_rust_bridge 2.12.  
  通过 Cargokit + flutter_rust_bridge 2.12 支持 Android、iOS、macOS、Windows、Linux。

[1.0.0]: https://github.com/your-org/xue_hua_media_compression/releases/tag/v1.0.0
