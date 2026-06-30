import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression/src/rust/api/traits.dart'
    show MediaError_Decode;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await XueHuaMediaCompression.initialize();
  });

  test('initialize is idempotent', () async {
    await expectLater(() async {
      await XueHuaMediaCompression.initialize();
      await XueHuaMediaCompression.initialize();
    }, returnsNormally);
  });

  test('default image options match rust seam', () async {
    final opts = await ImageOptions.default_();
    expect(opts.format, ImageFormat.jpeg);
    expect(opts.quality, 80);
    expect(opts.maxDimension, isNull);
    expect(opts.speed, 6);
  });

  test('default video options match rust seam', () async {
    final opts = await VideoOptions.default_();
    expect(opts.codec, VideoCodec.h264);
    expect(opts.bitrate, 2000000);
    expect(opts.fps, isNull);
    expect(opts.maxDimension, isNull);
    expect(opts.keyframeInterval, 60);
  });

  test('facade null speed/keyframeInterval runtime contract', () {
    // Facade passes null; Rust applies unwrap_or(6)/unwrap_or(60) at encode time.
    const imageOpts = ImageOptions(
      format: ImageFormat.jpeg,
      quality: 80,
      maxDimension: null,
      speed: null,
    );
    const videoOpts = VideoOptions(
      codec: VideoCodec.h264,
      bitrate: 2000000,
      fps: null,
      maxDimension: null,
      keyframeInterval: null,
    );
    expect(imageOpts.speed, isNull);
    expect(videoOpts.keyframeInterval, isNull);
  });

  test('videoBackendName returns platform backend', () async {
    final name = await XueHuaMediaCompression.videoBackendName();
    expect(name, isNotEmpty);
  });

  test('video compress missing input surfaces MediaError', () async {
    final output =
        '${Directory.systemTemp.path}/xue_missing_input_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await expectLater(
      XueHuaMediaCompression.video.compress(
        inputPath: '/nonexistent/xue_video_missing_test.mp4',
        outputPath: output,
      ),
      throwsA(isA<MediaError_Decode>()),
    );
  });

  test('image compress round-trip from fixture', () async {
    final bytes = await rootBundle.load('integration_test/fixtures/sample.jpg');
    final input = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final out = await XueHuaMediaCompression.image.compress(
      input: input,
      format: ImageFormat.webP,
      quality: 80,
    );
    expect(out.length, greaterThan(0));
    expect(out[0], 0x52); // RIFF
    expect(out[1], 0x49);
    expect(out[2], 0x46);
    expect(out[3], 0x46);
  });

  test('image compressFile writes output', () async {
    final bytes = await rootBundle.load('integration_test/fixtures/sample.jpg');
    final inputPath =
        '${Directory.systemTemp.path}/xue_img_in_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final outputPath =
        '${Directory.systemTemp.path}/xue_img_out_${DateTime.now().millisecondsSinceEpoch}.webp';
    await File(inputPath).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    addTearDown(() {
      for (final path in [inputPath, outputPath]) {
        final f = File(path);
        if (f.existsSync()) {
          f.deleteSync();
        }
      }
    });

    final size = await XueHuaMediaCompression.image.compressFile(
      inputPath: inputPath,
      outputPath: outputPath,
      format: ImageFormat.webP,
    );
    expect(size, greaterThan(0));
    expect(File(outputPath).existsSync(), isTrue);
  });

  test('video compress produces output from fixture', () async {
    final bytes = await rootBundle.load('integration_test/fixtures/sample.mp4');
    final fixture =
        '${Directory.systemTemp.path}/xue_sample_fixture_${DateTime.now().millisecondsSinceEpoch}.mp4';
    await File(fixture).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    addTearDown(() {
      final f = File(fixture);
      if (f.existsSync()) {
        f.deleteSync();
      }
    });

    final output =
        '${Directory.systemTemp.path}/xue_video_out_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final result = await XueHuaMediaCompression.video.compress(
      inputPath: fixture,
      outputPath: output,
      maxDimension: 64,
    );

    expect(result.outputPath, output);
    expect(result.sizeBytes.toInt(), greaterThan(0));
    expect(result.width, 64);
    expect(result.height, 64);
    expect(result.backend, isNotEmpty);
    expect(File(output).existsSync(), isTrue);

    addTearDown(() {
      final out = File(output);
      if (out.existsSync()) {
        out.deleteSync();
      }
    });
  });
}
