# xue_hua_media_compression_platform_interface

A common platform interface for the [`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) plugin.
[`xue_hua_media_compression`](https://pub.dev/packages/xue_hua_media_compression) 插件的通用平台接口。

This interface allows platform-specific implementations of the
`xue_hua_media_compression` plugin, as well as the plugin itself, to ensure they
are supporting the same interface.

本接口确保 `xue_hua_media_compression` 插件及其各平台实现遵循同一套契约。

## Usage / 用法

To implement a new platform-specific implementation of
`xue_hua_media_compression`, extend `MediaCompressionPlatform` with an
implementation that performs the platform-specific behavior, and when you
register your plugin, set the default `MediaCompressionPlatform` by calling
`MediaCompressionPlatform.instance = MyPlatform()`.

要为 `xue_hua_media_compression` 编写新的平台实现，请继承
`MediaCompressionPlatform` 并实现平台行为，然后在注册插件时通过
`MediaCompressionPlatform.instance = MyPlatform()` 设置默认实例。

## Note / 说明

Breaking changes to this interface will only be made when absolutely
necessary, since they require all implementations to be updated in lockstep.

仅在绝对必要时才会对本接口做破坏性变更，因为那要求所有平台实现同步更新。
