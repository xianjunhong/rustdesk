import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/text_overlay_model.dart';
import 'package:flutter_hbb/models/dogshare_subtitle_frame.dart';
import 'package:flutter_test/flutter_test.dart' hide isWindows;
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
}

class _ReceiverBinding extends _Binding {
  @override
  bool isIncomingOnly({dynamic hint}) => true;

  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';
}

class _Server extends Fake implements ServerModel {
  @override
  final clients = [
    Client(1, true, false, false, 'Peer', 'peer-a', true, true, true)
  ];
  @override
  final tabController = DesktopTabController(tabType: DesktopTabType.cm)
    ..state
        .value
        .tabs
        .add(TabInfo(key: '1', label: 'Peer', page: const SizedBox()));
  @override
  void jumpTo(int id) => fail('Subtitle messages must not switch CM tabs');
}

class _Session extends Fake implements FFI {
  @override
  final SessionID sessionId = const Uuid().v4obj();
  @override
  final serverModel = _Server();
}

class _Chat extends ChatModel {
  _Chat(FFI session) : super(WeakReference(session));
  @override
  Future<void> showChatPage(MessageKey key) async =>
      fail('Subtitle messages must not open the chat page');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('paired subtitle mode closes B chat without raising the window',
      () async {
    platformFFI.setBindingForTesting(_ReceiverBinding());
    final previousType = desktopType;
    final previousIsTest = isTest;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    desktopType = DesktopType.cm;
    isTest = true;
    const windows = MethodChannel('window_manager');
    const screens = MethodChannel('screen_retriever');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <String>[];
    messenger.setMockMethodCallHandler(windows, (call) async {
      requests.add(call.method);
      if (call.method == 'isMinimized') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(screens, (call) async {
      if (call.method == 'getAllDisplays') return {'displays': []};
      if (call.method == 'getCursorScreenPoint') return {'x': 0.0, 'y': 0.0};
      return {
        'id': 1,
        'size': {'width': 1920.0, 'height': 1080.0}
      };
    });
    addTearDown(() {
      desktopType = previousType;
      isTest = previousIsTest;
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(windows, null);
      messenger.setMockMethodCallHandler(screens, null);
    });

    await initGlobalFFI();
    final chat = gFFI.chatModel;
    final client =
        Client(1, true, false, false, 'Peer', 'peer-a', true, true, true);
    gFFI.serverModel.clients.add(client);
    gFFI.serverModel.tabController.state.value.tabs
        .add(TabInfo(key: '1', label: 'Peer', page: const SizedBox()));
    final key = MessageKey(client.peerId, client.id);
    await chat.toggleCMChatPage(key);
    expect(chat.isShowCMSidePage, isTrue);
    requests.clear();

    void setCaptions(bool enabled) => chat.receiveRemoteSubtitle({
          'id': '1',
          'frame': DogShareSubtitleFrame(
            enabled: enabled,
            text: '',
            fontSize: 16,
            fontFamily: 'Microsoft YaHei',
            color: 0xffffffff,
          ).encode(),
        });
    setCaptions(true);
    await pumpEventQueue();
    expect(chat.isShowCMSidePage, isFalse);
    await chat.toggleCMChatPage(key);
    expect(chat.isShowCMSidePage, isFalse);
    expect(requests, isNot(contains('show')));

    setCaptions(false);
    await chat.toggleCMChatPage(key);
    expect(chat.isShowCMSidePage, isTrue);
  });
  test('CM subtitles keep chat history without raising windows', () async {
    platformFFI.setBindingForTesting(_Binding());
    final previousType = desktopType;
    desktopType = DesktopType.cm;
    final session = _Session();
    final chat = _Chat(session);
    final key = MessageKey('peer-a', 1);
    final overlay = TextOverlayModel.instance;
    final source = chat.textOverlaySource(key);
    const channel = MethodChannel('dogshare/text_overlay');
    const windows = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(windows,
        (call) async => fail('Unexpected window request: ' + call.method));
    addTearDown(() async {
      await overlay.disable(source);
      chat.dispose();
      chat.inputNode.dispose();
      session.serverModel.tabController.state.value.pageController.dispose();
      desktopType = previousType;
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(windows, null);
    });
    await overlay.enable(source: source, label: 'Peer', placeholder: 'Waiting');
    calls.clear();

    await chat.receive(1, 'CM subtitle regression');
    await pumpEventQueue();

    expect(
        chat.messages[key]!.chatMessages.single.text, 'CM subtitle regression');
    expect(chat.latestReceivedKey, key);
    expect(chat.isShowCMSidePage, isFalse);
    expect(calls.single.method, 'show');
    expect(calls.single.arguments['source'], source);
    expect(calls.single.arguments['text'], 'CM subtitle regression');
  }, skip: !isWindows);
}
