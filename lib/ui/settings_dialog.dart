import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'icons.dart';

import '../app_state.dart';
import '../data/day.dart';
import '../data/export.dart';
import '../data/local_backups.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../services/android_bridge.dart';
import '../services/places.dart';
import '../sync/sync_service.dart';
import '../theme/app_theme.dart';
import 'calendar_settings.dart';
import 'settings_parts.dart';
import 'strings.dart';
import 'sync_settings.dart';
import 'task_dialog.dart';
import 'task_list.dart' show formatTime;
import 'widgets/controls.dart';

/// Opens the settings: on [section] if one is asked for, and otherwise on
/// the one last looked at.
Future<void> showSettingsDialog(BuildContext context, {SettingsSection? section}) =>
    showCard(context, (context) => _SettingsDialog(section: section));

/// What a section is called and drawn with.
extension SettingsSectionLook on SettingsSection {
  String get title => switch (this) {
        SettingsSection.general => 'General',
        SettingsSection.appearance => 'Appearance',
        SettingsSection.tasks => 'Tasks',
        SettingsSection.calendars => 'Calendars',
        SettingsSection.sync => 'Sync',
        SettingsSection.data => 'Data',
        SettingsSection.advanced => 'Advanced',
      };

  IconData get icon => switch (this) {
        SettingsSection.general => AppIcons.slidersHorizontal,
        SettingsSection.appearance => AppIcons.palette,
        SettingsSection.tasks => AppIcons.circleCheck,
        SettingsSection.calendars => AppIcons.calendarDays,
        SettingsSection.sync => AppIcons.cloud,
        SettingsSection.data => AppIcons.hardDrive,
        SettingsSection.advanced => AppIcons.wrench,
      };
}

