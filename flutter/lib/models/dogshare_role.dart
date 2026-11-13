import 'package:uuid/uuid.dart';

import '../consts.dart';
import 'platform_model.dart';
import 'dogshare_account_gate.dart';

const dogShareRoleMismatch = 'Use an account for this DogShare role.';
const dogSharePairUnavailable =
    'Pairing is unavailable. Contact your administrator.';
const dogSharePairNotReady =
    'The paired receiver has not signed in or bound a device yet.';
const dogShareReceiverConsent =
    'After signing in, your paired controller can connect to this computer.';

String get dogShareReceiverVoiceActiveText => _receiverVoiceText(
      'Voice call in progress',
      simplified: '语音通话中',
      traditional: '語音通話中',
    );

String _receiverVoiceText(
  String english, {
  required String simplified,
  required String traditional,
}) {
  final configured = bind.mainGetLocalOption(key: 'lang').toLowerCase();
  final language = (configured.isEmpty || configured == 'default'
          ? localeName.toString().toLowerCase()
          : configured)
      .replaceAll('_', '-');
  if (!language.startsWith('zh')) return english;
  return language.contains('hant') ||
          language.contains('-tw') ||
          language.contains('-hk') ||
          language.contains('-mo')
      ? traditional
      : simplified;
}

String? get dogShareClientRole {
  if (!DogShareAccountGate.isRequired) return null;
  if (bind.isIncomingOnly()) return 'receiver';
  if (bind.isOutgoingOnly()) return 'controller';
  return null;
}

bool get isDogShareReceiver => dogShareClientRole == 'receiver';
bool get isDogShareController => dogShareClientRole == 'controller';

Future<void> initializeDogShareConnectionViewMode(
  UuidValue sessionId, {
  required bool isCache,
}) async {
  // A cached UI restores the current connection, not a new login.
  if (isCache || !isDogShareController) return;
  if (!bind.sessionGetToggleOptionSync(
      sessionId: sessionId, arg: kOptionToggleViewOnly)) {
    await bind.sessionToggleOption(
        sessionId: sessionId, value: kOptionToggleViewOnly);
  }
}
