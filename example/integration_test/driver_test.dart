import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xue_hua_media_compression_example/main.dart';

import 'facade_seam.dart';
import 'linux_driver.dart';
import 'windows_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerFacadeSeamTests();

  testWidgets('example home loads image and video cards', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('图片压缩'), findsOneWidget);
    expect(find.text('视频压缩'), findsOneWidget);
    expect(find.text('选择图片并压缩'), findsOneWidget);
    expect(find.text('选择视频并压缩'), findsOneWidget);
    final errors = find.byIcon(Icons.error_outline);
    if (errors.evaluate().isNotEmpty) {
      final messages = find.byType(SelectableText).evaluate().map((element) {
        final widget = element.widget as SelectableText;
        return widget.data ?? widget.textSpan?.toPlainText() ?? '';
      });
      fail('example surfaced an error: ${messages.join('\n')}');
    }
  });

  // One process. Flutter's desktop log reader closes when the first
  // integration-test file exits, so a second *_test.dart never attaches.
  registerLinuxDriverTests();
  registerWindowsDriverTests();
}
