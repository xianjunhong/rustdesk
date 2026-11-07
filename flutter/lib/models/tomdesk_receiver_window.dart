import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../utils/multi_window_manager.dart';
import 'platform_model.dart';
import 'state_model.dart';
import 'tomdesk_role.dart';

const _receiverWindow = MethodChannel('tomdesk/receiver_window');

Future<void>? _receiverHide;
bool _receiverExiting = false;

bool get _isReceiverMain =>
    isWindows && desktopType == DesktopType.main && isTomDeskReceiver;

bool get isTomDeskReceiverConnectionManager =>
    isWindows && desktopType == DesktopType.cm && isTomDeskReceiver;

Future<bool> showTomDeskReceiverConnectionMinimized() async {
  if (!isTomDeskReceiverConnectionManager) return false;
  try {
    return await _receiverWindow.invokeMethod<bool>('showConnectionMinimized') ==
        true;
  } catch (error) {
    debugPrint('Unable to show TomDesk connection minimized: $error');
    return false;
  }
}

Future<void> minimizeTomDeskReceiverConnectionDetails() async {
  if (!isTomDeskReceiverConnectionManager) return;
  try {
    final onTaskbar = await _receiverWindow
        .invokeMethod<bool>('showConnectionInTaskbar');
    // The manager starts without a taskbar button. Keep it visible if the
    // taskbar cannot provide a way to bring it back.
    if (onTaskbar == true) await windowManager.minimize();
  } catch (error) {
    debugPrint('Unable to minimize TomDesk connection details: $error');
  }
}

String get tomDeskReceiverExitLabel {
  final configured = bind.mainGetLocalOption(key: 'lang').toLowerCase();
  final language = (configured.isEmpty || configured == 'default'
          ? localeName.toString().toLowerCase()
          : configured)
      .replaceAll('_', '-');
  if (!language.startsWith('zh')) return 'Exit program';
  return language.contains('hant') ||
          language.contains('-tw') ||
          language.contains('-hk') ||
          language.contains('-mo')
      ? '退出程式'
      : '退出程序';
}

Future<void> collapseTomDeskReceiverAfterLogin(bool? loggedIn) async {
  if (loggedIn == true) await hideTomDeskReceiverWindow();
}

Future<void> hideTomDeskReceiverWindow({
  bool alreadyMinimized = false,
}) async {
  if (!_isReceiverMain || _receiverExiting) return;
  await (_receiverHide ??= _hideReceiverMain(alreadyMinimized).whenComplete(() {
    _receiverHide = null;
  }));
}

Future<void> _hideReceiverMain(bool alreadyMinimized) async {
  var relaunchReady = false;
  try {
    relaunchReady =
        await _receiverWindow.invokeMethod<bool>('enableRelaunch') == true;
  } catch (error) {
    debugPrint('Unable to enable TomDesk receiver relaunch: $error');
  }
  if (_receiverExiting) return;
  if (!relaunchReady) {
    // Keep the window recoverable through the taskbar until relaunch is ready.
    if (!alreadyMinimized) {
      try {
        await windowManager.minimize();
      } catch (error) {
        debugPrint('Unable to minimize TomDesk receiver: $error');
      }
    }
    return;
  }
  try {
    await windowManager.hide();
  } catch (error) {
    debugPrint('Unable to hide TomDesk receiver: $error');
  }
}

Future<void> exitTomDeskReceiver() async {
  if (!_isReceiverMain || _receiverExiting) return;
  _receiverExiting = true;
  try {
    await _receiverHide;
    try {
      await rustDeskWinManager.closeAllSubWindows();
    } catch (error) {
      debugPrint('Unable to close TomDesk subwindows: $error');
    }
    try {
      await bind.mainOnMainWindowClose();
    } catch (error) {
      debugPrint('Unable to finish TomDesk window cleanup: $error');
    }
    // Destroy bypasses the close-to-hide handler and preserves the login.
    await windowManager.destroy();
  } catch (error) {
    debugPrint('Unable to exit TomDesk receiver: $error');
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      stateGlobal.setMinimized(false);
      await windowOnTop(null);
    } catch (restoreError) {
      debugPrint('Unable to restore TomDesk receiver: $restoreError');
    }
  } finally {
    _receiverExiting = false;
  }
}
