## [2.0.1] - 2026-08-21

### Fixed / 修复

- Documented Flutter requirement is now **≥ 3.44.0** (was 3.16); Dart **≥ 3.12.0**.
  README 环境要求改为 Flutter ≥ 3.44.0、Dart ≥ 3.12.0。

## [2.0.0] - 2026-08-20

### Breaking / 破坏性变更

- Rewrote the plugin as a **federated** package (no Web). Rust, Cargokit and
  `flutter_rust_bridge` are gone. Each OS uses its own hardware pipeline.
  改为联合插件（不含 Web），移除 Rust / Cargokit / FRB；各端走各自硬编管线。
- All 1.x method names are removed (`initialize`, `compressWith`,
  `compressFile`, `videoBackendName`, `ImageOptions.speed`, …). Callers must
  migrate to the session API.
  1.x 方法名全部删除，需改用会话 API。
- Android `minSdk` is **23**. Video output is always **MP4 without audio**.
  Android 最低 API 23。视频始终输出无音轨 MP4。

### Added / 新增

- `XueHuaMediaCompression.image` / `.video` with `queryCapabilities()` and
  `compress(...)` returning `CompressionSession` (`progress` stream, `result`,
  `cancel`, `dispose`). Progress is pushed from native EventChannels.
  会话式 API：进度由原生产推，可取消。
- Per-platform packages: `_android` (Media3 Transformer + ImageDecoder),
  `_darwin` (ImageIO + AVAssetWriter), `_windows` (WIC + MediaTranscoder),
  `_linux` (libvips + FFmpeg VAAPI).
- Structured `MediaCompressionException` codes (`unsupported`,
  `hardwareUnavailable`, `cancelled`, …).

## [1.4.0] - 2026-08-13

### Changed / 变更

- **Android `compileSdk` 36 / Android 编译 SDK** — Plugin `compileSdkVersion` raised from 33 to 36 so the
  library builds against current Android / Flutter toolchains. Host apps that still pin a lower
  `compileSdk` should bump it to at least 36.
  插件 `compileSdkVersion` 从 33 升至 36，以适配当前 Android / Flutter 工具链；仍锁定更低 `compileSdk` 的宿主
  应用需同步升至 36 及以上。

- **Android `minSdk` 21 / Android 最低 SDK** — Plugin `minSdkVersion` raised from 19 to 21 (Android 5.0).
  Apps that still target API 19–20 can no longer consume this plugin without raising their own `minSdk`.
  插件 `minSdkVersion` 从 19 升至 21（Android 5.0）；仍支持 API 19–20 的应用需同步提高 `minSdk` 才能依赖本插件。

- **Example Android Gradle Plugin / 示例 AGP** — Example app AGP updated from 8.11.1 to 8.13.2.
  示例工程 Android Gradle Plugin 从 8.11.1 升级到 8.13.2。

## [1.3.4] - 2026-07-13

### Fixed / 修复

- **macOS/iOS Pod build scripts CRLF / Pod 构建脚本行尾** — Ensure `cargokit/*.sh` ship with LF line
  endings and add `.gitattributes` so Windows `autocrlf` checkouts cannot republish CRLF scripts.
  Fixes Xcode `PhaseScriptExecution` failure (`set: - : invalid option`) when integrating from pub.dev.
  保证 `cargokit/*.sh` 以 LF 发布，并通过 `.gitattributes` 防止 Windows 检出后再发坏包；修复集成后
  Xcode 报 `set: - : invalid option` 导致 Pod 构建失败。

## [1.3.3] - 2026-07-12

### Fixed / 修复

- **Windows Media Foundation video encode / Windows 视频编码** — Replaced the fragile direct async hardware MFT
  `ProcessInput`/`ProcessOutput` loop with `IMFSourceReader` + `IMFSinkWriter`. Fixes build errors against
  `windows` 0.62 and runtime failures (`MF_E_TRANSFORM_ASYNC_LOCKED` `0xC00D6D77`, `MF_E_INVALIDMEDIATYPE`
  `0xC00D36B4`, `MF_E_NOTACCEPTING` `0xC00D36B5`, `E_UNEXPECTED` `0x8000FFFF`). SinkWriter correctly handles
  sync/async and hardware/software encoders; NV12 scaling is applied before write when `max_dimension` requires it.
  Covered by Windows unit tests (synthetic SinkWriter encode, full compress round-trip, scale-down).  
  将易错的异步硬件 MFT 直驱改为 SourceReader + SinkWriter；修复 `windows` 0.62 编译与上述运行时 HRESULT；
  缩放在写入前完成；补充 Windows 自动化测试。