/// The settings, a section at a time.
///
/// Where the window is wide enough the card has two parts: the sections
/// listed on the left, and the chosen one on the right. On a phone, or in a
/// narrow window, the card shows the list of sections first and one of them
/// after a tap, with an arrow back to the list.
class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({this.section});

  final SettingsSection? section;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog>
    with SingleTickerProviderStateMixin {
  /// The narrowest window in which the sections are listed beside the one
  /// on show.
  static const _twoPanes = 780.0;
  static const _wideWidth = 880.0;
  static const _narrowWidth = 560.0;
  static const _sidebar = 224.0;
  static const _height = 720.0;

  late SettingsSection _section =
      widget.section ?? context.readApp.settingsSection;

  /// In a narrow card: whether a section is open, rather than their list.
  late bool _open = widget.section != null;

  /// Sections are built when first shown and then kept, so that what was
  /// typed into one is still there on coming back to it.
  final _built = <SettingsSection>{};

  /// Brings a newly shown section in.
  late final _arrive =
      AnimationController(vsync: this, duration: Dim.medium, value: 1);

  /// Which side a section comes in from in a narrow card: the right when
  /// opened, the left when the list comes back.
  double _from = 0;

  /// How far each section, and their list (null), is scrolled. Once the
  /// one on show has moved, a line parts it from the heading above.
  final _scrolling = <SettingsSection?, ScrollController>{};
  bool _scrolled = false;

  ScrollController _scroller(SettingsSection? section) => _scrolling.putIfAbsent(
      section, () => ScrollController()..addListener(_onScroll));

  bool get _isScrolled {
    final scroller = _scrolling[_open ? _section : null];
    return scroller != null && scroller.hasClients && scroller.offset > 0;
  }

  void _onScroll() {
    if (_isScrolled != _scrolled && mounted) setState(() {});
  }

  @override
  void dispose() {
    _arrive.dispose();
    for (final scroller in _scrolling.values) {
      scroller.dispose();
    }
    super.dispose();
  }

  /// Takes the keyboard out of a field of the section being left. With no
  /// field in use the card itself holds the focus, and keeps it: Escape is
  /// heard there.
  void _leaveField() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus is! FocusScopeNode) focus.unfocus();
  }

  void _show(SettingsSection section, {required bool wide}) {
    if (_open && section == _section) return;
    _leaveField();
    context.readApp.settingsSection = section;
    setState(() {
      _section = section;
      _open = true;
      _from = wide ? 0 : 1;
    });
    // Beside the list a section simply appears; in a narrow card it comes
    // in from the side.
    _arrive.duration = wide ? const Duration(milliseconds: 120) : Dim.medium;
    _arrive.forward(from: 0);
  }

  void _back() {
    _leaveField();
    setState(() {
      _open = false;
      _from = -1;
    });
    _arrive.duration = Dim.medium;
    _arrive.forward(from: 0);
  }

  void _close() => Navigator.of(context).pop();

  Widget _page(SettingsSection section) => switch (section) {
        SettingsSection.general => const _GeneralPage(),
        SettingsSection.appearance => const _AppearancePage(),
        SettingsSection.tasks => const _TasksPage(),
        SettingsSection.calendars => const CalendarSettings(),
        SettingsSection.sync => const SyncSettings(),
        SettingsSection.data => const _DataPage(),
        SettingsSection.advanced => const _AdvancedPage(),
      };

  /// A line under a section's name in the list of them: where it stands,
  /// or what is in it.
  ({String text, bool failed}) _summary(BuildContext context, SettingsSection section) {
    switch (section) {
      case SettingsSection.general:
        return (text: 'Week, time format, new items, places', failed: false);
      case SettingsSection.appearance:
        final id = context.store.setting<String>(Settings.theme);
        final name = id == 'system'
            ? 'System'
            : AppTheme.all.where((theme) => theme.id == id).firstOrNull?.name;
        return (text: name == null ? 'Theme' : 'Theme: $name', failed: false);
      case SettingsSection.tasks:
        return (text: 'Completed tasks, lists, reminders', failed: false);
      case SettingsSection.calendars:
        final count = context.calendars.subscriptions.length;
        return (
          text: switch (count) {
            0 => 'Other calendars, birthdays',
            1 => '1 calendar',
            _ => '$count calendars',
          },
          failed: false,
        );
      case SettingsSection.sync:
        final sync = context.sync;
        final config = sync.config;
        if (config == null) return (text: 'Not connected', failed: false);
        if (sync.state == SyncState.error) {
          return (text: 'The last sync failed', failed: true);
        }
        if (config.isGoogle) return (text: 'Google Drive: ${config.user}', failed: false);
        final host = Uri.tryParse(config.root.toString())?.host ?? config.server;
        return (text: 'Nextcloud on $host', failed: false);
      case SettingsSection.data:
        return (text: 'Backup, export, copies on this device', failed: false);
      case SettingsSection.advanced:
        return (text: 'Frame timing', failed: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final size = MediaQuery.sizeOf(context);
    final below = MediaQuery.paddingOf(context).bottom;
    final wide = size.width >= _twoPanes;
    // Two panes always show a section; should the window narrow, that
    // section stays open.
    if (wide) _open = true;
    final showing = _open ? _section : null;
    if (showing != null) _built.add(showing);
    _scrolled = _isScrolled;
    // Under the heading, once what is below it has been scrolled.
    final rule = AnimatedContainer(
      duration: Dim.fast,
      height: 1,
      color: _scrolled ? theme.rule : theme.rule.withValues(alpha: 0),
    );

    final syncFailed = context.sync.state == SyncState.error;
    final close = AppButton(
      icon: AppIcons.x,
      kind: ButtonKind.ghost,
      tooltip: 'Close',
      onTap: _close,
    );

    final inset = wide ? 32.0 : 24.0;
    Widget scroll(SettingsSection section) => SingleChildScrollView(
          controller: _scroller(section),
          padding: EdgeInsets.fromLTRB(inset, 10, inset, 32),
          child: _page(section),
        );

    final pages = AnimatedBuilder(
      animation: _arrive,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_arrive.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * 16 * _from, 0),
            child: child,
          ),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!wide)
            Visibility(
              key: const ValueKey('sections'),
              visible: showing == null,
              maintainState: true,
              child: SingleChildScrollView(
                controller: _scroller(null),
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final section in SettingsSection.values)
                      Builder(builder: (context) {
                        final summary = _summary(context, section);
                        return _SectionLine(
                          section: section,
                          summary: summary.text,
                          failed: summary.failed,
                          onTap: () => _show(section, wide: false),
                        );
                      }),
                  ],
                ),
              ),
            ),
          for (final section in SettingsSection.values)
            if (_built.contains(section))
              Visibility(
                key: ValueKey(section),
                visible: section == showing,
                maintainState: true,
                child: scroll(section),
              ),
        ],
      ),
    );

    final Widget card;
    if (wide) {
      card = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: _sidebar,
            color: theme.text.withValues(alpha: theme.isDark ? 0.06 : 0.035),
            padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 18),
                  child: Text('Settings', style: context.text.heading24),
                ),
                for (final section in SettingsSection.values)
                  _SectionTab(
                    section: section,
                    selected: section == _section,
                    failed: section == SettingsSection.sync && syncFailed,
                    onTap: () => _show(section, wide: true),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 18, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_section.title, style: context.text.heading24),
                      ),
                      close,
                    ],
                  ),
                ),
                rule,
                Expanded(child: pages),
              ],
            ),
          ),
        ],
      );
    } else {
      card = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(showing == null ? 24 : 12, 16, 12, 6),
            child: SizedBox(
              height: Dim.controlLarge,
              child: Row(
                children: [
                  if (showing != null) ...[
                    AppButton(
                      icon: AppIcons.arrowLeft,
                      kind: ButtonKind.ghost,
                      tooltip: 'All settings',
                      onTap: _back,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      showing?.title ?? 'Settings',
                      style: showing == null
                          ? context.text.title28
                          : context.text.heading24,
                    ),
                  ),
                  close,
                ],
              ),
            ),
          ),
          rule,
          Expanded(child: pages),
        ],
      );
    }

    // The card keeps one size whichever section is on show, so that its
    // parts and its buttons stay where they are.
    final room = size.height - below;
    final double top, height;
    if (wide) {
      height = math.min(_height, room - 48);
      top = math.min(Dim.dialogTop, (room - height) / 2);
    } else {
      top = 16;
      height = math.min(_height, room - top - 24);
    }

    return PopScope(
      // In a narrow card, going back from a section leads to their list.
      canPop: wide || !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) _back();
      },
      child: EscapeToClose(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // A click or tap beside the card closes the settings, from a
            // section too.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: _close,
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: top, left: 16, right: 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: wide ? _wideWidth : _narrowWidth,
                  ),
                  child: Container(
                    height: math.max(height, 0),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: theme.dialog,
                      borderRadius: BorderRadius.circular(Dim.dialogRadius),
                    ),
                    child: card,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section in the list beside the one on show.
