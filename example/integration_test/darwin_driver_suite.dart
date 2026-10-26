import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression_example/main.dart';

import 'darwin_media.dart';
import 'facade_seam.dart';
import 'plugin_binary.dart';
import 'windows_media.dart';

const _timeout = Timeout(Duration(minutes: 5));

void driverTest(String name, Future<void> Function() body) {
  test(name, body, timeout: _timeout);
}

/// Shared iOS and macOS driver. Both platforms use the Darwin implementation.
void runDarwinDriver() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerFacadeSeamTests();

  testWidgets('example home loads image and video cards', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('图片压缩'), findsOneWidget);
    expect(find.text('视频压缩'), findsOneWidget);
    expect(find.text('选择图片并压缩'), findsOneWidget);
    expect(find.text('选择视频并压缩'), findsOneWidget);
    final errors = find.byIcon(Icons.error_outline);
    if (errors.evaluate().isNotEmpty) {
      final messages = find.byType(SelectableText).evaluate().map((element) {
        final widget = element.widget as SelectableText;
        return widget.data ?? widget.textSpan?.toPlainText() ?? '';
      });
      fail('example surfaced an error: ${messages.join('\n')}');
    }
  });

  if (!(Platform.isMacOS || Platform.isIOS)) {
    return;
  }

  group('Darwin compression driver', () {
    Directory? tempDir;
    late Directory temp;
    late String pngPath;
    late String jpegPath;
    late String shortVideo;
    late String audioVideo;
    late String oddVideo;
    late String longVideo;
    late String spacedVideo;

    setUpAll(() async {
      temp = tempDir = await Directory.systemTemp.createTemp(
        'xh_darwin_driver_',
      );
      pngPath = _join(temp.path, 'smpte.png');
      jpegPath = _join(temp.path, 'fixture.jpg');
      shortVideo = _join(temp.path, 'short.mov');
      audioVideo = _join(temp.path, 'with_audio.mov');
      oddVideo = _join(temp.path, 'odd.mov');
      longVideo = _join(temp.path, 'long.mov');
      final spacedDir = Directory(_join(temp.path, 'dir with space'))
        ..createSync(recursive: true);
      spacedVideo = _join(spacedDir.path, 'clip.mov');

      await File(pngPath).writeAsBytes(encodePng(320, 240, noisyRgb(320, 240)));
      final jpeg = await rootBundle.load(
        'integration_test/fixtures/sample.jpg',
      );
      await File(jpegPath).writeAsBytes(
        jpeg.buffer.asUint8List(jpeg.offsetInBytes, jpeg.lengthInBytes),
      );
      await writeDarwinVideo(
        shortVideo,
        width: 64,
        height: 64,
        fps: 30,
        frames: 30,
      );
      await writeDarwinVideo(
        audioVideo,
        width: 96,
        height: 64,
        fps: 30,
        frames: 30,
        audio: true,
      );
      await writeDarwinVideo(
        oddVideo,
        width: 101,
        height: 61,
        fps: 15,
        frames: 15,
        pixel: DarwinVideoPixel.jpeg,
      );
      await writeDarwinVideo(
        longVideo,
        width: 640,
        height: 360,
        fps: 20,
        frames: 120,
        pixel: DarwinVideoPixel.jpeg,
      );
      await File(shortVideo).copy(spacedVideo);
    });

    tearDownAll(() async {
      final root = tempDir;
      if (root != null && root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    driverTest('image and video capabilities match installed codecs', () async {
      final images = await XueHuaMediaCompression.image.queryCapabilities();
      expect(images.inputFormats, contains(ImageFormat.jpeg));
      expect(images.inputFormats, contains(ImageFormat.png));
      expect(images.inputFormats, contains(ImageFormat.gif));
      expect(images.outputFormats, contains(ImageFormat.jpeg));
      expect(images.outputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, isNot(contains(ImageFormat.gif)));
      expect(images.outputFormats, isNot(contains(ImageFormat.avif)));
      if (images.outputFormats.contains(ImageFormat.webp)) {
        expect(images.inputFormats, contains(ImageFormat.webp));
      }
      if (images.outputFormats.contains(ImageFormat.heic)) {
        expect(images.inputFormats, contains(ImageFormat.heic));
      }

      final video = await XueHuaMediaCompression.video.queryCapabilities();
      expect(video.acceptsContentUri, isFalse);
      expect(video.codecs, contains(VideoCodec.h264));
      final name = video.encoderName;
      if (name != null) {
        expect(name, 'VideoToolboxHW');
      }
      final label = name ?? '';
      expect(_containsAscii(label.toLowerCase(), _ffmpeg), isFalse);
      expect(_containsAscii(label.toLowerCase(), _libav), isFalse);
    });

    driverTest('image compress from path and bytes, with progress', () async {
      final output = _join(temp.path, 'out.jpg');
      final progress = <double>[];
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(jpegPath),
        destination: MediaDestination.path(output),
        options: const ImageCompressOptions(
          format: ImageFormat.jpeg,
          quality: 60,
        ),
      );
      final sub = session.progress.listen(progress.add);
      final result = await _resultOf(session);
      await sub.cancel();
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(progress, everyElement(inInclusiveRange(0, 1)));
      expect(progress.any((double value) => value > 0 && value < 1), isTrue);
      expect(result.outputPath, output);
      expect(result.bytes, isNull);
      expect(result.format, ImageFormat.jpeg);
      expect(result.width, 64);
      expect(result.height, 64);
      expect(result.sizeBytes, greaterThan(0));
      expect(await File(output).length(), result.sizeBytes);
      _expectPrefix(await File(output).readAsBytes(), const <int>[0xff, 0xd8]);

      final bytes = await File(pngPath).readAsBytes();
      final memory = XueHuaMediaCompression.image.compress(
        source: MediaSource.bytes(bytes),
        destination: MediaDestination.bytes(),
        options: const ImageCompressOptions(
          format: ImageFormat.png,
          quality: 40,
        ),
      );
      final png = await _resultOf(memory);
      expect(png.outputPath, isNull);
      expect(png.bytes, isNotNull);
      expect(png.format, ImageFormat.png);
      expect(png.width, 320);
      expect(png.height, 240);
      expect(png.sizeBytes, png.bytes!.length);
      _expectPrefix(png.bytes!, const <int>[0x89, 0x50, 0x4e, 0x47]);
    });

    driverTest('png to jpeg and webp or heic when advertised', () async {
      final jpegOut = _join(temp.path, 'from_png.jpg');
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(pngPath),
        destination: MediaDestination.path(jpegOut),
        options: const ImageCompressOptions(quality: 70),
      );
      final result = await _resultOf(session);
      expect(result.format, ImageFormat.jpeg);
      expect(result.width, 320);
      expect(result.height, 240);
      _expectPrefix(await File(jpegOut).readAsBytes(), const <int>[0xff, 0xd8]);

      final caps = await XueHuaMediaCompression.image.queryCapabilities();
      if (caps.outputFormats.contains(ImageFormat.webp)) {
        final webp = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(jpegPath),
          destination: MediaDestination.bytes(),
          options: const ImageCompressOptions(
            format: ImageFormat.webp,
            quality: 70,
          ),
        );
        final webpResult = await _resultOf(webp);
        expect(webpResult.format, ImageFormat.webp);
        expect(webpResult.bytes, isNotNull);
        _expectPrefix(webpResult.bytes!, const <int>[0x52, 0x49, 0x46, 0x46]);
      }
      if (caps.outputFormats.contains(ImageFormat.heic)) {
        final heic = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(jpegPath),
          destination: MediaDestination.bytes(),
          options: const ImageCompressOptions(
            format: ImageFormat.heic,
            quality: 70,
          ),
        );
        final heicResult = await _resultOf(heic);
        expect(heicResult.format, ImageFormat.heic);
        expect(heicResult.bytes, isNotNull);
        expect(heicResult.sizeBytes, heicResult.bytes!.length);
        expect(heicResult.sizeBytes, greaterThan(0));
      }
    });

    driverTest(
      'image maxDimension downscales and creates parent directories',
      () async {
        final output = _join(temp.path, 'nested dir/deeper/scaled.jpg');
        final session = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(pngPath),
          destination: MediaDestination.path(output),
          options: const ImageCompressOptions(quality: 80, maxDimension: 80),
        );
        final result = await _resultOf(session);
        expect(File(output).existsSync(), isTrue);
        expect(result.width, lessThanOrEqualTo(80));
        expect(result.height, lessThanOrEqualTo(80));
        expect(result.width, greaterThan(0));
        expect(result.height, greaterThan(0));
        final longest = result.width > result.height
            ? result.width
            : result.height;
        expect(longest, lessThanOrEqualTo(80));
        expect(result.width / result.height, closeTo(320 / 240, 0.05));
      },
    );

    driverTest('lower jpeg quality does not grow the file', () async {
      Future<int> encode(int quality) async {
        final session = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(pngPath),
          destination: MediaDestination.bytes(),
          options: ImageCompressOptions(quality: quality),
        );
        final result = await _resultOf(session);
        return result.sizeBytes;
      }

      final small = await encode(15);
      final large = await encode(95);
      expect(small, greaterThan(0));
      expect(large, greaterThan(small));
    });

    driverTest('gif input decodes and gif/avif output is unsupported', () async {
      const gif = <int>[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
        0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x21, 0xf9, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
      ];
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.bytes(Uint8List.fromList(gif)),
        destination: MediaDestination.bytes(),
        options: const ImageCompressOptions(quality: 80),
      );
      final result = await _resultOf(session);
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
      expect(result.bytes, isNotNull);

      final caps = await XueHuaMediaCompression.image.queryCapabilities();
      for (final format in const <ImageFormat>[
        ImageFormat.gif,
        ImageFormat.avif,
      ]) {
        final rejected = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(jpegPath),
          destination: MediaDestination.bytes(),
          options: ImageCompressOptions(format: format),
        );
        await _expectCode(rejected, MediaCompressionException.unsupported);
      }
      if (!caps.outputFormats.contains(ImageFormat.heic)) {
        final rejected = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(jpegPath),
          destination: MediaDestination.bytes(),
          options: const ImageCompressOptions(format: ImageFormat.heic),
        );
        await _expectCode(rejected, MediaCompressionException.unsupported);
      }
    });

    driverTest(
      'missing, corrupt, directory, and content URI images fail cleanly',
      () async {
        final missing = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(_join(temp.path, 'no-such-image.jpg')),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(missing, MediaCompressionException.notFound);

        final corruptPath = _join(temp.path, 'corrupt.jpg');
        await File(corruptPath).writeAsString('this is not a jpeg');
        final corrupt = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(corruptPath),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(corrupt, MediaCompressionException.decode);

        final directory = Directory(_join(temp.path, 'not-a-file'))
          ..createSync(recursive: true);
        final asFile = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(directory.path),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(asFile, MediaCompressionException.io);

        final content = XueHuaMediaCompression.image.compress(
          source: MediaSource.path('content://media/external/images/1'),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(content, MediaCompressionException.unsupported);

        expect(
          () => XueHuaMediaCompression.image.compress(
            source: MediaSource.path('   '),
            destination: MediaDestination.bytes(),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.image.compress(
            source: MediaSource.bytes(Uint8List(0)),
            destination: MediaDestination.bytes(),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.image.compress(
            source: MediaSource.path(jpegPath),
            destination: MediaDestination.bytes(),
            options: const ImageCompressOptions(quality: 0),
          ),
          throwsArgumentError,
        );
      },
    );

    driverTest('image cancel discards the output file', () async {
      final big = _join(temp.path, 'big.png');
      await File(big).writeAsBytes(encodePng(3600, 2400, noisyRgb(3600, 2400)));
      final output = _join(temp.path, 'cancelled-image.jpg');
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(big),
        destination: MediaDestination.path(output),
        options: const ImageCompressOptions(quality: 95),
      );
      final progress = <double>[];
      var cancelSent = false;
      final sub = session.progress.listen((double value) {
        progress.add(value);
        if (!cancelSent && value > 0 && value < 1) {
          cancelSent = true;
          unawaited(session.cancel());
        }
      });
      await _expectCode(session, MediaCompressionException.cancelled);
      await sub.cancel();
      expect(cancelSent, isTrue, reason: 'progress was $progress');
      expect(File(output).existsSync(), isFalse);
    });

    driverTest('video compresses H.264 with progress and file:// paths', () async {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      expect(caps.codecs, contains(VideoCodec.h264));
      final output = _join(temp.path, 'h264.mp4');
      final progress = <double>[];
      final session = XueHuaMediaCompression.video.compress(
        inputPath: Uri.file(shortVideo).toString(),
        outputPath: output,
        options: const VideoCompressOptions(
          codec: VideoCodec.h264,
          bitrate: 400000,
          keepAudio: false,
        ),
      );
      final sub = session.progress.listen(progress.add);
      final result = await _resultOf(session);
      await sub.cancel();
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(progress, everyElement(inInclusiveRange(0, 1)));
      expect(progress.any((double value) => value > 0 && value < 1), isTrue);
      expect(result.codec, VideoCodec.h264);
      expect(result.width, 64);
      expect(result.height, 64);
      expect(result.width.isEven, isTrue);
      expect(result.height.isEven, isTrue);
      expect(result.sizeBytes, greaterThan(0));
      _expectToolbox(result.encoderName, 'H264');
      expect(await File(output).length(), result.sizeBytes);
      final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
      expect(mp4.hasVideo, isTrue);
      expect(mp4.hasAudio, isFalse);
      expect(mp4.width, result.width);
      expect(mp4.height, result.height);
      expect(mp4.containsTag('avc1'), isTrue);
    });

    driverTest('video H.265 compresses when an encoder is advertised', () async {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      if (!caps.codecs.contains(VideoCodec.h265)) {
        return;
      }
      final output = _join(temp.path, 'h265.mp4');
      final session = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: output,
        options: const VideoCompressOptions(
          codec: VideoCodec.h265,
          bitrate: 400000,
          keepAudio: false,
        ),
      );
      final result = await _resultOf(session);
      expect(result.codec, VideoCodec.h265);
      expect(result.width, 64);
      expect(result.height, 64);
      _expectToolbox(result.encoderName, 'H265');
      final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
      expect(mp4.hasVideo, isTrue);
      expect(mp4.hasAudio, isFalse);
      expect(mp4.containsTag('hvc1') || mp4.containsTag('hev1'), isTrue);
    });

    driverTest('keepAudio keeps an AAC track and false strips it', () async {
      final keptPath = _join(temp.path, 'audio-kept.mp4');
      final kept = XueHuaMediaCompression.video.compress(
        inputPath: audioVideo,
        outputPath: keptPath,
        options: const VideoCompressOptions(bitrate: 500000, keepAudio: true),
      );
      final keptResult = await _resultOf(kept);
      expect(keptResult.width, 96);
      expect(keptResult.height, 64);
      final keptMp4 = Mp4Probe.parse(await File(keptPath).readAsBytes());
      expect(keptMp4.hasVideo, isTrue);
      expect(keptMp4.hasAudio, isTrue);
      expect(keptMp4.containsTag('mp4a'), isTrue);

      final droppedPath = _join(temp.path, 'audio-dropped.mp4');
      final dropped = XueHuaMediaCompression.video.compress(
        inputPath: audioVideo,
        outputPath: droppedPath,
        options: const VideoCompressOptions(
          bitrate: 500000,
          keepAudio: false,
          fps: 30,
          keyframeInterval: 10,
        ),
      );
      final droppedResult = await _resultOf(dropped);
      expect(droppedResult.width, 96);
      expect(droppedResult.height, 64);
      final droppedMp4 = Mp4Probe.parse(await File(droppedPath).readAsBytes());
      expect(droppedMp4.hasVideo, isTrue);
      expect(droppedMp4.hasAudio, isFalse);
      final sync = droppedMp4.syncSamples == 0
          ? droppedMp4.videoSamples
          : droppedMp4.syncSamples;
      expect(sync, greaterThan(1));
    });

    driverTest('fps and maxDimension reshape the video', () async {
      final scaled = _join(temp.path, 'scaled.mp4');
      final scaleSession = XueHuaMediaCompression.video.compress(
        inputPath: oddVideo,
        outputPath: scaled,
        options: const VideoCompressOptions(
          bitrate: 400000,
          maxDimension: 45,
          keepAudio: false,
        ),
      );
      final scale = await _resultOf(scaleSession);
      expect(scale.width.isEven, isTrue);
      expect(scale.height.isEven, isTrue);
      expect(scale.width, lessThanOrEqualTo(45));
      expect(scale.height, lessThanOrEqualTo(45));
      expect(scale.width, greaterThan(0));
      expect(scale.height, greaterThan(0));
      final mp4 = Mp4Probe.parse(await File(scaled).readAsBytes());
      expect(mp4.width, scale.width);
      expect(mp4.height, scale.height);

      final rated = _join(temp.path, 'fps.mp4');
      final fpsSession = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: rated,
        options: const VideoCompressOptions(
          bitrate: 400000,
          fps: 10,
          keepAudio: false,
        ),
      );
      final fps = await _resultOf(fpsSession);
      expect(fps.width, 64);
      expect(fps.height, 64);
      final fpsMp4 = Mp4Probe.parse(await File(rated).readAsBytes());
      expect(fpsMp4.videoSamples, inInclusiveRange(8, 12));
    });

    driverTest('odd frames are even and paths with spaces succeed', () async {
      final plain = _join(temp.path, 'odd-plain.mp4');
      final plainSession = XueHuaMediaCompression.video.compress(
        inputPath: oddVideo,
        outputPath: plain,
        options: const VideoCompressOptions(bitrate: 400000, keepAudio: false),
      );
      final plainResult = await _resultOf(plainSession);
      expect(plainResult.width.isEven, isTrue);
      expect(plainResult.height.isEven, isTrue);
      expect(plainResult.width, lessThanOrEqualTo(101));
      expect(plainResult.height, lessThanOrEqualTo(61));

      final output = _join(temp.path, 'new parent/clip out.mp4');
      final session = XueHuaMediaCompression.video.compress(
        inputPath: spacedVideo,
        outputPath: output,
        options: const VideoCompressOptions(bitrate: 400000, keepAudio: false),
      );
      final result = await _resultOf(session);
      expect(File(output).existsSync(), isTrue);
      expect(result.sizeBytes, greaterThan(0));
      expect(result.width, 64);
      expect(result.height, 64);
    });

    driverTest(
      'missing video, corrupt video, content URI, and empty path fail',
      () async {
        final missingOut = _join(temp.path, 'missing-out.mp4');
        final missing = XueHuaMediaCompression.video.compress(
          inputPath: _join(temp.path, 'missing-video.mp4'),
          outputPath: missingOut,
        );
        await _expectCode(missing, MediaCompressionException.notFound);
        expect(File(missingOut).existsSync(), isFalse);

        final corruptPath = _join(temp.path, 'corrupt.mp4');
        await File(corruptPath).writeAsString('not a video');
        final corruptOut = _join(temp.path, 'corrupt-out.mp4');
        final corrupt = XueHuaMediaCompression.video.compress(
          inputPath: corruptPath,
          outputPath: corruptOut,
        );
        await _expectCode(corrupt, MediaCompressionException.decode);
        expect(File(corruptOut).existsSync(), isFalse);

        final directory = Directory(_join(temp.path, 'video-dir'))
          ..createSync(recursive: true);
        final asDirOut = _join(temp.path, 'dir-out.mp4');
        final asDir = XueHuaMediaCompression.video.compress(
          inputPath: directory.path,
          outputPath: asDirOut,
        );
        await _expectCode(asDir, MediaCompressionException.io);
        expect(File(asDirOut).existsSync(), isFalse);

        final content = XueHuaMediaCompression.video.compress(
          inputPath: 'content://media/external/video/1',
          outputPath: _join(temp.path, 'content-out.mp4'),
        );
        await _expectCode(content, MediaCompressionException.unsupported);

        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: '  ',
            outputPath: _join(temp.path, 'empty.mp4'),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: _join(temp.path, 'bad.mp4'),
            options: const VideoCompressOptions(bitrate: 0),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: _join(temp.path, 'bad-fps.mp4'),
            options: const VideoCompressOptions(fps: 0),
          ),
          throwsArgumentError,
        );
      },
    );

    driverTest('long video cancel removes the output', () async {
      final output = _join(temp.path, 'cancelled.mp4');
      final session = XueHuaMediaCompression.video.compress(
        inputPath: longVideo,
        outputPath: output,
        options: const VideoCompressOptions(
          bitrate: 2000000,
          keepAudio: false,
        ),
      );
      final progress = <double>[];
      final sub = session.progress.listen(progress.add);
      // Cancel as soon as the session exists. Waiting for a mid-progress
      // sample deadlocked the platform thread on hardware when cancelWriting
      // ran there; the H.264 case already asserts in-flight progress.
      await session.cancel().timeout(const Duration(seconds: 20));
      await _expectCode(
        session,
        MediaCompressionException.cancelled,
      ).timeout(const Duration(seconds: 30));
      await sub.cancel();
      for (final value in progress) {
        expect(value, inInclusiveRange(0, 1));
      }
      expect(File(output).existsSync(), isFalse);
    });

    driverTest('cancel then dispose does not crash while a job is running', () async {
      final output = _join(temp.path, 'dispose-race.mp4');
      final session = XueHuaMediaCompression.video.compress(
        inputPath: longVideo,
        outputPath: output,
        options: const VideoCompressOptions(bitrate: 2500000, keepAudio: false),
      );
      unawaited(session.result.then<void>((_) {}, onError: (Object _) {}));
      await session.cancel().timeout(const Duration(seconds: 20));
      await session.dispose().timeout(const Duration(seconds: 20));
      await session.dispose().timeout(const Duration(seconds: 20));
      await session.cancel().timeout(const Duration(seconds: 20));
    });

    driverTest('dispose is idempotent and a later job still runs', () async {
      final output = _join(temp.path, 'second.mp4');
      final session = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: output,
        options: const VideoCompressOptions(bitrate: 300000, keepAudio: false),
      );
      await _resultOf(session);
      await session.dispose();
      await session.cancel();
      expect(File(output).existsSync(), isTrue);

      final again = _join(temp.path, 'second-again.mp4');
      final next = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: again,
        options: const VideoCompressOptions(bitrate: 300000, keepAudio: false),
      );
      final result = await _resultOf(next);
      expect(result.sizeBytes, greaterThan(0));
      expect(File(again).existsSync(), isTrue);
    });

    driverTest('plugin binary does not link foreign codec libraries', () async {
      final binaries = await _pluginBinaries();
      expect(binaries, isNotEmpty, reason: 'built plugin binary was not found');
      var sawToolbox = false;
      for (final library in binaries) {
        final bytes = await library.readAsBytes();
        final text = String.fromCharCodes(bytes).toLowerCase();
        for (final name in _forbiddenLibraries) {
          final label = String.fromCharCodes(name);
          expect(
            text.contains(label),
            isFalse,
            reason: '${library.path} has $label',
          );
        }
        if (_containsAscii(text, _videoToolbox)) {
          sawToolbox = true;
        }
      }
      expect(sawToolbox, isTrue, reason: 'VideoToolbox was not in ${binaries.map((File file) => file.path).join(', ')}');
    });
  });
}

