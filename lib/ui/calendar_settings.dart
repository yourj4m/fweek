import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../calendar/calendar_service.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'ics_import_dialog.dart';
import 'icons.dart';
import 'pickers.dart';
import 'sync_settings.dart' show SettingsField;
import 'task_list.dart' show calendarColor;
import 'widgets/controls.dart';

/// The "Calendars" part of the settings: the calendars whose events the
/// planner shows, each with its colour, its name and a switch to show or
/// hide it, and a form to subscribe to another.
class CalendarSettings extends StatefulWidget {
  const CalendarSettings({super.key});

  @override
  State<CalendarSettings> createState() => _CalendarSettingsState();
}

class _CalendarSettingsState extends State<CalendarSettings> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  final _rename = TextEditingController();
  final _renameFocus = FocusNode();
  String? _renaming;
  bool _adding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _renameFocus.addListener(() {
      if (!_renameFocus.hasFocus) _finishRename();
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _rename.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final calendars = context.readCalendars;
    setState(() {
      _adding = true;
      _error = null;
    });
    final error = await calendars.add(address: _address.text, name: _name.text);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _error = error;
      if (error == null) {
        _address.clear();
        _name.clear();
      }
    });
  }

  void _startRename(CalendarSubscription calendar) {
    _rename.text = calendar.name;
    setState(() => _renaming = calendar.id);
    _renameFocus.requestFocus();
  }

  void _finishRename() {
    final id = _renaming;
    if (id == null) return;
    context.readCalendars.rename(id, _rename.text);
    if (mounted) setState(() => _renaming = null);
  }

  Future<void> _pickColor(BuildContext anchor, CalendarSubscription calendar) async {
    final calendars = context.readCalendars;
    await showPopover<void>(
      context: context,
      anchor: globalRect(anchor),
      align: -1,
      builder: (popover) => PopoverSurface(
        child: ColorPalette(
          selected: calendar.color,
          onPick: (color) {
            // A calendar always has a colour; "none" is black.
            calendars.setColor(calendar.id, color ?? 'black');
            Navigator.of(popover).pop();
          },
        ),
      ),
    );
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
    final calendars = context.calendars;
    return ListenableBuilder(
      // Downloads come and go without the calendars changing; this part
      // shows their progress and outcome.
      listenable: calendars.status,
      builder: (context, _) => _build(context, theme, calendars),
    );
  }

  Widget _build(BuildContext context, AppTheme theme, CalendarService calendars) {
    final subscriptions = calendars.subscriptions;
    final elsewhere = calendars.elsewhere;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));
    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Show the events of another calendar in your week, read from the '
          'calendar\'s iCal address. In the planner you can move, recolour, '
          'annotate and hide them; the calendar itself is never changed.',
          style: muted,
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < subscriptions.length; i++)
          Builder(builder: (context) {
            final calendar = subscriptions[i];
            final shown = !calendar.hidden;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Builder(
                    builder: (anchor) => Pressable(
                      onTap: () => _pickColor(anchor, calendar),
                      semanticLabel: 'Change the colour of ${calendar.name}',
                      focusRadius: 18,
                      builder: (context, hovered, pressed) => SizedBox(
                        width: 36,
                        height: 40,
                        child: Center(
                          child: AnimatedContainer(
                            duration: Dim.fast,
                            width: hovered ? 18 : 14,
                            height: hovered ? 18 : 14,
                            decoration: BoxDecoration(
                              color: calendarColor(theme, calendar.color)
                                  .withValues(alpha: shown ? 1 : 0.35),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_renaming == calendar.id)
                          TextField(
                            controller: _rename,
                            focusNode: _renameFocus,
                            style: context.text.body17,
                            cursorColor: theme.text,
                            maxLines: 1,
                            decoration: const InputDecoration.collapsed(hintText: 'Name'),
                            onSubmitted: (_) => _renameFocus.unfocus(),
                          )
                        else
                          Pressable(
                            onTap: () => _startRename(calendar),
                            cursor: SystemMouseCursors.text,
                            semanticLabel: 'Rename ${calendar.name}',
                            builder: (context, hovered, pressed) => Text(
                              calendar.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.body17.copyWith(
                                color: shown ? theme.text : theme.ink(40),
                              ),
                            ),
                          ),
                        Text(
                          calendar.error ??
                              [
                                if (!shown) 'hidden',
                                if (calendar.events != null)
                                  '${calendar.events} events',
                                if (calendar.fetched != null)
                                  'read ${_ago(calendar.fetched!, now)}',
                              ].join(' · '),
                          style: calendar.error == null
                              ? muted
                              : muted.copyWith(color: AppTheme.danger),
                        ),
                      ],
                    ),
                  ),
                  AppButton(
                    icon: shown ? AppIcons.eye : AppIcons.eyeOff,
                    kind: ButtonKind.ghost,
                    size: isMobile ? Dim.controlLarge : Dim.controlSmall,
                    iconSize: 18,
                    foreground: shown ? theme.text : theme.ink(40),
                    tooltip: shown ? 'Hide ${calendar.name}' : 'Show ${calendar.name}',
                    onTap: () => calendars.setHidden(calendar.id, shown),
                  ),
                  if (subscriptions.length > 1)
                    AppButton(
                      icon: AppIcons.arrowUp,
                      kind: ButtonKind.ghost,
                      size: isMobile ? Dim.controlLarge : Dim.controlSmall,
                      iconSize: 16,
                      tooltip: 'Move ${calendar.name} up',
                      onTap: i == 0 ? null : () => calendars.move(calendar.id, -1),
                    ),
                  AppButton(
                    icon: AppIcons.trash2,
                    kind: ButtonKind.ghost,
                    size: isMobile ? Dim.controlLarge : Dim.controlSmall,
                    iconSize: 16,
                    tooltip: 'Remove ${calendar.name}',
                    onTap: () => calendars.remove(calendar.id),
                  ),
                ],
              ),
            );
          }),
        if (subscriptions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              icon: AppIcons.refreshCw,
              label: calendars.refreshing ? 'Reading…' : 'Read again now',
              size: Dim.controlInline,
              iconSize: 16,
              onTap: calendars.refreshing ? null : calendars.refresh,
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (elsewhere.isNotEmpty) ...[
          Text('On your other devices', style: context.text.small15),
          const SizedBox(height: 2),
          Text(
            'Known from another device. To show one here too, add its '
            'address below.',
            style: muted,
          ),
          for (final row in elsewhere)
            Row(
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: calendarColor(theme, row.color ?? 'black')
                            .withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    row.name.isEmpty ? 'Calendar' : row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.body17.copyWith(color: theme.ink(60)),
                  ),
                ),
                AppButton(
                  icon: AppIcons.x,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 16,
                  tooltip: 'Forget ${row.name}',
                  onTap: () => calendars.forget(row.id),
                ),
              ],
            ),
          const SizedBox(height: 14),
        ],
        SettingsField(
          label: 'Address',
          hint: 'https://…/basic.ics',
          controller: _address,
          enabled: !_adding,
          onSubmitted: _add,
        ),
        SettingsField(
          label: 'Name',
          hint: 'optional',
          controller: _name,
          enabled: !_adding,
          onSubmitted: _add,
        ),
        const SizedBox(height: 4),
        Text(
          'Google Calendar: Settings → the calendar → Integrate calendar → '
          '"Secret address in iCal format". Anyone who has this address can '
          'read the calendar, so it is kept '
          '${isMobile ? 'encrypted on this device' : 'in the system keyring'} '
          'and is never synced: add it on each device. Neither are the '
          'calendar\'s events. What does sync with your planner is what you '
          'arrange here: a calendar\'s name, colour and whether it is shown, '
          'and your changes to single events.',
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
            label: _adding ? 'Reading…' : 'Add calendar',
            kind: ButtonKind.primary,
            size: Dim.controlMedium,
            onTap: _adding ? null : _add,
          ),
        ),
        const SizedBox(height: 18),
        Text('A calendar file', style: context.text.small15),
        const SizedBox(height: 2),
        Text(
          'The events of an .ics file (an invitation, an export) are added '
          'to your planner as events of your own, and sync with it. '
          '${isMobile ? '' : 'You can also drop such a file anywhere on the window. '}'
          'The same file again brings them up to date.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            icon: AppIcons.calendarPlus,
            label: 'Import a calendar file…',
            size: Dim.controlInline,
            iconSize: 16,
            onTap: _importFile,
          ),
        ),
      ],
    );
  }

  Future<void> _importFile() async {
    final XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Calendar file',
            extensions: ['ics', 'ical'],
            mimeTypes: ['text/calendar'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final text = await file.readAsString();
      if (!mounted) return;
      await importCalendarFiles(context, [(name: file.name, text: text)]);
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Could not read the file: $error');
    }
  }
}
