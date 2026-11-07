import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/text_overlay_model.dart';
import 'package:flutter_hbb/models/tomdesk_subtitle_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tomdesk/text_overlay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final model = TextOverlayModel.instance;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() async {
    await model.disable('peer-a');
    await model.disable('peer-b');
    await model.updateStyle(
      fontSize: 32,
      color: 0xffffd54f,
      fontFamily: 'Microsoft YaHei',
      opacity: 1.0,
      width: 640,
      height: 360,
    );
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('incoming chat is displayed only for an explicitly enabled source',
      () async {
    await model.receive(source: 'peer-a', text: 'Hidden', label: 'Alice');
    expect(calls, isEmpty);

    await model.enable(
        source: 'peer-a', label: 'Alice', placeholder: 'Waiting');
    calls.clear();
    await model.receive(source: 'peer-b', text: 'Other peer', label: 'Bob');
    await model.disable('peer-b');
    expect(calls, isEmpty);
    await model.receive(source: 'peer-a', text: '你好\nHello', label: 'Alice');
    expect(calls.single.method, 'show');
    expect(calls.single.arguments['text'], '你好\nHello');
    expect(calls.single.arguments['source'], 'peer-a');

    calls.clear();
    await model.updateStyle(opacity: 0);
    expect(calls.single.method, 'show');
    expect(calls.single.arguments['opacity'], 0.0);
  });

  test('updated overlay dimensions persist across incoming subtitles', () async {
    await model.enable(
        source: 'peer-a', label: 'Alice', placeholder: 'Waiting');
    calls.clear();
    await model.updateStyle(width: 1200, height: 240);
    expect(calls.single.method, 'show');
    expect(calls.single.arguments['width'], 1200.0);
    expect(calls.single.arguments['height'], 240.0);

    calls.clear();
    await model.receive(source: 'peer-a', text: 'Updated text', label: 'Alice');
    expect(calls.single.method, 'show');
    expect(calls.single.arguments['text'], 'Updated text');
    expect(calls.single.arguments['width'], 1200.0);
    expect(calls.single.arguments['height'], 240.0);
  });

  test('closing the native window stops subsequent incoming subtitles', () async {
    await model.enable(
        source: 'peer-a', label: 'Alice', placeholder: 'Waiting');
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('closed', {'source': 'peer-a'})),
      (_) {},
    );
    calls.clear();
    await model.receive(source: 'peer-a', text: 'Later', label: 'Alice');
    expect(model.enabledFor('peer-a'), isFalse);
    expect(calls, isEmpty);
  });

  test('paired frames replace styled subtitles and clear the card', () async {
    TomDeskSubtitleFrame frame(String text, {bool enabled = true}) =>
        TomDeskSubtitleFrame(
          enabled: enabled,
          text: text,
          fontSize: 96,
          fontFamily: 'SimHei',
          color: 0x80ab12cd,
        );

    await model.receiveRemoteSubtitle(source: 'peer-a', frame: frame('第一版'));
    await model.receiveRemoteSubtitle(source: 'peer-a', frame: frame('定稿'));
    await model.receive(source: 'peer-a', text: 'Ordinary chat', label: 'Peer');
    await model.receiveRemoteSubtitle(
        source: 'peer-b', frame: frame('', enabled: false));
    expect(calls.map((call) => call.method), ['show', 'show']);
    final displayed = calls.last.arguments as Map;
    expect(displayed['text'], '定稿');
    expect(displayed['fontSize'], 96.0);
    expect(displayed['fontFamily'], 'SimHei');
    expect(displayed['color'], 0x80ab12cd);
    expect(displayed['pairedCard'], isTrue);

    await model.receiveRemoteSubtitle(source: 'peer-a', frame: frame(''));
    expect(calls.last.method, 'hide');
    expect(model.enabledFor('peer-a'), isFalse);

    await model.receiveRemoteSubtitle(source: 'peer-a', frame: frame('恢复'));
    await model.receiveRemoteSubtitle(
        source: 'peer-a', frame: frame('不显示', enabled: false));
    expect(calls.last.method, 'hide');
    expect(model.enabledFor('peer-a'), isFalse);
  });

  test('native errors disable the overlay and give the user a retry message',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'window_creation_failed');
    });
    await model.enable(
        source: 'peer-a', label: 'Alice', placeholder: 'Waiting');
    expect(model.enabledFor('peer-a'), isFalse);
    expect(model.error, 'Text overlay failed. Turn it on again to retry.');
  });
}
