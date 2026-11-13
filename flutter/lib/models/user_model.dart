import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as account_http;

import '../common.dart';
import '../utils/http_service.dart' as http;
import 'model.dart';
import 'platform_model.dart';
import 'dogshare_account_gate.dart';
import 'dogshare_role.dart';
import 'text_overlay_model.dart';

bool refreshingUser = false;

typedef _PairedDevice = ({String? targetId, bool? online});

const _dogShareDeviceBound =
    'This computer is bound to another account. Sign in with that account or contact your administrator.';
const _dogSharePairExpired =
    'This account pair has expired. Ask your administrator to renew it.';
const _dogShareLoginRateLimited =
    'Too many sign-in attempts. Try again later.';

String dogShareLoginErrorText(String cause) {
  final chinese = switch (cause) {
    _dogShareDeviceBound => (
        '本机已绑定其他账号。请用原账号登录，或联系管理员。',
        '本機已綁定其他帳號。請使用原帳號登入，或聯絡管理員。',
      ),
    _dogSharePairExpired => ('此账号配对已过期，请联系管理员续期。', '此帳號配對已過期，請聯絡管理員續期。'),
    _dogShareLoginRateLimited => ('登录尝试过多，请稍后再试。', '登入嘗試過多，請稍後再試。'),
    _ => null,
  };
  if (chinese == null) return translate(cause);

  final configured = bind.mainGetLocalOption(key: 'lang').toLowerCase();
  final language = (configured.isEmpty || configured == 'default'
          ? localeName.toString().toLowerCase()
          : configured)
      .replaceAll('_', '-');
  if (!language.startsWith('zh')) return cause;
  return language.contains('hant') ||
          language.contains('-tw') ||
          language.contains('-hk') ||
          language.contains('-mo')
      ? chinese.$2
      : chinese.$1;
}

class UserModel {
  final RxString userName = ''.obs;
  final RxString displayName = ''.obs;
  final RxString avatar = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString networkError = ''.obs;
  // True when networkError carries a server-reported error rather than a
  // connectivity failure; netWorkErrorWidget hides the network tip then.
  final RxBool networkErrorFromServer = false.obs;
  bool get isLogin => DogShareAccountGate.isRequired
      ? DogShareAccountGate.instance.authorized : userName.isNotEmpty;
  String get displayNameOrUserName =>
      displayName.value.trim().isEmpty ? userName.value : displayName.value;
  String get accountLabelWithHandle {
    final username = userName.value.trim();
    if (username.isEmpty) {
      return '';
    }
    final preferred = displayName.value.trim();
    if (preferred.isEmpty || preferred == username) {
      return username;
    }
    return '$preferred (@$username)';
  }

