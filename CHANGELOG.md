# Changelog / 更新日志

All notable changes to this project will be documented in this file.  
本项目的所有重要变更均记录于此。

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

**Documentation / 文档:** [English](README.md) · [中文](README.zh-CN.md)


## [1.1.1] - 2026-06-29

### Fixed / 修复

- **Android JNI (`jni` 0.22) / Android JNI 迁移** — Migrated `android_file.rs` from deprecated `JNIEnv` to `Env` / `EnvUnowned`; `JavaVM::attach_current_thread` now uses the closure API; `JObject::from_raw` and `jni_str!` / `jni_sig!` updated for 0.22. Removes `deprecated type alias jni::JNIEnv` build warnings.  
  将 `android_file.rs` 从已弃用的 `JNIEnv` 迁移至 `Env` / `EnvUnowned`；`attach_current_thread` 改为闭包调用；`JObject::from_raw` 与 `jni_str!` / `jni_sig!` 适配 0.22，消除 Android 构建中的 JNI 弃用警告。

---

## [1.1.0] - 2026-06-28

### Changed / 变更

- **Direct path input / 路径直传** — File picker paths (`xFile.path`) are passed directly to Rust; no Dart-side cache copy or `readAsBytes`. Rust normalizes `file://` prefixes and reads files by path.  
  文件选择器路径（`xFile.path`）直接传给 Rust，不再在 Dart 侧复制到缓存或 `readAsBytes`；Rust 规范化 `file://` 并按路径读文件。

- **Android `content://` / Android content URI** — Opened in Rust via `ContentResolver` + fd for `AMediaExtractor` (streaming, no full-file load in Dart).  
  Android `content://` 由 Rust 通过 `ContentResolver` 取 fd 供 `AMediaExtractor` 流式读取。

- **Linux video streaming / Linux 视频流式处理** — VA-API pipeline decodes and encodes one frame at a time with a fixed surface pool; no longer buffers all NV12 frames in memory (same class of OOM fix as Apple VideoToolbox).  
  Linux VA-API 管线改为逐帧解码+编码并使用固定 surface 池，不再将全部 NV12 帧载入内存（与 Apple VideoToolbox 同类 OOM 修复）。

- **Apple (macOS/iOS) video streaming / Apple 视频流式处理** — VideoToolbox pipeline streams decode+encode per frame instead of loading all CVPixelBuffers.  
  VideoToolbox 改为逐帧流式解码+编码，不再一次性加载全部 CVPixelBuffer。

- **Output path parent dirs / 输出目录** — Rust creates parent directories before writing image/video output (`prepare_output_path`).  
  Rust 写入图片/视频输出前自动创建父目录（`prepare_output_path`）。

- **Example temp dir / 示例临时目录** — Example uses `Directory.systemTemp` instead of `path_provider` (avoids macOS native dependency conflicts).  
  示例改用 `Directory.systemTemp`，不再依赖 `path_provider`（避免 macOS 原生依赖冲突）。

### Removed / 移除

- **`ensureLocalFileInput` / `ensureLocalVideoInput`** — Removed from the public API; use direct paths instead.  
  已从公开 API 移除；请直接传入 picker 路径。

---

## [1.0.0] - 2026-06-27

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
