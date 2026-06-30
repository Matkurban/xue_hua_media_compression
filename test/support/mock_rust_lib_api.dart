import 'dart:typed_data';

import 'package:xue_hua_media_compression/src/rust/api/traits.dart';
import 'package:xue_hua_media_compression/src/rust/frb_generated.dart';

/// 最小 mock 后端：验证 Dart 侧可经 [RustLib.initMock] 穿越 external seam。
class MockRustLibApi implements RustLibApi {
  @override
  Future<ImageOptions> crateApiTraitsImageOptionsDefault() async =>
      const ImageOptions(
        format: ImageFormat.jpeg,
        quality: 80,
        maxDimension: null,
        speed: 6,
      );

  @override
  Future<Uint8List> crateApiMediaRustCompressImage({
    required List<int> input,
    required ImageOptions opts,
  }) async => Uint8List.fromList(input);

  @override
  Future<BigInt> crateApiMediaRustCompressImageFile({
    required String inputPath,
    required String outputPath,
    required ImageOptions opts,
  }) async => BigInt.from(42);

  @override
  Future<VideoResult> crateApiMediaRustCompressVideo({
    required String inputPath,
    required String outputPath,
    required VideoOptions opts,
  }) async => VideoResult(
    outputPath: outputPath,
    sizeBytes: BigInt.from(100),
    backend: 'dart-mock',
    width: opts.maxDimension ?? 640,
    height: opts.maxDimension ?? 480,
  );

  @override
  Future<ImageOptions> crateApiMediaRustDefaultImageOptions() =>
      crateApiTraitsImageOptionsDefault();

  @override
  Future<VideoOptions> crateApiMediaRustDefaultVideoOptions() async =>
      const VideoOptions(
        codec: VideoCodec.h264,
        bitrate: 2000000,
        fps: null,
        maxDimension: null,
        keyframeInterval: 60,
      );

  @override
  Future<void> crateApiMediaRustInit() async {}

  @override
  Future<String> crateApiMediaRustVideoBackendName() async => 'dart-mock';

  @override
  Future<VideoOptions> crateApiTraitsVideoOptionsDefault() async =>
      const VideoOptions(
        codec: VideoCodec.h264,
        bitrate: 2000000,
        fps: null,
        maxDimension: null,
        keyframeInterval: 60,
      );
}
