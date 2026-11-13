import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../native/dogshare_account_stub.dart'
    if (dart.library.io) '../native/dogshare_account.dart' as native;

const dogShareAccountServer = 'https://phenoseed.com/dogshare-account';
const dogShareSignInRequired =
    'Sign in to DogShare to use remote control and subtitles.';
const dogShareAccountUnavailable =
    'DogShare account verification failed. Sign in again.';
const dogShareCredentialStoreFailed = 'Unable to store account credential';
const dogShareCredentialClearFailed =
    'Unable to clear account credential. Check local storage permissions.';

class DogShareAccountGate extends ChangeNotifier {
  static final instance = DogShareAccountGate();
  static bool get isRequired =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  final Future<String> Function() _refreshNative;
  final String Function() _snapshotNative;
  final bool Function() _overlayAllowedNative;
  final VoidCallback _invalidateNative;
  Timer? _timer;
  Future<bool>? _pending;
  int _generation = 0;
  bool _authorized = false;
  int _expiresAt = 0;
  String error = '';
  Map<String, dynamic>? user;

  DogShareAccountGate({
    Future<String> Function()? refresh,
    String Function()? snapshot,
    bool Function()? overlayAllowed,
    VoidCallback? invalidate,
  })  : _refreshNative = refresh ?? native.refresh,
        _snapshotNative = snapshot ?? native.snapshot,
        _overlayAllowedNative = overlayAllowed ?? native.overlayAllowed,
        _invalidateNative = invalidate ?? native.invalidate;

  bool get authorized =>
      !isRequired ||
      (_authorized &&
          _expiresAt > DateTime.now().millisecondsSinceEpoch ~/ 1000);

  void initialize() {
    if (!isRequired || _timer != null) return;
    readSnapshot();
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(refresh());
    });
  }

  bool readSnapshot() {
    if (!isRequired) return true;
    try {
      _apply(_snapshotNative());
    } catch (_) {
      _deny(dogShareAccountUnavailable);
    }
    return authorized;
  }

  bool get overlayAllowed {
    if (!isRequired) return true;
    if (!readSnapshot()) return false;
    try {
      if (_overlayAllowedNative()) return true;
    } catch (_) {}
    _deny(dogShareAccountUnavailable);
    return false;
  }

  Future<bool> refresh() {
    if (!isRequired) return Future.value(true);
    return _pending ??= _refresh(_generation);
  }

  Future<bool> _refresh(int generation) async {
    try {
      final result = await _refreshNative();
      if (generation == _generation) _apply(result);
    } catch (_) {
      if (generation == _generation) _deny(dogShareAccountUnavailable);
    } finally {
      if (generation == _generation) _pending = null;
    }
    return generation == _generation && authorized;
  }

  void invalidate() {
    ++_generation; // An in-flight refresh must not restore a logged-out lease.
    _pending = null;
    try {
      if (isRequired) _invalidateNative();
    } catch (_) {}
    _deny(dogShareSignInRequired);
  }

  void _apply(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final expiresAt = data['expires_at'] as int? ?? 0;
    final allowed = data['authorized'] == true &&
        expiresAt > DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = (data['error'] as String?) ?? '';
    final changed =
        _authorized != allowed || _expiresAt != expiresAt || error != message;
    _authorized = allowed;
    _expiresAt = expiresAt;
    error = message;
    user = allowed && data['user'] is Map<String, dynamic>
        ? data['user'] as Map<String, dynamic>
        : null;
    if (changed) notifyListeners();
  }

  void _deny(String message) {
    _authorized = false;
    _expiresAt = 0;
    user = null;
    error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
