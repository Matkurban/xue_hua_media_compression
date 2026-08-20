import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';
import 'package:xue_hua_media_compression_platform_interface/xue_hua_media_compression_platform_interface.dart';

final class _FakePlatform extends MediaCompressionPlatform
    with MockPlatformInterfaceMixin {
  int queryCount = 0;

  @override
  Future<ImageCompressionCapabilities> queryImageCapabilities() async {
    queryCount++;
    return const ImageCompressionCapabilities(
      inputFormats: {ImageFormat.jpeg},
      outputFormats: {ImageFormat.jpeg, ImageFormat.png},
    );
  }

  @override
  CompressionSession<ImageCompressResult> compressImage({
    required MediaSource source,
    required MediaDestination destination,
    required ImageCompressOptions options,
  }) {
    validateImageArgs(
      source: source,
      destination: destination,
      options: options,
    );
    return _ImmediateSession<ImageCompressResult>(
      ImageCompressResult(
        bytes: Uint8List.fromList(const [1]),
        sizeBytes: 1,
        format: options.format,
        width: 8,
        height: 8,
      ),
    );
  }

  @override
  Future<VideoCompressionCapabilities> queryVideoCapabilities() async {
    return const VideoCompressionCapabilities(
      encoderName: 'Fake',
      codecs: {VideoCodec.h264},
      acceptsContentUri: false,
    );
  }

  @override
  CompressionSession<VideoCompressResult> compressVideo({
    required String inputPath,
    required String outputPath,
    required VideoCompressOptions options,
  }) {
    validateVideoArgs(
      inputPath: inputPath,
      outputPath: outputPath,
      options: options,
    );
    return _ImmediateSession<VideoCompressResult>(
      VideoCompressResult(
        outputPath: outputPath,
        sizeBytes: 10,
        encoderName: 'Fake',
        codec: options.codec,
        width: 16,
        height: 16,
      ),
    );
  }
}

final class _ImmediateSession<T> implements CompressionSession<T> {
  _ImmediateSession(this._value);

  final T _value;

  @override
  Stream<double> get progress => Stream<double>.value(1.0);

  @override
  Future<T> get result async => _value;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform fake;
  late MediaCompressionPlatform previous;

  setUp(() {
    previous = MediaCompressionPlatform.instance;
    fake = _FakePlatform();
    MediaCompressionPlatform.instance = fake;
  });

  tearDown(() {
    MediaCompressionPlatform.instance = previous;
  });

  test('image.queryCapabilities forwards to the platform', () async {
    final caps = await XueHuaMediaCompression.image.queryCapabilities();
    expect(caps.outputFormats, contains(ImageFormat.jpeg));
    expect(fake.queryCount, 1);
  });

  test('image.compress returns a session that completes', () async {
    final session = XueHuaMediaCompression.image.compress(
      source: MediaSource.bytes(Uint8List.fromList(const [1, 2, 3])),
      destination: MediaDestination.bytes(),
    );
    final result = await session.result;
    expect(result.format, ImageFormat.jpeg);
    expect(result.sizeBytes, 1);
  });

  test('video.compress ArgumentError on empty path', () {
    expect(
      () => XueHuaMediaCompression.video.compress(
        inputPath: '',
        outputPath: '/tmp/out.mp4',
      ),
      throwsArgumentError,
    );
  });
}
