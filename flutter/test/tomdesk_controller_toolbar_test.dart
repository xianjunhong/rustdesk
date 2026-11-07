import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  _Binding({this.outgoingOnly = true});
  final bool outgoingOnly;
  final styles = <String>[];
  bool viewOnly = false;
  bool voiceMuted = true;
  String microphone = 'Default microphone';
  int voiceRequests = 0;
  int voiceStops = 0;

  @override
  String mainGetLocalOption({required String key, dynamic hint}) {
    if (key == kOptionHideRecordingButton) return 'Y';
    if (key == kOptionRemoteMenubarDragLeft) return '0.0';
    if (key == kOptionRemoteMenubarDragRight) return '1.0';
    return '';
  }

  @override
  int versionToNumber({required String v, dynamic hint}) =>
      v.split('.').fold(0, (n, part) => n * 1000 + int.parse(part));

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';

  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
    dynamic hint,
  }) async {}

  @override
  bool isIncomingOnly({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => outgoingOnly;

  @override
  String translate({
    required String name,
    required String locale,
    dynamic hint,
  }) =>
      name;

  @override
  Future<String?> sessionGetOption({
    required UuidValue sessionId,
    required String arg,
    dynamic hint,
  }) async =>
      null;

  @override
  Future<bool?> sessionGetToggleOption({
    required UuidValue sessionId,
    required String arg,
    dynamic hint,
  }) async =>
      (arg == kOptionToggleViewOnly || arg == kOptionToggleShowMyCursor) &&
      viewOnly;

  @override
  bool sessionGetToggleOptionSync({
    required UuidValue sessionId,
    required String arg,
    dynamic hint,
  }) =>
      arg == 'disable-audio' && voiceMuted;

  @override
  bool mainAudioSupportLoopback({dynamic hint}) => false;

  @override
  Future<List<String>> mainGetSoundInputs({dynamic hint}) async =>
      ['Default microphone', 'USB microphone'];

  @override
  Future<String> getVoiceCallInputDevice(
      {required bool isCm, dynamic hint}) async {
    expect(isCm, isFalse);
    return microphone;
  }

  @override
  Future<void> setVoiceCallInputDevice({
    required bool isCm,
    required String device,
    dynamic hint,
  }) async {
    expect(isCm, isFalse);
    microphone = device;
  }

  @override
  Future<void> sessionToggleOption({
    required UuidValue sessionId,
    required String value,
    dynamic hint,
  }) async {
    if (value == 'disable-audio') {
      voiceMuted = !voiceMuted;
    } else {
      expect(value, kOptionToggleViewOnly);
      viewOnly = !viewOnly;
    }
  }

  @override
  Future<void> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
    dynamic hint,
  }) async {}

  @override
  Future<void> sessionSetViewStyle({
    required UuidValue sessionId,
    required String value,
    dynamic hint,
  }) async {
    styles.add(value);
  }

  @override
  Future<void> sessionRequestVoiceCall({
    required UuidValue sessionId,
    dynamic hint,
  }) async {
    voiceRequests++;
  }

  @override
  Future<void> sessionCloseVoiceCall({
    required UuidValue sessionId,
    dynamic hint,
  }) async {
    voiceStops++;
  }
}

class _Canvas extends Fake implements CanvasModel {
  int updates = 0;

  @override
  Future<void> updateViewStyle({refreshMousePos = true, notify = true}) async {
    updates++;
  }
}

class _Input extends Fake implements InputModel {
  @override
  void refreshMousePos() {}

  @override
  bool setRelativeMouseMode(bool enabled) => true;
}

class _Dialogs extends OverlayDialogManager {
  int shown = 0;

  @override
  Future<T?> show<T>(DialogBuilder builder,
      {bool clickMaskDismiss = false,
      bool backDismiss = false,
      String? tag,
      bool useAnimation = true,
      bool forceGlobal = false}) async {
    shown++;
    return null;
  }
}

class _Recording extends RecordingModel {
  _Recording(super.parent);

  @override
  Future<void> toggle() async => updateStatus(!start);
}

class _Session extends Fake implements FFI {
  @override
  final sessionId = const Uuid().v4obj();

  @override
  ConnType get connType => ConnType.defaultConn;

  @override
  late final ffiModel = FfiModel(WeakReference<FFI>(this));

  @override
  late final chatModel = ChatModel(WeakReference<FFI>(this));

  @override
  final _Dialogs dialogManager = _Dialogs();

  @override
  final _Canvas canvasModel = _Canvas();

  @override
  final inputModel = _Input();

  @override
  late final recordingModel = _Recording(WeakReference<FFI>(this));
}

