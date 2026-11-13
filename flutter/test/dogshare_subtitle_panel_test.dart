import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/dogshare_subtitle_frame.dart';
import 'package:flutter_test/flutter_test.dart' hide isWindows;
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  final chatMessages = <String>[];
  final frames = <DogShareSubtitleFrame>[];

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
    frames.add(DogShareSubtitleFrame.tryDecode(value)!);
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
    expect(tester.widget<TextField>(input).minLines, 4);
    expect(tester.widget<TextField>(input).maxLines, 8);
    expect(tester.widget<TextField>(input).decoration!.hintText,
        'Enter 发送，Shift + Enter 换行');
    final initialInputHeight = tester.getSize(input).height;
    await tester.enterText(input, List.filled(8, '多行内容').join('\n'));
    await tester.pump();
    final eightLineHeight = tester.getSize(input).height;
    expect(eightLineHeight, greaterThan(initialInputHeight));
    await tester.enterText(input, List.filled(12, '多行内容').join('\n'));
    await tester.pump();
    expect(tester.getSize(input).height, closeTo(eightLineHeight, 0.1));

    for (final shift in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight
    ]) {
      await tester.enterText(input, '第一段待替换尾部');
      chat.textController.selection =
          const TextSelection(baseOffset: 3, extentOffset: 6);
      await tester.sendKeyDownEvent(shift);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(shift);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(chat.textController.text, '第一段\n尾部');
      expect(chat.textController.selection.baseOffset, 4);
      expect(binding.chatMessages, isEmpty);
    }

    KeyEventResult composingEnter() => chat.inputNode.onKey!(
          chat.inputNode,
          RawKeyDownEvent(
              data: const RawKeyEventDataWindows(keyCode: 13, scanCode: 28)),
        );
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    ));
    await tester.pump();
    expect(composingEnter(), KeyEventResult.ignored);
    expect(chat.textController.text, 'ni');
    expect(binding.chatMessages, isEmpty);
    expect(binding.frames, isEmpty);
    expect(tester.widget<IconButton>(send).onPressed, isNull);

    await tester.enterText(input, '普通聊天');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
    expect(tester.getRect(clear).bottom, lessThan(fieldBounds.center.dy));
    expect(tester.getCenter(clear).dx, greaterThan(fieldBounds.center.dx));
    expect(tester.getCenter(send).dx, greaterThan(fieldBounds.right));
    expect(tester.getCenter(send).dy, closeTo(fieldBounds.center.dy, 1));
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
    final auto = find.widgetWithText(SwitchListTile, 'Fit subtitles automatically');
    expect(tester.widget<SwitchListTile>(auto).value, isTrue);
    expect(binding.frames.last.width, 0);
    chat.textController.text = '仍未发送';
    await tester.tap(auto);
    await tester.pumpAndSettle();
    final sliders = find.descendant(of: settings, matching: find.byType(Slider));
    expect(sliders, findsNWidgets(4));
    await tester.tapAt(tester.getCenter(sliders.at(0)));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(sliders.at(1)));
    await tester.pumpAndSettle();
    final manual = binding.frames.last;
    expect(manual.width, greaterThan(DogShareSubtitleFrame.defaultWidth));
    expect(manual.height, greaterThan(DogShareSubtitleFrame.defaultHeight));
    expect(manual.text, '手动字幕');
    expect(chat.textController.text, '仍未发送');
    chat.clearDraft();
    await tester.tap(auto);
    await tester.pumpAndSettle();
    expect(binding.frames.last.width, 0);
    expect(binding.frames.last.height, 0);
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

    final previousRevision = binding.frames.last.revision;
    chat.subtitleDraft.receivePageStatus(previousRevision, 0, 3);
    await tester.pumpAndSettle();
    final next = find.byTooltip('Next subtitle page');
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(binding.frames.last.page, 1);
    expect(binding.frames.last.text, '手动字幕');
    chat.subtitleDraft.receivePageStatus(previousRevision, 0, 3);
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget);

    final oversized = List.filled(DogShareSubtitleFrame.maxTextUnits + 1, '文').join();
    final beforeOversized = binding.frames.length;
    await tester.enterText(input, oversized);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Subtitle is too long. Send it in parts.'), findsOneWidget);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(chat.textController.text, oversized);
    expect(binding.frames.length, beforeOversized);
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
    expect(composingEnter(), KeyEventResult.ignored);
    expect(chat.textController.text, 'ni');
    expect(binding.frames, hasLength(sentFrames));

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
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(chat.textController.text, '实时草稿\n');
    commit('实时草稿\n第二行');
    await tester.pump(const Duration(milliseconds: 160));
    expect(binding.frames.last.text, '实时草稿\n第二行');
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
