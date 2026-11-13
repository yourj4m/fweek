import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';

import '../app_state.dart';
import '../data/export.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'task_dialog.dart';
import 'widgets/controls.dart';

/// Opens the settings card.
Future<void> showSettingsDialog(BuildContext context) =>
    showCard(context, (context) => const _SettingsDialog());

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  /// Result of the last export or import, shown under the buttons.
  String? _message;
  bool _failed = false;

  void _report(String message, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _failed = failed;
    });
  }

  Future<void> _export(String label, String extension, String Function() build) async {
    try {
      final location = await getSaveLocation(
        suggestedName: 'weektodo.$extension',
        acceptedTypeGroups: [XTypeGroup(label: label, extensions: [extension])],
      );
      if (location == null) return;
      var path = location.path;
      if (!path.toLowerCase().endsWith('.$extension')) path = '$path.$extension';
      await File(path).writeAsString(build(), flush: true);
      _report('Saved $path');
    } on Object catch (error) {
      _report('Could not save: $error', failed: true);
    }
  }

  Future<void> _import() async {
    final store = context.readStore;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'WeekToDo backup', extensions: ['json']),
        ],
      );
      if (file == null) return;
      final count = Export.restore(store, await file.readAsString());
      _report('Restored $count tasks from ${file.name}');
    } on FormatException catch (error) {
      _report(error.message, failed: true);
    } on Object catch (error) {
      _report('Could not read the file: $error', failed: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < Dim.breakpoint;
    final themeId = store.setting<String>(Settings.theme);

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 10),
          child: Text(title, style: context.text.bodyBold17),
        );

    Widget toggle(String label, String key, {String? detail}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: context.text.body17),
                    if (detail != null)
                      Text(detail,
                          style: context.text.caption14
                              .copyWith(color: theme.ink(60))),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AppSwitch(
                value: store.setting<bool>(key),
                onChanged: (value) => store.setSetting(key, value),
              ),
            ],
          ),
        );

    return EscapeToClose(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: narrow ? 16 : Dim.dialogTop,
            left: 16,
            right: 16,
            bottom: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Dim.dialogWidth),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.dialog,
                borderRadius: BorderRadius.circular(Dim.dialogRadius),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Settings', style: context.text.title28),
                        ),
                        AppButton(
                          icon: AppIcons.x,
                          kind: ButtonKind.ghost,
                          tooltip: 'Close',
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    section('Theme'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ThemeTile(
                          label: 'System',
                          background: AppTheme.light.background,
                          text: AppTheme.light.text,
                          accent: AppTheme.dark.background,
                          split: true,
                          selected: themeId == 'system',
                          onTap: () => store.setSetting(Settings.theme, 'system'),
                        ),
                        for (final t in AppTheme.all)
                          _ThemeTile(
                            label: t.name,
                            background: t.background,
                            text: t.text,
                            accent: t.accent,
                            selected: themeId == t.id,
                            onTap: () => store.setSetting(Settings.theme, t.id),
                          ),
                      ],
                    ),
                    section('Week starts on'),
                    Segmented<int>(
                      value: store.weekStart,
                      options: const {1: 'Monday', 7: 'Sunday', 6: 'Saturday'},
                      onChanged: (v) => store.setSetting(Settings.weekStart, v),
                    ),
                    section('Time format'),
                    Segmented<bool>(
                      value: store.setting<bool>(Settings.use24h),
                      options: const {true: '24-hour', false: '12-hour'},
                      onChanged: (v) => store.setSetting(Settings.use24h, v),
                    ),
                    section('Tasks'),
                    toggle(
                      'Move unfinished tasks to today',
                      Settings.rollover,
                      detail: 'Once a day, tasks left open on past days move to '
                          'the top of today. Repeating tasks stay put.',
                    ),
                    toggle('Sort completed tasks down', Settings.sortDoneDown),
                    toggle('Hide completed tasks', Settings.hideDone),
                    section('Your data'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppButton(
                          icon: AppIcons.download,
                          label: 'Backup',
                          size: Dim.controlInline,
                          iconSize: 16,
                          onTap: () => _export(
                              'WeekToDo backup', 'json', () => Export.backup(store)),
                        ),
                        AppButton(
                          label: 'CSV',
                          size: Dim.controlInline,
                          onTap: () => _export(
                              'Comma-separated values', 'csv', () => Export.csv(store)),
                        ),
                        AppButton(
                          label: 'iCalendar',
                          size: Dim.controlInline,
                          onTap: () =>
                              _export('iCalendar', 'ics', () => Export.ics(store)),
                        ),
                        AppButton(
                          label: 'Text',
                          size: Dim.controlInline,
                          onTap: () =>
                              _export('Plain text', 'txt', () => Export.text(store)),
                        ),
                        AppButton(
                          icon: AppIcons.upload,
                          label: 'Restore backup',
                          size: Dim.controlInline,
                          iconSize: 16,
                          onTap: _import,
                        ),
                      ],
                    ),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _message!,
                          style: context.text.caption14.copyWith(
                            color: _failed ? AppTheme.danger : theme.ink(60),
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text(
                      'Everything is stored on this computer. '
                      'Reminders are delivered while the app is open.',
                      style: context.text.caption14.copyWith(color: theme.ink(40)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.label,
    required this.background,
    required this.text,
    required this.accent,
    required this.selected,
    required this.onTap,
    this.split = false,
  });

  final String label;
  final Color background;
  final Color text;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  /// Half light, half dark (the "follow the system" tile).
  final bool split;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      semanticLabel: '$label theme',
      builder: (context, hovered, pressed) => SizedBox(
        width: 100,
        child: Column(
          spacing: 6,
          children: [
            Container(
              height: 56,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(Dim.radiusM),
                border: Border.all(
                  color: selected ? theme.accent : theme.ink(hovered ? 40 : 15),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Stack(
                children: [
                  if (split)
                    Positioned.fill(
                      left: 50,
                      child: ColoredBox(color: accent),
                    ),
                  Positioned(
                    left: 10,
                    top: 12,
                    child: Container(width: 34, height: 5, color: text),
                  ),
                  Positioned(
                    left: 10,
                    top: 24,
                    child: Container(
                        width: 54, height: 2, color: text.withValues(alpha: 0.2)),
                  ),
                  Positioned(
                    left: 10,
                    top: 34,
                    child: Container(
                      width: 24,
                      height: 8,
                      decoration: BoxDecoration(
                        color: split ? const Color(0xFF5167F4) : accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              label,
              style: context.text.caption14.copyWith(
                color: selected ? theme.text : theme.ink(60),
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