class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.section,
    required this.selected,
    required this.failed,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;

  /// Something in it wants looking at (the last sync failed).
  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        onTap: onTap,
        semanticLabel: '${section.title} settings',
        labelOnly: true,
        focusRadius: 10,
        builder: (context, hovered, pressed) => AnimatedContainer(
          duration: hovered ? Duration.zero : Dim.fast,
          height: Dim.controlMedium,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? theme.ink(10)
                : hovered
                    ? theme.ink(5)
                    : const Color(0x00000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                failed ? AppIcons.cloudAlert : section.icon,
                size: 18,
                color: failed ? AppTheme.danger : theme.text,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: selected ? context.text.bodyBold17 : context.text.body17,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section in the list of them that a narrow card opens on.
class _SectionLine extends StatelessWidget {
  const _SectionLine({
    required this.section,
    required this.summary,
    required this.failed,
    required this.onTap,
  });

  final SettingsSection section;
  final String summary;
  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onTap,
      semanticLabel: '${section.title} settings',
      labelOnly: true,
      focusRadius: Dim.radiusM,
      builder: (context, hovered, pressed) => AnimatedContainer(
        duration: hovered ? Duration.zero : Dim.fast,
        padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
        decoration: BoxDecoration(
          color: pressed
              ? theme.ink(10)
              : hovered
                  ? theme.ink(5)
                  : const Color(0x00000000),
          borderRadius: BorderRadius.circular(Dim.radiusM),
        ),
        child: Row(
          children: [
            Icon(
              failed ? AppIcons.cloudAlert : section.icon,
              size: 22,
              color: failed ? AppTheme.danger : theme.text,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(section.title, style: context.text.body17),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption14.copyWith(
                      color: failed ? AppTheme.danger : theme.ink(60),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(AppIcons.chevronRight, size: 20, color: theme.ink(40)),
          ],
        ),
      ),
    );
  }
}

/// A setting that is on or off.
class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.setting, {this.detail});

  final String label;
  final String setting;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return SettingsRow(
      label: label,
      detail: detail,
      control: AppSwitch(
        value: store.setting<bool>(setting),
        onChanged: (value) => store.setSetting(setting, value),
      ),
    );
  }
}

