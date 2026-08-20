import 'dart:async';

import 'package:flutter/services.dart';

import 'capabilities.dart';
import 'compression_session.dart';
import 'image_format.dart';
import 'media_compression_exception.dart';
import 'media_compression_platform.dart';
import 'media_destination.dart';
import 'media_source.dart';
import 'messages.g.dart';
import 'options.dart';
import 'path_utils.dart';
import 'results.dart';
import 'video_codec.dart';

/// 默认 Pigeon 客户端。五端原生共用。
///
/// Default Pigeon client shared by the five native platforms.
final class MethodChannelMediaCompression extends MediaCompressionPlatform {
  /// 使用可选的 HostApi（测试可注入）。
  ///
  /// Optional HostApi for tests.
  MethodChannelMediaCompression({MediaCompressionHostApi? api})
    : _api = api ?? MediaCompressionHostApi();

  final MediaCompressionHostApi _api;

  /// 测试或自定义 EventChannel 工厂。
  ///
  /// Factory for EventChannels, overridable in tests.
  EventChannel Function(int id) eventChannelFor = (int id) {
    return EventChannel('$jobEventChannelPrefix$id');
  };

  @override
  Future<ImageCompressionCapabilities> queryImageCapabilities() async {
    try {
      final msg = await _api.queryImageCapabilities();
      return ImageCompressionCapabilities(
        inputFormats: imageFormatsFromWire(msg.inputFormats),
        outputFormats: imageFormatsFromWire(msg.outputFormats),
      );
    } catch (error) {
      throw exceptionFromPlatform(error);
    }
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
    return _PigeonCompressionSession<ImageCompressResult>(
      api: _api,
      eventChannelFor: eventChannelFor,
      start: (int id) {
        return _api.startImageCompress(
          id,
          _encodeSource(source),
          _encodeDestination(destination),
          ImageOptionsMsg(
            format: options.format.wireName,
            quality: options.quality,
            maxDimension: options.maxDimension,
            keepMetadata: options.keepMetadata,
          ),
        );
      },
      parseResult: imageResultFromMap,
    );
  }

  @override
  Future<VideoCompressionCapabilities> queryVideoCapabilities() async {
    try {
      final msg = await _api.queryVideoCapabilities();
      return VideoCompressionCapabilities(
        encoderName: msg.encoderName,
        codecs: videoCodecsFromWire(msg.codecs),
        acceptsContentUri: msg.acceptsContentUri,
      );
    } catch (error) {
      throw exceptionFromPlatform(error);
    }
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
    final normalizedInput = normalizeInputPath(inputPath);
    final normalizedOutput = normalizeInputPath(outputPath);
    return _PigeonCompressionSession<VideoCompressResult>(
      api: _api,
      eventChannelFor: eventChannelFor,
      start: (int id) {
        return _api.startVideoCompress(
          id,
          normalizedInput,
          normalizedOutput,
          VideoOptionsMsg(
            codec: options.codec.wireName,
            bitrate: options.bitrate,
            fps: options.fps,
            maxDimension: options.maxDimension,
            keyframeInterval: options.keyframeInterval,
            keepAudio: options.keepAudio,
          ),
        );
      },
      parseResult: videoResultFromMap,
    );
  }

  SourceMsg _encodeSource(MediaSource source) {
    return switch (source) {
      MediaSourceBytes(:final bytes) => SourceMsg(kind: 0, bytes: bytes),
      MediaSourcePath(:final path) => SourceMsg(
        kind: 1,
        path: normalizeInputPath(path),
      ),
    };
  }

  DestinationMsg _encodeDestination(MediaDestination destination) {
    return switch (destination) {
      MediaDestinationBytes() => DestinationMsg(kind: 0),
      MediaDestinationPath(:final path) => DestinationMsg(
        kind: 1,
        path: normalizeInputPath(path),
      ),
    };
  }
}

final class _PigeonCompressionSession<TResult>
    implements CompressionSession<TResult> {
  _PigeonCompressionSession({
    required this._api,
    required EventChannel Function(int id) eventChannelFor,
    required Future<void> Function(int id) start,
    required this._parseResult,
  }) {
    _idFuture = _start(eventChannelFor, start);
  }

  final MediaCompressionHostApi _api;
  final TResult Function(Map<Object?, Object?>) _parseResult;
  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final Completer<TResult> _resultCompleter = Completer<TResult>();

  late final Future<int> _idFuture;
  StreamSubscription<dynamic>? _eventSub;
  bool _disposed = false;
  int? _id;

  @override
  Stream<double> get progress => _progressController.stream;

  @override
  Future<TResult> get result => _resultCompleter.future;

  Future<int> _start(
    EventChannel Function(int id) eventChannelFor,
    Future<void> Function(int id) start,
  ) async {
    try {
      final id = await _api.createJob();
      _id = id;
      _eventSub = eventChannelFor(id).receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error, StackTrace stackTrace) {
          _fail(exceptionFromPlatform(error));
        },
      );
      await start(id);
      return id;
    } catch (error) {
      _fail(exceptionFromPlatform(error));
      return _id ?? -1;
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final map = Map<Object?, Object?>.from(event);
    final type = map['type'] as String?;
    switch (type) {
      case 'progress':
        final value = (map['value'] as num?)?.toDouble();
        if (value != null && !_progressController.isClosed) {
          _progressController.add(value.clamp(0.0, 1.0));
        }
      case 'completed':
        final payload = map['result'];
        if (payload is Map) {
          _succeed(_parseResult(Map<Object?, Object?>.from(payload)));
        } else {
          _fail(
            const MediaCompressionException(
              MediaCompressionException.encode,
              'Missing completion payload',
            ),
          );
        }
      case 'error':
        _fail(
          MediaCompressionException(
            map['code'] as String? ?? MediaCompressionException.encode,
            map['message'] as String? ?? 'Native error',
            details: map['details'] as String?,
          ),
        );
    }
  }

  void _succeed(TResult value) {
    if (!_resultCompleter.isCompleted) {
      _resultCompleter.complete(value);
    }
    if (!_progressController.isClosed) {
      _progressController.add(1.0);
      unawaited(_progressController.close());
    }
  }

  void _fail(MediaCompressionException error) {
    if (!_resultCompleter.isCompleted) {
      _resultCompleter.completeError(error);
    }
    if (!_progressController.isClosed) {
      unawaited(_progressController.close());
    }
  }

  @override
  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    try {
      final id = await _idFuture;
      await _api.cancelJob(id);
    } on MediaCompressionException catch (error) {
      if (error.code == MediaCompressionException.instanceNotFound) {
        return;
      }
      rethrow;
    } catch (error) {
      final translated = exceptionFromPlatform(error);
      if (translated.code == MediaCompressionException.instanceNotFound) {
        return;
      }
      // Native may complete the job via the event stream with `cancelled`.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    if (!_progressController.isClosed) {
      await _progressController.close();
    }
    final id = _id;
    if (id == null) {
      return;
    }
    try {
      await _api.disposeJob(id);
    } catch (_) {
      // Dispose is idempotent; swallow native errors after teardown.
    }
  }
}
