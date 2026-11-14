import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'src/capabilities.dart';
import 'src/compression_session.dart';
import 'src/compression_support.dart';
import 'src/image_format.dart';
import 'src/media_compression_exception.dart';
import 'src/media_destination.dart';
import 'src/media_source.dart';
import 'src/messages.g.dart';
import 'src/options.dart';
import 'src/path_utils.dart';
import 'src/results.dart';
import 'src/video_codec.dart';
import 'xue_hua_media_compression_platform_interface.dart';

/// 注册和注销按 job 隔离的 [MediaCompressionFlutterApi] 回调的签名。
///
/// Callback registration signature for per-job [MediaCompressionFlutterApi].
typedef FlutterApiRegister =
    void Function(MediaCompressionFlutterApi api, String suffix);

/// 注销按 job 隔离的 [MediaCompressionFlutterApi] 回调的签名。
///
/// Callback unregistration signature for per-job [MediaCompressionFlutterApi].
typedef FlutterApiUnregister =
    void Function(MediaCompressionFlutterApi api, String suffix);

/// 默认 Pigeon 客户端。五端原生共用：Android / iOS / macOS 走 Native Interop，
/// Windows / Linux 走 Pigeon Platform Channel。
///
/// Default Pigeon client shared by the five native platforms: Native Interop on
/// Android / iOS / macOS, and Platform Channels on Windows / Linux.
final class MethodChannelMediaCompression extends MediaCompressionPlatform {
  /// 使用可选的 HostApi 与 FlutterApi 注册钩子（测试可注入）。
  ///
  /// Optional HostApi and FlutterApi registration hooks for tests.
  MethodChannelMediaCompression({
    MediaCompressionHostApi? api,
    @visibleForTesting FlutterApiRegister? registerFlutterApi,
    @visibleForTesting FlutterApiUnregister? unregisterFlutterApi,
  }) : _apiOverride = api,
       _registerFlutterApi =
           registerFlutterApi ??
           (api != null ? _noopFlutterApiRegister : _defaultFlutterApiRegister),
       _unregisterFlutterApi =
           unregisterFlutterApi ??
           (api != null
               ? _noopFlutterApiUnregister
               : _defaultFlutterApiUnregister);

  final MediaCompressionHostApi? _apiOverride;
  final FlutterApiRegister _registerFlutterApi;
  final FlutterApiUnregister _unregisterFlutterApi;

  late final MediaCompressionHostApi _api = _resolveHostApi();

  static bool get _usesNativeInterop =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  MediaCompressionHostApi _resolveHostApi() {
    final override = _apiOverride;
    if (override != null) {
      return override;
    }
    if (_usesNativeInterop) {
      return MediaCompressionHostApi.createWithNativeInteropApi();
    }
    return MediaCompressionHostApi();
  }

  static void _defaultFlutterApiRegister(
    MediaCompressionFlutterApi api,
    String suffix,
  ) {
    if (_usesNativeInterop) {
      // Use the Native Interop registrar directly so background isolates
      // without an initialized ServicesBinding can receive @FlutterApi calls.
      MediaCompressionFlutterApiRegistrar().register(api, name: suffix);
      return;
    }
    MediaCompressionFlutterApi.setUp(api, messageChannelSuffix: suffix);
  }

  static void _defaultFlutterApiUnregister(
    MediaCompressionFlutterApi api,
    String suffix,
  ) {
    if (_usesNativeInterop) {
      MediaCompressionFlutterApiRegistrar().unregister(api, name: suffix);
      return;
    }
    MediaCompressionFlutterApi.setUp(null, messageChannelSuffix: suffix);
  }

  static void _noopFlutterApiRegister(
    MediaCompressionFlutterApi api,
    String suffix,
  ) {}

