/// 目标图片编码格式。
///
/// Target still-image encoding format.
enum ImageFormat {
  /// JPEG。有损；[ImageCompressOptions.quality] 立即生效。
  ///
  /// JPEG. Lossy; [ImageCompressOptions.quality] applies immediately.
  jpeg,

  /// PNG。无损；quality 被忽略。
  ///
  /// PNG. Lossless; quality is ignored.
  png,

  /// WebP。仅部分平台可编码，见能力矩阵。
  ///
  /// WebP. Encode support is platform-specific; see the capability matrix.
  webp,

  /// HEIC/HEIF。仅部分平台可编码。
  ///
  /// HEIC/HEIF. Encode support is platform-specific.
  heic,

  /// AVIF。当前各端编码均为不可能，调用会抛 `unsupported`。
  ///
  /// AVIF. Encoding is currently impossible on all supported platforms.
  avif,

  /// GIF。输出为不可能；输入仅解码首帧。
  ///
  /// GIF. Output is impossible; input decodes the first frame only.
  gif,
}

extension ImageFormatWire on ImageFormat {
  /// Pigeon / 原生使用的稳定线格式名。
  ///
  /// Stable wire name used by Pigeon and native code.
  String get wireName {
    return switch (this) {
      ImageFormat.jpeg => 'jpeg',
      ImageFormat.png => 'png',
      ImageFormat.webp => 'webp',
      ImageFormat.heic => 'heic',
      ImageFormat.avif => 'avif',
      ImageFormat.gif => 'gif',
    };
  }

  /// 从线格式名解析；未知值返回 null。
  ///
  /// Parses a wire name; returns null when unknown.
  static ImageFormat? tryParse(String name) {
    return switch (name) {
      'jpeg' => ImageFormat.jpeg,
      'png' => ImageFormat.png,
      'webp' => ImageFormat.webp,
      'heic' => ImageFormat.heic,
      'avif' => ImageFormat.avif,
      'gif' => ImageFormat.gif,
      _ => null,
    };
  }
}
