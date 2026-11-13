import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../icons.dart';

import '../../theme/app_theme.dart';

/// Tracks hover and press for a tappable area and rebuilds with both.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
    this.semanticLabel,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final MouseCursor cursor;
  final String? semanticLabel;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: enabled ? widget.cursor : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: widget.behavior,
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          child: widget.builder(context, enabled && _hovered, enabled && _pressed),
        ),
      ),
    );
  }
}

enum ButtonKind { primary, secondary, ghost, danger }

/// A pill button: icon-only when [label] is null.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    this.icon,
    this.label,
    required this.onTap,
    this.kind = ButtonKind.secondary,
    this.size = Dim.controlMedium,
    this.selected = false,
    this.tooltip,
    this.fill,
    this.foreground,
    this.iconSize = 20,
    this.expand = false,
  });

  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final ButtonKind kind;

  /// Control height: 32, 36, 40 or 44.
  final double size;

  /// Draws the button in its "on" state (black fill).
  final bool selected;
  final String? tooltip;

  /// Overrides the resting fill and content colour (used by the header's
  /// coloured menu button).
  final Color? fill;
  final Color? foreground;
  final double iconSize;

  /// Stretch to the available width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      semanticLabel: tooltip ?? label,
      builder: (context, hovered, pressed) {
        Color background;
        Color content;
        if (selected) {
          background = theme.text.withValues(alpha: hovered || pressed ? 0.75 : 1);
          content = theme.background;
        } else {
          switch (kind) {
            case ButtonKind.primary:
              background = !enabled
                  ? theme.ink(15)
                  : (fill ?? theme.navButton)
                      .withValues(alpha: hovered || pressed ? 0.75 : 1);
              content = foreground ?? theme.navButtonIcon;
            case ButtonKind.secondary:
              background = fill != null
                  ? fill!.withValues(alpha: hovered || pressed ? 0.75 : 1)
                  : theme.ink(pressed ? 15 : hovered ? 10 : 5);
              content = foreground ?? (enabled ? theme.text : theme.ink(20));
            case ButtonKind.ghost:
              background = pressed
                  ? theme.ink(10)
                  : hovered
                      ? theme.ink(5)
                      : const Color(0x00000000);
              content = foreground ?? (enabled ? theme.text : theme.ink(20));
            case ButtonKind.danger:
              background = !enabled
                  ? theme.ink(15)
                  : hovered || pressed
                      ? AppTheme.dangerPressed
                      : AppTheme.danger;
              content = const Color(0xFFFFFFFF);
          }
        }
        final small = size <= Dim.controlSmall;
        final textStyle = (small ? context.text.small15 : context.text.bodyBold17)
            .copyWith(color: content);
        final children = <Widget>[
          if (icon != null) Icon(icon, size: iconSize, color: content),
          if (label != null) Text(label!, style: textStyle, maxLines: 1),
        ];
        return AnimatedContainer(
          duration: hovered ? Duration.zero : Dim.fast,
          height: size,
          width: label == null ? size : (expand ? double.infinity : null),
          padding: label == null
              ? EdgeInsets.zero
              : EdgeInsets.symmetric(horizontal: small ? 12 : size >= 44 ? 24 : 18),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(256),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: small ? 6 : 10,
            children: children,
          ),
        );
      },
    );
  }
}

