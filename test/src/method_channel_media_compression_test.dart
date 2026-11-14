import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression/src/messages.g.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression_method_channel.dart';

final class _FakeHostApi extends MediaCompressionHostApi {
  _FakeHostApi() : super();

  int nextId = 7;
  Object? startError;
  int createCount = 0;
  int cancelCount = 0;
  int disposeCount = 0;
  final List<int> started = <int>[];

  @override
  Future<int> createJob() async {
    createCount++;
    return nextId;
  }

  @override
  Future<ImageCapabilitiesMsg> queryImageCapabilities() async {
    return ImageCapabilitiesMsg(
      inputFormats: const ['jpeg', 'png'],
      outputFormats: const ['jpeg', 'png'],
    );
  }

  @override
  Future<void> startImageCompress(
    int id,
    SourceMsg source,
    DestinationMsg destination,
    ImageOptionsMsg options,
  ) async {
    if (startError != null) {
      throw startError!;
    }
    started.add(id);
  }

  @override
  Future<VideoCapabilitiesMsg> queryVideoCapabilities() async {
    return VideoCapabilitiesMsg(
      encoderName: 'Fake',
      codecs: const ['h264'],
      acceptsContentUri: true,
    );
  }

  @override
  Future<void> startVideoCompress(
    int id,
    String inputPath,
    String outputPath,
    VideoOptionsMsg options,
  ) async {
    if (startError != null) {
      throw startError!;
    }
    started.add(id);
  }

  @override
  Future<void> cancelJob(int id) async {
    cancelCount++;
  }

  @override
  Future<void> disposeJob(int id) async {
    disposeCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHostApi api;
  late Map<String, MediaCompressionFlutterApi> flutterApis;
  late MethodChannelMediaCompression platform;

  setUp(() {
    api = _FakeHostApi();
    flutterApis = <String, MediaCompressionFlutterApi>{};
    platform = MethodChannelMediaCompression(
      api: api,
      registerFlutterApi: (MediaCompressionFlutterApi handler, String suffix) {
        flutterApis[suffix] = handler;
      },
      unregisterFlutterApi:
          (MediaCompressionFlutterApi handler, String suffix) {
            if (identical(flutterApis[suffix], handler)) {
              flutterApis.remove(suffix);
            }
          },
    );
  });

  test('queryImageCapabilities maps wire names', () async {
    final caps = await platform.queryImageCapabilities();
    expect(caps.outputFormats, contains(ImageFormat.jpeg));
    expect(caps.outputFormats, contains(ImageFormat.png));
  });

  test('queryVideoCapabilities maps codecs and content uri flag', () async {
    final caps = await platform.queryVideoCapabilities();
    expect(caps.encoderName, 'Fake');
    expect(caps.codecs, contains(VideoCodec.h264));
    expect(caps.acceptsContentUri, isTrue);
  });

  test('compressImage starts a job and completes from FlutterApi', () async {
    final session = platform.compressImage(
      source: MediaSource.bytes(Uint8List.fromList(const [9, 9, 9])),
      destination: MediaDestination.bytes(),
      options: const ImageCompressOptions(),
    );
    final progresses = <double>[];
    final sub = session.progress.listen(progresses.add);

    await Future<void>.delayed(Duration.zero);
    final handler = flutterApis['job_7'];
    expect(handler, isNotNull);
    await handler!.onProgress(0.5);
    await handler.onImageCompleted(
      ImageCompressResultMsg(
        bytes: Uint8List.fromList(const [1, 2, 3]),
        sizeBytes: 3,
        format: 'jpeg',
        width: 10,
        height: 8,
      ),
    );

    final result = await session.result;
    expect(result.sizeBytes, 3);
    expect(result.width, 10);
    expect(api.started, [7]);
    expect(progresses, contains(0.5));
    await sub.cancel();
    await session.dispose();
    expect(api.disposeCount, 1);
    expect(flutterApis.containsKey('job_7'), isFalse);
  });

  test('compressVideo completes from FlutterApi', () async {
    final session = platform.compressVideo(
      inputPath: '/tmp/in.mp4',
      outputPath: '/tmp/out.mp4',
      options: const VideoCompressOptions(codec: VideoCodec.h265),
    );
    await Future<void>.delayed(Duration.zero);
    final handler = flutterApis['job_7'];
    expect(handler, isNotNull);
    await handler!.onProgress(0.6);
    await handler.onVideoCompleted(
      VideoCompressResultMsg(
        outputPath: '/tmp/out.mp4',
        sizeBytes: 1024,
        encoderName: 'FakeEncoder',
        codec: 'h265',
        width: 1280,
        height: 720,
      ),
    );

    final result = await session.result;
    expect(result.outputPath, '/tmp/out.mp4');
    expect(result.sizeBytes, 1024);
    expect(result.encoderName, 'FakeEncoder');
    expect(result.codec, VideoCodec.h265);
    expect(result.width, 1280);
    expect(result.height, 720);
    await session.dispose();
    expect(api.disposeCount, 1);
    expect(flutterApis.containsKey('job_7'), isFalse);
  });

  test('late progress listener receives the latest value', () async {
    final session = platform.compressImage(
      source: MediaSource.bytes(Uint8List.fromList(const [4])),
      destination: MediaDestination.bytes(),
      options: const ImageCompressOptions(),
    );
    await Future<void>.delayed(Duration.zero);
    final handler = flutterApis['job_7']!;
    await handler.onProgress(0.25);
    await handler.onProgress(0.5);
    await handler.onImageCompleted(
      ImageCompressResultMsg(
        bytes: Uint8List.fromList(const [1]),
        sizeBytes: 1,
        format: 'jpeg',
        width: 2,
        height: 2,
      ),
    );

    await session.result;
    final progresses = <double>[];
    final sub = session.progress.listen(progresses.add);
    await Future<void>.delayed(Duration.zero);
    expect(progresses, [1.0]);
    await sub.cancel();
    await session.dispose();
    expect(api.disposeCount, 1);
    expect(flutterApis.containsKey('job_7'), isFalse);
  });

  test('pigeon start error becomes MediaCompressionException', () async {
    api.startError = PlatformException(
      code: MediaCompressionException.unsupported,
      message: 'no webp',
    );
    final session = platform.compressImage(
      source: MediaSource.bytes(Uint8List.fromList(const [1])),
      destination: MediaDestination.bytes(),
      options: const ImageCompressOptions(format: ImageFormat.webp),
    );
    await expectLater(
      session.result,
      throwsA(
        isA<MediaCompressionException>().having(
          (MediaCompressionException e) => e.code,
          'code',
          MediaCompressionException.unsupported,
        ),
      ),
    );
    expect(flutterApis.containsKey('job_7'), isFalse);
  });

  test(
    'flutterApi onError fails session with MediaCompressionException',
    () async {
      final session = platform.compressImage(
        source: MediaSource.bytes(Uint8List.fromList(const [1])),
        destination: MediaDestination.bytes(),
        options: const ImageCompressOptions(),
      );
      final expectation = expectLater(
        session.result,
        throwsA(
          isA<MediaCompressionException>()
              .having(
                (MediaCompressionException e) => e.code,
                'code',
                MediaCompressionException.decode,
              )
              .having(
                (MediaCompressionException e) => e.message,
                'message',
                'corrupt payload',
              ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await flutterApis['job_7']!.onError(
        MediaCompressionException.decode,
        'corrupt payload',
      );
      await expectation;
      await session.dispose();
    },
  );
}
