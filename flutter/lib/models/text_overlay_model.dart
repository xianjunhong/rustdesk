import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dogshare_account_gate.dart';
import 'dogshare_subtitle_frame.dart';

class TextOverlayModel extends ChangeNotifier {
  static final instance = TextOverlayModel();
  static const _channel = MethodChannel('dogshare/text_overlay');
  static const _maxTextLength = 16000;

  String? _source;
  String _text = '';
  String _label = '';
  bool _remoteControlled = false;
  String? error;
  double fontSize = 32;
  int color = 0xffffd54f;
  String fontFamily = 'Microsoft YaHei';
  double opacity = 1.0;
  double width = 640;
  double height = 360;

  final DogShareAccountGate _account;

  TextOverlayModel({DogShareAccountGate? account})
      : _account = account ?? DogShareAccountGate.instance {
    _account.addListener(_accountChanged);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed' &&
          call.arguments is Map &&
          call.arguments['source'] == _source) {
        _source = null;
        _text = '';
        _remoteControlled = false;
        notifyListeners();
      }
    });
  }

  void _accountChanged() {
    final source = _source;
    if (source != null && !_account.authorized) {
      error = dogShareSignInRequired;
      unawaited(disable(source));
    }
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    super.dispose();
  }

  String? get source => _source;

  bool enabledFor(String source) => _source == source;

  Future<void> enable({
    required String source,
    required String label,
    required String placeholder,
  }) async {
    if (source.isEmpty) return;
    if (!await _account.refresh()) {
      error = dogShareSignInRequired;
      notifyListeners();
      return;
    }
    _source = source;
    _remoteControlled = false;
    _label = label;
    _text = _boundedText(placeholder);
    error = null;
    notifyListeners();
    await _show();
  }

  Future<void> receive({
    required String source,
    required String text,
    required String label,
  }) async {
    if (_remoteControlled || !enabledFor(source) || text.isEmpty) return;
    _text = _boundedText(text);
    _label = label;
    await _show();
  }

  Future<void> receiveRemoteSubtitle({
    required String source,
    required DogShareSubtitleFrame frame,
  }) async {
    if (source.isEmpty) return;
    if (!frame.enabled || frame.text.trim().isEmpty || frame.color >> 24 == 0) {
      await disable(source);
      return;
    }
    _source = source;
    _remoteControlled = true;
    _text = _boundedText(frame.text);
    _label = 'Live subtitles';
    fontSize = frame.fontSize;
    color = frame.color;
    fontFamily = frame.fontFamily;
    error = null;
    if (!_account.authorized) await _account.refresh();
    if (_source == source && _remoteControlled) await _show();
  }

  Future<void> disable(String source) async {
    if (!enabledFor(source)) return;
    _source = null;
    _text = '';
    _remoteControlled = false;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('hide', {'source': source});
    } on PlatformException {
      error = 'Text overlay failed. Turn it on again to retry.';
      notifyListeners();
    } on MissingPluginException {
      error = 'Text overlay is unavailable. Rebuild the Windows app.';
      notifyListeners();
    }
  }

  Future<void> updateStyle({
    double? fontSize,
    int? color,
    String? fontFamily,
    double? opacity,
    double? width,
    double? height,
  }) async {
    if (fontSize != null && fontSize.isFinite) {
      this.fontSize = fontSize.clamp(16.0, 72.0).toDouble();
    }
    if (color != null) this.color = color & 0xffffffff;
    if (fontFamily != null &&
        const ['Microsoft YaHei', 'Segoe UI', 'SimSun'].contains(fontFamily)) {
      this.fontFamily = fontFamily;
    }
    if (opacity != null && opacity.isFinite) {
      this.opacity = opacity.clamp(0.0, 1.0).toDouble();
    }
    if (width != null && width.isFinite) {
      this.width = width.clamp(240.0, 2560.0).toDouble();
    }
    if (height != null && height.isFinite) {
      this.height = height.clamp(80.0, 1440.0).toDouble();
    }
    notifyListeners();
    if (_source != null) await _show();
  }

  Future<void> _show() async {
    final source = _source;
    if (source == null) return;
    if (!_account.overlayAllowed) {
      error = dogShareSignInRequired;
      await disable(source);
      return;
    }
    try {
      await _channel.invokeMethod<void>('show', {
        'source': source,
        'text': _text,
        'label': _label,
        'fontSize': fontSize,
        'color': color,
        'fontFamily': fontFamily,
        'opacity': opacity,
        'width': width,
        'height': height,
        if (_remoteControlled) 'pairedCard': true,
      });
    } on PlatformException {
      _failed(source, 'Text overlay failed. Turn it on again to retry.');
    } on MissingPluginException {
      _failed(source, 'Text overlay is unavailable. Rebuild the Windows app.');
    }
  }

  void _failed(String source, String message) {
    if (_source != source) return;
    _source = null;
    _text = '';
    _remoteControlled = false;
    error = message;
    notifyListeners();
  }

  static String _boundedText(String text) {
    if (text.length <= _maxTextLength) return text;
    var end = _maxTextLength - 1;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return '${text.substring(0, end)}\u2026';
  }
}
