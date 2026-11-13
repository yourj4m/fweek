import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../platform.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'widgets/controls.dart';

/// The "Sync" part of the settings: connect to a Nextcloud account, or see
/// the state of the connection.
class SyncSettings extends StatefulWidget {
  const SyncSettings({super.key});

  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<SyncSettings> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: 'WeekToDo');
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final sync = context.readSync;
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await sync.connect(
      server: _server.text,
      user: _user.text,
      password: _password.text,
      folder: _folder.text,
    );
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _error = error;
      if (error == null) _password.clear();
    });
  }

  static String _ago(DateTime then, DateTime now) {
    final minutes = now.difference(then).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    if (minutes < 24 * 60) return '${minutes ~/ 60} h ago';
    return 'on ${then.day}.${then.month}.${then.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final sync = context.sync;
    final config = sync.config;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));

    if (config != null) {
      final host = Uri.tryParse(config.root.toString())?.host ?? config.server;
      final status = switch (sync.state) {
        SyncState.syncing => 'Syncing…',
        SyncState.error => sync.message ?? 'The last sync failed.',
        _ => sync.lastSync == null
            ? 'Not synced yet.'
            : 'Synced ${_ago(sync.lastSync!, DateTime.now())}.',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                sync.state == SyncState.error ? AppIcons.cloudAlert : AppIcons.cloud,
                size: 20,
                color: sync.state == SyncState.error ? AppTheme.danger : theme.text,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${config.user} on $host, folder ${config.folder}',
                  style: context.text.body17,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            status,
            style: muted.copyWith(
              color: sync.state == SyncState.error ? AppTheme.danger : null,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppButton(
                icon: AppIcons.refreshCw,
                label: 'Sync now',
                size: Dim.controlInline,
                iconSize: 16,
                onTap: sync.state == SyncState.syncing ? null : sync.syncNow,
              ),
              AppButton(
                label: 'Disconnect',
                size: Dim.controlInline,
                kind: ButtonKind.ghost,
                onTap: sync.disconnect,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Disconnecting keeps everything, here and on the server.',
            style: muted,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Keep this planner in step with your other devices through your '
          'own Nextcloud.',
          style: muted,
        ),
        const SizedBox(height: 12),
        SettingsField(
          label: 'Server',
          hint: 'cloud.example.com',
          controller: _server,
          enabled: !_connecting,
        ),
        SettingsField(
          label: 'Login name',
          controller: _user,
          enabled: !_connecting,
        ),
        SettingsField(
          label: 'App password',
          controller: _password,
          enabled: !_connecting,
          obscure: true,
          onSubmitted: _connect,
        ),
        SettingsField(
          label: 'Folder',
          controller: _folder,
          enabled: !_connecting,
          onSubmitted: _connect,
        ),
        const SizedBox(height: 4),
        Text(
          'Create an app password in Nextcloud under Settings → Security → '
          'Devices & sessions; that page also shows your login name. The '
          'password is kept ${isMobile ? 'encrypted on this device' : 'in the system keyring'}.',
          style: muted,
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: muted.copyWith(color: AppTheme.danger)),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            label: _connecting ? 'Connecting…' : 'Connect',
            kind: ButtonKind.primary,
            size: Dim.controlMedium,
            onTap: _connecting ? null : _connect,
          ),
        ),
      ],
    );
  }
}

/// One labelled line of a settings form.
class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.enabled = true,
    this.onSubmitted,
  });

  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        height: Dim.controlLarge,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: theme.ink(5),
          borderRadius: BorderRadius.circular(Dim.radiusM),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 118,
              child: Text(
                label,
                style: context.text.small15.copyWith(color: theme.ink(60)),
              ),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                style: context.text.body17,
                cursorColor: theme.text,
                decoration: InputDecoration.collapsed(
                  hintText: hint ?? '',
                  hintStyle: context.text.body17.copyWith(color: theme.ink(25)),
                ),
                onSubmitted: (_) => onSubmitted?.call(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
