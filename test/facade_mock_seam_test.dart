import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_media_compression/src/media_compression.dart';
import 'package:xue_hua_media_compression/src/rust/frb_generated.dart';
import 'package:xue_hua_media_compression/xue_hua_media_compression.dart';

import 'support/mock_rust_lib_api.dart';

void main() {
  setUpAll(() {
    RustLib.initMock(api: MockRustLibApi());
  });

  test('facade image compress uses mock backend', () async {
    final out = await XueHuaMediaCompression.image.compress(
      input: Uint8List.fromList([1, 2, 3]),
    );
    expect(out, Uint8List.fromList([1, 2, 3]));
  });

  test('facade video backend name from mock', () async {
    final name = await XueHuaMediaCompression.videoBackendName();
    expect(name, 'dart-mock');
  });

  test('facadeImageOptions matches compress defaults', () {
    final opts = facadeImageOptions();
    expect(opts.speed, isNull);
    expect(opts.quality, 80);
  });
}
