import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/main.dart' show showCmWindow;
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/dogshare_receiver_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

class _Binding extends Fake implements RustdeskImpl {
  _Binding(this.calls, {this.receiver = true});

  final List<String> calls;
  final bool receiver;

  @override
  bool isIncomingOnly({dynamic hint}) => receiver;

  @override
  bool isOutgoingOnly({dynamic hint}) => !receiver;

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';

  @override
  String mainGetLocalOption({required String key, dynamic hint}) =>
      key == kOptionAllowRemoteCmModification ? 'Y' : '';

  @override
  String mainGetPeerOptionSync({
    required String id,
    required String key,
    dynamic hint,
  }) =>
      '';

  @override
  String translate({
    required String name,
    required String locale,
    dynamic hint,
  }) =>
      name;

  @override
  bool mainHideDock({dynamic hint}) => false;

  @override
  Future<void> cmCloseConnection({required int connId, dynamic hint}) async {
    calls.add('disconnect:$connId');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const receiverWindow = MethodChannel('dogshare/receiver_window');
  const windowManager = MethodChannel('window_manager');
  const screens = MethodChannel('screen_retriever');
  const windowsOnly = TargetPlatformVariant({TargetPlatform.windows});
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  bool taskbarAvailable = true;
  late int oldBuildNumber;
  late bool oldIsTest;
  DesktopType? oldDesktopType;

  setUp(() {
    oldDesktopType = desktopType;
    oldBuildNumber = windowsBuildNumber;
    oldIsTest = isTest;
    desktopType = DesktopType.cm;
    windowsBuildNumber = 22631;
    isTest = true;
    platformFFI.setBindingForTesting(_Binding(calls));
    calls.clear();
    taskbarAvailable = true;
    messenger.setMockMethodCallHandler(receiverWindow, (call) async {
      calls.add('receiver:${call.method}');
      return taskbarAvailable;
    });
    messenger.setMockMethodCallHandler(windowManager, (call) async {
      if (const ['isFullScreen', 'isMaximized', 'isMinimized']
          .contains(call.method)) {
        return false;
      }
      calls.add('window:${call.method}');
      return null;
    });
    messenger.setMockMethodCallHandler(screens, (call) async {
      const display = {
        'id': 1,
        'size': {'width': 1920.0, 'height': 1080.0},
        'visiblePosition': {'x': 0.0, 'y': 0.0},
      };
      return switch (call.method) {
        'getPrimaryDisplay' => display,
        'getAllDisplays' => {
            'displays': [display]
          },
        'getCursorScreenPoint' => {'x': 0.0, 'y': 0.0},
        _ => null,
      };
    });
  });

  tearDown(() {
    desktopType = oldDesktopType;
    windowsBuildNumber = oldBuildNumber;
    isTest = oldIsTest;
    messenger.setMockMethodCallHandler(receiverWindow, null);
    messenger.setMockMethodCallHandler(windowManager, null);
    messenger.setMockMethodCallHandler(screens, null);
  });

  testWidgets(
      'B details start minimized, title buttons preserve the live connection',
      (tester) async {
    await initGlobalFFI();
    final model = gFFI.serverModel;
    await showCmWindow(isStartup: true);
    expect(calls, contains('window:waitUntilReadyToShow'));
    expect(
      calls.where((call) =>
          call.startsWith('receiver:') ||
          const ['window:show', 'window:focus', 'window:minimize']
              .contains(call)),
      isEmpty,
    );
    calls.clear();

    final client = Client(42, true, false, false, 'Test paired controller',
        '123456789', true, true, true);
    model.addConnection({'client': jsonEncode(client.toJson())});
    expect(model.clients.single.id, client.id);
    expect(model.cmHiddenTimer, isNull);
    Get.put<DesktopTabController>(model.tabController);
    addTearDown(() async {
      await Get.delete<DesktopTabController>(force: true);
    });
    await tester.binding.setSurfaceSize(kConnectionManagerWindowSizeClosedChat);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: MyTheme.lightTheme,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<ServerModel>.value(value: model),
          ChangeNotifierProvider<ChatModel>.value(value: gFFI.chatModel),
        ],
        child: Scaffold(body: ConnectionManager()),
      ),
    ));
    // Wait beyond the old delayed focus and three-second re-minimize.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call != 'window:setTitle'),
        ['receiver:showConnectionMinimized']);
    calls.clear();

    for (final tooltip in ['Minimize', 'Close']) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(calls, ['receiver:showConnectionInTaskbar', 'window:minimize']);
      expect(model.clients.single.disconnected, isFalse);
      calls.clear();
    }

    final disconnect = find.text('Disconnect');
    expect(
      find.ancestor(
        of: disconnect,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).color == Colors.redAccent,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(disconnect);
    await tester.pumpAndSettle();
    expect(calls, ['disconnect:42']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, variant: windowsOnly);

  testWidgets('B CM stays visible when taskbar registration fails',
      (tester) async {
    taskbarAvailable = false;
    await minimizeDogShareReceiverConnectionDetails();
    expect(calls, ['receiver:showConnectionInTaskbar']);
  }, variant: windowsOnly);

  testWidgets('B CM startup requests native minimized show without focus',
      (tester) async {
    expect(await showDogShareReceiverConnectionMinimized(), isTrue);
    expect(calls, ['receiver:showConnectionMinimized']);

    calls.clear();
    taskbarAvailable = false;
    expect(await showDogShareReceiverConnectionMinimized(), isFalse);
    expect(calls, ['receiver:showConnectionMinimized']);
  }, variant: windowsOnly);

  testWidgets('connection details window helpers ignore other windows and A',
      (tester) async {
    desktopType = DesktopType.main;
    expect(await showDogShareReceiverConnectionMinimized(), isFalse);
    await minimizeDogShareReceiverConnectionDetails();

    desktopType = DesktopType.cm;
    platformFFI.setBindingForTesting(_Binding(calls, receiver: false));
    expect(await showDogShareReceiverConnectionMinimized(), isFalse);
    await minimizeDogShareReceiverConnectionDetails();

    expect(calls, isEmpty);
  }, variant: windowsOnly);
}
