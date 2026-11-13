import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/text_overlay_model.dart';
import 'package:flutter_hbb/models/dogshare_account_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dogshare/text_overlay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DogShareAccountGate account;
  late TextOverlayModel overlay;
  var allowed = false;
  final calls = <MethodCall>[];

  String snapshot() => jsonEncode({
        'authorized': allowed,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
        'error': allowed ? '' : dogShareSignInRequired,
        'user': {'name': 'test-user'},
      });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    allowed = false;
    calls.clear();
    account = DogShareAccountGate(
      refresh: () async => snapshot(),
      snapshot: snapshot,
      overlayAllowed: () => allowed,
      invalidate: () => allowed = false,
    );
    overlay = TextOverlayModel(account: account);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    overlay.dispose();
    account.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('failed account validation refuses subtitle activation', () async {
    await overlay.enable(source: 'peer', label: 'Peer', placeholder: 'Waiting');
    expect(account.authorized, isFalse);
    expect(overlay.enabledFor('peer'), isFalse);
    expect(overlay.error, dogShareSignInRequired);
    expect(calls, isEmpty);
  });

  test('logout invalidation hides subtitles and refuses later messages',
      () async {
    allowed = true;
    await overlay.enable(source: 'peer', label: 'Peer', placeholder: 'Waiting');
    expect(calls.single.method, 'show');
    calls.clear();
    account.invalidate();
    await pumpEventQueue();
    expect(overlay.enabledFor('peer'), isFalse);
    expect(calls.single.method, 'hide');
    calls.clear();
    await overlay.receive(source: 'peer', label: 'Peer', text: 'Later');
    expect(calls, isEmpty);
  });
}
