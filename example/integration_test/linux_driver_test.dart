import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart'; // ignore: deprecated_member_use
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression_example/main.dart';

import 'facade_seam.dart';

const _timeout = Timeout(Duration(minutes: 2));

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

  if (!Platform.isLinux) {
    return;
  }

  group('Linux compression driver', () {
    late Directory temp;
    late String pngPath;
    late String jpegPath;
    late String shortVideo;
    late String audioVideo;
    late String oddVideo;
    late String longVideo;
    late String spacedVideo;

    setUpAll(() async {
      temp = await Directory.systemTemp.createTemp('xh_linux_driver_');
      pngPath = '${temp.path}/smpte.png';
      jpegPath = '${temp.path}/ball.jpg';
      shortVideo = '${temp.path}/short.mkv';
      audioVideo = '${temp.path}/with_audio.mkv';
      oddVideo = '${temp.path}/odd.mkv';
      longVideo = '${temp.path}/long.mkv';
      final spacedDir = Directory('${temp.path}/dir with space')
        ..createSync(recursive: true);
      spacedVideo = '${spacedDir.path}/clip.mkv';

      await _gst([
        'videotestsrc', 'num-buffers=1', 'pattern=smpte', '!',
        'video/x-raw,width=320,height=240', '!',
        'pngenc', '!',
        'filesink', 'location=$pngPath',
      ]);
      await _gst([
        'videotestsrc', 'num-buffers=1', 'pattern=ball', '!',
        'video/x-raw,width=160,height=120', '!',
        'jpegenc', 'quality=90', '!',
        'filesink', 'location=$jpegPath',
      ]);
      await _gst([
        'videotestsrc', 'num-buffers=30', 'pattern=smpte', '!',
        'video/x-raw,width=64,height=64,framerate=30/1', '!',
        'vp8enc', 'deadline=1', 'cpu-used=16', '!',
        'matroskamux', '!',
        'filesink', 'location=$shortVideo',
      ]);
      await _gst([
        'videotestsrc', 'num-buffers=30', 'pattern=ball', '!',
        'video/x-raw,width=96,height=64,framerate=30/1', '!',
        'vp8enc', 'deadline=1', 'cpu-used=16', '!',
        'queue', '!', 'mux.',
        'audiotestsrc', 'num-buffers=47', 'samplesperbuffer=1024', '!',
        'audio/x-raw,rate=48000,channels=2', '!',
        'vorbisenc', '!',
        'queue', '!', 'mux.',
        'matroskamux', 'name=mux', '!',
        'filesink', 'location=$audioVideo',
      ]);
      await _gst([
        'videotestsrc', 'num-buffers=15', 'pattern=smpte', '!',
        'video/x-raw,width=100,height=60,framerate=30/1', '!',
        'vp8enc', 'deadline=1', 'cpu-used=16', '!',
        'matroskamux', '!',
        'filesink', 'location=$oddVideo',
      ]);
      await _gst([
        'videotestsrc', 'num-buffers=180', 'pattern=smpte', '!',
        'video/x-raw,width=1280,height=720,framerate=30/1', '!',
        'vp8enc', 'deadline=1', 'cpu-used=16', '!',
        'matroskamux', '!',
        'filesink', 'location=$longVideo',
      ]);
      await File(shortVideo).copy(spacedVideo);
    });

    tearDownAll(() async {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    driverTest('image and video capabilities match installed encoders', () async {
      final images = await XueHuaMediaCompression.image.queryCapabilities();
      expect(images.inputFormats, contains(ImageFormat.jpeg));
      expect(images.inputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, contains(ImageFormat.jpeg));
      expect(images.outputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, isNot(contains(ImageFormat.gif)));
      expect(images.outputFormats, isNot(contains(ImageFormat.avif)));
      expect(images.outputFormats, isNot(contains(ImageFormat.heic)));
      if (images.outputFormats.contains(ImageFormat.webp)) {
        expect(images.inputFormats, contains(ImageFormat.webp));
      }

      final video = await XueHuaMediaCompression.video.queryCapabilities();
      expect(video.acceptsContentUri, isFalse);
      final h264 = await _anyFactory(const [
        'vah264enc',
        'vah264lpenc',
        'vaapih264enc',
        'nvh264enc',
        'x264enc',
        'openh264enc',
      ]);
      final h265 = await _anyFactory(const [
        'vah265enc',
        'vah265lpenc',
        'vaapih265enc',
        'nvh265enc',
        'x265enc',
      ]);
      final hardware = await _anyFactory(const [
        'vah264enc',
        'vah264lpenc',
        'vaapih264enc',
        'nvh264enc',
        'vah265enc',
        'vah265lpenc',
        'vaapih265enc',
        'nvh265enc',
      ]);
      if (h264) {
        expect(video.codecs, contains(VideoCodec.h264));
      }
      if (h265) {
        expect(video.codecs, contains(VideoCodec.h265));
      }
      expect(video.codecs, isNotEmpty);
      if (hardware) {
        expect(video.encoderName, 'GStreamerHW');
      } else {
        expect(video.encoderName, isNull);
      }
      expect(video.encoderName, isNot(contains('FFmpeg')));
      expect(video.encoderName, isNot(contains('libav')));
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
      expect(result.width, 160);
      expect(result.height, 120);
      expect(result.sizeBytes, greaterThan(0));
      expect(await File(output).length(), result.sizeBytes);
      _expectPrefix(await File(output).readAsBytes(), const [0xff, 0xd8]);

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
      _expectPrefix(png.bytes!, const [0x89, 0x50, 0x4e, 0x47]);
    });

    driverTest('png with alpha and webp when advertised', () async {
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
      _expectPrefix(await File(jpegOut).readAsBytes(), const [0xff, 0xd8]);

      final caps = await XueHuaMediaCompression.image.queryCapabilities();
      if (!caps.outputFormats.contains(ImageFormat.webp)) {
        return;
      }
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
      _expectPrefix(webpResult.bytes!, const [0x52, 0x49, 0x46, 0x46]);
      expect(webpResult.width, 160);
      expect(webpResult.height, 120);
    });

    driverTest('image maxDimension downscales and creates parent directories', () async {
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
      final longest = result.width > result.height ? result.width : result.height;
      expect(longest, lessThanOrEqualTo(80));
      expect(result.width / result.height, closeTo(320 / 240, 0.05));
    });

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

    driverTest('gif input decodes and gif/avif/heic output is unsupported', () async {
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

      for (final format in const [
        ImageFormat.gif,
        ImageFormat.avif,
        ImageFormat.heic,
      ]) {
        final rejected = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(jpegPath),
          destination: MediaDestination.bytes(),
          options: ImageCompressOptions(format: format),
        );
        await _expectCode(rejected, MediaCompressionException.unsupported);
      }
    });

    driverTest('missing, corrupt, and content URI image inputs fail cleanly', () async {
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
    });

    driverTest('image cancel discards the output file', () async {
      final big = '${temp.path}/big.png';
      await _gst([
        'videotestsrc', 'num-buffers=1', 'pattern=smpte', '!',
        'video/x-raw,width=3000,height=2000', '!',
        'pngenc', 'compression-level=1', '!',
        'filesink', 'location=$big',
      ]);
      final output = '${temp.path}/cancelled-image.jpg';
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(big),
        destination: MediaDestination.path(output),
        options: const ImageCompressOptions(quality: 90),
      );
      final result = session.result;
      await session.cancel();
      await _expectCode(session, MediaCompressionException.cancelled);
      await expectLater(result, throwsA(isA<MediaCompressionException>()));
      expect(File(output).existsSync(), isFalse);
    });

    driverTest('video compresses H.264 with progress and file:// paths', () async {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      expect(caps.codecs, contains(VideoCodec.h264));
      final output = '${temp.path}/h264.mp4';
      final progress = <double>[];
      final session = XueHuaMediaCompression.video.compress(
        inputPath: 'file://$shortVideo',
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
      expect(result.encoderName, startsWith('GStreamer:'));
      expect(result.encoderName.toLowerCase(), isNot(contains('avdec')));
      expect(result.encoderName.toLowerCase(), isNot(contains('ffmpeg')));
      expect(await File(output).length(), result.sizeBytes);
      final mp4 = _Mp4Probe.parse(await File(output).readAsBytes());
      expect(mp4.hasVideo, isTrue);
      expect(mp4.hasAudio, isFalse);
      expect(mp4.width, result.width);
      expect(mp4.height, result.height);
      expect(mp4.containsTag('avc1'), isTrue);
      await _assertDecodable(output);
    });

    driverTest('video H.265 compresses when an encoder is advertised', () async {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      if (!caps.codecs.contains(VideoCodec.h265)) {
        return;
      }
      final output = '${temp.path}/h265.mp4';
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
      expect(result.encoderName, startsWith('GStreamer:'));
      final mp4 = _Mp4Probe.parse(await File(output).readAsBytes());
      expect(mp4.hasVideo, isTrue);
      expect(mp4.hasAudio, isFalse);
      expect(mp4.containsTag('hvc1') || mp4.containsTag('hev1'), isTrue);
      await _assertDecodable(output);
    });

    driverTest('keepAudio keeps an AAC track and false strips it', () async {
      final keptPath = '${temp.path}/audio-kept.mp4';
      final kept = XueHuaMediaCompression.video.compress(
        inputPath: audioVideo,
        outputPath: keptPath,
        options: const VideoCompressOptions(
          bitrate: 500000,
          keepAudio: true,
        ),
      );
      final keptResult = await _resultOf(kept);
      expect(keptResult.width, 96);
      expect(keptResult.height, 64);
      final keptMp4 = _Mp4Probe.parse(await File(keptPath).readAsBytes());
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
      final droppedMp4 = _Mp4Probe.parse(await File(droppedPath).readAsBytes());
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
      final mp4 = _Mp4Probe.parse(await File(scaled).readAsBytes());
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
      final fpsMp4 = _Mp4Probe.parse(await File(rated).readAsBytes());
      expect(fpsMp4.videoSamples, inInclusiveRange(8, 12));
    });

    driverTest('paths with spaces and missing parents succeed', () async {
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

    driverTest('missing video, content URI, and empty path fail cleanly', () async {
      final missing = XueHuaMediaCompression.video.compress(
        inputPath: '${temp.path}/missing-video.mp4',
        outputPath: '${temp.path}/missing-out.mp4',
      );
      await _expectCode(missing, MediaCompressionException.notFound);
      expect(File('${temp.path}/missing-out.mp4').existsSync(), isFalse);

      final content = XueHuaMediaCompression.video.compress(
        inputPath: 'content://media/external/video/1',
        outputPath: '${temp.path}/content-out.mp4',
      );
      await _expectCode(content, MediaCompressionException.unsupported);

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
    });

    driverTest('long video reports mid-progress and cancel removes the output', () async {
      final output = '${temp.path}/cancelled.mp4';
      final session = XueHuaMediaCompression.video.compress(
        inputPath: longVideo,
        outputPath: output,
        options: const VideoCompressOptions(bitrate: 2000000, keepAudio: false),
      );
      final progress = <double>[];
      var cancelSent = false;
      final sub = session.progress.listen((value) {
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
    });

    driverTest('cancel then dispose does not crash while a job is running', () async {
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
    });

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
    });

    driverTest('plugin binary does not link FFmpeg libraries', () async {
      final so = await _findPluginSo();
      expect(so, isNotNull, reason: 'built plugin .so was not found');
      final library = so!;
      final readelf = await Process.run('readelf', ['-d', library.path]);
      final ldd = await Process.run('ldd', [library.path]);
      final strings = await Process.run('strings', ['-a', library.path]);
      expect(readelf.exitCode, 0, reason: '${readelf.stderr}');
      expect(ldd.exitCode, 0, reason: '${ldd.stderr}');
      final linked = '${readelf.stdout}\n${ldd.stdout}'.toLowerCase();
      for (final name in const [
        'libavcodec',
        'libavformat',
        'libavutil',
        'libavfilter',
        'libavdevice',
        'libswscale',
        'libswresample',
        'libpostproc',
      ]) {
        expect(linked, isNot(contains(name)), reason: library.path);
      }
      final text = '${strings.stdout}'.toLowerCase();
      expect(text, isNot(contains('avdec_')));
      expect(text, isNot(contains('avenc_')));
      expect(text, isNot(contains('libavcodec')));
      expect(text, contains('libav'));
    });
  });
}

void _expectPrefix(List<int> bytes, List<int> prefix) {
  expect(bytes.length, greaterThanOrEqualTo(prefix.length));
  expect(bytes.sublist(0, prefix.length), prefix);
}

Future<T> _resultOf<T>(CompressionSession<T> session) async {
  try {
    return await session.result;
  } finally {
    await session.dispose();
  }
}

Future<void> _expectCode<T>(
  CompressionSession<T> session,
  String code,
) async {
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

Future<void> _gst(List<String> pipeline) async {
  final result = await Process.run('gst-launch-1.0', [
    '-q',
    '-e',
    ...pipeline,
  ]);
  if (result.exitCode != 0) {
    fail(
      'gst-launch-1.0 failed (${result.exitCode}): ${pipeline.join(' ')}\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}

Future<bool> _factory(String name) async {
  final result = await Process.run('gst-inspect-1.0', [name]);
  return result.exitCode == 0;
}

Future<bool> _anyFactory(List<String> names) async {
  for (final name in names) {
    if (await _factory(name)) {
      return true;
    }
  }
  return false;
}

Future<void> _assertDecodable(String path) async {
  final result = await Process.run('gst-launch-1.0', [
    '-q',
    '-e',
    'filesrc',
    'location=$path',
    '!',
    'decodebin',
    '!',
    'fakesink',
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'output is not decodable: ${result.stdout}\n${result.stderr}',
  );
}

Future<File?> _findPluginSo() async {
  final roots = <Directory>[
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ];
  var parent = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    roots.add(parent);
    final next = parent.parent;
    if (next.path == parent.path) {
      break;
    }
    parent = next;
  }
  for (final root in roots) {
    if (!root.existsSync()) {
      continue;
    }
    final found = await _searchSo(root, 0);
    if (found != null) {
      return found;
    }
  }
  return null;
}

Future<File?> _searchSo(Directory dir, int depth) async {
  if (depth > 6) {
    return null;
  }
  List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } on FileSystemException {
    return null;
  }
  for (final entity in children) {
    if (entity is File &&
        entity.path.endsWith('libxue_hua_media_compression_plugin.so')) {
      return entity;
    }
  }
  for (final entity in children) {
    if (entity is! Directory) {
      continue;
    }
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name == 'ephemeral' || name.startsWith('.')) {
      continue;
    }
    final found = await _searchSo(entity, depth + 1);
    if (found != null) {
      return found;
    }
  }
  return null;
}

final class _Mp4Probe {
  _Mp4Probe._({
    required this.hasVideo,
    required this.hasAudio,
    required this.width,
    required this.height,
    required this.videoSamples,
    required this.syncSamples,
    required this.bytes,
  });

  final bool hasVideo;
  final bool hasAudio;
  final int width;
  final int height;
  final int videoSamples;
  final int syncSamples;
  final Uint8List bytes;

  bool containsTag(String tag) {
    final needle = tag.codeUnits;
    if (needle.length != 4) {
      return false;
    }
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] == needle[0] &&
          bytes[i + 1] == needle[1] &&
          bytes[i + 2] == needle[2] &&
          bytes[i + 3] == needle[3]) {
        return true;
      }
    }
    return false;
  }

  static _Mp4Probe parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var hasVideo = false;
    var hasAudio = false;
    var width = 0;
    var height = 0;
    var samples = 0;
    var sync = 0;
    void walk(int start, int end) {
      var offset = start;
      while (offset + 8 <= end) {
        final header = _box(data, offset, end);
        if (header == null) {
          return;
        }
        final body = offset + header.headerSize;
        final boxEnd = offset + header.size;
        switch (header.type) {
          case 'moov':
          case 'mdia':
          case 'minf':
          case 'stbl':
            walk(body, boxEnd);
            break;
          case 'trak':
            final handler = _handler(data, body, boxEnd);
            if (handler == 'vide') {
              hasVideo = true;
              final size = _trackSize(data, body, boxEnd);
              if (size != null && (width == 0 || height == 0)) {
                width = size.$1;
                height = size.$2;
              }
              samples += _sampleCount(data, body, boxEnd);
              sync += _syncCount(data, body, boxEnd);
            } else if (handler == 'soun') {
              hasAudio = true;
            }
            break;
          default:
            break;
        }
        offset = boxEnd;
      }
    }

    walk(0, bytes.length);
    return _Mp4Probe._(
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      width: width,
      height: height,
      videoSamples: samples,
      syncSamples: sync,
      bytes: bytes,
    );
  }
}