  static void _noopFlutterApiUnregister(
    MediaCompressionFlutterApi api,
    String suffix,
  ) {}

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
      registerFlutterApi: _registerFlutterApi,
      unregisterFlutterApi: _unregisterFlutterApi,
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
      parseImageResult: imageResultFromMsg,
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
      registerFlutterApi: _registerFlutterApi,
      unregisterFlutterApi: _unregisterFlutterApi,
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
      parseVideoResult: videoResultFromMsg,
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
    implements CompressionSession<TResult>, MediaCompressionFlutterApi {
  _PigeonCompressionSession({
    required this._api,
    required this._registerFlutterApi,
    required this._unregisterFlutterApi,
    required Future<void> Function(int id) start,
    this._parseImageResult,
    this._parseVideoResult,
  }) {
    _idFuture = _start(start);
  }

  final MediaCompressionHostApi _api;
  final FlutterApiRegister _registerFlutterApi;
  final FlutterApiUnregister _unregisterFlutterApi;
  final TResult Function(ImageCompressResultMsg)? _parseImageResult;
  final TResult Function(VideoCompressResultMsg)? _parseVideoResult;
  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final Completer<TResult> _resultCompleter = Completer<TResult>();
  double? _latestProgress;

  late final Future<int> _idFuture;
  bool _disposed = false;
  int? _id;
  String? _registeredSuffix;

  @override
  Stream<double> get progress {
    return Stream<double>.multi((MultiStreamController<double> controller) {
      final latest = _latestProgress;
      if (latest != null) {
        controller.add(latest);
      }
      final subscription = _progressController.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = () {
        subscription.cancel();
      };
    });
  }

  void _emitProgress(double value) {
    final clamped = value.clamp(0.0, 1.0);
    _latestProgress = clamped;
    if (!_progressController.isClosed) {
      _progressController.add(clamped);
    }
  }

  @override
  Future<TResult> get result => _resultCompleter.future;

  Future<int> _start(Future<void> Function(int id) start) async {
    try {
      final id = await _api.createJob();
      _id = id;
      if (_disposed) {
        unawaited(_safeDisposeNative(id));
        return id;
      }
      final suffix = jobFlutterApiSuffix(id);
      _registerFlutterApi(this, suffix);
      _registeredSuffix = suffix;
      await start(id);
      return id;
    } catch (error) {
      _unregisterIfNeeded();
      _fail(exceptionFromPlatform(error));
      return _id ?? -1;
    }
  }

  @override
  Future<void> onProgress(double value) async {
    if (_disposed) {
      return;
    }
    _emitProgress(value);
  }

  @override
  Future<void> onImageCompleted(ImageCompressResultMsg result) async {
    if (_disposed) {
      return;
    }
    final parser = _parseImageResult;
    if (parser == null) {
      _fail(
        const MediaCompressionException(
          MediaCompressionException.encode,
          'Unexpected image completion for non-image job',
        ),
      );
      return;
    }
    _succeed(parser(result));
  }

  @override
  Future<void> onVideoCompleted(VideoCompressResultMsg result) async {
    if (_disposed) {
      return;
    }
    final parser = _parseVideoResult;
    if (parser == null) {
      _fail(
        const MediaCompressionException(
          MediaCompressionException.encode,
          'Unexpected video completion for non-video job',
        ),
      );
      return;
    }
    _succeed(parser(result));
  }

  @override
  Future<void> onError(String code, String message) async {
    if (_disposed) {
      return;
    }
    _fail(MediaCompressionException(code, message));
  }

  void _succeed(TResult value) {
    if (!_resultCompleter.isCompleted) {
      _resultCompleter.complete(value);
    }
    _emitProgress(1.0);
    if (!_progressController.isClosed) {
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

  void _unregisterIfNeeded() {
    final suffix = _registeredSuffix;
    if (suffix == null) {
      return;
    }
    _registeredSuffix = null;
    try {
      _unregisterFlutterApi(this, suffix);
    } catch (_) {
      // Unregister is idempotent during teardown.
    }
  }

  Future<void> _safeDisposeNative(int id) async {
    try {
      await _api.disposeJob(id);
    } catch (_) {
      // Dispose is idempotent; swallow native errors after teardown.
    }
  }

  @override
  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    try {
      final id = await _idFuture;
      if (id < 0 || _disposed) {
        return;
      }
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
      // Native may complete the job via FlutterApi with `cancelled`.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (!_progressController.isClosed) {
      await _progressController.close();
    }
    final id = _id;
    try {
      if (id != null && id >= 0) {
        await _safeDisposeNative(id);
      }
    } finally {
      _unregisterIfNeeded();
    }
  }
}
