import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../theme/app_theme.dart';

/// What the pages of the settings are built from: headings, rows, notes and
/// form lines, so that every page reads the same way.

/// A heading inside a page, over the settings it gathers.
class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.title, {super.key, this.first = false});

  final String title;

  /// The first thing on its page: no space above it.
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: first ? 0 : 28, bottom: 8),
        child: Text(title, style: context.text.bodyBold17),
      );
}

/// Muted text that explains a setting, or says how something went.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.failed = false});

  final String text;

  /// Says that something went wrong.
  final bool failed;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: context.text.caption14.copyWith(
          color: failed ? AppTheme.danger : context.theme.ink(60),
        ),
      );
}

/// One setting: what it is called, what it does, and its control.
///
/// A switch sits beside its name. A row of choices needs more room: it sits
/// beside the name where the page is wide enough for both, and under it
/// otherwise (a phone, a narrow window).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.control,
    this.detail,
    this.choices = false,
  });

  final String label;
  final String? detail;
  final Widget control;

  /// Whether [control] is a row of choices rather than a switch.
  final bool choices;

  /// The width given to a row of choices beside its name.
  static const choicesWidth = 320.0;

  /// The narrowest page on which choices sit beside their name.
  static const besideFrom = 540.0;

  @override
  Widget build(BuildContext context) {
    final name = Text(label, style: context.text.body17);
    final note = detail == null ? null : SettingsNote(detail!);
    if (!choices) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [name, ?note],
              ),
            ),
            const SizedBox(width: 16),
            control,
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final beside = constraints.maxWidth >= besideFrom;
        return Padding(
          padding: EdgeInsets.symmetric(vertical: beside ? 8 : 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (beside)
                Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 16),
                    SizedBox(width: choicesWidth, child: control),
                  ],
                )
              else ...[
                name,
                const SizedBox(height: 8),
                control,
              ],
              if (note != null)
                Padding(padding: const EdgeInsets.only(top: 6), child: note),
            ],
          ),
        );
      },
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
    this.onBlur,
  });

  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final bool enabled;
  final VoidCallback? onSubmitted;

  /// Called when the field is left.
  final VoidCallback? onBlur;

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
              child: Focus(
                skipTraversal: true,
                onFocusChange: (focused) {
                  if (!focused) onBlur?.call();
                },
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
            ),
          ],
        ),
      ),
    );
  }
}
