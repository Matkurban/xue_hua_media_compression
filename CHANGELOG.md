## 2.3.3

* Android: strip display-width/height before MediaCodec decoder configure (MPEG-4 on API 30).
* Android: map missing content:// videos to notFound via ContentResolver.
* Tests: resolve FileProvider cache when systemTemp is code_cache; stream-read /proc/self/maps.

## [2.3.2] - 2026-10-26

### Fixed / 修复

- Android video no longer requires a hardware encoder or Media3 Transformer. `codecs` lists MediaCodec encoders that are installed (hardware or software). `encoderName` is `MediaCodecHW` only when a hardware video encoder is present, otherwise null. Compress results name the encoder that ran (`MediaCodec:H264`, `MediaCodecHW:H265`, …). Missing H.264/H.265 throws `unsupported`.
  Android 视频不再强制硬编，也不再使用 Media3 Transformer。`codecs` 是本机已安装的 MediaCodec 编码器（硬编或软编）。只有存在硬编时 `encoderName` 才是 `MediaCodecHW`，否则为 null。压缩结果里的名字是实际编码器（`MediaCodec:H264`、`MediaCodecHW:H265` 等）。没有 H.264/H.265 编码器时抛 `unsupported`。
- Android video honours `keepAudio` (AAC passthrough, or PCM transcode when the source is not AAC). When the source has audio and no AAC encoder is installed, `keepAudio: true` throws `unsupported` instead of dropping the track. `keepAudio: false` writes a silent MP4. `fps`, `maxDimension` (even dimensions), and `keyframeInterval` are applied. Cancel stops the encode and deletes the output. A missing file is `notFound`, a directory is `io`, and a corrupt file is `decode`. `content://` input is accepted.
  Android 视频遵守 `keepAudio`（AAC 透传，非 AAC 则转码）。源片有音轨但没有 AAC 编码器时，`keepAudio: true` 抛 `unsupported`，不再静默丢掉音轨。`keepAudio: false` 写出无音轨 MP4。`fps`、`maxDimension`（偶数尺寸）和 `keyframeInterval` 会生效。取消会停掉编码并删除输出。文件不存在为 `notFound`，目录为 `io`，损坏文件为 `decode`。接受 `content://` 输入。
- Android image errors match the other platforms: a missing file or `content://` is `notFound`, a file that exists but cannot be decoded is `decode`, and a directory is `io`. Cancelling an image compress deletes the output. Encode failures remove a partial file. HEIC output is advertised only on API 28+ when an HEVC encoder is installed.
  Android 图片错误与其它平台对齐：文件或 `content://` 不存在为 `notFound`，文件在但解不出为 `decode`，目录为 `io`。取消图片压缩会删掉输出。编码失败会删掉半成品。只有 API 28+ 且安装了 HEVC 编码器时才宣告 HEIC 输出。
- Jobs stay alive until the worker finishes, so `dispose` during an encode no longer frees the event channel out from under MediaCodec. Progress below 1.0 stays throttled, and the latest value is flushed before completion.
  任务会活到工作线程结束，编码过程中 `dispose` 不再把事件通道从 MediaCodec 底下拆掉。低于 1.0 的进度仍节流，完成前会送出最新一条。

### Changed / 变更

- Android video encode uses MediaCodec + MediaMuxer (hardware when present, software otherwise) and image encode uses Bitmap / ImageDecoder / HeifWriter. The plugin does not use FFmpeg, libav, or Media3.
  Android 视频走 MediaCodec + MediaMuxer（有硬编用硬编，否则软编），图片走 Bitmap / ImageDecoder / HeifWriter。不使用 FFmpeg、libav 或 Media3。

## [2.3.1] - 2026-10-26

### Fixed / 修复

- Darwin (iOS / macOS) image errors match the other platforms. A missing file is `notFound`, a file that exists but cannot be decoded is `decode`, and a directory is `io`. Cancelling an image compress deletes the output. Encode failures remove a partial file. `queryImageCapabilities` lists HEIC and WebP only when ImageIO can actually encode them. Reported file sizes are the real byte length.
  Darwin（iOS / macOS）图片错误与其它平台对齐。文件不存在为 `notFound`，文件在但解不出为 `decode`，目录为 `io`。取消图片压缩会删掉输出。编码失败会删掉半成品。`queryImageCapabilities` 只在 ImageIO 真能编码时列出 HEIC 和 WebP。返回的文件大小是实际字节数。
