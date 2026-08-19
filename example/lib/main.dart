import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XueHua Media Compression',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('雪花媒体压缩 Demo')),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ImageCompressionCard(),
            SizedBox(height: 16),
            VideoCompressionCard(),
          ],
        ),
      ),
    );
  }
}

class ImageCompressionCard extends StatefulWidget {
  const ImageCompressionCard({super.key});

  @override
  State<ImageCompressionCard> createState() => _ImageCompressionCardState();
}

class _ImageCompressionCardState extends State<ImageCompressionCard> {
  ImageCompressionCapabilities? _caps;
  ImageFormat _format = ImageFormat.jpeg;
  double _quality = 80;
  bool _busy = false;
  double _progress = 0;
  CompressionSession<ImageCompressResult>? _session;
  String? _name;
  String? _originalPath;
  String? _compressedPath;
  int? _originalSize;
  int? _compressedSize;
  Duration? _elapsed;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCaps());
  }

  Future<void> _loadCaps() async {
    try {
      final caps = await XueHuaMediaCompression.image.queryCapabilities();
      if (!mounted) return;
      setState(() {
        _caps = caps;
        if (!caps.outputFormats.contains(_format) &&
            caps.outputFormats.isNotEmpty) {
          _format = caps.outputFormats.first;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _pickAndCompress() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      const typeGroup = XTypeGroup(
        label: 'images',
        extensions: [
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'heic',
          'heif',
          'avif',
        ],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) {
        setState(() => _busy = false);
        return;
      }
      final tmp =
          '${Directory.systemTemp.path}/xh_img_out_${DateTime.now().millisecondsSinceEpoch}${_ext(_format)}';
      final session = XueHuaMediaCompression.image.compress(
        source: MediaSource.path(file.path),
        destination: MediaDestination.path(tmp),
        options: ImageCompressOptions(
          format: _format,
          quality: _quality.round(),
        ),
      );
      _session = session;
      final sub = session.progress.listen((value) {
        if (mounted) setState(() => _progress = value);
      });
      final sw = Stopwatch()..start();
      final result = await session.result;
      sw.stop();
      await sub.cancel();
      await session.dispose();
      _session = null;
      if (!mounted) return;
      setState(() {
        _name = file.name;
        _originalPath = file.path;
        _compressedPath = result.outputPath;
        _originalSize = awaitSizeSync(file.path);
        _compressedSize = result.sizeBytes;
        _elapsed = sw.elapsed;
        _progress = 1;
      });
    } on MediaCompressionException catch (error) {
      if (error.code == MediaCompressionException.cancelled) {
        setState(() => _error = '已取消');
      } else {
        setState(() => _error = '$error');
      }
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    await _session?.cancel();
  }

  static int awaitSizeSync(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  String _ext(ImageFormat format) {
    return switch (format) {
      ImageFormat.jpeg => '.jpg',
      ImageFormat.png => '.png',
      ImageFormat.webp => '.webp',
      ImageFormat.gif => '.gif',
      ImageFormat.avif => '.avif',
      ImageFormat.heic => '.heic',
    };
  }

  @override
  Widget build(BuildContext context) {
    final formats = _caps?.outputFormats.toList() ?? [ImageFormat.jpeg];
    return _SectionCard(
      icon: Icons.image_outlined,
      title: '图片压缩',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('目标格式: '),
              const SizedBox(width: 8),
              DropdownButton<ImageFormat>(
                value: formats.contains(_format) ? _format : formats.first,
                items: formats
                    .map((f) => DropdownMenuItem(value: f, child: Text(f.name)))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _format = v ?? ImageFormat.jpeg),
              ),
            ],
          ),
          if (_format != ImageFormat.png)
            Row(
              children: [
                const Text('质量: '),
                Expanded(
                  child: Slider(
                    value: _quality,
                    min: 1,
                    max: 100,
                    divisions: 99,
                    label: _quality.round().toString(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _quality = v),
                  ),
                ),
                SizedBox(width: 36, child: Text(_quality.round().toString())),
              ],
            ),
          if (_busy)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _pickAndCompress,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_busy ? '压缩中...' : '选择图片并压缩'),
                ),
              ),
              if (_busy) ...[
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _cancel, child: const Text('取消')),
              ],
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: _error!),
          ],
          if (_originalPath != null &&
              _compressedPath != null &&
              _originalSize != null &&
              _compressedSize != null) ...[
            const SizedBox(height: 12),
            _SizeResult(
              name: _name ?? '',
              originalSize: _originalSize!,
              compressedSize: _compressedSize!,
              elapsed: _elapsed,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ImagePreview(label: '原图', path: _originalPath!),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ImagePreview(label: '压缩后', path: _compressedPath!),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class VideoCompressionCard extends StatefulWidget {
  const VideoCompressionCard({super.key});

  @override
  State<VideoCompressionCard> createState() => _VideoCompressionCardState();
}

class _VideoCompressionCardState extends State<VideoCompressionCard> {
  VideoCompressionCapabilities? _caps;
  VideoCodec _codec = VideoCodec.h264;
  double _bitrateMbps = 2;
  bool _busy = false;
  double _progress = 0;
  CompressionSession<VideoCompressResult>? _session;
  String? _name;
  int? _originalSize;
  int? _compressedSize;
  String? _encoderName;
  Duration? _elapsed;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCaps());
  }

  Future<void> _loadCaps() async {
    try {
      final caps = await XueHuaMediaCompression.video.queryCapabilities();
      if (!mounted) return;
      setState(() {
        _caps = caps;
        if (!caps.codecs.contains(_codec) && caps.codecs.isNotEmpty) {
          _codec = caps.codecs.first;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _pickAndCompress() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _compressedSize = null;
    });
    try {
      const typeGroup = XTypeGroup(
        label: 'videos',
        extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) {
        setState(() => _busy = false);
        return;
      }
      final output =
          '${Directory.systemTemp.path}/xh_compressed_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final originalSize = await File(file.path).length();
      setState(() {
        _name = file.name;
        _originalSize = originalSize;
      });
      final session = XueHuaMediaCompression.video.compress(
        inputPath: file.path,
        outputPath: output,
        options: VideoCompressOptions(
          codec: _codec,
          bitrate: (_bitrateMbps * 1000000).round(),
        ),
      );
      _session = session;
      final sub = session.progress.listen((value) {
        if (mounted) setState(() => _progress = value);
      });
      final sw = Stopwatch()..start();
      final result = await session.result;
      sw.stop();
      await sub.cancel();
      await session.dispose();
      _session = null;
      if (!mounted) return;
      setState(() {
        _compressedSize = result.sizeBytes;
        _encoderName = result.encoderName;
        _elapsed = sw.elapsed;
        _progress = 1;
      });
    } on MediaCompressionException catch (error) {
      if (error.code == MediaCompressionException.cancelled) {
        setState(() => _error = '已取消');
      } else {
        setState(() => _error = '$error');
      }
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    await _session?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final codecs = _caps?.codecs.toList() ?? [VideoCodec.h264];
    return _SectionCard(
      icon: Icons.movie_outlined,
      title: '视频压缩',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_caps?.encoderName != null) Text('硬编: ${_caps!.encoderName}'),
          Row(
            children: [
              const Text('编码: '),
              const SizedBox(width: 8),
              DropdownButton<VideoCodec>(
                value: codecs.contains(_codec) ? _codec : codecs.first,
                items: codecs
                    .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _codec = v ?? VideoCodec.h264),
              ),
            ],
          ),
          Row(
            children: [
              const Text('码率: '),
              Expanded(
                child: Slider(
                  value: _bitrateMbps,
                  min: 0.5,
                  max: 20,
                  divisions: 39,
                  label: '${_bitrateMbps.toStringAsFixed(1)} Mbps',
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _bitrateMbps = v),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text('${_bitrateMbps.toStringAsFixed(1)}M'),
              ),
            ],
          ),
          if (_busy)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _pickAndCompress,
                  icon: const Icon(Icons.video_file),
                  label: Text(_busy ? '压缩中...' : '选择视频并压缩'),
                ),
              ),
              if (_busy) ...[
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _cancel, child: const Text('取消')),
              ],
            ],
          ),
          if (_originalSize != null) ...[
            const SizedBox(height: 12),
            _KeyValueRow(label: '文件', value: _name ?? ''),
            _KeyValueRow(label: '原始大小', value: formatBytes(_originalSize!)),
          ],
          if (_compressedSize != null)
            _SizeResult(
              name: _name ?? '',
              originalSize: _originalSize!,
              compressedSize: _compressedSize!,
              elapsed: _elapsed,
              backend: _encoderName,
              compact: true,
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: _error!),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(height: 24),
            child,
          ],
        ),
      ),
    );
  }
}

