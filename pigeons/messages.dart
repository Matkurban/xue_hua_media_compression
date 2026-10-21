import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/xuehua/xue_hua_media_compression/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.xuehua.xue_hua_media_compression',
    ),
    swiftOut:
        'darwin/xue_hua_media_compression/Sources/xue_hua_media_compression/Messages.g.swift',
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'xue_hua_media_compression'),
    gobjectHeaderOut: 'linux/messages.g.h',
    gobjectSourceOut: 'linux/messages.g.cc',
    gobjectOptions: GObjectOptions(module: 'XhMc'),
    dartPackageName: 'xue_hua_media_compression',
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
/// 输入位置：0 = 内存字节，1 = 路径 / URI。
///
/// Source kind: 0 = in-memory bytes, 1 = filesystem path / URI.
class SourceMsg {
  SourceMsg({required this.kind, this.bytes, this.path});

  int kind;
  Uint8List? bytes;
  String? path;
}

/// 输出位置：0 = 内存字节，1 = 文件路径。
///
/// Destination kind: 0 = in-memory bytes, 1 = filesystem path.
class DestinationMsg {
  DestinationMsg({required this.kind, this.path});

  int kind;
  String? path;
}

class ImageOptionsMsg {
  ImageOptionsMsg({
    required this.format,
    required this.quality,
    this.maxDimension,
    required this.keepMetadata,
  });

  String format;
  int quality;
  int? maxDimension;
  bool keepMetadata;
}

class VideoOptionsMsg {
  VideoOptionsMsg({
    required this.codec,
    required this.bitrate,
    this.fps,
    this.maxDimension,
    this.keyframeInterval,
    required this.keepAudio,
  });

  String codec;
  int bitrate;
  int? fps;
  int? maxDimension;
  int? keyframeInterval;
  bool keepAudio;
}

class ImageCapabilitiesMsg {
  ImageCapabilitiesMsg({
    required this.inputFormats,
    required this.outputFormats,
  });

  List<String> inputFormats;
  List<String> outputFormats;
}

class VideoCapabilitiesMsg {
  VideoCapabilitiesMsg({
    this.encoderName,
    required this.codecs,
    required this.acceptsContentUri,
  });

  String? encoderName;
  List<String> codecs;
  bool acceptsContentUri;
}

@HostApi()
abstract class MediaCompressionHostApi {
  int createJob();

  ImageCapabilitiesMsg queryImageCapabilities();

  @async
  void startImageCompress(
    int id,
    SourceMsg source,
    DestinationMsg destination,
    ImageOptionsMsg options,
  );

  VideoCapabilitiesMsg queryVideoCapabilities();

  @async
  void startVideoCompress(
    int id,
    String inputPath,
    String outputPath,
    VideoOptionsMsg options,
  );

  void cancelJob(int id);

  void disposeJob(int id);
}
