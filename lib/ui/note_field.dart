import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show TextField, InputDecoration;

import '../app_state.dart';
import '../text/links.dart';
import '../theme/app_theme.dart';

/// How a link looks: underlined in the text's own colour, so that it reads
/// on any card colour without shouting.
TextStyle _linkStyle(Color ink) => TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: ink.withValues(alpha: ink.a * 0.55),
    );

/// A text controller that underlines the links in what is typed.
class LinkTextController extends TextEditingController {
  LinkTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // While the keyboard is still composing a word, leave the marking of
    // that word to the framework.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final pieces = linkify(text);
    if (!pieces.any((p) => p.isLink)) return TextSpan(style: style, text: text);
    final link = _linkStyle(style?.color ?? const Color(0xFF000000));
    return TextSpan(
      style: style,
      children: [
        for (final piece in pieces)
          TextSpan(text: piece.text, style: piece.isLink ? link : null),
      ],
    );
  }
}

/// Text whose links can be clicked: a web address opens in the browser, a
/// mail address in the mail program. The text can be selected like any
/// other.
class LinkedText extends StatefulWidget {
  const LinkedText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.onTapText,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;

  /// Called for a tap that hit no link, with the tapped position in the
  /// text.
  final ValueChanged<int>? onTapText;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final _key = GlobalKey();
  List<TextPiece> _pieces = const [];
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(LinkedText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _prepare();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _prepare() {
    _release();
    _pieces = linkify(widget.text);
    for (final piece in _pieces) {
      if (!piece.isLink) continue;
      _recognizers.add(
        TapGestureRecognizer()
          ..onTap = () => context.readOpener.open(piece.url!),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _linkStyle(widget.style.color ?? context.theme.text);
    var next = 0;
    final rich = Text.rich(
      key: _key,
      TextSpan(
        children: [
          for (final piece in _pieces)
            piece.isLink
                ? TextSpan(
                    text: piece.text,
                    style: link,
                    recognizer: _recognizers[next++],
                    mouseCursor: SystemMouseCursors.click,
                    semanticsLabel: 'Link: ${piece.text}',
                  )
                : TextSpan(text: piece.text),
        ],
      ),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
    );
    final onTapText = widget.onTapText;
    if (onTapText == null) return rich;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final paragraph = _key.currentContext?.findRenderObject();
        if (paragraph is! RenderParagraph) return onTapText(widget.text.length);
        final local = paragraph.globalToLocal(details.globalPosition);
        onTapText(paragraph.getPositionForOffset(local).offset);
      },
      child: rich,
    );
  }
}

/// A notes field that shows its links. While it is being typed in, links
/// are underlined; otherwise they can be clicked, and a click anywhere else
/// starts typing at that place.
class NoteField extends StatefulWidget {
  const NoteField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.hint,
    required this.onChanged,
    this.minLines = 1,
  });

  /// Should be a [LinkTextController], so links show while typing too.
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final String hint;
  final VoidCallback onChanged;
  final int minLines;

  @override
  State<NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<NoteField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(NoteField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final text = widget.controller.text;
    final reading = !widget.focusNode.hasFocus && hasLinks(text);
    final lineHeight = widget.style.fontSize! * (widget.style.height ?? 1.2);
    // The field stays in the tree while the links are shown over it, so
    // that it keeps its place in the keyboard's Tab order and can take the
    // focus the moment the text is tapped.
    final field = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      style: widget.style,
      cursorColor: theme.text,
      maxLines: null,
      minLines: widget.minLines,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration.collapsed(
        hintText: widget.hint,
        hintStyle: widget.style.copyWith(color: theme.ink(25)),
      ),
      onChanged: (_) => widget.onChanged(),
    );
    if (!reading) return field;
    return Stack(
      children: [
        Visibility(
          visible: false,
          maintainState: true,
          maintainSize: true,
          maintainAnimation: true,
          maintainInteractivity: false,
          // It must be able to take the keyboard: that is what brings it
          // back in place of the links.
          maintainFocusability: true,
          child: field,
        ),
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            // A tap below the last line starts typing at the end.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.controller.selection =
                    TextSelection.collapsed(offset: text.length);
                widget.focusNode.requestFocus();
              },
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: lineHeight * widget.minLines),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: LinkedText(
                    text,
                    style: widget.style,
                    onTapText: (offset) {
                      widget.controller.selection = TextSelection.collapsed(
                          offset: offset.clamp(0, text.length));
                      widget.focusNode.requestFocus();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
