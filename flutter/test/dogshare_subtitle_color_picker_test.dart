import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show CustomAlertDialog;
import 'package:flutter_hbb/desktop/widgets/dogshare_subtitle_color_picker.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
}

void main() {
  testWidgets('RGBA values survive a narrow layout and apply on confirmation',
      (tester) async {
    platformFFI.setBindingForTesting(_Binding());
    tester.view.physicalSize = const Size(920, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final confirmed = <Color>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomAlertDialog(
          title: const Text('Choose color'),
          contentBoxConstraints: const BoxConstraints(maxWidth: 650),
          content: DogShareSubtitleColorPicker(
            initialColor: const Color(0xffdddddd),
            onConfirm: confirmed.add,
            onCancel: () => fail('Unexpected color cancellation'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> enterChannel(String label, String value) async {
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
      await tester.pump();
    }

    await enterChannel('R', '18');
    await enterChannel('G', '52');
    await enterChannel('B', '86');
    expect(confirmed, isEmpty);

    tester.view.physicalSize = const Size(420, 640);
    await tester.pumpAndSettle();
    await enterChannel('A', '50');
    expect(confirmed, isEmpty);

    final ok = find.widgetWithText(TextButton, 'OK');
    await tester.ensureVisible(ok);
    await tester.tap(ok);
    expect(confirmed, [const Color(0x80123456)]);
    expect(tester.takeException(), isNull);
  });
}
