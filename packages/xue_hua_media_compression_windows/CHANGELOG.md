# Changelog

## 2.0.2

- Shorten the Windows MSBuild target so `.tlog` / `lastbuildstate` paths stay
  under MAX_PATH (260); register via `XueHuaMediaCompressionWindowsPluginCApi`;
  silence VS 18 `/await` experimental-coroutine deprecation.
  缩短 Windows MSBuild 目标名，避免 `.tlog` / `lastbuildstate` 超过 MAX_PATH；
  通过 `XueHuaMediaCompressionWindowsPluginCApi` 注册；压制 VS 18 `/await`
  实验协程弃用错误。

## 2.0.1

- Align README Flutter requirement with pubspec (`>= 3.44.0`).
  README 的 Flutter 版本要求与 pubspec 对齐。

## 2.0.0

- Initial federated release: WIC image compression and Media Foundation
  `MediaTranscoder` video (H.264 / H.265 MP4, no audio).
  联合插件首个 Windows 实现：WIC 图片与 MediaTranscoder 视频压缩。
