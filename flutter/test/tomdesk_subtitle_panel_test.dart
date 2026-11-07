import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/tomdesk_subtitle_frame.dart';
import 'package:flutter_test/flutter_test.dart' hide isWindows;
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  final chatMessages = <String>[];
  final frames = <TomDeskSubtitleFrame>[];

  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';

  @override
  Future<void> setLocalFlutterOption(
      {required String k, required String v, dynamic hint}) async {}

  @override
  bool isIncomingOnly({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => true;

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;

  @override
  Future<void> sessionSendChat({
    required UuidValue sessionId,
    required String text,
    dynamic hint,
  }) async {
    chatMessages.add(text);
  }

  @override
  Future<void> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
    dynamic hint,
  }) async {
    frames.add(TomDeskSubtitleFrame.tryDecode(value)!);
  }
}

class _Session extends Fake implements FFI {
  @override
  final dialogManager = OverlayDialogManager();

  @override
  final sessionId = const Uuid().v4obj();

  @override
  ConnType get connType => ConnType.defaultConn;

  @override
  late final ffiModel = FfiModel(WeakReference<FFI>(this));

  @override
  late final chatModel = ChatModel(WeakReference<FFI>(this));
}

void main() {
  testWidgets('one chat field sends ordinary, manual and live captions',
      (tester) async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    final wasTest = isTest;
    isTest = true;
    addTearDown(() => isTest = wasTest);
    await initGlobalFFI();
    draggablePositions.load();
    final session = _Session();
    session.ffiModel.pi.isSet.value = true;
    session.ffiModel.waitForFirstImage.value = false;
    final chat = session.chatModel;
    chat.changeCurrentKey(
        MessageKey('paired-receiver', ChatModel.clientModeID));
    addTearDown(() {
      chat.dispose();
      chat.inputNode.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: globalKey,
      theme: MyTheme.lightTheme,
      home: Scaffold(
        body: DraggableChatWindow(
          position: const Offset(50, 30),
          width: 250,
          height: 350,
          chatModel: chat,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final panel = find.descendant(
      of: find.byType(DraggableChatWindow),
      matching: find.byType(Scaffold),
    );
    final start = tester.getRect(panel);
    expect(start.width, greaterThan(400));
    expect(start.height, greaterThan(410));
    final resize = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.open_in_full)),
    );
    await resize.moveBy(const Offset(30, 22));
    await resize.moveBy(const Offset(25, 18));
    await resize.moveBy(const Offset(25, 18));
    await resize.up();
    await tester.pump();
    final resized = tester.getRect(panel);
    expect(resized.width, greaterThan(start.width + 45));
    expect(resized.height, greaterThan(start.height + 30));
    await tester.drag(find.text('Chat'), const Offset(30, 20));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(panel).left, greaterThan(resized.left));
    expect(tester.getRect(panel).width, closeTo(resized.width, 0.1));
    expect(tester.getRect(panel).height, closeTo(resized.height, 0.1));

    final input = find.byType(TextField);
    final display = find.byType(Switch);
    final send = find.widgetWithIcon(IconButton, Icons.send);
    expect(input, findsOneWidget);
    expect(send, findsOneWidget);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(input, '普通聊天');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(binding.chatMessages, ['普通聊天']);
    expect(binding.frames, isEmpty);

    await tester.tap(display);
    await tester.pumpAndSettle();
    expect(binding.frames.single.enabled, isTrue);
    expect(binding.frames.single.text, isEmpty);
    await tester.enterText(input, '手动字幕');
    await tester.pump(const Duration(milliseconds: 200));
    expect(binding.frames, hasLength(1));
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(binding.frames.last.text, '手动字幕');
    expect(binding.chatMessages, ['普通聊天']);
    expect(find.text('手动字幕'), findsOneWidget); // Retained in A's chat history.

    final clear = find.byTooltip('Clear');
    await tester.enterText(input, '未发送');
    await tester.pump();
    final fieldBounds = tester.getRect(input);
    expect(fieldBounds.contains(tester.getCenter(clear)), isTrue);
    expect(tester.getCenter(send).dx, greaterThan(fieldBounds.right));
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    expect(binding.frames.last.text, '手动字幕');
    expect(find.text('手动字幕'), findsOneWidget);

    await tester.tap(find.text('Subtitle settings'));
    await tester.pumpAndSettle();
    final settings = find.byType(CustomAlertDialog);
    expect(find.descendant(of: settings, matching: input), findsNothing);
    final opacity =
        find.descendant(of: settings, matching: find.byType(Slider)).last;
    await tester.tapAt(tester.getCenter(opacity));
    await tester.pumpAndSettle();
    expect(binding.frames.last.color >> 24, closeTo(128, 2));
    await tester.tap(find.text('Send in real time'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.descendant(of: settings, matching: find.text('Close')));
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);

    await tester.showKeyboard(input);
    final sentFrames = binding.frames.length;
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(binding.frames, hasLength(sentFrames));
    expect(tester.widget<IconButton>(send).onPressed, isNull);

    void commit(String text) {
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
    }

    commit('你');
    await tester.pump(const Duration(milliseconds: 60));
    commit('你好');
    await tester.pump(const Duration(milliseconds: 60));
    commit('你好世');
    await tester.pump(const Duration(milliseconds: 40));
    expect(binding.frames.last.text, '你好世');

    await tester.tap(send);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(binding.frames.last.text, '你好世');
    expect(binding.chatMessages, ['普通聊天']);
    await tester.enterText(input, '实时草稿');
    await tester.pump(const Duration(milliseconds: 160));
    expect(binding.frames.last.text, '实时草稿');
    await tester.tap(clear);
    await tester.pump(const Duration(milliseconds: 160));
    expect(binding.frames.last.text, isEmpty);
    expect(find.text('你好世'), findsOneWidget);
    await tester.tap(display);
    await tester.pumpAndSettle();
    expect(binding.frames.last.enabled, isFalse);
    expect(tester.takeException(), isNull);
  },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
      skip: !isWindows);
}