class _SizeResult extends StatelessWidget {
  const _SizeResult({
    required this.name,
    required this.originalSize,
    required this.compressedSize,
    this.elapsed,
    this.backend,
    this.compact = false,
  });

  final String name;
  final int originalSize;
  final int compressedSize;
  final Duration? elapsed;
  final String? backend;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final saved = originalSize - compressedSize;
    final ratio = originalSize == 0 ? 0.0 : saved / originalSize;
    final isSmaller = saved > 0;
    final color = isSmaller ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) _KeyValueRow(label: '文件', value: name),
          _KeyValueRow(label: '原始大小', value: formatBytes(originalSize)),
          _KeyValueRow(label: '压缩后大小', value: formatBytes(compressedSize)),
          _KeyValueRow(
            label: isSmaller ? '节省' : '体积变化',
            value:
                '${formatBytes(saved.abs())} (${(ratio * 100).toStringAsFixed(1)}%)',
            valueColor: color,
          ),
          if (elapsed != null)
            _KeyValueRow(label: '耗时', value: '${elapsed!.inMilliseconds} ms'),
          if (backend != null) _KeyValueRow(label: '编码后端', value: backend!),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: valueColor,
                fontWeight: valueColor != null
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            height: 120,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => Container(
              height: 120,
              alignment: Alignment.center,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Text('无法预览该格式'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
