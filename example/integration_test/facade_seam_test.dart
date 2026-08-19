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
