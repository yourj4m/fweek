import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../calendar/ics_import.dart';
import '../data/planner_store.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'strings.dart';
import 'task_dialog.dart';
import 'task_list.dart' show formatTime;
import 'widgets/controls.dart';

/// A calendar file as it was read: what it is called and what it says.
typedef CalendarFile = ({String name, String text});

/// Takes the events of calendar files (`.ics`) into the planner and shows
/// what was added, with a way to each of them and a way to take them out
/// again. A file that is no calendar is named in a message instead.
Future<void> importCalendarFiles(BuildContext context, List<CalendarFile> files) async {
  if (files.isEmpty) return;
  final store = context.readStore;
  final app = context.readApp;
  final items = <ImportedItem>[];
  final from = <String>[], refused = <String>[];
  var skipped = 0;
  for (final file in files) {
    try {
      final result = IcsImport.run(store, file.text);
      items.addAll(result.items);
      skipped += result.skipped;
      from.add(file.name);
    } on FormatException {
      refused.add(file.name);
    }
  }
  if (from.isEmpty) {
    app.say(refused.length == 1
        ? '${refused.single} is not a calendar file'
        : 'None of these is a calendar file');
    return;
  }
  items.sort((a, b) {
    final byDay = a.day.compareTo(b.day);
    return byDay != 0 ? byDay : (a.time ?? -1).compareTo(b.time ?? -1);
  });
  await showCard(
    context,
    (card) => _Recap(
      root: context,
      items: items,
      from: from,
      refused: refused,
      skipped: skipped,
    ),
  );
}

class _Recap extends StatelessWidget {
  const _Recap({
    required this.root,
    required this.items,
    required this.from,
    required this.refused,
    required this.skipped,
  });

  /// Where the planner is: the card itself is gone when an item opens.
  final BuildContext root;
  final List<ImportedItem> items;
  final List<String> from;
  final List<String> refused;
  final int skipped;

  static String _count(int n, String one) => n == 1 ? 'one $one' : '$n ${one}s';

  void _show(BuildContext context, ImportedItem item) {
    Navigator.of(context).pop();
    if (!root.mounted) return;
    root.readApp
      ..setMonthView(false)
      ..show(item.day, highlight: item.id, focus: true);
    showTaskDialog(root, item.id);
  }

  void _undo(BuildContext context) {
    final store = root.readStore;
    final added = items.where((i) => i.isNew).toList();
    for (final item in added) {
      store.deleteTask(item.id, wholeSeries: true);
    }
    Navigator.of(context).pop();
    if (root.mounted) {
      root.readApp.say('${_count(added.length, 'event')} taken out again');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final use24h = store.setting<bool>(Settings.use24h);
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < Dim.breakpoint;
    final added = items.where((i) => i.isNew).length;
    final updated = items.length - added;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));

    final summary = [
      if (added > 0) '${_count(added, 'event')} added',
      if (updated > 0) '$updated already there, brought up to date',
      if (items.isEmpty) 'No events in it',
      if (skipped > 0) '$skipped could not be read',
      if (refused.isNotEmpty) '${refused.join(', ')}: not a calendar file',
    ].join(' · ');

    String when(ImportedItem item) {
      final time = item.time;
      if (time == null) return 'all day';
      final start = formatTime(time, use24h: use24h);
      return item.end == null ? start : '$start – ${formatTime(item.end!, use24h: use24h)}';
    }

    return EscapeToClose(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: narrow ? 16 : Dim.dialogTop,
            left: 16,
            right: 16,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Dim.dialogWidth),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.dialog,
                borderRadius: BorderRadius.circular(Dim.dialogRadius),
              ),
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(AppIcons.calendarPlus, size: 20, color: theme.text),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'From ${from.join(', ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.heading21,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(summary, style: muted),
                  if (items.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: size.height * 0.5),
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: [
                            for (final item in items)
                              Pressable(
                                onTap: () => _show(context, item),
                                semanticLabel:
                                    'Show ${item.title}, ${Strings.fullDate(item.day)}',
                                labelOnly: true,
                                builder: (context, hovered, pressed) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 9, horizontal: 10),
                                  decoration: BoxDecoration(
                                    color: hovered || pressed ? theme.ink(5) : null,
                                    borderRadius: BorderRadius.circular(Dim.radiusM),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: context.text.body17,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                Strings.dateRange(
                                                    item.day, item.lastDay ?? item.day),
                                                when(item),
                                                if (item.recurrence case final rule?)
                                                  Strings.describe(rule, item.day),
                                                if (!item.isNew) 'was there already',
                                              ].join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: muted,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(AppIcons.chevronRight,
                                          size: 16, color: theme.ink(40)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (added > 0)
                        AppButton(
                          label: 'Undo',
                          size: Dim.controlMedium,
                          onTap: () => _undo(context),
                        ),
                      const Spacer(),
                      AppButton(
                        label: 'Done',
                        kind: ButtonKind.primary,
                        size: Dim.controlMedium,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
