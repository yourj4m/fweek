import 'package:flutter/widgets.dart';
import 'icons.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import 'strings.dart';
import 'task_dialog.dart';
import 'task_list.dart';
import 'widgets/controls.dart';

/// Opens search: a text field, colour filters, and matching tasks.
Future<void> showSearchDialog(BuildContext context) =>
    showCard(context, (context) => const _SearchDialog());

class _SearchDialog extends StatefulWidget {
  const _SearchDialog();

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _query = TextEditingController();
  String? _color;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(Task task) {
    final app = context.readApp;
    final navigator = Navigator.of(context);
    final root = navigator.context;
    navigator.pop();
    final day = task.date;
    if (day != null) {
      app.setMonthView(false);
      app.show(day, highlight: task.id);
    }
    showTaskDialog(root, task.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final store = context.store;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < Dim.breakpoint;
    final results = store.search(_query.text, color: _color);
    final usedColors = {
      for (final t in store.allTasks)
        if (t.color != null) t.color!,
    };
    final filters = [
      for (final c in TaskColor.palette)
        if (usedColors.contains(c.key)) c,
      for (final key in usedColors)
        if (key.startsWith('#')) ?TaskColor.resolve(key),
    ];
    final empty = _query.text.trim().isEmpty && _color == null;

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
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: Dim.controlLarge,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: theme.ink(5),
                      borderRadius: BorderRadius.circular(Dim.radiusM),
                    ),
                    child: Row(
                      children: [
                        Icon(AppIcons.search, size: 18, color: theme.ink(40)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _query,
                            autofocus: true,
                            style: context.text.body17,
                            cursorColor: theme.text,
                            decoration: InputDecoration.collapsed(
                              hintText: 'Search',
                              hintStyle: context.text.body17
                                  .copyWith(color: theme.ink(40)),
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) {
                              if (results.isNotEmpty) _open(results.first);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (filters.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final c in filters)
                          Pressable(
                            onTap: () => setState(
                                () => _color = _color == c.key ? null : c.key),
                            semanticLabel: 'Only ${c.name}',
                            builder: (context, hovered, pressed) => SizedBox(
                              width: 32,
                              height: 32,
                              child: Center(
                                child: AnimatedContainer(
                                  duration: Dim.fast,
                                  width: _color == c.key || hovered ? 24 : 18,
                                  height: _color == c.key || hovered ? 24 : 18,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: c.key == 'black' ? theme.text : c.fill,
                                  ),
                                  child: _color == c.key
                                      ? Icon(
                                          AppIcons.check,
                                          size: 14,
                                          color: c.key == 'black'
                                              ? theme.background
                                              : c.onFill,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (empty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'Type to search titles, notes and subtasks.',
                        textAlign: TextAlign.center,
                        style: context.text.small15.copyWith(color: theme.ink(40)),
                      ),
                    )
                  else if (results.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'Nothing found.',
                        textAlign: TextAlign.center,
                        style: context.text.small15.copyWith(color: theme.ink(40)),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemExtent: Dim.row,
                        itemBuilder: (context, index) {
                          final task = results[index];
                          final list = task.listId == null
                              ? null
                              : store.list(task.listId!);
                          final where = task.date != null
                              ? '${Strings.dayMonth(task.date!)} ${task.date!.year}'
                              : (list == null || list.title.isEmpty
                                  ? 'Someday'
                                  : list.title);
                          return Pressable(
                            onTap: () => _open(task),
                            builder: (context, hovered, pressed) => Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: hovered ? theme.hoverRule : theme.rule,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: TaskPill(
                                        task: task,
                                        style: context.text.task14,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    where,
                                    style: context.text.caption14
                                        .copyWith(color: theme.ink(40)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
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
