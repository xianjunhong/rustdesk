import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../native/dogshare_subtitle_stub.dart'
    if (dart.library.io) '../native/dogshare_subtitle.dart' as native_subtitle;
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
  DogShareSubtitleFrame? _remoteFrame;
  int? _remoteConnId;
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
      final args = call.arguments;
      if (args is! Map || args['source'] != _source) return;
      if (call.method == 'closed') {
        _source = null;
        _text = '';
        _remoteControlled = false;
        _remoteFrame = null;
        _remoteConnId = null;
        notifyListeners();
      } else if (call.method == 'pageStatus') {
        _sendPageStatus(args);
      }
    });
  }

  void _sendPageStatus(Map args) {
    final connId = _remoteConnId;
    final frame = _remoteFrame;
    final page = args['page'];
    final count = args['count'];
    if (!_remoteControlled ||
        connId == null ||
        frame == null ||
        frame.revision == 0 ||
        args['revision'] != frame.revision ||
        page is! int ||
        count is! int ||
        page < 0 ||
        page >= count ||
        count > DogShareSubtitleFrame.maxTextUnits) return;
    try {
      native_subtitle.sendPage(connId, frame.revision, page, count);
    } on ArgumentError {
      debugPrint('DogShare subtitle page feedback is unavailable.');
    }
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
    _remoteFrame = null;
    _remoteConnId = null;
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
    int? connId,
  }) async {
    if (source.isEmpty) return;
    if (!frame.enabled || frame.text.trim().isEmpty || frame.color >> 24 == 0) {
      await disable(source);
      return;
    }
    _source = source;
    _remoteControlled = true;
    _remoteFrame = frame;
    _remoteConnId = connId;
    _text = _boundedText(frame.text);
    _label = 'Live subtitles';
    fontSize = frame.fontSize;
    color = frame.color;
    fontFamily = frame.fontFamily;
    error = null;
    if (!_account.authorized) await _account.refresh();
    if (_source == source && _remoteControlled && _remoteFrame == frame) {
      await _show();
    }
  }

  Future<void> disable(String source) async {
    if (!enabledFor(source)) return;
    _source = null;
    _text = '';
    _remoteControlled = false;
    _remoteFrame = null;
    _remoteConnId = null;
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
    final frame = _remoteControlled ? _remoteFrame : null;
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
        'width': frame == null || frame.width == 0 ? width : frame.width,
        'height': frame == null || frame.height == 0 ? height : frame.height,
        if (frame != null) ...{
          'pairedCard': true,
          'autoFit': frame.width == 0,
          'page': frame.page,
          'revision': frame.revision,
        },
      });
    } on PlatformException {
      if (frame == _remoteFrame) {
        _failed(source, 'Text overlay failed. Turn it on again to retry.');
      }
    } on MissingPluginException {
      if (frame == _remoteFrame) {
        _failed(source, 'Text overlay is unavailable. Rebuild the Windows app.');
      }
    }
  }

  void _failed(String source, String message) {
    if (_source != source) return;
    _source = null;
    _text = '';
    _remoteControlled = false;
    _remoteFrame = null;
    _remoteConnId = null;
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