/// An on/off switch.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Pressable(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      builder: (context, hovered, pressed) => AnimatedContainer(
        duration: Dim.medium,
        width: 44,
        height: 26,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? theme.text : theme.ink(20),
          borderRadius: BorderRadius.circular(13),
        ),
        child: AnimatedAlign(
          duration: Dim.medium,
          curve: Curves.ease,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: theme.background,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of mutually exclusive choices.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      height: Dim.controlLarge,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.ink(5),
        borderRadius: BorderRadius.circular(Dim.radiusM),
      ),
      child: Row(
        children: [
          for (final entry in options.entries)
            Expanded(
              child: Pressable(
                onTap: () => onChanged(entry.key),
                builder: (context, hovered, pressed) {
                  final on = entry.key == value;
                  return AnimatedContainer(
                    duration: Dim.fast,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on
                          ? theme.dialog
                          : hovered
                              ? theme.ink(5)
                              : const Color(0x00000000),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      entry.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: on ? context.text.bodyBold17 : context.text.body17,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The translucent rounded surface behind menus and pickers.
class PopoverSurface extends StatelessWidget {
  const PopoverSurface({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Dim.radiusL),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Dim.radiusL),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: ColoredBox(
            color: theme.popover,
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }
}

/// One line of a menu: optional icon, label, optional trailing widget.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.danger = false,
    this.checked,
    this.hint,
  });

  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  /// When non-null the row reserves a leading check-mark column.
  final bool? checked;

  /// Muted text at the right edge, such as a keyboard shortcut.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final enabled = onTap != null;
    final color = !enabled
        ? theme.ink(25)
        : danger
            ? AppTheme.danger
            : theme.text;
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, pressed) => Container(
        height: Dim.controlInline,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: hovered ? theme.ink(5) : const Color(0x00000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (checked != null)
              SizedBox(
                width: 26,
                child: checked!
                    ? Icon(AppIcons.check, size: 16, color: color)
                    : null,
              ),
            if (icon != null) ...[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body17.copyWith(color: color),
              ),
            ),
            if (hint != null)
              Text(hint!, style: context.text.small15.copyWith(color: theme.ink(40))),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

enum PopoverSide { below, above }

/// Shows [builder]'s widget next to [anchor] (a rectangle in global
/// coordinates), kept inside the window. A click outside or Escape closes it.
Future<T?> showPopover<T>({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
  PopoverSide side = PopoverSide.below,
  double gap = 6,

  /// −1 aligns left edges, 0 centres on the anchor, 1 aligns right edges.
  double align = 0,
}) {
  final theme = context.theme;
  return Navigator.of(context, rootNavigator: true).push<T>(
    _PopoverRoute<T>(
      anchor: anchor,
      side: side,
      gap: gap,
      align: align,
      builder: (context) => ThemeScope(theme: theme, child: builder(context)),
    ),
  );
}

/// The global rectangle of the widget owning [context].
Rect globalRect(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({
    required this.anchor,
    required this.side,
    required this.gap,
    required this.align,
    required this.builder,
  });

  final Rect anchor;
  final PopoverSide side;
  final double gap;
  final double align;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => Dim.fast;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      CustomSingleChildLayout(
        delegate: _PopoverLayout(anchor, side, gap, align),
        child: FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.ease),
          child: builder(context),
        ),
      );
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.anchor, this.side, this.gap, this.align);

  final Rect anchor;
  final PopoverSide side;
  final double gap;
  final double align;

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: constraints.maxWidth - 2 * _margin,
        maxHeight: constraints.maxHeight - 2 * _margin,
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final centred = anchor.center.dx - child.width / 2;
    final left = anchor.left;
    final right = anchor.right - child.width;
    var x = align < 0
        ? left + (centred - left) * (1 + align)
        : centred + (right - centred) * align;
    var y = side == PopoverSide.below
        ? anchor.bottom + gap
        : anchor.top - gap - child.height;
    // Flip to the other side when there is no room, then clamp to the window.
    if (side == PopoverSide.below && y + child.height > size.height - _margin) {
      final above = anchor.top - gap - child.height;
      if (above >= _margin) y = above;
    } else if (side == PopoverSide.above && y < _margin) {
      final below = anchor.bottom + gap;
      if (below + child.height <= size.height - _margin) y = below;
    }
    x = x.clamp(_margin, (size.width - child.width - _margin).clamp(_margin, double.infinity));
    y = y.clamp(_margin, (size.height - child.height - _margin).clamp(_margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor || old.side != side || old.gap != gap || old.align != align;
}

/// Closes the nearest route when Escape is pressed.
class EscapeToClose extends StatelessWidget {
  const EscapeToClose({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: child,
      );
}
