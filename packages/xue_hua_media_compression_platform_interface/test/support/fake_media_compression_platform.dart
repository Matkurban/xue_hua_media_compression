import 'dart:async';
import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_media_compression_platform_interface/xue_hua_media_compression_platform_interface.dart';

/// 测试替身：记录调用，并按原生 EventChannel 规则缓冲进度 / 终态。
final class FakeMediaCompressionPlatform extends MediaCompressionPlatform
    with MockPlatformInterfaceMixin {
  ImageCompressionCapabilities imageCapabilities =
      const ImageCompressionCapabilities(
        inputFormats: {ImageFormat.jpeg, ImageFormat.png},
        outputFormats: {ImageFormat.jpeg, ImageFormat.png},
      );

  VideoCompressionCapabilities videoCapabilities =
      const VideoCompressionCapabilities(
        encoderName: 'FakeEncoder',
        codecs: {VideoCodec.h264},
        acceptsContentUri: false,
      );

  Object? nextImageError;
  Object? nextVideoError;

  final List<String> calls = <String>[];
  final Map<int, FakeCompressionSession<dynamic>> sessions =
      <int, FakeCompressionSession<dynamic>>{};

  int _nextId = 1;

  @override
  Future<ImageCompressionCapabilities> queryImageCapabilities() async {
    calls.add('queryImageCapabilities');
    return imageCapabilities;
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
    calls.add('compressImage');
    final session = FakeCompressionSession<ImageCompressResult>(
      id: _nextId++,
      onCancel: (int id) => calls.add('cancel:$id'),
      onDispose: (int id) {
        calls.add('dispose:$id');
        sessions.remove(id);
      },
    );
    sessions[session.id] = session;
    final error = nextImageError;
    nextImageError = null;
    if (error != null) {
      session.emitError(_asException(error));
    }
    return session;
  }

  @override
  Future<VideoCompressionCapabilities> queryVideoCapabilities() async {
    calls.add('queryVideoCapabilities');
    return videoCapabilities;
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
    calls.add('compressVideo');
    final session = FakeCompressionSession<VideoCompressResult>(
      id: _nextId++,
      onCancel: (int id) => calls.add('cancel:$id'),
      onDispose: (int id) {
        calls.add('dispose:$id');
        sessions.remove(id);
      },
    );
    sessions[session.id] = session;
    final error = nextVideoError;
    nextVideoError = null;
    if (error != null) {
      session.emitError(_asException(error));
    }
    return session;
  }

  MediaCompressionException _asException(Object error) {
    if (error is MediaCompressionException) {
      return error;
    }
    return MediaCompressionException(
      MediaCompressionException.encode,
      error.toString(),
    );
  }
}

/// 可手动推送进度 / 完成 / 错误的会话替身。
final class FakeCompressionSession<TResult>
    implements CompressionSession<TResult> {
  FakeCompressionSession({
    required this.id,
    required this.onCancel,
    required this.onDispose,
  });

  final int id;
  final void Function(int id) onCancel;
  final void Function(int id) onDispose;

  final StreamController<double> _progress =
      StreamController<double>.broadcast();
  final Completer<TResult> _result = Completer<TResult>();

  double? _bufferedProgress;
  Object? _bufferedTerminal;
  int _listeners = 0;
  bool _disposed = false;
  bool _cancelCalled = false;

  @override
  Stream<double> get progress {
    return Stream<double>.multi((MultiStreamController<double> controller) {
      _listeners++;
      final buffered = _bufferedProgress;
      if (buffered != null) {
        controller.add(buffered);
        _bufferedProgress = null;
      }
      final terminal = _bufferedTerminal;
      if (terminal != null) {
        _completeTerminal(terminal);
        _bufferedTerminal = null;
      }
      final sub = _progress.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller
        ..onCancel = () {
          _listeners--;
          unawaited(sub.cancel());
        }
        ..onResume = () {};
    });
  }

  @override
  Future<TResult> get result => _result.future;

  void emitProgress(double value) {
    if (_listeners > 0) {
      if (!_progress.isClosed) {
        _progress.add(value);
      }
    } else {
      _bufferedProgress = value;
    }
  }

  void emitCompleted(TResult value) {
    _completeTerminal(value);
    if (_listeners == 0) {
      _bufferedProgress = 1.0;
    }
  }

  void emitError(MediaCompressionException error) {
    _completeTerminal(error);
  }

  void _completeTerminal(Object? value) {
    if (!_result.isCompleted) {
      if (value is MediaCompressionException) {
        _result.completeError(value);
      } else {
        _result.complete(value as TResult);
        if (!_progress.isClosed) {
          _progress.add(1.0);
        }
      }
    }
    if (!_progress.isClosed) {
      unawaited(_progress.close());
    }
  }

  @override
  Future<void> cancel() async {
    if (_disposed || _cancelCalled) {
      return;
    }
    _cancelCalled = true;
    onCancel(id);
    emitError(
      const MediaCompressionException(
        MediaCompressionException.cancelled,
        'Cancelled',
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    onDispose(id);
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }

  bool get cancelCalled => _cancelCalled;
}

ImageCompressResult fakeImageResult({
  Uint8List? bytes,
  String? outputPath = '/tmp/out.jpg',
}) {
  return ImageCompressResult(
    bytes: bytes,
    outputPath: outputPath,
    sizeBytes: bytes?.length ?? 12,
    format: ImageFormat.jpeg,
    width: 32,
    height: 24,
  );
}

VideoCompressResult fakeVideoResult({String outputPath = '/tmp/out.mp4'}) {
  return VideoCompressResult(
    outputPath: outputPath,
    sizeBytes: 100,
    encoderName: 'FakeEncoder',
    codec: VideoCodec.h264,
    width: 64,
    height: 48,
  );
}