/// How the week is laid out and read, and what typing makes.
class _GeneralPage extends StatefulWidget {
  const _GeneralPage();

  @override
  State<_GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<_GeneralPage> {
  late final _placeServer = TextEditingController(
      text: context.readStore.setting<String>(Settings.placeServer));
  String? _placeServerError;

  @override
  void dispose() {
    _placeServer.dispose();
    super.dispose();
  }

  void _savePlaceServer() {
    final store = context.readStore;
    final typed = _placeServer.text.trim();
    try {
      // Checked now, so that a mistyped address is said here and not found
      // out by suggestions silently staying away.
      final address = typed.isEmpty ? '' : placeServer(typed).toString();
      store.setSetting(Settings.placeServer, address);
      setState(() => _placeServerError = null);
    } on FormatException catch (error) {
      setState(() => _placeServerError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: 'Week starts on',
          choices: true,
          control: Segmented<int>(
            value: store.weekStart,
            options: const {1: 'Monday', 7: 'Sunday', 6: 'Saturday'},
            onChanged: (v) => store.setSetting(Settings.weekStart, v),
          ),
        ),
        SettingsRow(
          label: 'Time format',
          choices: true,
          control: Segmented<bool>(
            value: store.setting<bool>(Settings.use24h),
            options: const {true: '24-hour', false: '12-hour'},
            onChanged: (v) => store.setSetting(Settings.use24h, v),
          ),
        ),
        SettingsRow(
          label: 'New items are',
          choices: true,
          control: Segmented<String>(
            value: store.newItemKind.name,
            options: const {'task': 'Tasks', 'event': 'Events'},
            onChanged: (v) => store.setSetting(Settings.newItems, v),
          ),
          detail: 'A task has a circle to tick it off; an event has none '
              'and fades once it is over. While typing, '
              '${isMobile ? 'the first button above the keyboard' : 'Ctrl+E'} '
              'makes an item the other.',
        ),
        const SettingsHeading('Places'),
        const _Toggle(
          'Suggest places while typing',
          Settings.placeSearch,
          detail: 'What you type into a place field is sent to a '
              'search server to find matching places in '
              'OpenStreetMap\'s data. Nothing else is sent. '
              'Without it, a place is kept exactly as typed.',
        ),
        if (store.setting<bool>(Settings.placeSearch)) ...[
          const SizedBox(height: 4),
          SettingsField(
            label: 'Search server',
            hint: PlaceSearch.defaultServer,
            controller: _placeServer,
            onSubmitted: _savePlaceServer,
            onBlur: _savePlaceServer,
          ),
          SettingsNote(
            _placeServerError ??
                'A Photon server. Leave empty for the public one, '
                    'which asks for fair use.',
            failed: _placeServerError != null,
          ),
        ],
      ],
    );
  }
}