void main() {
  testWidgets('A hides only elevation menu and elevation messages',
      (tester) async {
    platformFFI.setBindingForTesting(_Binding());
    final session = _Session();
    final peer = session.ffiModel.pi
      ..platform = kPeerPlatformWindows
      ..sasEnabled = false;
    final elevation = ElevationModel(WeakReference<FFI>(session))
      ..onPeerInfo(peer);
    expect(elevation.showRequestMenu, isFalse);

    void event(String type, {String title = 'Prompt', String text = ''}) {
      session.ffiModel.handleMsgBox({
        'type': type,
        'title': title,
        'text': text,
        'link': '',
      }, session.sessionId, 'test-peer');
    }

    for (final type in [
      'on-uac',
      'on-foreground-elevated',
      'wait-uac',
      'elevation-error',
    ]) {
      event(type);
    }
    event('custom-nocancel-success',
        title: 'Successful', text: 'Elevate successfully');
    expect(session.dialogManager.shown, 0);
    event('wait-remote-accept-nook');
    expect(session.dialogManager.shown, 1);

    platformFFI.setBindingForTesting(_Binding(outgoingOnly: false));
    expect(elevation.showRequestMenu, isTrue);
    event('on-uac');
    expect(session.dialogManager.shown, 2);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'paired controller keeps its remote controls and red close button',
      (tester) async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    final session = _Session();
    session.ffiModel.pi
      ..version = '1.4.6'
      ..isSet.value = true;
    final toolbar = ToolbarState();

    await tester.pumpWidget(MaterialApp(
      theme: MyTheme.lightTheme,
      home: Scaffold(
        body: MultiProvider(
          providers: [
            ChangeNotifierProvider<FfiModel>.value(value: session.ffiModel),
            ChangeNotifierProvider<RecordingModel>.value(
                value: session.recordingModel),
          ],
          child: RemoteToolbar(
            id: 'paired-receiver',
            ffi: session,
            state: toolbar,
            onEnterOrLeaveImageSetter: (_, __) {},
            onEnterOrLeaveImageCleaner: (_) {},
            setRemoteState: (callback) => callback(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    for (final tooltip in [
      'Pin Toolbar',
      'Scale adaptive',
      'Input Control',
      'Chat',
      'Start session recording',
      'Close',
    ]) {
      expect(find.byTooltip(tooltip), findsWidgets);
    }
    for (final tooltip in [
      'Fullscreen',
      'Display Settings',
      'Keyboard Settings',
      'Control Actions',
    ]) {
      expect(find.byTooltip(tooltip), findsNothing);
    }

    Future<void> tap(Finder finder) async {
      await tester.tap(finder.first);
      await tester.pumpAndSettle();
    }

    await tap(find.byTooltip('Pin Toolbar'));
    expect(find.byTooltip('Unpin Toolbar'), findsWidgets);
    await tap(find.byTooltip('Scale adaptive'));
    expect(binding.styles, [kRemoteViewStyleAdaptive]);
    expect(session.canvasModel.updates, 1);

    await tap(find.byTooltip('Input Control'));
    expect(find.text('Control Remote Desktop'), findsOneWidget);
    await tap(find.text('View Mode'));
    expect(session.ffiModel.viewOnly, isTrue);
    expect(session.ffiModel.showMyCursor, isTrue);
    await tap(find.byTooltip('Input Control'));
    await tap(find.text('Control Remote Desktop'));
    expect(session.ffiModel.viewOnly, isFalse);
    expect(session.ffiModel.showMyCursor, isFalse);

    final mute = find.widgetWithText(CheckboxMenuButton, 'Mute');
    await tap(find.byTooltip('Chat'));
    expect(find.text('Text chat'), findsOneWidget);
    expect(tester.widget<CheckboxMenuButton>(mute).value, isTrue);
    expect(binding.voiceMuted, isTrue);
    await tap(find.text('Mute'));
    expect(binding.voiceMuted, isFalse);

    await tap(find.byTooltip('Chat'));
    expect(mute, findsNothing);
    await tap(find.text('Voice call'));
    expect(binding.voiceRequests, 1);
    session.chatModel.voiceCallStatus.value =
        VoiceCallStatus.waitingForResponse;
    await tester.pumpAndSettle();
    await tap(find.byTooltip('Chat'));
    expect(find.text('Voice call: Waiting'), findsOneWidget);
    expect(find.text('Stop voice call'), findsNothing);
    expect(find.text('Audio Input Device'), findsNothing);
    await tap(find.text('Cancel'));
    expect(binding.voiceStops, 1);

    session.chatModel.voiceCallStatus.value = VoiceCallStatus.connected;
    await tester.pumpAndSettle();
    await tap(find.byTooltip('Chat'));
    expect(find.text('Voice call: Connected'), findsOneWidget);
    expect(tester.widget<CheckboxMenuButton>(mute).value, isFalse);
    await tap(find.text('Mute'));
    expect(binding.voiceMuted, isTrue);

    await tap(find.byTooltip('Chat'));
    expect(tester.widget<CheckboxMenuButton>(mute).value, isTrue);
    await tap(find.text('Mute'));
    expect(binding.voiceMuted, isFalse);

    await tap(find.byTooltip('Chat'));
    await tap(find.text('Audio Input Device'));
    await tap(find.text('USB microphone'));
    expect(binding.microphone, 'USB microphone');

    await tap(find.byTooltip('Chat'));
    await tap(find.text('Stop voice call'));
    expect(binding.voiceStops, 2);

    await tap(find.byTooltip('Start session recording'));
    expect(find.byTooltip('Stop session recording'), findsWidgets);
    await tap(find.byTooltip('Stop session recording'));
    expect(find.byTooltip('Start session recording'), findsWidgets);
    await tester.pump(const Duration(seconds: 6));
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
