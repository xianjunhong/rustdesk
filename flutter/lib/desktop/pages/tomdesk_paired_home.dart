import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/hbbs/hbbs.dart';
import '../../common/widgets/login.dart';
import '../../models/platform_model.dart';
import '../../models/tomdesk_account_gate.dart';
import '../../models/tomdesk_receiver_window.dart';
import '../../models/tomdesk_role.dart';
import 'connection_page.dart';

class TomDeskPairedHome extends StatefulWidget {
  const TomDeskPairedHome({super.key});

  @override
  State<TomDeskPairedHome> createState() => _TomDeskPairedHomeState();
}

class _TomDeskPairedHomeState extends State<TomDeskPairedHome> {
  bool _connecting = false;
  String? _error;

  Future<void> _connectPairedDevice() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final target = await gFFI.userModel.pairedDevice();
      if (!mounted) return;
      if (target == null) {
        setState(() => _error = tomDeskPairNotReady);
        return;
      }
      await connect(context, target);
    } on RequestException catch (error) {
      if (mounted) setState(() => _error = error.cause);
    } catch (_) {
      if (mounted) setState(() => _error = tomDeskAccountUnavailable);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final receiver = isTomDeskReceiver;
    return Obx(() {
      final user = gFFI.userModel;
      final loggedIn = user.userName.value.isNotEmpty && user.isLogin;
      final error = user.networkError.value;
      return _buildRoleCard(
        context,
        receiver: receiver,
        body: loggedIn
            ? _buildDashboard(
                context,
                receiver: receiver,
                account: user.accountLabelWithHandle,
                error: error,
              )
            : _buildSignIn(context, receiver: receiver, error: error),
      );
    });
  }

  Widget _buildRoleCard(BuildContext context,
      {required bool receiver, required Widget body}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colors.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(child: loadIcon(42)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  translate(
                      receiver ? 'TomDesk receiver' : 'TomDesk controller'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                body,
                if (receiver && isWindows)
                  Center(
                    child: TextButton(
                      onPressed: exitTomDeskReceiver,
                      child: Text(tomDeskReceiverExitLabel),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignIn(BuildContext context,
      {required bool receiver, required String error}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          translate(receiver ? tomDeskReceiverConsent : tomDeskSignInRequired),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (error.isNotEmpty && error != tomDeskSignInRequired)
          _buildError(context, error),
        const SizedBox(height: 24),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            onPressed: loginDialog,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: Text(translate('Login')),
          ),
        ),
      ],
    );
  }

  Widget _buildDashboard(BuildContext context,
      {required bool receiver,
      required String account,
      required String error}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withOpacity(0.35),
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.person_outline_rounded,
                  size: 22, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(translate('Account'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        )),
                    const SizedBox(height: 4),
                    Text(account, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (error.isNotEmpty) _buildError(context, error),
        const SizedBox(height: 20),
        Text(translate(receiver ? 'Status' : 'Paired device'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (receiver)
          const Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: OnlineStatusWidget(),
            ),
          )
        else ...[
          _PairedDeviceStatus(accountName: gFFI.userModel.userName.value),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: _connecting ? null : _connectPairedDevice,
              icon: _connecting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.desktop_windows, size: 18),
              label: Text(translate(_connecting ? 'Connecting...' : 'Connect')),
            ),
          ),
        ],
        if (!receiver && _error != null) _buildError(context, _error!),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: logOutConfirmDialog,
            child: Text(translate('Logout')),
          ),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context, String error) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        translate(error),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

class _PairedDeviceStatus extends StatefulWidget {
  _PairedDeviceStatus({required this.accountName})
      : super(key: ValueKey(accountName));

  final String accountName;

  @override
  State<_PairedDeviceStatus> createState() => _PairedDeviceStatusState();
}

class _PairedDeviceStatusState extends State<_PairedDeviceStatus> {
  Timer? _timer;
  bool? _online;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final user = gFFI.userModel;
    if (!user.isLogin || user.userName.value != widget.accountName) return;

    bool? online;
    try {
      online = await user.pairedDeviceOnline();
    } catch (_) {
      // This status is advisory. A failed lookup must not block Connect or
      // present a network error as a confirmed B logout.
    }
    if (!mounted || !user.isLogin || user.userName.value != widget.accountName) {
      return;
    }
    if (online != _online) setState(() => _online = online);
    // Schedule after the current response so polls never overlap.
    _timer = Timer(const Duration(seconds: 22), () => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _label(BuildContext context) {
    final configured = bind.mainGetLocalOption(key: 'lang').toLowerCase();
    final language = configured.isEmpty || configured == 'default'
        ? Localizations.localeOf(context).toLanguageTag().toLowerCase()
        : configured;
    if (language.startsWith('zh')) {
      final traditional = language.contains('hant') ||
          language.endsWith('-tw') ||
          language.endsWith('-hk') ||
          language.endsWith('-mo');
      return switch (_online) {
        true => traditional ? 'B 在線' : 'B 在线',
        false => traditional ? 'B 離線' : 'B 离线',
        null => traditional ? 'B 狀態未知' : 'B 状态未知',
      };
    }
    return switch (_online) {
      true => 'B online',
      false => 'B offline',
      null => 'B status unknown',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: _online == true
                ? const Color(0xff2f81f7)
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _label(context),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
