import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression_platform_interface/src/path_utils.dart';

void main() {
  group('normalizeInputPath', () {
    test('keeps content:// URIs intact', () {
      const uri = 'content://media/external/images/media/1';
      expect(normalizeInputPath(uri), uri);
    });

    test('decodes file:// URIs', () {
      expect(normalizeInputPath('file:///tmp/photo.jpg'), '/tmp/photo.jpg');
    });

    test('trims ordinary paths', () {
      expect(normalizeInputPath('  /tmp/a.mp4  '), '/tmp/a.mp4');
    });
  });
}