String _join(String directory, String name) {
  return '$directory${Platform.pathSeparator}$name';
}

void _expectPrefix(List<int> bytes, List<int> prefix) {
  expect(bytes.length, greaterThanOrEqualTo(prefix.length));
  expect(bytes.sublist(0, prefix.length), prefix);
}

void _expectToolbox(String name, String codec) {
  expect(name, anyOf('VideoToolbox:$codec', 'VideoToolboxHW:$codec'));
  expect(_containsAscii(name.toLowerCase(), _ffmpeg), isFalse);
  expect(_containsAscii(name.toLowerCase(), _libav), isFalse);
}

bool _containsAscii(String text, List<int> codes) {
  return text.contains(String.fromCharCodes(codes));
}

const _ffmpeg = <int>[0x66, 0x66, 0x6d, 0x70, 0x65, 0x67];
const _libav = <int>[0x6c, 0x69, 0x62, 0x61, 0x76];
const _videoToolbox = <int>[
  0x76, 0x69, 0x64, 0x65, 0x6f, 0x74, 0x6f, 0x6f, 0x6c, 0x62, 0x6f, 0x78,
];
const _forbiddenLibraries = <List<int>>[
  [0x6c, 0x69, 0x62, 0x61, 0x76, 0x63, 0x6f, 0x64, 0x65, 0x63],
  [0x6c, 0x69, 0x62, 0x61, 0x76, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74],
  [0x6c, 0x69, 0x62, 0x61, 0x76, 0x75, 0x74, 0x69, 0x6c],
  [0x6c, 0x69, 0x62, 0x61, 0x76, 0x66, 0x69, 0x6c, 0x74, 0x65, 0x72],
  [0x6c, 0x69, 0x62, 0x61, 0x76, 0x64, 0x65, 0x76, 0x69, 0x63, 0x65],
  [0x6c, 0x69, 0x62, 0x73, 0x77, 0x73, 0x63, 0x61, 0x6c, 0x65],
  [0x6c, 0x69, 0x62, 0x73, 0x77, 0x72, 0x65, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65],
  [0x6c, 0x69, 0x62, 0x70, 0x6f, 0x73, 0x74, 0x70, 0x72, 0x6f, 0x63],
  [0x67, 0x73, 0x74, 0x2d, 0x6c, 0x69, 0x62, 0x61, 0x76],
  [0x61, 0x76, 0x64, 0x65, 0x63, 0x5f],
  [0x61, 0x76, 0x65, 0x6e, 0x63, 0x5f],
  _ffmpeg,
];

