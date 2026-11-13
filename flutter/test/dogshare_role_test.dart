import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/dogshare_account_gate.dart';
import 'package:flutter_hbb/models/dogshare_role.dart';
import 'package:flutter_test/flutter_test.dart';

class _RoleBinding extends Fake implements RustdeskImpl {
  String? role;
  String server = 'https://phenoseed.com/dogshare-paired-account';

  @override
  bool isIncomingOnly({dynamic hint}) => role == 'receiver';
  @override
  bool isOutgoingOnly({dynamic hint}) => role == 'controller';
  @override
  String mainGetLoginDeviceInfo({dynamic hint}) => '{}';
  @override
  Future<String> mainGetApiServer({dynamic hint}) async => server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RoleBinding binding;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    binding = _RoleBinding();
    platformFFI.setBindingForTesting(binding);
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('role builds send their compiled role and accept the paired issuer',
      () async {
    for (final role in ['controller', 'receiver']) {
      binding.role = role;
      final request =
          LoginRequest(username: 'example', id: 'device', uuid: 'uuid');
      expect(request.toJson()['client_role'], role);
      expect(dogShareClientRole, role);
      expect(await accountApiServer(), binding.server);
      expect(
          UserPayload.fromJson({'name': 'example', 'role': role}).role, role);
    }
  });

  test('unrestricted builds preserve the original issuer and role-free login',
      () async {
    binding.server = dogShareAccountServer;
    expect(LoginRequest().toJson().containsKey('client_role'), isFalse);
    expect(dogShareClientRole, isNull);
    expect(await accountApiServer(), dogShareAccountServer);
  });

  test('role account requests reject legacy, HTTP and redirected issuer paths',
      () async {
    binding.role = 'controller';
    for (final server in [
      dogShareAccountServer,
      'http://phenoseed.com/dogshare-paired-account',
      'https://phenoseed.com/dogshare-paired-account/other',
    ]) {
      binding.server = server;
      await expectLater(accountApiServer(), throwsA(isA<RequestException>()));
    }
  });
}
