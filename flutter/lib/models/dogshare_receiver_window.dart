import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../utils/multi_window_manager.dart';
import 'platform_model.dart';
import 'state_model.dart';
import 'dogshare_role.dart';

const _receiverWindow = MethodChannel('dogshare/receiver_window');

Future<void>? _receiverHide;
bool _receiverExiting = false;

bool get _isReceiverMain =>
    isWindows && desktopType == DesktopType.main && isDogShareReceiver;

bool get isDogShareReceiverConnectionManager =>
    isWindows && desktopType == DesktopType.cm && isDogShareReceiver;

Future<bool> showDogShareReceiverConnectionMinimized() async {
  if (!isDogShareReceiverConnectionManager) return false;
  try {
    return await _receiverWindow.invokeMethod<bool>('showConnectionMinimized') ==
        true;
  } catch (error) {
    debugPrint('Unable to show DogShare connection minimized: $error');
    return false;
  }
}

Future<void> minimizeDogShareReceiverConnectionDetails() async {
  if (!isDogShareReceiverConnectionManager) return;
  try {
    final onTaskbar = await _receiverWindow
        .invokeMethod<bool>('showConnectionInTaskbar');
    // The manager starts without a taskbar button. Keep it visible if the
    // taskbar cannot provide a way to bring it back.
    if (onTaskbar == true) await windowManager.minimize();
  } catch (error) {
    debugPrint('Unable to minimize DogShare connection details: $error');
  }
}

String get dogShareReceiverExitLabel {
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

Future<void> collapseDogShareReceiverAfterLogin(bool? loggedIn) async {
  if (loggedIn == true) await hideDogShareReceiverWindow();
}

Future<void> hideDogShareReceiverWindow({
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
    debugPrint('Unable to enable DogShare receiver relaunch: $error');
  }
  if (_receiverExiting) return;
  if (!relaunchReady) {
    // Keep the window recoverable through the taskbar until relaunch is ready.
    if (!alreadyMinimized) {
      try {
        await windowManager.minimize();
      } catch (error) {
        debugPrint('Unable to minimize DogShare receiver: $error');
      }
    }
    return;
  }
  try {
    await windowManager.hide();
  } catch (error) {
    debugPrint('Unable to hide DogShare receiver: $error');
  }
}

Future<void> exitDogShareReceiver() async {
  if (!_isReceiverMain || _receiverExiting) return;
  _receiverExiting = true;
  try {
    await _receiverHide;
    try {
      await rustDeskWinManager.closeAllSubWindows();
    } catch (error) {
      debugPrint('Unable to close DogShare subwindows: $error');
    }
    try {
      await bind.mainOnMainWindowClose();
    } catch (error) {
      debugPrint('Unable to finish DogShare window cleanup: $error');
    }
    // Destroy bypasses the close-to-hide handler and preserves the login.
    await windowManager.destroy();
  } catch (error) {
    debugPrint('Unable to exit DogShare receiver: $error');
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      stateGlobal.setMinimized(false);
      await windowOnTop(null);
    } catch (restoreError) {
      debugPrint('Unable to restore DogShare receiver: $restoreError');
    }
  } finally {
    _receiverExiting = false;
  }
}