Future<T> _resultOf<T>(CompressionSession<T> session) async {
  try {
    return await session.result;
  } finally {
    await session.dispose();
  }
}

Future<void> _expectCode<T>(CompressionSession<T> session, String code) async {
  try {
    await expectLater(
      session.result,
      throwsA(
        isA<MediaCompressionException>().having(
          (MediaCompressionException error) => error.code,
          'code',
          code,
        ),
      ),
    );
  } finally {
    await session.dispose();
  }
}

Future<List<File>> _pluginBinaries() async {
  final executable = File(Platform.resolvedExecutable);
  final pluginFiles = <File>[];

  Future<void> collect(Directory directory, {required bool recursive}) async {
    try {
      if (!directory.existsSync()) {
        return;
      }
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is File && isDarwinPluginMachO(entity.path)) {
          pluginFiles.add(entity);
        }
      }
    } on FileSystemException {
      // App Sandbox rejects paths outside the bundle. Skip them.
    }
  }

  // SPM Debug: Contents/MacOS/<app>.debug.dylib sits next to the executable.
  // Stay inside the .app. Products/ next to the bundle is outside the sandbox.
  await collect(executable.parent, recursive: false);
  if (pluginFiles.isNotEmpty) {
    return pluginFiles;
  }
  final contents = executable.parent.parent;
  await collect(Directory(_join(contents.path, 'Frameworks')), recursive: true);
  if (pluginFiles.isNotEmpty) {
    return pluginFiles;
  }
  // Static link (iOS, or a macOS host with no companion dylib). Never a
  // kernel blob or App.framework resource.
  if (executable.existsSync() && !isDarwinBundleAsset(executable.path)) {
    return <File>[executable];
  }
  return pluginFiles;
}
