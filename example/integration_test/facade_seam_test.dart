import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('queryCapabilities returns non-empty image outputs', () async {
    final caps = await XueHuaMediaCompression.image.queryCapabilities();
    expect(caps.outputFormats, isNotEmpty);
  });

  test('image compress round-trip from fixture', () async {
    final bytes = await rootBundle.load('integration_test/fixtures/sample.jpg');
    final input = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final session = XueHuaMediaCompression.image.compress(
      source: MediaSource.bytes(input),
      destination: MediaDestination.bytes(),
      options: const ImageCompressOptions(
        format: ImageFormat.jpeg,
        quality: 80,
      ),
    );
    final result = await session.result;
    await session.dispose();
    expect(result.bytes, isNotNull);
    expect(result.bytes!.length, greaterThan(0));
    expect(result.width, greaterThan(0));
  });

  test('video queryCapabilities reports VideoToolbox on Darwin', () async {
    if (!(Platform.isIOS || Platform.isMacOS)) {
      return;
    }
    final caps = await XueHuaMediaCompression.video.queryCapabilities();
    expect(caps.encoderName, 'VideoToolbox');
    expect(caps.codecs, contains(VideoCodec.h264));
  });

  test('video compress round-trip keeps storage size without audio', () async {
    final data = await rootBundle.load('integration_test/fixtures/sample.mp4');
    final tmp = Directory.systemTemp.createTempSync('xue_video_');
    addTearDown(() {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });
    final input = File('${tmp.path}/in.mp4')
      ..writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    final output = '${tmp.path}/out.mp4';
    final session = XueHuaMediaCompression.video.compress(
      inputPath: input.path,
      outputPath: output,
      options: const VideoCompressOptions(bitrate: 400000),
    );
    final result = await session.result;
    await session.dispose();
    expect(File(output).existsSync(), isTrue);
    expect(result.sizeBytes, greaterThan(0));
    expect(result.width, 64);
    expect(result.height, 64);
    if (Platform.isIOS || Platform.isMacOS) {
      expect(result.encoderName, 'VideoToolbox');
      expect(result.codec, VideoCodec.h264);
    }
  });

  test('video compress maxDimension uses even display size', () async {
    final data = await rootBundle.load('integration_test/fixtures/sample.mp4');
    final tmp = Directory.systemTemp.createTempSync('xue_video_scale_');
    addTearDown(() {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });
    final input = File('${tmp.path}/in.mp4')
      ..writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    final output = '${tmp.path}/out.mp4';
    final session = XueHuaMediaCompression.video.compress(
      inputPath: input.path,
      outputPath: output,
      options: const VideoCompressOptions(bitrate: 400000, maxDimension: 32),
    );
    final result = await session.result;
    await session.dispose();
    expect(result.width, 32);
    expect(result.height, 32);
    expect(result.width.isEven, isTrue);
    expect(result.height.isEven, isTrue);
  });

  test(
    'video compress missing input surfaces MediaCompressionException',
    () async {
      final output =
          '${Directory.systemTemp.path}/xue_missing_input_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final session = XueHuaMediaCompression.video.compress(
        inputPath: '/nonexistent/xue_video_missing_test.mp4',
        outputPath: output,
      );
      await expectLater(
        session.result,
        throwsA(
          isA<MediaCompressionException>().having(
            (e) => e.code,
            'code',
            anyOf(
              MediaCompressionException.notFound,
              MediaCompressionException.decode,
            ),
          ),
        ),
      );
      await session.dispose();
    },
  );
}