/// The themes: one row per kind (light, dark, and the semi-dark themes in
/// deep, muted colours).
class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final themeId = store.setting<String>(Settings.theme);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Six to a row, so that each kind keeps to one row where the page
        // is wide enough for that; larger where there is room to spare.
        final large = constraints.maxWidth >= 6 * 84 + 5 * 10;
        final width = large ? 84.0 : 68.0;
        final gap = large ? 10.0 : 8.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in ThemeGroup.values) ...[
              if (group != ThemeGroup.light) const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  group.label,
                  style: context.text.caption14.copyWith(color: theme.ink(60)),
                ),
              ),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  if (group == ThemeGroup.light)
                    _ThemeTile(
                      label: 'System',
                      width: width,
                      background: AppTheme.light.background,
                      text: AppTheme.light.text,
                      accent: AppTheme.dark.background,
                      split: true,
                      selected: themeId == 'system',
                      onTap: () => store.setSetting(Settings.theme, 'system'),
                    ),
                  for (final t in AppTheme.all)
                    if (t.group == group)
                      _ThemeTile(
                        label: t.name,
                        width: width,
                        background: t.background,
                        text: t.text,
                        accent: t.accent,
                        selected: themeId == t.id,
                        onTap: () => store.setSetting(Settings.theme, t.id),
                      ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            SettingsNote(
              'System is light or dark as this '
              '${isMobile ? 'device' : 'computer'} is set.',
            ),
          ],
        );
      },
    );
  }
}

/// What becomes of tasks: in the week, in lists, and when they remind.
class _TasksPage extends StatelessWidget {
  const _TasksPage();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final keep = store.setting<bool>(Settings.keepInList);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading('In the week', first: true),
        const _Toggle(
          'Move unfinished tasks to today',
          Settings.rollover,
          detail: 'Once a day, tasks left open on past days move to '
              'the top of today. Repeating tasks stay put.',
        ),
        const _Toggle('Sort completed tasks down', Settings.sortDoneDown),
        const _Toggle('Hide completed tasks', Settings.hideDone),
        const SettingsHeading('In lists'),
        SettingsRow(
          label: 'A task from a list, given a day',
          choices: true,
          control: Segmented<bool>(
            value: keep,
            options: const {true: 'Stays in its list', false: 'Leaves its list'},
            onChanged: (v) => store.setSetting(Settings.keepInList, v),
          ),
          detail: keep
              ? 'It shows in both places: on its day in the week '
                  'and, marked with that day, in its list.'
              : 'It moves to the week and is no longer in its list.',
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: SettingsNote(
            'A list keeps what was ticked today in its place until the day '
            'ends; older done tasks are folded away under its last line on '
            'the Tasks page. Sorting and hiding completed tasks is for the '
            'days of the week only.',
          ),
        ),
        const SettingsHeading('Reminders'),
        if (context.readAndroid case final android?)
          _NotificationPermission(android: android)
        else
          const SettingsNote(
            'A reminder set on a task appears as a notification at its '
            'time, while the app is open.',
          ),
      ],
    );
  }
}

/// Getting the planner out of the app and back into it.
class _DataPage extends StatefulWidget {
  const _DataPage();

  @override
  State<_DataPage> createState() => _DataPageState();
}

/// The parts of the data page, each of which says how its own doings went.
enum _DataPart { save, restore }

class _DataPageState extends State<_DataPage> {
  /// Result of the last export or restore, shown under the buttons of the
  /// part it belongs to.
  String? _message;
  bool _failed = false;
  _DataPart _at = _DataPart.save;

