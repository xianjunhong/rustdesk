import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/dogshare_account_gate.dart';
import 'package:flutter_hbb/models/dogshare_role.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Binding extends Fake implements RustdeskImpl {
  _Binding(this.role, this.token, {this.language = 'en'});

  final String? role;
  final String language;
  String token;
  int writes = 0;

  @override
  bool isIncomingOnly({dynamic hint}) => role == 'receiver';

  @override
  bool isOutgoingOnly({dynamic hint}) => role == 'controller';

  @override
  Future<String> mainGetApiServer({dynamic hint}) async => role == null
      ? dogShareAccountServer
      : 'https://phenoseed.com/dogshare-paired-account';

  @override
  String mainGetLoginDeviceInfo({dynamic hint}) => '{}';

  @override
  String mainGetLocalOption({required String key, dynamic hint}) =>
      key == 'access_token' ? token : key == 'lang' ? language : '';

  @override
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
    dynamic hint,
  }) async {
    writes++;
    if (key == 'access_token') token = value;
  }
}

class _Parent extends Fake implements FFI {}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<LoginResponse> login(_Binding binding, MockClient client) {
    platformFFI.setBindingForTesting(binding);
    final parent = _Parent();
    final model = UserModel(WeakReference<FFI>(parent));
    return http.runWithClient(
      () => model.login(LoginRequest(
        username: 'test-account',
        password: 'test-password',
        id: 'test-device',
        uuid: 'test-device-uuid',
        autoLogin: true,
        type: HttpType.kAuthReqTypeAccount,
      )),
      () => client,
    );
  }

  for (final role in ['controller', 'receiver']) {
    test('$role signs in without prior credentials and keeps them after denial',
        () async {
      final binding = _Binding(role, 'test-prior-token');
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://phenoseed.com/dogshare-paired-account/api/login',
        );
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['client_role'], role);
        expect(body.containsKey('access_token'), isFalse);
        expect(body.values, isNot(contains('test-prior-token')));
        return http.Response('{"code":"invalid_credentials"}', 401);
      });
      await expectLater(
        login(binding, client),
        throwsA(isA<RequestException>()
            .having((error) => error.statusCode, 'status', 401)
            .having((error) => error.cause, 'cause', 'Wrong credentials')),
      );
      expect(binding.token, 'test-prior-token');
      expect(binding.writes, 0);
    });
  }

  for (final (role, token) in [
    ('receiver', ''),
    ('receiver', 'test-prior-token'),
    ('controller', 'test-prior-token'),
    (null, 'test-unpaired-token'),
  ]) {
    test('no prior Bearer when role=$role or credential is empty', () async {
      final binding = _Binding(role, token);
      final client = MockClient((request) async {
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response(jsonEncode({
          'type': 'access_token',
          'access_token': 'test-new-token',
          'user': {
            'name': 'test-account',
            'status': 1,
            if (role != null) 'role': role,
          },
        }), 200);
      });
      final response = await login(binding, client);
      expect(response.access_token, 'test-new-token');
      expect(binding.token, token);
      expect(binding.writes, 0);
    });
  }

  test('a response for the wrong role cannot replace the prior token', () async {
    final binding = _Binding('receiver', 'test-prior-token');
    final client = MockClient((_) async => http.Response(
        '{"type":"access_token","access_token":"test-wrong-role",'
        '"user":{"name":"test-account","role":"controller","status":1}}',
        200));
    await expectLater(
      login(binding, client),
      throwsA(isA<RequestException>()
          .having((error) => error.cause, 'cause', dogShareRoleMismatch)),
    );
    expect(binding.token, 'test-prior-token');
    expect(binding.writes, 0);
  });

  for (final (code, status, english, chinese) in [
    ('device_bound', 409, 'This computer is bound', '本机已绑定其他账号'),
    ('pair_expired', 403, 'This account pair has expired', '此账号配对已过期'),
    ('rate_limited', 429, 'Too many sign-in attempts', '登录尝试过多'),
  ]) {
    test('paired login explains $code without displaying the response', () async {
      final binding = _Binding('receiver', 'test-prior-token', language: 'zh-cn');
      final client = MockClient((_) async => http.Response(
          jsonEncode({'code': code, 'error': 'test-raw-server-detail'}), status));
      await expectLater(
        login(binding, client),
        throwsA(isA<RequestException>()
            .having((error) => error.cause, 'safe English cause', startsWith(english))
            .having((error) => dogShareLoginErrorText(error.cause),
                'Chinese cause', startsWith(chinese))),
      );
      expect(binding.writes, 0);
    });
  }
}
