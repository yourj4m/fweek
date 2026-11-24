import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../platform.dart';
import '../sync/google_drive.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'settings_parts.dart';
import 'widgets/controls.dart';

/// The "Sync" part of the settings: connect to a Nextcloud account or a
/// Google account's Drive, or see the state of the connection.
class SyncSettings extends StatefulWidget {
  const SyncSettings({super.key});

  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<SyncSettings> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: defaultSyncFolder);
  bool _connecting = false;
  String? _error;

  /// Which kind of place the form is for, while nothing is connected.
  SyncProvider _provider = SyncProvider.google;

  /// While the browser is open for signing in to Google: completing it
  /// stops waiting.
  Completer<void>? _cancelGoogle;

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

  Future<void> _connectGoogle() async {
    final sync = context.readSync;
    final opener = context.readOpener;
    final cancel = _cancelGoogle = Completer<void>();
    setState(() {
      _connecting = true;
      _error = null;
    });
    String? error;
    try {
      final account = await sync.signInToGoogle(open: opener.open, cancel: cancel.future);
      if (!mounted) return;
      error = await sync.connectGoogle(account);
    } on GoogleSignInException catch (failure) {
      error = failure.cancelled ? null : failure.message;
    } on Object catch (failure) {
      error = 'Could not sign in to Google: $failure';
    }
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _cancelGoogle = null;
      _error = error;
    });
  }

  void _stopGoogle() {
    final cancel = _cancelGoogle;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  @override
  void deactivate() {
    // Leaving the settings ends the wait for the browser.
    _stopGoogle();
    super.deactivate();
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
      final host = config.isGoogle
          ? null
          : Uri.tryParse(config.root.toString())?.host ?? config.server;
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
                  config.isGoogle
                      ? '${config.user} on Google Drive'
                      : '${config.user} on $host, folder ${config.folder}',
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
            config.isGoogle
                ? 'Disconnecting stops syncing on this device and withdraws '
                    'fweek\'s access to your Google account. Your planner stays '
                    'here, and its copy stays in your Google Drive: connect '
                    'again to pick it up, or remove it in Google Drive under '
                    'Settings → Manage apps → fweek → Delete hidden app data.'
                : 'Disconnecting keeps everything, here and on the server.',
            style: muted,
          ),
        ],
      );
    }

    final google = sync.googleAvailable;
    final provider = google ? _provider : SyncProvider.nextcloud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (google) ...[
          Segmented<SyncProvider>(
            value: provider,
            options: const {
              SyncProvider.google: 'Google Drive',
              SyncProvider.nextcloud: 'Nextcloud',
            },
            onChanged: (value) {
              if (_connecting) return;
              setState(() {
                _provider = value;
                _error = null;
              });
            },
          ),
          const SizedBox(height: 14),
        ],
        if (provider == SyncProvider.google)
          _googleForm(context, muted)
        else
          _nextcloudForm(context, muted),
      ],
    );
  }

  Widget _googleForm(BuildContext context, TextStyle muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Keep this planner in step with your other devices through your '
          'Google account. Every change is saved there shortly after you make '
          'it; on a new device, connecting brings your planner back.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Text(
          'fweek keeps its files in a folder of its own in your Google Drive, '
          'hidden from your files and from other apps, and cannot see '
          'anything else there. Signing in happens on Google\'s own page in '
          'your browser; fweek never sees your password.',
          style: muted,
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: muted.copyWith(color: AppTheme.danger)),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppButton(
              icon: AppIcons.logIn,
              iconSize: 18,
              label: _connecting ? 'Waiting for Google…' : 'Connect Google account',
              kind: ButtonKind.primary,
              size: Dim.controlMedium,
              onTap: _connecting ? null : _connectGoogle,
            ),
            if (_connecting)
              AppButton(
                label: 'Cancel',
                kind: ButtonKind.ghost,
                size: Dim.controlMedium,
                onTap: _stopGoogle,
              ),
          ],
        ),
        if (_connecting) ...[
          const SizedBox(height: 8),
          Text(
            'Choose your account and allow access in the browser, then come '
            'back here.',
            style: muted,
          ),
        ],
      ],
    );
  }

  Widget _nextcloudForm(BuildContext context, TextStyle muted) {

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
          'password is kept $secretPlace.',
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