## [1.3.2] - 2026-07-10

- Android 使用 current_thread FRB handler，避免多插件并存时 pthread_key 耗尽。

## [1.3.1] - 2026-07-04

- Optimized initialization

## [1.3.0] - 2026-07-02

### Fixed / 修复

- **Rust 2024 edition compatibility / Rust 2024 版本兼容** — Fix Android Gradle and cross-platform Rust builds after
  `edition = "2024"`: `extern "C"` FFI blocks now use `unsafe extern "C"`, and `unsafe fn` bodies wrap NDK / WMF /
  CoreVideo calls in explicit `unsafe { }` blocks (`unsafe_op_in_unsafe_fn` / E0133). Resolves `assembleDebug` /
  `cargo build` failures on current Rust toolchains.
  修复升级 `edition = "2024"` 后的编译失败：`extern "C"` 改为 `unsafe extern "C"`；Android `pipeline`、NDK 工具函数、Windows
  Media Foundation、Apple `reader` 等 `unsafe fn` 内补齐显式 `unsafe` 块，消除 E0133 警告并恢复 Android 构建。

## [1.2.2] - 2026-07-02

### Fixed / 修复

- **Android NDK context init / Android NDK 上下文初始化** — Align with sibling plugins (`xue_hua_audio`,
  `xue_hua_device_info`): Kotlin `XueHuaMediaCompressionPlugin` with `@JvmStatic initAndroid`, dedicated
  `rust/src/android_init.rs`, and `CONTEXT_HOLDER` idempotent guard. Fixes `assertion failed: previous.is_none()` panic
  when `onAttachedToEngine` is called more than once during plugin registration.
  对齐兄弟插件的 jni 0.22 + `ndk-context` 初始化模式；`CONTEXT_HOLDER` 幂等守卫修复插件注册阶段多次 `onAttachedToEngine`
  时 `ndk_context` 重复初始化崩溃。

- **Removed unused `mediacodec` dependency / 移除未使用的 `mediacodec` 依赖** — Android 视频硬编仍使用自研 NDK FFI（
  `platform/android/ndk.rs`）。
  Android 视频路径未变，仅清理 Cargo 依赖。

## [1.2.1] - 2026-6-30

- fix `android` build error

## [1.2.0] - 2026-06-30

### Changed / 变更

- **Sealed external seam / 封住外部接缝** — FRB `rust_input` narrowed to `api::media` + `api::traits`; internal
  compressors moved behind `route` module with free-function dispatch. Dart bindings no longer export
  `AppleVideoCompressor`, `GenericImageCompressor`, or scaffold `greet`.  
  收窄 FRB 扫描范围；压缩路由经 `route` module；Dart 不再导出泄漏的平台 compressor 与脚手架 `greet`。

- **Removed `apple_stub.rs` / 删除 apple stub** — `platform::apple` compiles only on iOS/macOS.  
  `platform::apple` 仅在 Apple target 编译，移除仅为 codegen 服务的 stub。

- **Removed `RustLib` from public export / 公开 API 不再 export `RustLib`** — use `XueHuaMediaCompression.initialize()`
  instead.  
  请统一使用 `XueHuaMediaCompression.initialize()` 初始化。

### Breaking changes / 破坏性变更

- Removed public export of `RustLib`.
- Removed generated Dart bindings for direct compressor access (`AppleVideoCompressor.compress`,
  `GenericImageCompressor.compress`, `greet`). Use `XueHuaMediaCompression.image` / `.video` instead.

---

## [1.1.1] - 2026-06-29

### Fixed / 修复

- **Android JNI (`jni` 0.22) / Android JNI 迁移** — Migrated `android_file.rs` from deprecated `JNIEnv` to `Env` /
  `EnvUnowned`; `JavaVM::attach_current_thread` now uses the closure API; `JObject::from_raw` and `jni_str!` /
  `jni_sig!` updated for 0.22. Removes `deprecated type alias jni::JNIEnv` build warnings.  
  将 `android_file.rs` 从已弃用的 `JNIEnv` 迁移至 `Env` / `EnvUnowned`；`attach_current_thread` 改为闭包调用；
  `JObject::from_raw` 与 `jni_str!` / `jni_sig!` 适配 0.22，消除 Android 构建中的 JNI 弃用警告。