  void _report(String message, {bool failed = false, _DataPart at = _DataPart.restore}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _failed = failed;
      _at = at;
    });
  }

  static const _mimeTypes = {
    'json': 'application/json',
    'csv': 'text/csv',
    'ics': 'text/calendar',
    'txt': 'text/plain',
  };

  Future<void> _export(String label, String extension, String Function() build) async {
    final android = context.readAndroid;
    try {
      if (android != null) {
        // Android has no path to write to; its file picker hands out a
        // location in whichever storage app the user chooses.
        final saved = await android.saveDocument(
          name: 'fweek.$extension',
          mime: _mimeTypes[extension] ?? 'application/octet-stream',
          bytes: Uint8List.fromList(utf8.encode(build())),
        );
        if (saved) _report('Saved fweek.$extension', at: _DataPart.save);
        return;
      }
      final location = await getSaveLocation(
        suggestedName: 'fweek.$extension',
        acceptedTypeGroups: [XTypeGroup(label: label, extensions: [extension])],
      );
      if (location == null) return;
      var path = location.path;
      if (!path.toLowerCase().endsWith('.$extension')) path = '$path.$extension';
      await File(path).writeAsString(build(), flush: true);
      _report('Saved $path', at: _DataPart.save);
    } on Object catch (error) {
      _report('Could not save: $error', failed: true, at: _DataPart.save);
    }
  }

  Future<void> _import() async {
    final store = context.readStore;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'fweek backup',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
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

  Widget _said(_DataPart part) => _message == null || _at != part
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SettingsNote(_message!, failed: _failed),
        );

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final backups = AppScope.read(context).backups;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsNote(
          'Your planner is stored on this ${isMobile ? 'device' : 'computer'}, '
          'and in your Nextcloud or Google Drive if sync is on.',
        ),
        const SettingsHeading('Save to a file'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              icon: AppIcons.download,
              label: 'Backup',
              size: Dim.controlInline,
              iconSize: 16,
              onTap: () =>
                  _export('fweek backup', 'json', () => Export.backup(store)),
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
              onTap: () => _export('iCalendar', 'ics', () => Export.ics(store)),
            ),
            AppButton(
              label: 'Text',
              size: Dim.controlInline,
              onTap: () => _export('Plain text', 'txt', () => Export.text(store)),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SettingsNote(
            'A backup is the whole planner, and can be restored. The other '
            'three are for reading it elsewhere.',
          ),
        ),
        _said(_DataPart.save),
        const SettingsHeading('Restore'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              icon: AppIcons.upload,
              label: 'Restore backup',
              size: Dim.controlInline,
              iconSize: 16,
              onTap: _import,
            ),
            if (backups != null) _RestoreCopy(backups: backups, report: _report),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SettingsNote(
            'Restoring brings back what the backup holds: what was deleted '
            'since returns, and what was changed since is as it was then. '
            'What was added since stays.',
          ),
        ),
        _said(_DataPart.restore),
        if (backups != null) ...[
          const SettingsHeading('Copies on this device'),
          _KeptCopies(backups: backups),
        ],
      ],
    );
  }
}

/// For checking how the app runs.
class _AdvancedPage extends StatelessWidget {
  const _AdvancedPage();

  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toggle(
            'Show frame timing',
            Settings.frameTiming,
            detail: 'Draws two graphs over the app: time spent '
                'preparing each frame (below) and drawing it '
                '(above). Bars over the line are frames that came '
                'late. For checking smoothness on this device.',
          ),
        ],
      );
}

/// Android only: whether reminders can appear, and a way to allow them.
class _NotificationPermission extends StatefulWidget {
  const _NotificationPermission({required this.android});

  final AndroidBridge android;

  @override
  State<_NotificationPermission> createState() =>
      _NotificationPermissionState();
}