  WeakReference<FFI> parent;

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
    });
  }

  void updateDogShareAccount() {
    final account = DogShareAccountGate.instance;
    if (account.authorized && account.user != null) {
      _parseAndUpdateUser(UserPayload.fromJson(account.user!));
      networkError.value = '';
    } else {
      userName.value = '';
      displayName.value = '';
      avatar.value = '';
      isAdmin.value = false;
      networkError.value = account.error.isEmpty
          ? dogShareSignInRequired : account.error;
    }
  }

  void refreshCurrentUser() async {
    if (DogShareAccountGate.isRequired) {
      await DogShareAccountGate.instance.refresh();
      return;
    }
    if (bind.isDisableAccount()) return;
    networkError.value = '';
    networkErrorFromServer.value = false;
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token == '') {
      await updateOtherModels();
      return;
    }
    _updateLocalUserInfo();
    final url = await accountApiServer();
    final body = {
      'id': await bind.mainGetMyId(),
      'uuid': await bind.mainGetUuid()
    };
    if (refreshingUser) return;
    try {
      refreshingUser = true;
      final http.Response response;
      try {
        response = await http.post(Uri.parse('$url/api/currentUser'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token'
            },
            body: json.encode(body));
      } catch (e) {
        networkError.value = e.toString();
        rethrow;
      }
      refreshingUser = false;
      final status = response.statusCode;
      if (status == 401 || status == 400) {
        reset(resetOther: status == 401);
        return;
      }
      final data = json.decode(decode_http_response(response));
      final error = data['error'];
      if (error != null) {
        // The only failure known to come from the server itself, so the
        // check-your-network tip does not apply. Flag before the message is
        // set in the catch below so rebuilds read a consistent pair.
        networkErrorFromServer.value = true;
        throw error;
      }

      final user = UserPayload.fromJson(data);
      _parseAndUpdateUser(user);
    } catch (e) {
      debugPrint('Failed to refreshCurrentUser: $e');
      // Surface failures in the address book / group tabs, which offer a
      // retry. Anything not flagged above -- transport errors, non-JSON or
      // unexpected-schema bodies (e.g. a filter's block page) -- keeps the
      // check-your-network tip.
      if (networkError.value.isEmpty) {
        networkError.value = e.toString();
      }
    } finally {
      refreshingUser = false;
      await updateOtherModels();
    }
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (e) {
      debugPrint('Failed to get local user info "$userInfo": $e');
    }
    return null;
  }

  _updateLocalUserInfo() {
    final userInfo = getLocalUserInfo();
    if (userInfo != null) {
      userName.value = (userInfo['name'] ?? '').toString();
      displayName.value = (userInfo['display_name'] ?? '').toString();
      avatar.value = (userInfo['avatar'] ?? '').toString();
    }
  }

  Future<void> reset({bool resetOther = false}) async {
    if (DogShareAccountGate.isRequired) {
      DogShareAccountGate.instance.invalidate();
      final overlay = TextOverlayModel.instance;
      final source = overlay.source;
      if (source != null) await overlay.disable(source);
    }
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: 'user_info', value: '');
    if (resetOther) {
      await gFFI.abModel.reset();
      await gFFI.groupModel.reset();
    }
    userName.value = '';
    displayName.value = '';
    avatar.value = '';
    if (DogShareAccountGate.isRequired &&
        bind.mainGetLocalOption(key: 'access_token').isNotEmpty) {
      throw StateError(dogShareCredentialClearFailed);
    }
  }

  _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    displayName.value = user.displayName;
    avatar.value = user.avatar;
    isAdmin.value = user.isAdmin;
    bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb) {
      // ugly here, tmp solution
      bind.mainSetLocalOption(key: 'verifier', value: user.verifier ?? '');
    }
  }

  // update ab and group status
  static Future<void> updateOtherModels() async {
    if (DogShareAccountGate.isRequired) return;
    await Future.wait([
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false),
      gFFI.groupModel.pull()
    ]);
  }

  Future<account_http.Response> _postDogShareAccount(
      String endpoint, Map<String, dynamic> body, {String? token}) async {
    final client = account_http.Client();
    try {
      final server = await accountApiServer();
      final request = account_http.Request(
          'POST', Uri.parse('$server/api/$endpoint'))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      // Account secrets must not use the generic Rust HTTP TLS fallback.
      return await client.send(request)
          .then(account_http.Response.fromStream)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw RequestException(0, dogShareAccountUnavailable);
    } finally {
      client.close();
    }
  }

  Future<_PairedDevice>? _pairedDeviceRequest;
  String? _pairedDeviceRequestToken;

  Future<String?> pairedDevice() async {
    if (!isDogShareController) {
      throw RequestException(403, dogShareRoleMismatch);
    }
    if (!await DogShareAccountGate.instance.refresh()) {
      throw RequestException(401, dogShareSignInRequired);
    }
    return (await _lookupPairedDevice()).targetId;
  }

  Future<bool?> pairedDeviceOnline() async {
    if (!isDogShareController || !isLogin) return null;
    return (await _lookupPairedDevice()).online;
  }

  bool _isCurrentPairedDeviceToken(String token) =>
      isLogin && token == bind.mainGetLocalOption(key: 'access_token');

  Future<_PairedDevice> _lookupPairedDevice() async {
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (!isLogin || token.isEmpty) {
      throw RequestException(401, dogShareSignInRequired);
    }
    // Opening a connection can use a lookup already in flight for this login.
    // A later connection attempt still performs a fresh lookup.
    final inFlight = _pairedDeviceRequest;
    if (inFlight != null && _pairedDeviceRequestToken == token) {
      return inFlight;
    }
    final request = _fetchPairedDevice(token);
    _pairedDeviceRequest = request;
    _pairedDeviceRequestToken = token;
    try {
      return await request;
    } finally {
      if (identical(_pairedDeviceRequest, request)) {
        _pairedDeviceRequest = null;
        _pairedDeviceRequestToken = null;
      }
    }
  }

  Future<_PairedDevice> _fetchPairedDevice(String token) async {
    final id = await bind.mainGetMyId();
    final uuid = await bind.mainGetUuid();
    if (!_isCurrentPairedDeviceToken(token)) {
      throw RequestException(401, dogShareSignInRequired);
    }
    final response = await _postDogShareAccount('dogshare/paired-device', {
      'id': id,
      'uuid': uuid,
    }, token: token);
    if (!_isCurrentPairedDeviceToken(token)) {
      throw RequestException(401, dogShareSignInRequired);
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map) throw const FormatException();
      if (response.statusCode != 200) {
        final message = body['code'] == 'pair_required' || body['code'] == 'pair_disabled'
            ? dogSharePairUnavailable
            : body['code'] == 'role_mismatch'
                ? dogShareRoleMismatch : dogShareAccountUnavailable;
        throw RequestException(response.statusCode, message);
      }
      if (!body.containsKey('target_id')) throw const FormatException();
      final target = body['target_id'];
      if (target != null && (target is! String || target.trim().isEmpty)) {
        throw const FormatException();
      }
      final online = body['online'];
      return (targetId: target as String?, online: online is bool ? online : null);
    } on RequestException {
      rethrow;
    } catch (_) {
      throw RequestException(0, dogShareAccountUnavailable);
    }
  }

  Future<LoginResponse> _loginDogShare(LoginRequest request) async {
    final clientRole = dogShareClientRole;
    final response = await _postDogShareAccount(
      'login',
      request.toJson(),
    );
    if (response.statusCode != 200) {
      var message = dogShareAccountUnavailable;
      try {
        final error = jsonDecode(utf8.decode(response.bodyBytes));
        final code = error is Map ? error['code'] : null;
        message = switch (code) {
          'role_mismatch' => dogShareRoleMismatch,
          'pair_required' || 'pair_disabled' => dogSharePairUnavailable,
          'invalid_credentials' => 'Wrong credentials',
          'device_bound' => _dogShareDeviceBound,
          'pair_expired' => _dogSharePairExpired,
          'rate_limited' => _dogShareLoginRateLimited,
          _ => dogShareAccountUnavailable,
        };
      } catch (_) {}
      throw RequestException(response.statusCode, message);
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
      if (body['error'] != null) throw const FormatException();
      final result = LoginResponse.fromJson(body);
      if (result.type != HttpType.kAuthResTypeToken ||
          result.access_token == null || result.access_token!.isEmpty ||
          result.user == null || result.user!.name.isEmpty) {
        throw const FormatException();
      }
      if (clientRole != null && result.user!.role != clientRole) {
        throw RequestException(403, dogShareRoleMismatch);
      }
      return result;
    } on RequestException {
      rethrow;
    } catch (_) {
      // Parsing exceptions can contain response fragments, including tokens.
      throw RequestException(0, dogShareAccountUnavailable);
    }
  }

  Future<void> _logOutDogShare() async {
    final token = bind.mainGetLocalOption(key: 'access_token');
    var storageFailed = false;
    try {
      await reset(resetOther: true);
    } catch (_) {
      storageFailed = true;
    }
    try {
      await _postDogShareAccount('logout', {
        'id': await bind.mainGetMyId(),
        'uuid': await bind.mainGetUuid(),
      }, token: token);
    } catch (_) {
      // Local invalidation takes effect even when the server is unreachable.
    }
    if (storageFailed) {
      networkError.value = dogShareCredentialClearFailed;
      BotToast.showText(text: translate(dogShareCredentialClearFailed));
    }
  }

  Future<void> logOut({String? apiServer}) async {
    if (DogShareAccountGate.isRequired) {
      await _logOutDogShare();
      return;
    }
    final tag = gFFI.dialogManager.showLoading(translate('Waiting'));
    try {
      final url = apiServer ?? await accountApiServer();
      final authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      await http
          .post(Uri.parse('$url/api/logout'),
              body: jsonEncode({
                'id': await bind.mainGetMyId(),
                'uuid': await bind.mainGetUuid(),
              }),
              headers: authHeaders)
          .timeout(Duration(seconds: 2));
    } catch (e) {
      debugPrint("request /api/logout failed: err=$e");
    } finally {
      await reset(resetOther: true);
      gFFI.dialogManager.dismissByTag(tag);
    }
  }

  /// throw [RequestException]
  Future<LoginResponse> login(LoginRequest loginRequest) async {
    if (DogShareAccountGate.isRequired) return _loginDogShare(loginRequest);
    final url = await accountApiServer();
    final resp = await http.post(Uri.parse('$url/api/login'),
        body: jsonEncode(loginRequest.toJson()));

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(decode_http_response(resp));
    } catch (e) {
      debugPrint("login: jsonDecode resp body failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
            contentColor: Colors.red, text: 'HTTP ${resp.statusCode}');
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    return getLoginResponseFromAuthBody(body);
  }

  LoginResponse getLoginResponseFromAuthBody(Map<String, dynamic> body) {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    final isLogInDone = loginResponse.type == HttpType.kAuthResTypeToken &&
        loginResponse.access_token != null;
    if (!DogShareAccountGate.isRequired &&
        isLogInDone && loginResponse.user != null) {
      _parseAndUpdateUser(loginResponse.user!);
    }

    return loginResponse;
  }

  /// Throws on network failures, non-success responses, and invalid response
  /// data. Returns an empty list when no API server is configured or a
  /// successful response contains no third-party login options.
  static Future<List<dynamic>> queryOidcLoginOptions() async {
    if (DogShareAccountGate.isRequired) return [];
    final url = await accountApiServer();
    if (url.trim().isEmpty) return [];
    final resp = await http.get(Uri.parse('$url/api/login-options'));
    const successStatusCodeStart = 200;
    const successStatusCodeEnd = 300;
    if (resp.statusCode < successStatusCodeStart ||
        resp.statusCode >= successStatusCodeEnd) {
      throw RequestException(
          resp.statusCode, resp.reasonPhrase ?? 'Request failed');
    }
    final List<String> ops = [];
    for (final item in jsonDecode(resp.body)) {
      ops.add(item as String);
    }
    for (final item in ops) {
      if (item.startsWith('common-oidc/')) {
        return jsonDecode(item.substring('common-oidc/'.length));
      }
    }
    return ops
        .where((item) => item.startsWith('oidc/'))
        .map((item) => {'name': item.substring('oidc/'.length)})
        .toList();
  }
}
