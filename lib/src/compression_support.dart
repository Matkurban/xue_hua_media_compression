import 'package:flutter/services.dart';

import 'image_format.dart';
import 'media_compression_exception.dart';
import 'media_destination.dart';
import 'media_source.dart';
import 'messages.g.dart';
import 'options.dart';
import 'results.dart';
import 'video_codec.dart';

/// 校验图片参数；非法时抛 [ArgumentError]。
///
/// Validates image arguments; throws [ArgumentError] when invalid.
void validateImageArgs({
  required MediaSource source,
  required MediaDestination destination,
  required ImageCompressOptions options,
}) {
  if (options.quality < 1 || options.quality > 100) {
    throw ArgumentError.value(
      options.quality,
      'options.quality',
      'must be in 1–100',
    );
  }
  final maxDimension = options.maxDimension;
  if (maxDimension != null && maxDimension <= 0) {
    throw ArgumentError.value(
      maxDimension,
      'options.maxDimension',
      'must be > 0',
    );
  }
  switch (source) {
    case MediaSourceBytes(:final bytes):
      if (bytes.isEmpty) {
        throw ArgumentError.value(bytes, 'source.bytes', 'must not be empty');
      }
    case MediaSourcePath(:final path):
      if (path.trim().isEmpty) {
        throw ArgumentError.value(path, 'source.path', 'must not be empty');
      }
  }
  switch (destination) {
    case MediaDestinationBytes():
      break;
    case MediaDestinationPath(:final path):
      if (path.trim().isEmpty) {
        throw ArgumentError.value(
          path,
          'destination.path',
          'must not be empty',
        );
      }
  }
}

/// 校验视频参数；非法时抛 [ArgumentError]。
///
/// Validates video arguments; throws [ArgumentError] when invalid.
void validateVideoArgs({
  required String inputPath,
  required String outputPath,
  required VideoCompressOptions options,
}) {
  if (inputPath.trim().isEmpty) {
    throw ArgumentError.value(inputPath, 'inputPath', 'must not be empty');
  }
  if (outputPath.trim().isEmpty) {
    throw ArgumentError.value(outputPath, 'outputPath', 'must not be empty');
  }
  if (options.bitrate <= 0) {
    throw ArgumentError.value(
      options.bitrate,
      'options.bitrate',
      'must be > 0',
    );
  }
  final fps = options.fps;
  if (fps != null && fps <= 0) {
    throw ArgumentError.value(fps, 'options.fps', 'must be > 0');
  }
  final maxDimension = options.maxDimension;
  if (maxDimension != null && maxDimension <= 0) {
    throw ArgumentError.value(
      maxDimension,
      'options.maxDimension',
      'must be > 0',
    );
  }
  final keyframeInterval = options.keyframeInterval;
  if (keyframeInterval != null && keyframeInterval <= 0) {
    throw ArgumentError.value(
      keyframeInterval,
      'options.keyframeInterval',
      'must be > 0',
    );
  }
}

/// 将 [PlatformException] 译为 [MediaCompressionException]。
///
/// Translates a [PlatformException] into [MediaCompressionException].
MediaCompressionException exceptionFromPlatform(Object error) {
  if (error is MediaCompressionException) {
    return error;
  }
  if (error is PlatformException) {
    return MediaCompressionException(
      error.code,
      error.message ?? error.code,
      details: error.details?.toString(),
    );
  }
  return MediaCompressionException(
    MediaCompressionException.encode,
    error.toString(),
  );
}

/// 从 Pigeon FlutterApi 图片完成消息解析图片结果。
///
/// Parses an image result from a Pigeon FlutterApi completion message.
ImageCompressResult imageResultFromMsg(ImageCompressResultMsg msg) {
  final format = ImageFormatWire.tryParse(msg.format) ?? ImageFormat.jpeg;
  return ImageCompressResult(
    bytes: msg.bytes,
    outputPath: msg.outputPath,
    sizeBytes: msg.sizeBytes,
    format: format,
    width: msg.width,
    height: msg.height,
  );
}

/// 从 Pigeon FlutterApi 视频完成消息解析视频结果。
///
/// Parses a video result from a Pigeon FlutterApi completion message.
VideoCompressResult videoResultFromMsg(VideoCompressResultMsg msg) {
  final codec = VideoCodecWire.tryParse(msg.codec) ?? VideoCodec.h264;
  return VideoCompressResult(
    outputPath: msg.outputPath,
    sizeBytes: msg.sizeBytes,
    encoderName: msg.encoderName,
    codec: codec,
    width: msg.width,
    height: msg.height,
  );
}

/// 把线格式名列表译成枚举集合。
///
/// Parses a list of wire format names into an enum set.
Set<ImageFormat> imageFormatsFromWire(List<Object?> names) {
  return {
    for (final name in names)
      if (name is String) ImageFormatWire.tryParse(name),
  }.whereType<ImageFormat>().toSet();
}

/// 把线编码名列表译成枚举集合。
///
/// Parses a list of wire codec names into an enum set.
Set<VideoCodec> videoCodecsFromWire(List<Object?> names) {
  return {
    for (final name in names)
      if (name is String) VideoCodecWire.tryParse(name),
  }.whereType<VideoCodec>().toSet();
}