final class _Box {
  const _Box(this.type, this.size, this.headerSize);

  final String type;
  final int size;
  final int headerSize;
}

_Box? _box(ByteData data, int offset, int end) {
  if (offset + 8 > end) {
    return null;
  }
  var size = data.getUint32(offset);
  var header = 8;
  final type = _type(data, offset + 4);
  if (size == 1) {
    if (offset + 16 > end) {
      return null;
    }
    size = data.getUint64(offset + 8);
    header = 16;
  } else if (size == 0) {
    size = end - offset;
  }
  if (size < header || offset + size > end) {
    return null;
  }
  return _Box(type, size, header);
}

String _type(ByteData data, int offset) {
  return String.fromCharCodes([
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
    data.getUint8(offset + 3),
  ]);
}

String? _handler(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return null;
    }
    final body = offset + box.headerSize;
    if (box.type == 'hdlr' && box.size >= box.headerSize + 12) {
      return _type(data, body + 8);
    }
    if (box.type == 'mdia' || box.type == 'minf') {
      final nested = _handler(data, body, offset + box.size);
      if (nested != null) {
        return nested;
      }
    }
    offset += box.size;
  }
  return null;
}

(int, int)? _trackSize(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return null;
    }
    if (box.type == 'tkhd' && box.size >= box.headerSize + 8) {
      final version = data.getUint8(offset + box.headerSize);
      final widthOffset = offset + (version == 0 ? 84 : 96);
      if (widthOffset + 8 <= offset + box.size) {
        final width = data.getUint32(widthOffset) >> 16;
        final height = data.getUint32(widthOffset + 4) >> 16;
        return (width, height);
      }
    }
    offset += box.size;
  }
  return null;
}

int _sampleCount(ByteData data, int start, int end) {
  var total = 0;
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return total;
    }
    final body = offset + box.headerSize;
    if (box.type == 'stts' && box.size >= box.headerSize + 8) {
      final entries = data.getUint32(body + 4);
      var cursor = body + 8;
      for (var i = 0; i < entries; i++) {
        if (cursor + 8 > offset + box.size) {
          break;
        }
        total += data.getUint32(cursor);
        cursor += 8;
      }
    } else if (box.type == 'mdia' ||
        box.type == 'minf' ||
        box.type == 'stbl') {
      total += _sampleCount(data, body, offset + box.size);
    }
    offset += box.size;
  }
  return total;
}

int _syncCount(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return 0;
    }
    final body = offset + box.headerSize;
    if (box.type == 'stss' && box.size >= box.headerSize + 8) {
      return data.getUint32(body + 4);
    }
    if (box.type == 'mdia' || box.type == 'minf' || box.type == 'stbl') {
      final nested = _syncCount(data, body, offset + box.size);
      if (nested > 0) {
        return nested;
      }
    }
    offset += box.size;
  }
  return 0;
}