- Darwin video `encoderName` is `VideoToolboxHW` only when a hardware encoder is present, otherwise null. Software H.264 stays in `codecs`. Compress results name the encoder that ran (`VideoToolbox:H264`, `VideoToolboxHW:H265`, …). Frames smaller than 64px, or a hardware encoder that rejects the frame, fall back to the software encoder instead of failing.
  Darwin 视频只有存在硬编时 `encoderName` 才是 `VideoToolboxHW`，否则为 null。软编 H.264 仍在 `codecs` 里。压缩结果写的是实际编码器（`VideoToolbox:H264`、`VideoToolboxHW:H265` 等）。边长小于 64，或硬编拒绝该尺寸时，会改走软编而不是失败。
- Darwin video honours cancel by stopping AVAssetReader / AVAssetWriter and deleting the output, including when `dispose` runs during the encode. `cancel` returns as soon as the flag is set. `cancelWriting` runs on a side queue, so the platform thread and the media callback cannot deadlock waiting for each other. The session always settles with `cancelled`. The event channel stays alive until the worker finishes. Missing files are `notFound`, directories are `io`, and corrupt files are `decode`. Odd dimensions are scaled to even numbers. `fps`, `maxDimension`, and `keyframeInterval` still apply. `keepAudio: true` transcodes non-AAC audio to AAC.
  Darwin 视频取消时会停掉 AVAssetReader / AVAssetWriter 并删除输出；编码过程中 `dispose` 也一样。`cancel` 在置位后立刻返回。`cancelWriting` 在旁路队列上执行，平台线程和媒体回调不会互相死等。会话一定会以 `cancelled` 结束。事件通道会留到工作线程结束。文件不存在为 `notFound`，目录为 `io`，损坏文件为 `decode`。奇数边会收成偶数。`fps`、`maxDimension` 和 `keyframeInterval` 仍然生效。`keepAudio: true` 会把非 AAC 音轨转成 AAC。
- Progress events are no longer dropped while a listener is attached: the first in-flight value is delivered, and a coalesced update is flushed before completion.
  已有监听者时，进度不再被丢掉：第一笔进行中的进度会送出，完成前会把合并掉的最新进度补发。
- Shared Darwin sources compile for iOS. `AVVideoEncoderSpecificationKey` is macOS-only, so the hardware encoder specification stays on the macOS writer settings. iOS still probes VideoToolbox and AVAssetWriter uses a hardware encoder when one is present.
  共享的 Darwin 源码可以在 iOS 上编译。`AVVideoEncoderSpecificationKey` 只在 macOS 上存在，硬编规格因此只写进 macOS 的 writer 设置。iOS 仍探测 VideoToolbox，有硬编时由 AVAssetWriter 使用硬编。

### Added / 新增

- `example/integration_test/macos_driver_test.dart` and `ios_driver_test.dart` share one Darwin driver. Fixtures are QuickTime movies and PNGs built in Dart (ImageIO / VideoToolbox inputs). No FFmpeg.
  `example/integration_test/macos_driver_test.dart` 与 `ios_driver_test.dart` 共用一套 Darwin 驱动测试。夹具是 Dart 生成的 QuickTime 和 PNG（交给 ImageIO / VideoToolbox）。不使用 FFmpeg。

## [2.3.0] - 2026-10-26

### Fixed / 修复

- Windows image errors match the other platforms: a missing file is `notFound`, a file that exists but cannot be decoded is `decode`, and a directory is `io`. Cancelling an image compress deletes the output. Nested destination directories are created. Encode failures remove a partial file. `queryImageCapabilities` lists only WIC codecs that are actually installed, and lossy `quality` applies to WebP and HEIC as well as JPEG.
  Windows 图片错误与其它平台对齐：文件不存在为 `notFound`，文件在但解不出为 `decode`，目录为 `io`。取消图片压缩会删掉输出。目标路径会创建嵌套父目录。编码失败会删掉半成品。`queryImageCapabilities` 只列出本机已安装的 WIC 编解码器；有损 `quality` 对 WebP、HEIC 和 JPEG 都生效。
