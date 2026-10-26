import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('android sources do not depend on FFmpeg or Media3', () {
    final root = Directory('android');
    expect(root.existsSync(), isTrue, reason: 'run from the package root');
    const banned = <String>[
      'libavcodec',
      'libavformat',
      'libavutil',
      'libavfilter',
      'libavdevice',
      'libswscale',
      'libswresample',
      'libpostproc',
      'gst-libav',
      'media3',
      'ffmpeg-kit',
      'mobile-ffmpeg',
      'libx264',
    ];
    final hits = <String>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final path = entity.path.replaceAll('\\', '/');
      if (!path.endsWith('.kt') &&
          !path.endsWith('.kts') &&
          !path.endsWith('.xml') &&
          !path.endsWith('.gradle')) {
        continue;
      }
      if (path.contains('/build/')) {
        continue;
      }
      final text = entity.readAsStringSync().toLowerCase();
      for (final name in banned) {
        if (text.contains(name)) {
          hits.add('$path contains $name');
        }
      }
    }
    expect(hits, isEmpty);
  });
}
