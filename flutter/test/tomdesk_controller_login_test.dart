import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/tomdesk_paired_home.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/tomdesk_receiver_window.dart';
import 'package:flutter_test/flutter_test.dart';

class _PairedBinding extends Fake implements RustdeskImpl {
  _PairedBinding({required this.receiver});

  final bool receiver;

  @override
  bool isIncomingOnly({dynamic hint}) => receiver;

  @override
  bool isOutgoingOnly({dynamic hint}) => !receiver;

  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';

  @override
  String translate({
    required String name,
    required String locale,
    dynamic hint,
  }) =>
      name;
}

void main() {
  for (final receiver in [false, true]) {
    final role = receiver ? 'B' : 'A';
    testWidgets('paired $role sign-in fits and keeps the form validation',
        (tester) async {
      platformFFI.setBindingForTesting(_PairedBinding(receiver: receiver));
      final wasTest = isTest;
      isTest = true;
      addTearDown(() => isTest = wasTest);
      await tester.binding.setSurfaceSize(const Size(390, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await initGlobalFFI();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: globalKey,
        theme: MyTheme.lightTheme,
        home: const Scaffold(body: TomDeskPairedHome()),
      ));

      expect(find.text(receiver ? 'TomDesk receiver' : 'TomDesk controller'),
          findsOneWidget);
      expect(find.text('Connect'), findsNothing);
      const receiverHint =
          'After signing in, your paired controller can connect to this computer.';
      final voiceNotice = find.textContaining(
        RegExp(r'microphone|voice calls?|auto.?answer', caseSensitive: false),
      );
      if (receiver) {
        expect(find.text(receiverHint), findsOneWidget);
        expect(voiceNotice, findsNothing);
      }
      final homeLogin = find.text('Login');
      await tester.ensureVisible(homeLogin);
      await tester.tap(homeLogin);
      await tester.pumpAndSettle();

      final dialog = find.byType(CustomAlertDialog);
      final fields =
          find.descendant(of: dialog, matching: find.byType(TextField));
      final submit = find.descendant(
          of: dialog, matching: find.widgetWithText(FilledButton, 'Login'));
      expect(fields, findsNWidgets(2));
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(receiver
              ? receiverHint
              : 'Accounts are managed by your administrator.'),
        ),
        findsOneWidget,
      );
      if (receiver) {
        expect(find.descendant(of: dialog, matching: voiceNotice),
            findsNothing);
        expect(find.descendant(of: dialog, matching: find.byType(Checkbox)),
            findsNothing);
        expect(find.descendant(of: dialog, matching: find.byType(Switch)),
            findsNothing);
      }
      expect(tester.widget<TextField>(fields.last).obscureText, isTrue);

      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Username missed'), findsOneWidget);

      await tester.ensureVisible(fields.first);
      await tester.enterText(fields.first, 'test-account');
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Password missed'), findsOneWidget);

      final close = find.byTooltip('Close');
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      final programExit =
          find.widgetWithText(TextButton, tomDeskReceiverExitLabel);
      expect(programExit, receiver ? findsOneWidget : findsNothing);
      if (receiver) await tester.ensureVisible(programExit);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }
}