- Windows video no longer reports H.264, H.265, and `encoderName: MediaTranscoder` unconditionally. `codecs` lists Media Foundation encoders that are installed (hardware or software). `encoderName` is `MediaFoundationHW` only when a hardware video encoder is present, otherwise null. Compress results name the encoder that ran (`MediaFoundation:H264`, `MediaFoundationHW:H265`, …).
  Windows 视频不再无条件报告 H.264、H.265 和 `encoderName: MediaTranscoder`。`codecs` 是本机已安装的 Media Foundation 编码器（硬编或软编）。只有存在硬编时 `encoderName` 才是 `MediaFoundationHW`，否则为 null。压缩结果里的名字是实际编码器（`MediaFoundation:H264`、`MediaFoundationHW:H265` 等）。
- Windows video honours `keepAudio` (AAC via Media Foundation). When the source has audio and no AAC encoder is installed, `keepAudio: true` throws `unsupported` instead of dropping the track. `keepAudio: false` still writes a silent MP4. `fps`, `maxDimension` (even dimensions), and `keyframeInterval` are applied. Cancel stops the encode and deletes the output. Missing files are `notFound`; corrupt files are `decode`. The Media Foundation H.264/HEVC encoder rejects frames below 64×64, so an even output smaller than that throws `unsupported` and does not write a file.
  Windows 视频遵守 `keepAudio`（用 Media Foundation 转成 AAC）。源片有音轨但没有 AAC 编码器时，`keepAudio: true` 抛 `unsupported`，不再静默丢掉音轨。`keepAudio: false` 仍写出无音轨 MP4。`fps`、`maxDimension`（偶数尺寸）和 `keyframeInterval` 会生效。取消会停掉编码并删除输出。文件不存在为 `notFound`，损坏文件为 `decode`。Media Foundation 的 H.264/HEVC 编码器拒绝小于 64×64 的画面，偶数对齐后仍小于该尺寸时抛 `unsupported`，并且不写文件。
- Jobs stay alive until the worker finishes, so `dispose` during an encode no longer frees the event channel out from under the encoder.
  任务会活到工作线程结束，编码过程中 `dispose` 不再把事件通道从编码器底下拆掉。
- The example no longer throws when a format or codec list is empty.
  示例在格式或编码列表为空时不再抛异常。

### Changed / 变更

- Windows video encode stays on Media Foundation (Source Reader + Sink Writer, hardware when present, software otherwise). It does not use FFmpeg, libav, or GStreamer.
  Windows 视频仍走 Media Foundation（Source Reader + Sink Writer，有硬编用硬编，否则软编）。不使用 FFmpeg、libav 或 GStreamer。

## [2.2.1] - 2026-10-26

### Fixed / 修复

- Linux image load errors: a missing file is `notFound`; a file that exists but cannot be decoded is `decode`.
  Linux 图片：文件不存在为 `notFound`；文件在但解不出为 `decode`。
- Cancelling an image compress deletes the output file that native code already wrote.
  取消图片压缩时删掉原生已经写出的文件。
- `queryVideoCapabilities().encoderName` is null unless a hardware GStreamer encoder is installed. Software encoders stay in `codecs`, and the compress result still names the element that ran (`GStreamer:x264enc`, …). The example no longer labels a software encoder as hardware.
  只有安装了 GStreamer 硬编时 `encoderName` 才非空。软编仍出现在 `codecs` 里；压缩结果里的 `encoderName` 仍是实际元件（如 `GStreamer:x264enc`）。示例不再把软编显示成硬编。
- Linux `keepAudio: true` fails with `unsupported` when the source has audio but no AAC encoder (`fdkaacenc` / `voaacenc`) is installed, instead of dropping the track.
  源片有音轨但系统没有 AAC 编码器时，`keepAudio: true` 抛 `unsupported`，不再静默丢掉音轨。
- Jobs stay alive until the worker finishes, so `dispose` during an encode no longer frees the event channel out from under GStreamer. Progress events are no longer dropped while the client is listening.
  任务会活到工作线程结束，编码过程中 `dispose` 不再把事件通道从 GStreamer 底下拆掉。客户端已在听时，进度事件不再被丢掉。
- `CompressionSession.progress` replays the latest value to a new listener.
  `CompressionSession.progress` 会把最新进度重放给新的订阅者。