class _NotificationPermissionState extends State<_NotificationPermission> {
  bool? _allowed;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _check();
    // The answer may change in the system's settings while the app waits.
    _lifecycle = AppLifecycleListener(onResume: _check);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final allowed = await widget.android.notificationsAllowed();
    if (mounted) setState(() => _allowed = allowed);
  }

  Future<void> _allow() async {
    // The system shows its prompt only until it has been declined; after
    // that the switch lives in the system's settings.
    if (!await widget.android.requestNotifications()) {
      await widget.android.openNotificationSettings();
    }
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsNote(
          'A reminder set on a task appears as a notification at its time, '
          'whether or not the app is open.',
        ),
        if (_allowed == false) ...[
          const SizedBox(height: 8),
          const SettingsNote(
            'Notifications are turned off for fweek, so reminders cannot '
            'appear.',
            failed: true,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              icon: AppIcons.bell,
              label: 'Allow notifications',
              size: Dim.controlInline,
              iconSize: 16,
              onTap: _allow,
            ),
          ),
        ],
      ],
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.label,
    required this.width,
    required this.background,
    required this.text,
    required this.accent,
    required this.selected,
    required this.onTap,
    this.split = false,
  });

  final String label;

  /// 68 as drawn; everything in the tile grows with it.
  final double width;
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
    final s = width / 68;
    return Pressable(
      onTap: onTap,
      semanticLabel: '$label theme',
      builder: (context, hovered, pressed) => SizedBox(
        width: width,
        child: Column(
          spacing: 6,
          children: [
            Container(
              height: 48 * s,
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
                      left: 34 * s,
                      child: ColoredBox(color: accent),
                    ),
                  Positioned(
                    left: 9 * s,
                    top: 10 * s,
                    child: Container(width: 22 * s, height: 5 * s, color: text),
                  ),
                  Positioned(
                    left: 9 * s,
                    top: 21 * s,
                    child: Container(
                        width: 20 * s,
                        height: 2 * s,
                        color: text.withValues(alpha: 0.2)),
                  ),
                  Positioned(
                    left: 9 * s,
                    top: 29 * s,
                    child: Container(
                      width: 18 * s,
                      height: 8 * s,
                      decoration: BoxDecoration(
                        color: split ? const Color(0xFF5167F4) : accent,
                        borderRadius: BorderRadius.circular(4 * s),
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

String _copyName(LocalBackup copy, Day today) => switch (today.difference(copy.day)) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => '${Strings.weekdayShort(copy.day)}, ${Strings.dayMonth(copy.day)}'
          '${copy.day.year == today.year ? '' : ' ${copy.day.year}'}',
    };

/// Says which copies of the planner are kept on this device (the sync
/// button makes one a day).
class _KeptCopies extends StatelessWidget {
  const _KeptCopies({required this.backups});

  final LocalBackups backups;

  @override
  Widget build(BuildContext context) {
    // Read again when the planner changes: restoring one, for a start.
    final today = context.store.today;
    final copies = backups.list();
    // A phone has no button for it: there the page is pulled down.
    final how = isMobile
        ? 'Syncing (pull the page down from its top) makes one a day'
        : 'The sync button in the header makes one each day it is pressed';
    return SettingsNote(
      copies.isEmpty
          ? 'No copy of the planner is kept on this device yet. $how.'
          : 'Copies kept on this device: ${copies.length}, the latest from '
              '${_copyName(copies.first, today).toLowerCase()}. $how; the '
              '${backups.keep} latest are kept. "Restore a copy" above '
              'brings one back.',
    );
  }
}

/// The way to bring back one of the copies kept on this device. Shown only
/// when there is one.
class _RestoreCopy extends StatelessWidget {
  const _RestoreCopy({required this.backups, required this.report});

  final LocalBackups backups;
  final void Function(String message, {bool failed}) report;

  Future<void> _choose(BuildContext context) async {
    final store = context.readStore;
    final today = store.today;
    final copies = backups.list();
    final use24h = store.setting<bool>(Settings.use24h);
    final picked = await showPopover<LocalBackup>(
      context: context,
      anchor: globalRect(context),
      align: -1,
      builder: (popover) => PopoverSurface(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 264,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final copy in copies)
                    MenuRow(
                      icon: AppIcons.history,
                      label: _copyName(copy, today),
                      hint: formatTime(copy.written.hour * 60 + copy.written.minute,
                          use24h: use24h),
                      onTap: () => Navigator.of(popover).pop(copy),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    try {
      final count = Export.restore(store, picked.file.readAsStringSync());
      report('Restored $count tasks from the copy of '
          '${_copyName(picked, today).toLowerCase()}');
    } on FormatException catch (error) {
      report(error.message, failed: true);
    } on Object catch (error) {
      report('Could not read the copy: $error', failed: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Looked at again whenever the planner changes.
    context.store;
    if (backups.list().isEmpty) return const SizedBox.shrink();
    return Builder(
      builder: (anchor) => AppButton(
        icon: AppIcons.history,
        label: 'Restore a copy',
        size: Dim.controlInline,
        iconSize: 16,
        onTap: () => _choose(anchor),
      ),
    );
  }
}
