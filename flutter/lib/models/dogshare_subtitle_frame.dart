import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../common.dart' show SessionID;
import 'platform_model.dart' show bind;

/// Complete, ephemeral subtitle state sent on the current A-to-B session.
@immutable
class DogShareSubtitleFrame {
  const DogShareSubtitleFrame({
    required this.enabled,
    required this.text,
    required this.fontSize,
    required this.fontFamily,
    required this.color,
  });

  static const maxTextUnits = 2000;
  static const fontFamilies = {
    'Microsoft YaHei',
    'SimHei',
    'SimSun',
    'Segoe UI',
    'Arial',
    'Consolas',
  };

  final bool enabled;
  final String text;
  final double fontSize;
  final String fontFamily;
  final int color;

  bool get _isValid =>
      text.length <= maxTextUnits &&
      !text.contains('\u0000') &&
      fontSize >= 8 &&
      fontSize <= 96 &&
      fontFamilies.contains(fontFamily) &&
      color >= 0 &&
      color <= 0xffffffff;

  String? encode() => _isValid
      ? jsonEncode({
          'enabled': enabled,
          'text': text,
          'fontSize': fontSize,
          'fontFamily': fontFamily,
          'color': color,
        })
      : null;

  static DogShareSubtitleFrame? tryDecode(String payload) {
    if (payload.length > 16 * 1024) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map<String, dynamic> ||
          map.length != 5 ||
          map['enabled'] is! bool ||
          map['text'] is! String ||
          map['fontSize'] is! num ||
          map['fontFamily'] is! String ||
          map['color'] is! int) {
        return null;
      }
      final frame = DogShareSubtitleFrame(
        enabled: map['enabled'] as bool,
        text: map['text'] as String,
        fontSize: (map['fontSize'] as num).toDouble(),
        fontFamily: map['fontFamily'] as String,
        color: map['color'] as int,
      );
      return frame._isValid ? frame : null;
    } on FormatException {
      return null;
    }
  }
}

/// Subtitle settings and publishing state for a single outgoing chat.
class DogShareSubtitleDraft extends ChangeNotifier {
  DogShareSubtitleDraft({
    required this.sessionId,
    required TextEditingController input,
  }) : _input = input {
    _input.addListener(_onInputChanged);
  }

  final SessionID sessionId;
  final TextEditingController _input;
  bool _enabled = false;
  bool _realtime = false;
  String _submittedText = '';
  String? _lastCommittedInput;
  Timer? _sendTimer;
  double fontSize = 16;
  String fontFamily = 'Microsoft YaHei';
  int color = 0xffdddddd;

  bool get enabled => _enabled;
  bool get realtime => _realtime;
  bool get isComposing =>
      _input.value.isComposingRangeValid && !_input.value.composing.isCollapsed;

  DogShareSubtitleFrame get frame => DogShareSubtitleFrame(
        enabled: enabled,
        text: _submittedText,
        fontSize: fontSize,
        fontFamily: fontFamily,
        color: color,
      );

  void setDisplayEnabled(bool enabled) {
    if (enabled == _enabled) return;
    _cancelPending();
    _enabled = enabled;
    if (enabled && realtime) _takeCurrentInput();
    _send();
    notifyListeners();
  }

  void setRealtime(bool enabled) {
    if (enabled == _realtime) return;
    _cancelPending();
    _realtime = enabled;
    if (this.enabled && enabled && _takeCurrentInput()) _send();
    notifyListeners();
  }

  void styleChanged() {
    if (enabled) _send();
    notifyListeners();
  }

  String submit(String message) {
    _cancelPending();
    _submittedText = _bounded(message);
    _send();
    // DashChat clears the shared controller after calling onSend. Mark our own
    // synchronous clear as handled so it does not erase the submitted caption.
    _lastCommittedInput = '';
    _input.clear();
    return _submittedText;
  }

  bool _takeCurrentInput() {
    if (isComposing || _input.text.trim().isEmpty) return false;
    final text = _bounded(_input.text);
    if (text == _submittedText) return false;
    _submittedText = text;
    return true;
  }

  void _onInputChanged() {
    if (isComposing) {
      _lastCommittedInput = null;
      _cancelPending();
      return;
    }
    final text = _input.text;
    if (text == _lastCommittedInput) return;
    _lastCommittedInput = text;
    if (!enabled || !realtime) return;
    _sendTimer ??= Timer(const Duration(milliseconds: 150), () {
      _sendTimer = null;
      final current = _bounded(_input.text);
      if (current == _submittedText) return;
      _submittedText = current;
      _send();
    });
  }

  void _cancelPending() {
    _sendTimer?.cancel();
    _sendTimer = null;
  }

  static String _bounded(String input) {
    final text = input.replaceAll('\u0000', '').trim();
    const limit = DogShareSubtitleFrame.maxTextUnits;
    if (text.length <= limit) return text;
    final clipped = StringBuffer();
    for (final character in text.characters) {
      if (clipped.length + character.length > limit) break;
      clipped.write(character);
    }
    return clipped.toString();
  }

  void _send() => sendDogShareSubtitleFrame(sessionId, frame);

  @override
  void dispose() {
    _cancelPending();
    _input.removeListener(_onInputChanged);
    super.dispose();
  }
}

final _pendingFrames = <SessionID, String?>{};

/// Order bridge writes by session and keep at most the latest waiting snapshot.
void sendDogShareSubtitleFrame(SessionID sessionId, DogShareSubtitleFrame frame) {
  final payload = frame.encode();
  if (payload == null) return;
  final busy = _pendingFrames.containsKey(sessionId);
  _pendingFrames[sessionId] = payload;
  if (!busy) unawaited(_drainFrames(sessionId));
}

Future<void> _drainFrames(SessionID sessionId) async {
  while (true) {
    final payload = _pendingFrames[sessionId];
    if (payload == null) {
      _pendingFrames.remove(sessionId);
      return;
    }
    _pendingFrames[sessionId] = null;
    try {
      await bind.sessionPeerOption(
        sessionId: sessionId,
        name: 'dogshare-runtime-subtitle-frame',
        value: payload,
      );
    } catch (_) {
      debugPrint('Could not send DogShare subtitle frame.');
    }
  }
}
