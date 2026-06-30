import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression/src/media_compression.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

void main() {
  test('facade exposes image and video namespaces', () {
    expect(XueHuaMediaCompression.image, isNotNull);
    expect(XueHuaMediaCompression.video, isNotNull);
  });

  test('image facade default parameter assembly', () {
    final opts = facadeImageOptions();
    expect(opts.format, ImageFormat.jpeg);
    expect(opts.quality, 80);
    expect(opts.maxDimension, isNull);
    expect(opts.speed, isNull);
  });

  test('video facade default parameter assembly', () {
    final opts = facadeVideoOptions();
    expect(opts.codec, VideoCodec.h264);
    expect(opts.bitrate, 2000000);
    expect(opts.fps, isNull);
    expect(opts.maxDimension, isNull);
    expect(opts.keyframeInterval, isNull);
  });

  test('image facade explicit compress parameters', () {
    final opts = facadeImageOptions(
      format: ImageFormat.webP,
      quality: 55,
      maxDimension: 512,
      speed: 4,
    );
    expect(opts.format, ImageFormat.webP);
    expect(opts.quality, 55);
    expect(opts.maxDimension, 512);
    expect(opts.speed, 4);
  });

  test('video facade explicit compress parameters', () {
    final opts = facadeVideoOptions(
      codec: VideoCodec.h265,
      bitrate: 3500000,
      fps: 30,
      maxDimension: 1080,
      keyframeInterval: 120,
    );
    expect(opts.codec, VideoCodec.h265);
    expect(opts.bitrate, 3500000);
    expect(opts.fps, 30);
    expect(opts.maxDimension, 1080);
    expect(opts.keyframeInterval, 120);
  });
}
