import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/tomdesk_receiver_window.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  _Binding(this.receiver, this.calls);

  final bool receiver;
  final List<String> calls;
  String token = 'test-local-token';

  @override
  bool isIncomingOnly({dynamic hint}) => receiver;

  @override
  bool isOutgoingOnly({dynamic hint}) => !receiver;

  @override
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
    dynamic hint,
  }) async {
    if (key == 'access_token') {
      calls.add('setToken');
      token = value;
    }
  }

  @override
  Future<void> mainOnMainWindowClose({dynamic hint}) async {
    calls.add('nativeCleanup');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowsOnly = TargetPlatformVariant({TargetPlatform.windows});
  const tray = MethodChannel('tomdesk/receiver_tray');
  const receiverWindow = MethodChannel('tomdesk/receiver_window');
  const windows = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  late _Binding binding;
  bool hideSucceeds = true;
  bool relaunchReady = true;

  setUp(() {
    desktopType = DesktopType.main;
    binding = _Binding(true, calls);
    platformFFI.setBindingForTesting(binding);
    hideSucceeds = true;
    relaunchReady = true;
    calls.clear();
    messenger.setMockMethodCallHandler(tray, (call) async {
      calls.add('tray:${call.method}');
      return true;
    });
    messenger.setMockMethodCallHandler(receiverWindow, (call) async {
      calls.add('receiver:${call.method}');
      return relaunchReady;
    });
    messenger.setMockMethodCallHandler(windows, (call) async {
      calls.add(call.method);
      if (call.method == 'hide' && !hideSucceeds) {
        throw PlatformException(code: 'test-hide-failed');
      }
      return null;
    });
  });

  tearDown(() {
    desktopType = null;
    messenger.setMockMethodCallHandler(tray, null);
    messenger.setMockMethodCallHandler(receiverWindow, null);
    messenger.setMockMethodCallHandler(windows, null);
  });

  testWidgets('successful receiver login only hides and keeps main registered',
      (tester) async {
    final wasActive =
        rustDeskWinManager.getActiveWindows().contains(kMainWindowId);
    await rustDeskWinManager.registerActiveWindow(kMainWindowId);
    rustDeskWinManager.registerActiveWindowListener(onActiveWindowChanged);
    addTearDown(() async {
      rustDeskWinManager.unregisterActiveWindowListener(onActiveWindowChanged);
      if (!wasActive) {
        await rustDeskWinManager.unregisterActiveWindow(kMainWindowId);
      }
    });

    await collapseTomDeskReceiverAfterLogin(true);
    expect(calls, ['receiver:enableRelaunch', 'hide']);
    expect(rustDeskWinManager.getActiveWindows(), contains(kMainWindowId));
  }, variant: windowsOnly);

  testWidgets('failed or cancelled login does not hide', (tester) async {
    await collapseTomDeskReceiverAfterLogin(false);
    await collapseTomDeskReceiverAfterLogin(null);
    expect(calls, isEmpty);
  }, variant: windowsOnly);

  testWidgets('simultaneous hide requests share one window operation',
      (tester) async {
    await Future.wait([
      hideTomDeskReceiverWindow(),
      hideTomDeskReceiverWindow(),
    ]);
    expect(calls, ['receiver:enableRelaunch', 'hide']);
  }, variant: windowsOnly);

  testWidgets('failed relaunch registration leaves taskbar recovery',
      (tester) async {
    relaunchReady = false;
    await hideTomDeskReceiverWindow();
    expect(calls, ['receiver:enableRelaunch', 'minimize']);

    calls.clear();
    await hideTomDeskReceiverWindow(alreadyMinimized: true);
    expect(calls, ['receiver:enableRelaunch']);
  }, variant: windowsOnly);

  testWidgets('failed hide does not register a tray or minimize to taskbar',
      (tester) async {
    hideSucceeds = false;
    await hideTomDeskReceiverWindow();
    expect(calls, ['receiver:enableRelaunch', 'hide']);

    hideSucceeds = true;
    calls.clear();
    await hideTomDeskReceiverWindow();
    expect(calls, ['receiver:enableRelaunch', 'hide']);
  }, variant: windowsOnly);

  testWidgets('explicit exit cleans up and preserves the receiver login',
      (tester) async {
    await exitTomDeskReceiver();
    expect(calls, ['nativeCleanup', 'destroy']);
    expect(binding.token, 'test-local-token');
  }, variant: windowsOnly);

  testWidgets('controller and connection manager retain their window behavior',
      (tester) async {
    platformFFI.setBindingForTesting(_Binding(false, calls));
    await collapseTomDeskReceiverAfterLogin(true);
    await hideTomDeskReceiverWindow();
    await exitTomDeskReceiver();
    platformFFI.setBindingForTesting(binding);
    desktopType = DesktopType.cm;
    await collapseTomDeskReceiverAfterLogin(true);
    await hideTomDeskReceiverWindow();
    await exitTomDeskReceiver();
    expect(calls, isEmpty);
  }, variant: windowsOnly);
}
