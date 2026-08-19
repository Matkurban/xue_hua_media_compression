import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression_platform_interface/xue_hua_media_compression_platform_interface.dart';

import '../support/fake_media_compression_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validateImageArgs', () {
    test('rejects quality outside 1–100', () {
      expect(
        () => validateImageArgs(
          source: MediaSource.bytes(Uint8List.fromList(const [1, 2, 3])),
          destination: MediaDestination.bytes(),
          options: const ImageCompressOptions(quality: 0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty source bytes', () {
      expect(
        () => validateImageArgs(
          source: MediaSource.bytes(Uint8List(0)),
          destination: MediaDestination.bytes(),
          options: const ImageCompressOptions(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('validateVideoArgs', () {
    test('rejects empty input path', () {
      expect(
        () => validateVideoArgs(
          inputPath: '  ',
          outputPath: '/tmp/out.mp4',
          options: const VideoCompressOptions(),
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-positive bitrate', () {
      expect(
        () => validateVideoArgs(
          inputPath: '/tmp/in.mp4',
          outputPath: '/tmp/out.mp4',
          options: const VideoCompressOptions(bitrate: 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('FakeMediaCompressionPlatform', () {
    late FakeMediaCompressionPlatform fake;
    late MediaCompressionPlatform previous;

    setUp(() {
      previous = MediaCompressionPlatform.instance;
      fake = FakeMediaCompressionPlatform();
      MediaCompressionPlatform.instance = fake;
    });

    tearDown(() {
      MediaCompressionPlatform.instance = previous;
    });

    test('success path completes with image result', () async {
      final session = MediaCompressionPlatform.instance.compressImage(
        source: MediaSource.bytes(Uint8List.fromList(const [1, 2, 3, 4])),
        destination: MediaDestination.bytes(),
        options: const ImageCompressOptions(),
      );
      final fakeSession =
          session as FakeCompressionSession<ImageCompressResult>;
      fakeSession.emitCompleted(
        fakeImageResult(bytes: Uint8List.fromList(const [9, 9])),
      );
      final result = await session.result;
      expect(result.width, 32);
      expect(result.bytes, isNotNull);
    });

    test('error code surfaces on result', () async {
      fake.nextVideoError = const MediaCompressionException(
        MediaCompressionException.hardwareUnavailable,
        'no VAAPI',
      );
      final session = MediaCompressionPlatform.instance.compressVideo(
        inputPath: '/tmp/in.mp4',
        outputPath: '/tmp/out.mp4',
        options: const VideoCompressOptions(),
      );
      await expectLater(
        session.result,
        throwsA(
          isA<MediaCompressionException>().having(
            (MediaCompressionException e) => e.code,
            'code',
            MediaCompressionException.hardwareUnavailable,
          ),
        ),
      );
    });

    test('cancel and dispose are idempotent', () async {
      final session = MediaCompressionPlatform.instance.compressImage(
        source: MediaSource.bytes(Uint8List.fromList(const [1])),
        destination: MediaDestination.path('/tmp/out.jpg'),
        options: const ImageCompressOptions(),
      );
      session.result.ignore();
      await session.cancel();
      await session.cancel();
      await session.dispose();
      await session.dispose();
      expect(fake.calls.where((String c) => c.startsWith('cancel:')).length, 1);
      expect(
        fake.calls.where((String c) => c.startsWith('dispose:')).length,
        1,
      );
    });

    test(
      'progress emitted before listen keeps only the latest value',
      () async {
        final session =
            MediaCompressionPlatform.instance.compressImage(
                  source: MediaSource.bytes(Uint8List.fromList(const [1])),
                  destination: MediaDestination.bytes(),
                  options: const ImageCompressOptions(),
                )
                as FakeCompressionSession<ImageCompressResult>;
        session.emitProgress(0.1);
        session.emitProgress(0.4);
        session.emitProgress(0.7);
        final received = <double>[];
        final sub = session.progress.listen(received.add);
        await Future<void>.delayed(Duration.zero);
        expect(received, [0.7]);
        await sub.cancel();
      },
    );

    test('completed emitted before listen is not dropped', () async {
      final session =
          MediaCompressionPlatform.instance.compressVideo(
                inputPath: '/tmp/in.mp4',
                outputPath: '/tmp/out.mp4',
                options: const VideoCompressOptions(),
              )
              as FakeCompressionSession<VideoCompressResult>;
      session.emitCompleted(fakeVideoResult());
      final sub = session.progress.listen((_) {});
      final result = await session.result;
      expect(result.encoderName, 'FakeEncoder');
      await sub.cancel();
    });
  });
}
