/// 目标视频编码。
///
/// Target video codec.
enum VideoCodec {
  /// H.264 / AVC，封装进 MP4。
  ///
  /// H.264 / AVC, muxed into MP4.
  h264,

  /// H.265 / HEVC，封装进 MP4。无硬件编码器时抛 `hardwareUnavailable`。
  ///
  /// H.265 / HEVC, muxed into MP4. Throws `hardwareUnavailable` without a HW encoder.
  h265,
}

extension VideoCodecWire on VideoCodec {
  /// Pigeon / 原生使用的稳定线格式名。
  ///
  /// Stable wire name used by Pigeon and native code.
  String get wireName {
    return switch (this) {
      VideoCodec.h264 => 'h264',
      VideoCodec.h265 => 'h265',
    };
  }

  /// 从线格式名解析；未知值返回 null。
  ///
  /// Parses a wire name; returns null when unknown.
  static VideoCodec? tryParse(String name) {
    return switch (name) {
      'h264' => VideoCodec.h264,
      'h265' => VideoCodec.h265,
      _ => null,
    };
  }
}
