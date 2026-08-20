import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression_platform_interface/src/messages.g.dart';
import 'package:xue_hua_media_compression_platform_interface/xue_hua_media_compression_platform_interface.dart';

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
  late MethodChannelMediaCompression platform;

  setUp(() {
    api = _FakeHostApi();
    platform = MethodChannelMediaCompression(api: api);
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

  test('compressImage starts a job and completes from EventChannel', () async {
    platform.eventChannelFor = (int id) {
      return EventChannel('test/job_events_$id');
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          EventChannel('test/job_events_7'),
          MockStreamHandler.inline(
            onListen: (Object? arguments, MockStreamHandlerEventSink sink) {
              sink.success(<String, Object?>{'type': 'progress', 'value': 0.5});
              sink.success(<String, Object?>{
                'type': 'completed',
                'result': <String, Object?>{
                  'bytes': Uint8List.fromList(const [1, 2, 3]),
                  'sizeBytes': 3,
                  'format': 'jpeg',
                  'width': 10,
                  'height': 8,
                },
              });
            },
          ),
        );

    final session = platform.compressImage(
      source: MediaSource.bytes(Uint8List.fromList(const [9, 9, 9])),
      destination: MediaDestination.bytes(),
      options: const ImageCompressOptions(),
    );
    final progresses = <double>[];
    final sub = session.progress.listen(progresses.add);
    final result = await session.result;
    expect(result.sizeBytes, 3);
    expect(result.width, 10);
    expect(api.started, [7]);
    expect(progresses, contains(0.5));
    await sub.cancel();
    await session.dispose();
    expect(api.disposeCount, 1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('test/job_events_7'), null);
  });

  test('pigeon start error becomes MediaCompressionException', () async {
    api.startError = PlatformException(
      code: MediaCompressionException.unsupported,
      message: 'no webp',
    );
    platform.eventChannelFor = (int id) => EventChannel('test/job_events_$id');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('test/job_events_7'),
          MockStreamHandler.inline(
            onListen: (Object? arguments, MockStreamHandlerEventSink sink) {},
          ),
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
  });
}
