import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'event_rows.dart';
import 'icons.dart';
import 'sync_settings.dart' show SettingsField;
import 'widgets/controls.dart';

/// The "Calendars" part of the settings: calendars whose events the planner
/// shows, and a form to subscribe to another.
class CalendarSettings extends StatefulWidget {
  const CalendarSettings({super.key});

  @override
  State<CalendarSettings> createState() => _CalendarSettingsState();
}

class _CalendarSettingsState extends State<CalendarSettings> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  bool _adding = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
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

  static String _ago(DateTime then, DateTime now) {
    final minutes = now.difference(then).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    if (minutes < 24 * 60) return '${minutes ~/ 60} h ago';
    return 'on ${then.day}.${then.month}.${then.year}';
  }

  /// The next palette colour after the calendar's current one.
  static String _nextColor(String current) {
    final keys = [for (final c in TaskColor.palette) c.key];
    return keys[(keys.indexOf(current) + 1) % keys.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final calendars = context.calendars;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));
    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Show the events of another calendar in your week. They are read '
          'from the calendar\'s iCal address and cannot be changed here.',
          style: muted,
        ),
        const SizedBox(height: 8),
        for (final calendar in calendars.subscriptions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Pressable(
                  onTap: () =>
                      calendars.setColor(calendar.id, _nextColor(calendar.color)),
                  semanticLabel: 'Change the colour of ${calendar.name}',
                  builder: (context, hovered, pressed) => SizedBox(
                    width: 32,
                    height: 36,
                    child: Center(
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: calendarColor(context, calendar),
                          shape: BoxShape.circle,
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
                      Text(
                        calendar.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.body17,
                      ),
                      Text(
                        calendar.error ??
                            [
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
                  icon: AppIcons.trash2,
                  kind: ButtonKind.ghost,
                  size: Dim.controlSmall,
                  iconSize: 16,
                  tooltip: 'Remove ${calendar.name}',
                  onTap: () => calendars.remove(calendar.id),
                ),
              ],
            ),
          ),
        if (calendars.subscriptions.isNotEmpty) ...[
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
          'and is not synced: add it on each device.',
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
      ],
    );
  }
}