- The example disposes a session after success, cancel, and failure.
  示例在成功、取消和失败后都会释放会话。

## [2.2.0] - 2026-10-21

### Changed / 变更

- Ship as one Flutter plugin package. Platform implementations and the platform interface now live in `xue_hua_media_compression` instead of separate endorsed packages.
  改为单个 Flutter 插件包。平台实现和平台接口都收进 `xue_hua_media_compression`，不再拆成独立的 endorsed 包。
- Public Dart API is unchanged. Import `package:xue_hua_media_compression/xue_hua_media_compression.dart` as before. `MediaCompressionPlatform` is exported from that library; the method channel is `package:xue_hua_media_compression/xue_hua_media_compression_method_channel.dart`.
  公开 Dart API 不变，仍从 `package:xue_hua_media_compression/xue_hua_media_compression.dart` 导入。`MediaCompressionPlatform` 由该库导出；method channel 位于 `package:xue_hua_media_compression/xue_hua_media_compression_method_channel.dart`。
- Generate Pigeon bindings with 29.0.11. Android and Darwin `@async` host methods are `suspend` / `async`; Linux and Windows keep the response-callback host API.
  用 Pigeon 29.0.11 生成绑定。Android 与 Darwin 的 `@async` Host 方法改为 `suspend` / `async`；Linux 与 Windows 仍是应答回调。

## [2.1.0] - 2026-10-13

### Changed / 变更

- Require `xue_hua_media_compression_linux ^2.1.0`: Linux video compression now uses
  GStreamer (hardware encoders with automatic software fallback), honours `keepAudio`,
  and needs new system packages (see README).
  依赖 linux ^2.1.0：Linux 视频改用 GStreamer（硬编优先，自动软编回退），支持 `keepAudio`，系统依赖有变化（见 README）。

## [2.0.7] - 2026-10-13

### Fixed / 修复

- Require `xue_hua_media_compression_linux ^2.0.3`, which fixes the Linux compile error (`-Wunused-result`) / 依赖 linux 2.0.3，修复 Linux 编译错误。

## [2.0.6] - 2026-10-08

### Changed / 变更

- **Android toolchain / Android 构建工具链** — Require `xue_hua_media_compression_android` 2.0.3. The Android implementation and the example use Android Gradle Plugin 9.1.0, Gradle 9.3.1, and Kotlin 2.4.0. The example compiles against Android SDK 37.
  依赖 `xue_hua_media_compression_android` 2.0.3。Android 实现与示例使用 Android Gradle Plugin 9.1.0、Gradle 9.3.1、Kotlin 2.4.0；示例 `compileSdk` 为 37。
- Install constraint is `^2.0.6`.
  安装约束为 `^2.0.6`。

## [2.0.5] - 2026-09-21

### Added / 新增

- **Package skills / 随包分发 Agent Skills** — Ship `xue-hua-media-compression-image`
  and `xue-hua-media-compression-video` under `skills/`. Consumers install them
  with `dart run skills@ get`.
  在 `skills/` 下提供图片与视频两条 skill；依赖方执行 `dart run skills@ get` 即可安装。

### Fixed / 修复

- **README matches the 2.x API / README 与源码对齐** — Document `keepAudio`
  (default `true`, ignored on Windows/Linux), correct install constraint
  `^2.0.5`, session usage (`queryCapabilities`, `progress`, `result`,
  `dispose`), and the Chinese Windows requirements row.
  文档改为默认保留音轨（Windows/Linux 忽略 `keepAudio`），安装约束 `^2.0.5`，
  补全会话用法与中文 Windows 环境行。

## [2.0.2] - 2026-08-24

### Fixed / 修复

- **Windows MAX_PATH build / Windows 超长路径构建** — Shorten the Windows
  MSBuild target so `.tlog` / `lastbuildstate` paths stay under MAX_PATH (260);
  register via `XueHuaMediaCompressionWindowsPluginCApi`; silence VS 18 `/await`
  experimental-coroutine deprecation.
  缩短 Windows MSBuild 目标名，避免 `.tlog` / `lastbuildstate` 超过 MAX_PATH；
  通过 `XueHuaMediaCompressionWindowsPluginCApi` 注册；压制 VS 18 `/await`
  实验协程弃用错误。

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
