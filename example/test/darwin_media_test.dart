import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/darwin_media.dart';
import '../integration_test/plugin_binary.dart';
import '../integration_test/windows_media.dart';

void main() {
  test('uyvy movie reports size, samples, and audio', () {
    final bytes = encodeDarwinVideo(
      width: 64,
      height: 48,
      fps: 30,
      frames: 12,
      audio: true,
    );
    expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
    final parsed = Mp4Probe.parse(bytes);
    expect(parsed.hasVideo, isTrue);
    expect(parsed.hasAudio, isTrue);
    expect(parsed.width, 64);
    expect(parsed.height, 48);
    expect(parsed.videoSamples, 12);
    expect(parsed.syncSamples, 12);
  });

  test('jpeg movie keeps odd dimensions', () {
    final bytes = encodeDarwinVideo(
      width: 101,
      height: 61,
      fps: 15,
      frames: 6,
      pixel: DarwinVideoPixel.jpeg,
    );
    final parsed = Mp4Probe.parse(bytes);
    expect(parsed.hasVideo, isTrue);
    expect(parsed.hasAudio, isFalse);
    expect(parsed.width, 101);
    expect(parsed.height, 61);
    expect(parsed.videoSamples, 6);
    expect(_contains(bytes, const <int>[0xff, 0xd8]), isTrue);
    final sof = _sofSize(bytes);
    expect(sof, (101, 61));
  });

  test('ffmpeg decodes fixtures when XH_FFMPEG_CHECK=1', () async {
    if (Platform.environment['XH_FFMPEG_CHECK'] != '1') {
      return;
    }
    final ffmpeg = await Process.run('ffmpeg', const <String>['-version']);
    expect(ffmpeg.exitCode, 0, reason: 'ffmpeg is required for this check');
    final dir = await Directory.systemTemp.createTemp('xh_darwin_media_');
    try {
      final uyvy = '${dir.path}/uyvy.mov';
      final jpeg = '${dir.path}/odd.mov';
      await writeDarwinVideo(
        uyvy,
        width: 64,
        height: 64,
        fps: 30,
        frames: 8,
        audio: true,
      );
      await writeDarwinVideo(
        jpeg,
        width: 101,
        height: 61,
        fps: 15,
        frames: 4,
        pixel: DarwinVideoPixel.jpeg,
      );
      for (final path in <String>[uyvy, jpeg]) {
        final result = await Process.run('ffmpeg', <String>[
          '-v',
          'error',
          '-i',
          path,
          '-f',
          'null',
          '-',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stderr}\n${result.stdout}',
        );
      }
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test('plugin scan ignores the app kernel blob', () {
    const app =
        '/work/xue_hua_media_compression/example/build/macos/Build/Products/Debug/xue_hua_media_compression_example.app';
    expect(
      isDarwinPluginMachO(
        '$app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin',
      ),
      isFalse,
    );
    expect(
      isDarwinPluginMachO(
        '$app/Contents/Frameworks/xue_hua_media_compression.framework/Versions/A/Resources/Info.plist',
      ),
      isFalse,
    );
    expect(
      isDarwinPluginMachO(
        '$app/Contents/Frameworks/xue_hua_media_compression.framework/Versions/A/xue_hua_media_compression',
      ),
      isTrue,
    );
    expect(
      isDarwinPluginMachO(
        '$app/Contents/Frameworks/libxue_hua_media_compression.dylib',
      ),
      isTrue,
    );
  });
}

bool _contains(List<int> bytes, List<int> needle) {
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return true;
    }
  }
  return false;
}

(int, int)? _sofSize(List<int> bytes) {
  for (var i = 0; i + 9 < bytes.length; i++) {
    if (bytes[i] == 0xff && bytes[i + 1] == 0xc0) {
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      return (width, height);
    }
  }
  return null;
}
