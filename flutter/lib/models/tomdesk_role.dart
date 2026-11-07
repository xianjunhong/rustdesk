import 'platform_model.dart';
import 'tomdesk_account_gate.dart';

const tomDeskRoleMismatch = 'Use an account for this TomDesk role.';
const tomDeskPairUnavailable =
    'Pairing is unavailable. Contact your administrator.';
const tomDeskPairNotReady =
    'The paired receiver has not signed in or bound a device yet.';
const tomDeskReceiverConsent =
    'After signing in, your paired controller can connect to this computer.';

String get tomDeskReceiverVoiceActiveText => _receiverVoiceText(
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

String? get tomDeskClientRole {
  if (!TomDeskAccountGate.isRequired) return null;
  if (bind.isIncomingOnly()) return 'receiver';
  if (bind.isOutgoingOnly()) return 'controller';
  return null;
}

bool get isTomDeskReceiver => tomDeskClientRole == 'receiver';
bool get isTomDeskController => tomDeskClientRole == 'controller';
