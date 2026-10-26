import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

import 'windows_media.dart';

const _timeout = Timeout(Duration(minutes: 3));

void driverTest(String name, Future<void> Function() body) {
  test(name, body, timeout: _timeout);
}

void registerWindowsDriverTests() {
  if (!Platform.isWindows) {
    return;
  }

  group('Windows compression driver', () {
    Directory? tempDir;
    late Directory temp;
    late String pngPath;
    late String jpegPath;
    late String shortVideo;
    late String audioVideo;
    late String oddVideo;
    late String spacedVideo;

    setUpAll(() async {
      temp = tempDir = await Directory.systemTemp.createTemp(
        'xh_windows_driver_',
      );
      pngPath = '${temp.path}\\smpte.png';
      jpegPath = '${temp.path}\\fixture.jpg';
      shortVideo = '${temp.path}\\short.avi';
      audioVideo = '${temp.path}\\with_audio.avi';
      oddVideo = '${temp.path}\\odd.avi';
      final spacedDir = Directory('${temp.path}\\dir with space')
        ..createSync(recursive: true);
      spacedVideo = '${spacedDir.path}\\clip.avi';

      await File(pngPath).writeAsBytes(encodePng(320, 240, noisyRgb(320, 240)));
      final jpeg = await rootBundle.load(
        'integration_test/fixtures/sample.jpg',
      );
      await File(jpegPath).writeAsBytes(
        jpeg.buffer.asUint8List(jpeg.offsetInBytes, jpeg.lengthInBytes),
      );
      await writeAvi(shortVideo, width: 64, height: 64, fps: 30, frames: 30);
      await writeAvi(
        audioVideo,
        width: 96,
        height: 64,
        fps: 30,
        frames: 30,
        audio: true,
      );
      await writeAvi(oddVideo, width: 129, height: 81, fps: 15, frames: 15);
      await File(shortVideo).copy(spacedVideo);
    });

    tearDownAll(() async {
      final temp = tempDir;
      if (temp != null && temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    driverTest('image and video capabilities match installed codecs', () async {
      final images = await XueHuaMediaCompression.image.queryCapabilities();
      expect(images.inputFormats, contains(ImageFormat.jpeg));
      expect(images.inputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, contains(ImageFormat.jpeg));
      expect(images.outputFormats, contains(ImageFormat.png));
      expect(images.outputFormats, isNot(contains(ImageFormat.gif)));
      expect(images.outputFormats, isNot(contains(ImageFormat.avif)));
      if (images.outputFormats.contains(ImageFormat.webp)) {
        expect(images.inputFormats, contains(ImageFormat.webp));
      }

      final video = await XueHuaMediaCompression.video.queryCapabilities();
      expect(video.acceptsContentUri, isFalse);
      expect(
        video.codecs,
        contains(VideoCodec.h264),
        reason: 'Media Foundation H.264 encoder is not installed',
      );
      if (video.encoderName != null) {
        expect(video.encoderName, 'MediaFoundationHW');
      }
      final label = video.encoderName ?? '';
      expect(label.toLowerCase(), isNot(contains('ffmpeg')));
      expect(label.toLowerCase(), isNot(contains('libav')));
    });

    driverTest('image compress from path and bytes, with progress', () async {
      final output = '${temp.path}\\out.jpg';
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
      final jpegOut = '${temp.path}\\from_png.jpg';
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
      _expectPrefix(webpResult.bytes!, const <int>[0x52, 0x49, 0x46, 0x46]);
    });

    driverTest(
      'image maxDimension downscales and creates parent directories',
      () async {
        final output = '${temp.path}\\nested\\deeper\\scaled.jpg';
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
      'gif input decodes and gif/avif output is unsupported',
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
        if (!caps.outputFormats.contains(ImageFormat.heic)) {
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
      'missing, corrupt, directory, and content URI images fail cleanly',
      () async {
        final missing = XueHuaMediaCompression.image.compress(
          source: MediaSource.path('${temp.path}\\no-such-image.jpg'),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(missing, MediaCompressionException.notFound);

        final corruptPath = '${temp.path}\\corrupt.jpg';
        await File(corruptPath).writeAsString('this is not a jpeg');
        final corrupt = XueHuaMediaCompression.image.compress(
          source: MediaSource.path(corruptPath),
          destination: MediaDestination.bytes(),
        );
        await _expectCode(corrupt, MediaCompressionException.decode);

        final directory = Directory('${temp.path}\\not-a-file')
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
      final big = '${temp.path}\\big.png';
      await File(big).writeAsBytes(encodePng(2400, 1600, noisyRgb(2400, 1600)));
      final output = '${temp.path}\\cancelled-image.jpg';
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
        final output = '${temp.path}\\h264.mp4';
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
        expect(result.encoderName.toLowerCase(), isNot(contains('ffmpeg')));
        expect(result.encoderName.toLowerCase(), isNot(contains('libav')));
        expect(result.encoderName, startsWith('MediaFoundation'));
        expect(await File(output).length(), result.sizeBytes);
        final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
        expect(mp4.hasVideo, isTrue);
        expect(mp4.hasAudio, isFalse);
        expect(mp4.width, result.width);
        expect(mp4.height, result.height);
        expect(mp4.containsTag('avc1'), isTrue);
      },
    );

    driverTest(
      'video H.265 compresses when an encoder is advertised',
      () async {
        final caps = await XueHuaMediaCompression.video.queryCapabilities();
        if (!caps.codecs.contains(VideoCodec.h265)) {
          return;
        }
        final output = '${temp.path}\\h265.mp4';
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
        expect(result.encoderName, startsWith('MediaFoundation'));
        final mp4 = Mp4Probe.parse(await File(output).readAsBytes());
        expect(mp4.hasVideo, isTrue);
        expect(mp4.hasAudio, isFalse);
        expect(mp4.containsTag('hvc1') || mp4.containsTag('hev1'), isTrue);
      },
    );

    driverTest('keepAudio keeps an AAC track and false strips it', () async {
      final keptPath = '${temp.path}\\audio-kept.mp4';
      final kept = XueHuaMediaCompression.video.compress(
        inputPath: audioVideo,
        outputPath: keptPath,
        options: const VideoCompressOptions(bitrate: 500000, keepAudio: true),
      );
      try {
        final keptResult = await kept.result;
        expect(keptResult.width, 96);
        expect(keptResult.height, 64);
        final keptMp4 = Mp4Probe.parse(await File(keptPath).readAsBytes());
        expect(keptMp4.hasVideo, isTrue);
        expect(keptMp4.hasAudio, isTrue);
        expect(keptMp4.containsTag('mp4a'), isTrue);
      } on MediaCompressionException catch (error) {
        expect(error.code, MediaCompressionException.unsupported);
      } finally {
        await kept.dispose();
      }

      final droppedPath = '${temp.path}\\audio-dropped.mp4';
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
      final scaled = '${temp.path}\\scaled.mp4';
      final scaleSession = XueHuaMediaCompression.video.compress(
        inputPath: oddVideo,
        outputPath: scaled,
        options: const VideoCompressOptions(
          bitrate: 400000,
          maxDimension: 110,
          keepAudio: false,
        ),
      );
      final scale = await _resultOf(scaleSession);
      expect(scale.width, 110);
      expect(scale.height, 68);
      expect(scale.width.isEven, isTrue);
      expect(scale.height.isEven, isTrue);
      expect(scale.width, greaterThan(0));
      expect(scale.height, greaterThan(0));
      final mp4 = Mp4Probe.parse(await File(scaled).readAsBytes());
      expect(mp4.width, scale.width);
      expect(mp4.height, scale.height);

      final rated = '${temp.path}\\fps.mp4';
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
      final plain = '${temp.path}\\odd-plain.mp4';
      final plainSession = XueHuaMediaCompression.video.compress(
        inputPath: oddVideo,
        outputPath: plain,
        options: const VideoCompressOptions(bitrate: 400000, keepAudio: false),
      );
      final plainResult = await _resultOf(plainSession);
      expect(plainResult.width, 128);
      expect(plainResult.height, 80);
      expect(plainResult.width.isEven, isTrue);
      expect(plainResult.height.isEven, isTrue);

      final output = '${temp.path}\\new parent\\clip out.mp4';
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
        final missingOut = '${temp.path}\\missing-out.mp4';
        final missing = XueHuaMediaCompression.video.compress(
          inputPath: '${temp.path}\\missing-video.mp4',
          outputPath: missingOut,
        );
        await _expectCode(missing, MediaCompressionException.notFound);
        expect(File(missingOut).existsSync(), isFalse);

        final corruptPath = '${temp.path}\\corrupt.mp4';
        await File(corruptPath).writeAsString('not a video');
        final corruptOut = '${temp.path}\\corrupt-out.mp4';
        final corrupt = XueHuaMediaCompression.video.compress(
          inputPath: corruptPath,
          outputPath: corruptOut,
        );
        await _expectCode(corrupt, MediaCompressionException.decode);
        expect(File(corruptOut).existsSync(), isFalse);

        final content = XueHuaMediaCompression.video.compress(
          inputPath: 'content://media/external/video/1',
          outputPath: '${temp.path}\\content-out.mp4',
        );
        await _expectCode(content, MediaCompressionException.unsupported);

        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: '  ',
            outputPath: '${temp.path}\\empty.mp4',
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: '${temp.path}\\bad.mp4',
            options: const VideoCompressOptions(bitrate: 0),
          ),
          throwsArgumentError,
        );
        expect(
          () => XueHuaMediaCompression.video.compress(
            inputPath: shortVideo,
            outputPath: '${temp.path}\\bad-fps.mp4',
            options: const VideoCompressOptions(fps: 0),
          ),
          throwsArgumentError,
        );
      },
    );

    driverTest(
      'long video reports mid-progress and cancel removes the output',
      () async {
        final input = '${temp.path}\\long.avi';
        await writeAvi(input, width: 640, height: 360, fps: 20, frames: 60);
        final output = '${temp.path}\\cancelled.mp4';
        final session = XueHuaMediaCompression.video.compress(
          inputPath: input,
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
        final input = '${temp.path}\\dispose-long.avi';
        if (!File(input).existsSync()) {
          await writeAvi(input, width: 640, height: 360, fps: 20, frames: 60);
        }
        final output = '${temp.path}\\dispose-race.mp4';
        final session = XueHuaMediaCompression.video.compress(
          inputPath: input,
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
      },
    );

    driverTest('dispose is idempotent and a second job still runs', () async {
      final output = '${temp.path}\\second.mp4';
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
      final library = await _findPluginDll();
      expect(library, isNotNull, reason: 'built plugin DLL was not found');
      final bytes = await library!.readAsBytes();
      final text = String.fromCharCodes(bytes).toLowerCase();
      for (final name in const <String>[
        'libavcodec',
        'libavformat',
        'libavutil',
        'libavfilter',
        'libavdevice',
        'libswscale',
        'libswresample',
        'libpostproc',
        'gst-libav',
        'avdec_',
        'avenc_',
        'ffmpeg',
      ]) {
        expect(
          text.contains(name),
          isFalse,
          reason: '${library.path} has $name',
        );
      }
      expect(text, contains('mediafoundation'));
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

Future<File?> _findPluginDll() async {
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
    final found = await _searchDll(root, 0);
    if (found != null) {
      return found;
    }
  }
  return null;
}

Future<File?> _searchDll(Directory dir, int depth) async {
  if (depth > 8) {
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
        entity.path.toLowerCase().endsWith(
          'xue_hua_media_compression_plugin.dll',
        )) {
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
    final found = await _searchDll(entity, depth + 1);
    if (found != null) {
      return found;
    }
  }
  return null;
}
