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
    this.width = 0,
    this.height = 0,
    this.page = 0,
    this.revision = 0,
  });

  static const maxTextUnits = 2000;
  static const defaultWidth = 640;
  static const defaultHeight = 360;
  static const minWidth = 240;
  static const maxWidth = 2560;
  static const minHeight = 80;
  static const maxHeight = 1440;
  static const maxRevision = 0x7fffffff;
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
  // Zero dimensions request automatic layout. Revision zero is the old format.
  final int width;
  final int height;
  final int page;
  final int revision;

  bool get _isValid =>
      text.length <= maxTextUnits &&
      !text.contains('\u0000') &&
      fontSize >= 8 &&
      fontSize <= 96 &&
      fontFamilies.contains(fontFamily) &&
      color >= 0 &&
      color <= 0xffffffff &&
      ((width == 0 && height == 0) ||
          (width >= minWidth &&
              width <= maxWidth &&
              height >= minHeight &&
              height <= maxHeight)) &&
      page >= 0 &&
      page < maxTextUnits &&
      revision >= 0 &&
      revision <= maxRevision;

  String? encode() => _isValid
      ? jsonEncode({
          'enabled': enabled,
          'text': text,
          'fontSize': fontSize,
          'fontFamily': fontFamily,
          'color': color,
          if (width != 0) 'width': width,
          if (height != 0) 'height': height,
          if (page != 0) 'page': page,
          if (revision != 0) 'revision': revision,
        })
      : null;

  static DogShareSubtitleFrame? tryDecode(String payload) {
    if (payload.length > 16 * 1024) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map<String, dynamic> ||
          map['enabled'] is! bool ||
          map['text'] is! String ||
          map['fontSize'] is! num ||
          map['fontFamily'] is! String ||
          map['color'] is! int ||
          map.entries.any((entry) => switch (entry.key) {
                'enabled' ||
                'text' ||
                'fontSize' ||
                'fontFamily' ||
                'color' =>
                  false,
                'width' ||
                'height' ||
                'page' ||
                'revision' =>
                  entry.value is! int,
                _ => true,
              })) {
        return null;
      }
      final frame = DogShareSubtitleFrame(
        enabled: map['enabled'] as bool,
        text: map['text'] as String,
        fontSize: (map['fontSize'] as num).toDouble(),
        fontFamily: map['fontFamily'] as String,
        color: map['color'] as int,
        width: map['width'] as int? ?? 0,
        height: map['height'] as int? ?? 0,
        page: map['page'] as int? ?? 0,
        revision: map['revision'] as int? ?? 0,
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
  bool _autoFit = true;
  int _width = DogShareSubtitleFrame.defaultWidth;
  int _height = DogShareSubtitleFrame.defaultHeight;
  int _page = 0;
  int _pageCount = 0;
  int _revision = 0;
  String _submittedText = '';
  String? _lastCommittedInput;
  Timer? _sendTimer;
  double fontSize = 16;
  String fontFamily = 'Microsoft YaHei';
  int color = 0xffdddddd;

  bool get enabled => _enabled;
  bool get realtime => _realtime;
  bool get autoFit => _autoFit;
  int get width => _width;
  int get height => _height;
  int get page => _page;
  int get pageCount => _pageCount;
  bool get isComposing =>
      _input.value.isComposingRangeValid && !_input.value.composing.isCollapsed;

  DogShareSubtitleFrame get frame => DogShareSubtitleFrame(
        enabled: enabled,
        text: _submittedText,
        fontSize: fontSize,
        fontFamily: fontFamily,
        color: color,
        width: autoFit ? 0 : width,
        height: autoFit ? 0 : height,
        page: page,
        revision: _revision,
      );

  void setDisplayEnabled(bool enabled) {
    if (enabled == _enabled) return;
    _cancelPending();
    _enabled = enabled;
    if (enabled && realtime) _takeCurrentInput();
    _send(resetPage: true);
  }

  void setRealtime(bool enabled) {
    if (enabled == _realtime) return;
    _cancelPending();
    _realtime = enabled;
    if (this.enabled && enabled && _takeCurrentInput()) {
      _send(resetPage: true);
    } else {
      notifyListeners();
    }
  }

  void styleChanged() {
    if (enabled) {
      _send(resetPage: true);
    } else {
      notifyListeners();
    }
  }

  void setAutoFit(bool autoFit) {
    if (autoFit == _autoFit) return;
    _autoFit = autoFit;
    styleChanged();
  }

  void setSize({int? width, int? height}) {
    _width = width?.clamp(
            DogShareSubtitleFrame.minWidth, DogShareSubtitleFrame.maxWidth) ??
        _width;
    _height = height?.clamp(
            DogShareSubtitleFrame.minHeight, DogShareSubtitleFrame.maxHeight) ??
        _height;
    styleChanged();
  }

  void selectPage(int page) {
    if (!enabled || page < 0 || page >= _pageCount || page == _page) return;
    _page = page;
    _send();
  }

  void receivePageStatus(int revision, int page, int count) {
    if (!enabled ||
        revision == 0 ||
        revision != _revision ||
        count > DogShareSubtitleFrame.maxTextUnits ||
        page < 0 ||
        page >= count) return;
    _page = page;
    _pageCount = count;
    notifyListeners();
  }

  String? submit(String message) {
    final text = _normalized(message);
    if (text.isEmpty || _tooLong(text)) return null;
    _cancelPending();
    _submittedText = text;
    _send(resetPage: true);
    // DashChat clears the shared controller after calling onSend. Mark our own
    // synchronous clear as handled so it does not erase the submitted caption.
    _lastCommittedInput = '';
    _input.clear();
    return _submittedText;
  }

  bool _takeCurrentInput() {
    if (isComposing || _input.text.trim().isEmpty) return false;
    final text = _normalized(_input.text);
    if (text == _submittedText || _tooLong(text)) return false;
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
      final current = _normalized(_input.text);
      if (current == _submittedText || _tooLong(current)) return;
      _submittedText = current;
      _send(resetPage: true);
    });
  }

  void _cancelPending() {
    _sendTimer?.cancel();
    _sendTimer = null;
  }

  static String _normalized(String input) =>
      input.replaceAll('\u0000', '').trim();

  static bool _tooLong(String text) =>
      text.length > DogShareSubtitleFrame.maxTextUnits;

  bool exceedsTextLimit(String input) =>
      enabled && _tooLong(_normalized(input));

  void resend() => _send(resetPage: true);

  void _send({bool resetPage = false}) {
    if (resetPage) {
      _page = 0;
      _pageCount = 0;
    }
    _revision = _revision % DogShareSubtitleFrame.maxRevision + 1;
    sendDogShareSubtitleFrame(sessionId, frame);
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelPending();
    _input.removeListener(_onInputChanged);
    super.dispose();
  }
}

final _pendingFrames = <SessionID, String?>{};

/// Order bridge writes by session and keep at most the latest waiting snapshot.
void sendDogShareSubtitleFrame(
    SessionID sessionId, DogShareSubtitleFrame frame) {
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
