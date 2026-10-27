import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression_example/main.dart';

import 'facade_seam.dart';
import 'windows_media.dart';

const _timeout = Timeout(Duration(minutes: 4));

/// Example applicationId plus the FileProvider authority suffix.
const _fileProviderAuthority =
    'com.example.xue_hua_media_compression_example.fileprovider';

const _forbiddenNative = <String>[
  'libavcodec',
  'libavformat',
  'libavutil',
  'libavfilter',
  'libavdevice',
  'libswscale',
  'libswresample',
  'libpostproc',
  'libffmpeg',
  'gst-libav',
  'libx264',
];

void driverTest(String name, Future<void> Function() body) {
  test(name, body, timeout: _timeout);
}

void main() {
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

  if (!Platform.isAndroid) {
    return;
  }

  group('Android compression driver', () {
    Directory? owned;
    late Directory cache;
    late Directory temp;
    late String pngPath;
    late String jpegPath;
    late String shortVideo;
    late String audioVideo;
    late String oddVideo;
    late String longVideo;
    late String spacedVideo;

    setUpAll(() async {
      // FileProvider serves Context.getCacheDir() at content://…/cache/.
      // Flutter 3.47+ may point Directory.systemTemp at …/code_cache instead;
      // prefer the sibling app cache dir so content:// URIs resolve.
      final systemTemp = Directory.systemTemp;
      if (systemTemp.path.endsWith('/code_cache')) {
        cache = Directory(
          '${systemTemp.path.substring(0, systemTemp.path.length - '/code_cache'.length)}/cache',
        );
        if (!cache.existsSync()) {
          cache.createSync(recursive: true);
        }
      } else {
        cache = systemTemp;
      }
      expect(
        cache.path.endsWith('/cache') || cache.path.contains('/cache/'),
        isTrue,
        reason: 'expected the app cache dir, got ${cache.path} (systemTemp=${systemTemp.path})',
      );
      temp = owned = Directory(
        '${cache.path}/xh_android_driver_${DateTime.now().millisecondsSinceEpoch}',
      )..createSync(recursive: true);
      pngPath = '${temp.path}/smpte.png';
      jpegPath = '${temp.path}/fixture.jpg';
      shortVideo = '${temp.path}/short.mp4';
      audioVideo = '${temp.path}/with_audio.mp4';
      oddVideo = '${temp.path}/odd.mp4';
      longVideo = '${temp.path}/long.mp4';
      final spacedDir = Directory('${temp.path}/dir with space')
        ..createSync(recursive: true);
      spacedVideo = '${spacedDir.path}/clip.mp4';

      await File(pngPath).writeAsBytes(encodePng(320, 240, noisyRgb(320, 240)));
      await _copyAsset('integration_test/fixtures/sample.jpg', jpegPath);
      await _copyAsset(
        'integration_test/fixtures/android/short.mp4',
        shortVideo,
      );
      await _copyAsset(
        'integration_test/fixtures/android/with_audio.mp4',
        audioVideo,
      );
      await _copyAsset('integration_test/fixtures/android/odd.mp4', oddVideo);
      await _copyAsset('integration_test/fixtures/android/long.mp4', longVideo);
      await File(shortVideo).copy(spacedVideo);
    });

    tearDownAll(() async {
      final directory = owned;
      if (directory != null && directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    driverTest('image and video capabilities match installed codecs', () async {
      final images = await XueHuaMediaCompression.image.queryCapabilities();
      expect(images.inputFormats, contains(ImageFormat.jpeg));
      expect(images.inputFormats, contains(ImageFormat.png));
      expect(images.inputFormats, contains(ImageFormat.webp));
      expect(images.inputFormats, contains(ImageFormat.gif));
      expect(images.outputFormats, contains(ImageFormat.jpeg));
      expect(images.outputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, contains(ImageFormat.webp));
      expect(images.outputFormats, isNot(contains(ImageFormat.gif)));
      expect(images.outputFormats, isNot(contains(ImageFormat.avif)));

      final video = await XueHuaMediaCompression.video.queryCapabilities();
      expect(video.acceptsContentUri, isTrue);
      expect(
        video.codecs,
        contains(VideoCodec.h264),
        reason: 'Android image has no H.264 encoder',
      );
      if (video.encoderName != null) {
        expect(video.encoderName, 'MediaCodecHW');
      }
      final label = (video.encoderName ?? '').toLowerCase();
      expect(label, isNot(contains('ffmpeg')));
      expect(label, isNot(contains('libav')));
      expect(label, isNot(contains('media3')));
    });

    driverTest('image compress from path and bytes, with progress', () async {
      final output = '${temp.path}/out.jpg';
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
      expect(result.outputPath, output);
      expect(result.bytes, isNull);
      expect(result.format, ImageFormat.jpeg);
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
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

    driverTest('png to jpeg and webp when advertised', () async {
      final jpegOut = '${temp.path}/from_png.jpg';
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
      expect(caps.outputFormats, contains(ImageFormat.webp));
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
    });

    driverTest(
      'image maxDimension downscales and creates parent directories',
      () async {
        final output = '${temp.path}/nested/deeper/scaled.jpg';
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

    driverTest(
      'gif input decodes and unsupported stills stay rejected',
      () async {
        const gif = <int>[
          0x47,
          0x49,
          0x46,
          0x38,
          0x39,
          0x61,
          0x01,
          0x00,
          0x01,
          0x00,
          0x80,
          0x00,
          0x00,
          0xff,
          0xff,
          0xff,
          0x00,
          0x00,
          0x00,
          0x21,
          0xf9,
          0x04,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
          0x2c,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x01,
          0x00,
          0x00,
          0x02,
          0x02,
          0x44,
          0x01,
          0x00,
          0x3b,
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
          expect(heicResult.sizeBytes, greaterThan(0));
        } else {
          final rejected = XueHuaMediaCompression.image.compress(
            source: MediaSource.path(jpegPath),
            destination: MediaDestination.bytes(),
            options: const ImageCompressOptions(format: ImageFormat.heic),
          );
          await _expectCode(rejected, MediaCompressionException.unsupported);
        }
      },
    );

    driverTest(
      'missing, corrupt, directory, and content URI images fail or round-trip',
      () async {
        final missing = XueHuaMediaCompression.image.compress(
          source: MediaSource.path('${temp.path}/no-such-image.jpg'),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(missing, MediaCompressionException.notFound);

        final corruptPath = '${temp.path}/corrupt.jpg';
        await File(corruptPath).writeAsString('this is not a jpeg');
        final corrupt = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(corruptPath),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(corrupt, MediaCompressionException.decode);

        final directory = Directory('${temp.path}/not-a-file')
          ..createSync(recursive: true);
        final asFile = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(directory.path),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(asFile, MediaCompressionException.io);

        final missingContent = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(_missingContentUri('jpg')),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(missingContent, MediaCompressionException.notFound);

        final contentOut = '${temp.path}/from-content.jpg';
        final content = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(_contentUri(cache, jpegPath)),
          destination: MediaDestination.path(contentOut),
          options: const ImageCompressOptions(quality: 70),
        );
        final contentResult = await _resultOf(content);
        expect(contentResult.format, ImageFormat.jpeg);
        expect(File(contentOut).existsSync(), isTrue);
        _expectPrefix(await File(contentOut).readAsBytes(), const <int>[
          0xff,
          0xd8,
        ]);

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
      final big = '${temp.path}/big.png';
      await File(big).writeAsBytes(encodePng(2400, 1600, noisyRgb(2400, 1600)));
      final output = '${temp.path}/cancelled-image.jpg';
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(big),
        destination: MediaDestination.path(output),
        options: const ImageCompressOptions(quality: 95),
      );
      final result = session.result;
      await session.cancel();
      await _expectCode(session, MediaCompressionException.cancelled);
      await expectLater(result, throwsA(isA<MediaCompressionException>()));
      expect(File(output).existsSync(), isFalse);
    });

    driverTest(
      'video compresses H.264 with progress and file:// paths',
      () async {
        final caps = await XueHuaMediaCompression.video.queryCapabilities();
        expect(caps.codecs, contains(VideoCodec.h264));
        final output = '${temp.path}/h264.mp4';
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
        expect(result.codec, VideoCodec.h264);
        expect(result.width, 64);
        expect(result.height, 64);
        expect(result.width.isEven, isTrue);
        expect(result.height.isEven, isTrue);
        expect(result.sizeBytes, greaterThan(0));
        _expectAndroidEncoder(result.encoderName, 'H264', caps.encoderName);
        expect(await File(output).length(), result.sizeBytes);
        final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
        expect(mp4.hasVideo, isTrue);
        expect(mp4.hasAudio, isFalse);
        expect(mp4.width, result.width);
        expect(mp4.height, result.height);
        expect(mp4.containsTag('avc1'), isTrue);
      },
    );

    driverTest('video H.265 follows the advertised encoder list', () async {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      final output = '${temp.path}/h265.mp4';
      if (!caps.codecs.contains(VideoCodec.h265)) {
        final rejected = XueHuaMediaCompression.video.compress(
          inputPath: shortVideo,
          outputPath: output,
          options: const VideoCompressOptions(
            codec: VideoCodec.h265,
            bitrate: 400000,
            keepAudio: false,
          ),
        );
        await _expectCode(rejected, MediaCompressionException.unsupported);
        expect(File(output).existsSync(), isFalse);
        return;
      }
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
      _expectAndroidEncoder(result.encoderName, 'H265', caps.encoderName);
      final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
      expect(mp4.hasVideo, isTrue);
      expect(mp4.hasAudio, isFalse);
      expect(mp4.containsTag('hvc1') || mp4.containsTag('hev1'), isTrue);
    });

    driverTest('keepAudio keeps an AAC track and false strips it', () async {
      final keptPath = '${temp.path}/audio-kept.mp4';
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

      final droppedPath = '${temp.path}/audio-dropped.mp4';
      final dropped = XueHuaMediaCompression.video.compress(
        inputPath: audioVideo,
        outputPath: droppedPath,
        options: const VideoCompressOptions(
          bitrate: 500000,
          keepAudio: false,
          keyframeInterval: 10,
        ),
      );
      final droppedResult = await _resultOf(dropped);
      expect(droppedResult.width, 96);
      expect(droppedResult.height, 64);
      final droppedMp4 = Mp4Probe.parse(await File(droppedPath).readAsBytes());
      expect(droppedMp4.hasVideo, isTrue);
      expect(droppedMp4.hasAudio, isFalse);
      expect(droppedMp4.syncSamples, greaterThan(1));
    });

    driverTest('fps and maxDimension reshape the video', () async {
      final scaled = '${temp.path}/scaled.mp4';
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

      final rated = '${temp.path}/fps.mp4';
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
      final plain = '${temp.path}/odd-plain.mp4';
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

      final output = '${temp.path}/new parent/clip out.mp4';
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
      'missing, corrupt, directory, and content URI videos fail cleanly',
      () async {
        final missingOut = '${temp.path}/missing-out.mp4';
        final missing = XueHuaMediaCompression.video.compress(
          inputPath: '${temp.path}/missing-video.mp4',
          outputPath: missingOut,
        );
        await _expectCode(missing, MediaCompressionException.notFound);
        expect(File(missingOut).existsSync(), isFalse);

        final corruptPath = '${temp.path}/corrupt.mp4';
        await File(corruptPath).writeAsString('not a video');
        final corruptOut = '${temp.path}/corrupt-out.mp4';
        final corrupt = XueHuaMediaCompression.video.compress(
          inputPath: corruptPath,
          outputPath: corruptOut,
        );
        await _expectCode(corrupt, MediaCompressionException.decode);
        expect(File(corruptOut).existsSync(), isFalse);

        final directory = Directory('${temp.path}/video-dir')
          ..createSync(recursive: true);
        final directoryOut = '${temp.path}/directory-out.mp4';
        final asFile = XueHuaMediaCompression.video.compress(
          inputPath: directory.path,
          outputPath: directoryOut,
        );
        await _expectCode(asFile, MediaCompressionException.io);
        expect(File(directoryOut).existsSync(), isFalse);

        final missingContentOut = '${temp.path}/missing-content.mp4';
        final missingContent = XueHuaMediaCompression.video.compress(
          inputPath: _missingContentUri('mp4'),
          outputPath: missingContentOut,
        );
        await _expectCode(missingContent, MediaCompressionException.notFound);
        expect(File(missingContentOut).existsSync(), isFalse);

        final contentOut = '${temp.path}/from-content.mp4';
        final content = XueHuaMediaCompression.video.compress(
          inputPath: _contentUri(cache, shortVideo),
          outputPath: contentOut,
          options: const VideoCompressOptions(
            bitrate: 400000,
            keepAudio: false,
          ),
        );
        final contentResult = await _resultOf(content);
        expect(contentResult.codec, VideoCodec.h264);
        expect(contentResult.width, 64);
        expect(contentResult.height, 64);
        expect(File(contentOut).existsSync(), isTrue);

        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: '  ',
            outputPath: '${temp.path}/empty.mp4',
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: '${temp.path}/bad.mp4',
            options: const VideoCompressOptions(bitrate: 0),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: '${temp.path}/bad-fps.mp4',
            options: const VideoCompressOptions(fps: 0),
          ),
          throwsArgumentError,
        );
      },
    );

    driverTest(
      'long video reports mid-progress and cancel removes the output',
      () async {
        final output = '${temp.path}/cancelled.mp4';
        final session = XueHuaMediaCompression.video.compress(
          inputPath: longVideo,
          outputPath: output,
          options: const VideoCompressOptions(
            bitrate: 2000000,
            keepAudio: false,
          ),
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
        expect(progress, isNotEmpty);
        expect(File(output).existsSync(), isFalse);
      },
    );

    driverTest(
      'cancel then dispose does not crash while a job is running',
      () async {
        final output = '${temp.path}/dispose-race.mp4';
        final session = XueHuaMediaCompression.video.compress(
          inputPath: longVideo,
          outputPath: output,
          options: const VideoCompressOptions(
            bitrate: 2500000,
            keepAudio: false,
          ),
        );
        unawaited(session.result.then<void>((_) {}, onError: (Object _) {}));
        await session.cancel();
        await session.dispose();
        await session.dispose();
        await session.cancel();
        expect(File(output).existsSync(), isFalse);
      },
    );

    driverTest('dispose is idempotent and a second job still runs', () async {
      final output = '${temp.path}/second.mp4';
      final session = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: output,
        options: const VideoCompressOptions(bitrate: 300000, keepAudio: false),
      );
      await _resultOf(session);
      await session.dispose();
      await session.cancel();
      expect(File(output).existsSync(), isTrue);

      final again = '${temp.path}/second-again.mp4';
      final next = XueHuaMediaCompression.video.compress(
        inputPath: shortVideo,
        outputPath: again,
        options: const VideoCompressOptions(bitrate: 300000, keepAudio: false),
      );
      final result = await _resultOf(next);
      expect(result.width, 64);
      expect(result.height, 64);
      expect(File(again).existsSync(), isTrue);
    });

    driverTest('packaged process does not load FFmpeg libraries', () async {
      final mapsFile = File('/proc/self/maps');
      expect(
        mapsFile.existsSync(),
        isTrue,
        reason: 'cannot read /proc/self/maps',
      );
      final maps = await mapsFile.readAsString();
      expect(maps, contains('libflutter.so'));
      final lower = maps.toLowerCase();
      for (final name in _forbiddenNative) {
        expect(lower.contains(name), isFalse, reason: 'maps contain $name');
      }
      String? libLine;
      for (final line in maps.split('\n')) {
        if (line.contains('libflutter.so')) {
          libLine = line;
          break;
        }
      }
      expect(libLine, isNotNull);
      final libraryPath = libLine!.trim().split(RegExp(r'\s+')).last;
      final directory = File(libraryPath).parent;
      expect(directory.existsSync(), isTrue, reason: libraryPath);
      final names = directory
          .listSync(followLinks: false)
          .map((entity) => entity.uri.pathSegments.last.toLowerCase())
          .toList();
      expect(names, contains('libflutter.so'));
      for (final name in names) {
        for (final banned in _forbiddenNative) {
          expect(name.contains(banned), isFalse, reason: name);
        }
      }
    });
  });
}

String _contentUri(Directory cache, String filePath) {
  final cachePath = cache.path.endsWith('/')
      ? cache.path.substring(0, cache.path.length - 1)
      : cache.path;
  if (!filePath.startsWith('$cachePath/')) {
    fail('$filePath is outside the app cache $cachePath');
  }
  final relative = filePath.substring(cachePath.length + 1);
  return Uri(
    scheme: 'content',
    host: _fileProviderAuthority,
    path: '/cache/$relative',
  ).toString();
}

String _missingContentUri(String extension) {
  return Uri(
    scheme: 'content',
    host: _fileProviderAuthority,
    path: '/cache/missing-${DateTime.now().microsecondsSinceEpoch}.$extension',
  ).toString();
}

void _expectAndroidEncoder(String name, String label, String? hardwareLabel) {
  expect(name.toLowerCase(), isNot(contains('ffmpeg')));
  expect(name.toLowerCase(), isNot(contains('libav')));
  expect(name.toLowerCase(), isNot(contains('media3')));
  if (hardwareLabel == null) {
    expect(name, 'MediaCodec:$label');
    return;
  }
  expect(name, anyOf('MediaCodec:$label', 'MediaCodecHW:$label'));
}

void _expectPrefix(List<int> bytes, List<int> prefix) {
  expect(bytes.length, greaterThanOrEqualTo(prefix.length));
  expect(bytes.sublist(0, prefix.length), prefix);
}

Future<void> _copyAsset(String asset, String dest) async {
  final data = await rootBundle.load(asset);
  await File(dest).writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

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
