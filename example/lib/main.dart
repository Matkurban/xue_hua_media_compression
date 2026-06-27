import 'dart:io';

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await XueHuaMediaCompression.initialize();
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

/// 把字节数格式化为人类可读的字符串。
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _backend = '...';

  @override
  void initState() {
    super.initState();
    XueHuaMediaCompression.videoBackendName().then((value) {
      if (mounted) setState(() => _backend = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('雪花媒体压缩 Demo'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '当前平台视频硬编后端: $_backend',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
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

// ===========================================================================
// 图片压缩卡片
// ===========================================================================

class ImageCompressionCard extends StatefulWidget {
  const ImageCompressionCard({super.key});

  @override
  State<ImageCompressionCard> createState() => _ImageCompressionCardState();
}

class _ImageCompressionCardState extends State<ImageCompressionCard> {
  static const _formats = <String, ImageFormat>{
    'JPEG': ImageFormat.jpeg,
    'PNG': ImageFormat.png,
    'WebP': ImageFormat.webP,
    'AVIF': ImageFormat.avif,
  };

  ImageFormat _format = ImageFormat.jpeg;
  double _quality = 80;

  bool _busy = false;
  String? _name;
  Uint8List? _original;
  Uint8List? _compressed;
  Duration? _elapsed;
  String? _error;

  Future<void> _pickAndCompress() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? tempInPath;
    String? tempOutPath;
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

      final tmpDir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      tempInPath = '${tmpDir.path}/xh_img_in_$ts';
      tempOutPath = '${tmpDir.path}/xh_img_out_$ts${_outputExtension(_format)}';
      await file.saveTo(tempInPath);
      final original = await File(tempInPath).readAsBytes();

      final sw = Stopwatch()..start();
      await XueHuaMediaCompression.image.compressFile(
        inputPath: tempInPath,
        outputPath: tempOutPath,
        format: _format,
        quality: _quality.round(),
      );
      sw.stop();

      final compressed = await File(tempOutPath).readAsBytes();

      setState(() {
        _name = file.name;
        _original = original;
        _compressed = compressed;
        _elapsed = sw.elapsed;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      for (final path in [tempInPath, tempOutPath]) {
        if (path != null) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  String _outputExtension(ImageFormat format) {
    return switch (format) {
      ImageFormat.jpeg => '.jpg',
      ImageFormat.png => '.png',
      ImageFormat.webP => '.webp',
      ImageFormat.gif => '.gif',
      ImageFormat.avif => '.avif',
      ImageFormat.heic => '.heic',
    };
  }

  @override
  Widget build(BuildContext context) {
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
                value: _format,
                items: _formats.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.value, child: Text(e.key)),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _format = v ?? ImageFormat.jpeg),
              ),
            ],
          ),
          if (_format == ImageFormat.png)
            Text(
              'PNG 为无损格式，从 JPEG 转换后体积通常会增大；PNG→PNG 可无损优化体积。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
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
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _pickAndCompress,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file),
            label: Text(_busy ? '压缩中...' : '选择图片并压缩'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: _error!),
          ],
          if (_original != null && _compressed != null) ...[
            const SizedBox(height: 12),
            _SizeResult(
              name: _name ?? '',
              originalSize: _original!.length,
              compressedSize: _compressed!.length,
              elapsed: _elapsed,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ImagePreview(label: '原图', bytes: _original!),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ImagePreview(label: '压缩后', bytes: _compressed!),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 视频压缩卡片
// ===========================================================================

class VideoCompressionCard extends StatefulWidget {
  const VideoCompressionCard({super.key});

  @override
  State<VideoCompressionCard> createState() => _VideoCompressionCardState();
}

class _VideoCompressionCardState extends State<VideoCompressionCard> {
  static const _codecs = <String, VideoCodec>{
    'H.264': VideoCodec.h264,
    'H.265 (HEVC)': VideoCodec.h265,
  };

  VideoCodec _codec = VideoCodec.h264;
  double _bitrateMbps = 2;

  bool _busy = false;
  String? _name;
  int? _originalSize;
  int? _compressedSize;
  String? _resultBackend;
  Duration? _elapsed;
  String? _error;

  Future<void> _pickAndCompress() async {
    setState(() {
      _busy = true;
      _error = null;
      _compressedSize = null;
      _elapsed = null;
    });
    String? tempInputPath;
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

      final originalSize = await file.length();
      final tmpDir = await getTemporaryDirectory();
      tempInputPath = await ensureLocalVideoInput(
        inputPath: file.path,
        cacheDirectory: tmpDir.path,
        openStream: () async => file.openRead().cast<List<int>>(),
        fileName: file.name,
        expectedBytes: originalSize,
      );
      assert(() {
        // ignore: avoid_print
        print(
          '视频已复制到缓存: $tempInputPath, '
          '大小=${File(tempInputPath!).lengthSync()} 字节',
        );
        return true;
      }());
      final outPath =
          '${tmpDir.path}/xh_compressed_${DateTime.now().millisecondsSinceEpoch}.mp4';

      setState(() {
        _name = file.name;
        _originalSize = originalSize;
      });

      final sw = Stopwatch()..start();
      final result = await XueHuaMediaCompression.video.compress(
        inputPath: tempInputPath,
        outputPath: outPath,
        codec: _codec,
        bitrate: (_bitrateMbps * 1000000).round(),
      );
      sw.stop();

      setState(() {
        _compressedSize = result.sizeBytes.toInt();
        _resultBackend = result.backend;
        _elapsed = sw.elapsed;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (tempInputPath != null) {
        try {
          final f = File(tempInputPath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      icon: Icons.movie_outlined,
      title: '视频压缩',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('编码: '),
              const SizedBox(width: 8),
              DropdownButton<VideoCodec>(
                value: _codec,
                items: _codecs.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.value, child: Text(e.key)),
                    )
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
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _pickAndCompress,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.video_file),
            label: Text(_busy ? '压缩中...' : '选择视频并压缩'),
          ),
          if (_originalSize != null) ...[
            const SizedBox(height: 12),
            _KeyValueRow(label: '文件', value: _name ?? ''),
            _KeyValueRow(label: '原始大小', value: formatBytes(_originalSize!)),
          ],
          if (_compressedSize != null) ...[
            _SizeResult(
              name: _name ?? '',
              originalSize: _originalSize!,
              compressedSize: _compressedSize!,
              elapsed: _elapsed,
              backend: _resultBackend,
              compact: true,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: _error!),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// 复用小部件
// ===========================================================================

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
  const _ImagePreview({required this.label, required this.bytes});

  final String label;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
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