---

## [1.1.0] - 2026-06-28

### Changed / 变更

- **Direct path input / 路径直传** — File picker paths (`xFile.path`) are passed directly to Rust; no Dart-side cache
  copy or `readAsBytes`. Rust normalizes `file://` prefixes and reads files by path.  
  文件选择器路径（`xFile.path`）直接传给 Rust，不再在 Dart 侧复制到缓存或 `readAsBytes`；Rust 规范化 `file://` 并按路径读文件。

- **Android `content://` / Android content URI** — Opened in Rust via `ContentResolver` + fd for `AMediaExtractor` (
  streaming, no full-file load in Dart).  
  Android `content://` 由 Rust 通过 `ContentResolver` 取 fd 供 `AMediaExtractor` 流式读取。

- **Linux video streaming / Linux 视频流式处理** — VA-API pipeline decodes and encodes one frame at a time with a fixed
  surface pool; no longer buffers all NV12 frames in memory (same class of OOM fix as Apple VideoToolbox).  
  Linux VA-API 管线改为逐帧解码+编码并使用固定 surface 池，不再将全部 NV12 帧载入内存（与 Apple VideoToolbox 同类 OOM 修复）。

- **Apple (macOS/iOS) video streaming / Apple 视频流式处理** — VideoToolbox pipeline streams decode+encode per frame
  instead of loading all CVPixelBuffers.  
  VideoToolbox 改为逐帧流式解码+编码，不再一次性加载全部 CVPixelBuffer。

- **Output path parent dirs / 输出目录** — Rust creates parent directories before writing image/video output (
  `prepare_output_path`).  
  Rust 写入图片/视频输出前自动创建父目录（`prepare_output_path`）。

- **Example temp dir / 示例临时目录** — Example uses `Directory.systemTemp` instead of `path_provider` (avoids macOS
  native dependency conflicts).  
  示例改用 `Directory.systemTemp`，不再依赖 `path_provider`（避免 macOS 原生依赖冲突）。

### Removed / 移除

- **`ensureLocalFileInput` / `ensureLocalVideoInput`** — Removed from the public API; use direct paths instead.  
  已从公开 API 移除；请直接传入 picker 路径。

---

## [1.0.0] - 2026-06-27

First public release.  
首次公开发布。

### Added / 新增

- **Image compression / 图片压缩** — Pure Rust pipeline on all platforms; output JPEG, PNG, WebP, GIF, AVIF; optional
  HEIC (build-time feature). Supports quality, max-dimension downscale, and format-specific speed options.  
  全平台纯 Rust 图片压缩管线；支持输出 JPEG、PNG、WebP、GIF、AVIF；可选 HEIC（构建时 feature）。支持质量、最大边长缩放及格式相关速度参数。

- **Video compression / 视频压缩** — Platform-native hardware encoding with MP4 muxing:  
  各平台原生硬件编码并封装 MP4：
    - Android — AMediaCodec (NDK)
    - iOS / macOS — VideoToolbox
    - Windows — Media Foundation
    - Linux — VA-API

- **Dart facade API / Dart 门面 API** — `XueHuaMediaCompression.initialize()`, `.image.*`, `.video.*`, and
  `videoBackendName()` for diagnostics.  
  `XueHuaMediaCompression.initialize()`、`.image.*`、`.video.*` 及诊断用 `videoBackendName()`。

- **`ensureLocalVideoInput` helper / 辅助函数** — Copies picker `content://` or inaccessible paths to a local cache file
  on Android (with size and container validation).  
  在 Android 上将选择器 `content://` 或不可直接访问的路径复制到本地缓存（含大小与容器校验）。

- **Example app / 示例应用** — Interactive demo for image and video compression in `example/`.  
  `example/` 目录下的图片与视频压缩交互式 Demo。

- **Multi-platform FFI plugin / 多平台 FFI 插件** — Android, iOS, macOS, Windows, Linux via Cargokit +
  flutter_rust_bridge 2.12.  
  通过 Cargokit + flutter_rust_bridge 2.12 支持 Android、iOS、macOS、Windows、Linux。
