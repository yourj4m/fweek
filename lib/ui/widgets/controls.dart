import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import '../icons.dart';

import '../../platform.dart';
import '../../theme/app_theme.dart';

/// Makes the text below it selectable with the mouse or by a long press.
/// Whatever can be clicked ([Pressable] and the like) takes itself out, so
/// clicking, dragging and long presses on those behave as without this.
class Selectable extends StatelessWidget {
  const Selectable({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionArea(child: child);
}

/// Tracks hover and press for a tappable area and rebuilds with both.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
    this.semanticLabel,
    this.behavior = HitTestBehavior.opaque,
    this.onSecondaryTap,
    this.focusable = true,
    this.autofocus = false,
    this.focusRadius = 8,
    this.labelOnly = false,
  });

  /// Whether [semanticLabel] is all a screen reader is told, rather than
  /// that label followed by what the child says itself. For a button whose
  /// child is its own label, which would otherwise be read twice.
  final bool labelOnly;

  /// Called with `hovered` true under the pointer and also while the
  /// control holds the keyboard focus.
  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final MouseCursor cursor;
  final String? semanticLabel;
  final HitTestBehavior behavior;

  /// A click with the secondary mouse button, at a global position.
  final ValueChanged<Offset>? onSecondaryTap;

  /// Whether the Tab and arrow keys reach this control; Enter and Space
  /// then press it.
  final bool focusable;
  final bool autofocus;

  /// Corner radius of the ring drawn while it holds the keyboard focus.
  final double focusRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      widget.onTap?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    // Focus shows only when it was moved there with the keyboard.
    final keyed = enabled &&
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final secondary = widget.onSecondaryTap;
    Widget child = Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: widget.labelOnly && widget.semanticLabel != null,
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
          onSecondaryTapUp:
              secondary == null ? null : (details) => secondary(details.globalPosition),
          child: widget.builder(
              context, enabled && (_hovered || keyed), enabled && _pressed),
        ),
      ),
    );
    if (keyed) {
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.focusRadius),
          border: Border.all(color: context.theme.accent, width: 2),
        ),
        child: child,
      );
    }
    // What can be pressed is not text to select.
    child = SelectionContainer.disabled(child: child);
    if (!widget.focusable || !enabled) return child;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _onKey,
      child: child,
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
    this.turning,
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

  /// While given, the icon turns with it: something is under way.
  final Animation<double>? turning;

  @override
  Widget build(BuildContext context) {
    final button = _button(context);
    // A button that is only an icon says what it does when the pointer
    // rests on it. A finger has no way to rest without pressing.
    final hint = tooltip;
    return hint == null || label != null || isMobile
        ? button
        : HoverHint(text: hint, child: button);
  }

  Widget _button(BuildContext context) {
    final theme = context.theme;
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      semanticLabel: tooltip ?? label,
      labelOnly: true,
      focusRadius: 256,
      builder: (context, hovered, pressed) {
        Color background;
        Color content;
        if (selected) {
          background = theme.text.withValues(alpha: hovered || pressed ? 0.75 : 1);
          content = theme.background;
        } else {
          switch (kind) {
            case ButtonKind.primary:
              // With nothing to do it is a faint ground with a faint mark,
              // in dark themes as in light ones.
              background = !enabled
                  ? theme.ink(8)
                  : (fill ?? theme.navButton)
                      .withValues(alpha: hovered || pressed ? 0.75 : 1);
              content = !enabled ? theme.ink(30) : foreground ?? theme.navButtonIcon;
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
          if (icon != null)
            turning == null
                ? Icon(icon, size: iconSize, color: content)
                : RotationTransition(
                    turns: turning!,
                    child: Icon(icon, size: iconSize, color: content),
                  ),
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

/// Says in a few words what [child] is for, in a small label under it,
/// once the mouse pointer has rested on it for a moment. Moving off it, or
/// pressing it, takes the label away.
class HoverHint extends StatefulWidget {
  const HoverHint({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  /// How long the pointer rests before the label shows.
  static const delay = Duration(milliseconds: 600);

  @override
  State<HoverHint> createState() => _HoverHintState();
}

class _HoverHintState extends State<HoverHint> {
  final _portal = OverlayPortalController();
  Timer? _timer;
  Rect _target = Rect.zero;

  void _rest() {
    _timer?.cancel();
    _timer = Timer(HoverHint.delay, () {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      _target = box.localToGlobal(Offset.zero) & box.size;
      _portal.show();
    });
  }

  void _leave() {
    _timer?.cancel();
    _timer = null;
    if (_portal.isShowing) _portal.hide();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return MouseRegion(
      onEnter: (_) => _rest(),
      onExit: (_) => _leave(),
      child: Listener(
        onPointerDown: (_) => _leave(),
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (overlay) {
            // Light on dark where the page is light, and the other way
            // round, as the messages at the bottom of the window are.
            final ink = theme.isDark ? const Color(0xFF111111) : const Color(0xFFFFFFFF);
            final surface =
                theme.isDark ? const Color(0xFFF2F2F2) : const Color(0xFF222226);
            return IgnorePointer(
              child: ExcludeSemantics(
                child: CustomSingleChildLayout(
                  delegate: _HintLayout(_target),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.text,
                      maxLines: 1,
                      style: context.text.tiny12.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Places a hint under its target, centred on it, and inside the window;
/// above the target where there is no room below.
class _HintLayout extends SingleChildLayoutDelegate {
  _HintLayout(this.target);

  final Rect target;

  static const _gap = 6.0;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (target.center.dx - childSize.width / 2)
        .clamp(_margin, math.max(_margin, size.width - childSize.width - _margin))
        .toDouble();
    final below = target.bottom + _gap;
    final top = below + childSize.height + _margin <= size.height
        ? below
        : target.top - _gap - childSize.height;
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_HintLayout old) => old.target != target;
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
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (isMobile) {
      // Blurring what lies behind is among the costliest things a phone's
      // graphics chip can be asked for; there the surface is simply opaque.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.popover.withValues(alpha: 1),
          borderRadius: BorderRadius.circular(Dim.radiusL),
          boxShadow: const [
            BoxShadow(color: Color(0x26000000), blurRadius: 16, offset: Offset(0, 8)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Dim.radiusL),
          child: content,
        ),
      );
    }
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
          child: ColoredBox(color: theme.popover, child: content),
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
    this.autofocus = false,
  });

  /// Takes the keyboard focus when the menu opens.
  final bool autofocus;

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
      autofocus: autofocus,
      builder: (context, hovered, pressed) => Container(
        height: isMobile ? Dim.controlLarge : Dim.controlInline,
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
  ) {
    // Keep clear of the status bar, the navigation bar and the keyboard.
    final media = MediaQuery.of(context);
    final safe = media.padding.copyWith(
      bottom: math.max(media.padding.bottom, media.viewInsets.bottom),
    );
    return CustomSingleChildLayout(
      delegate: _PopoverLayout(anchor, side, gap, align, safe),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.ease),
        // The arrow keys move through a menu's rows; text in it (an event's
        // details) can be selected.
        child: FocusTraversalGroup(
          child: Selectable(child: Builder(builder: builder)),
        ),
      ),
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.anchor, this.side, this.gap, this.align, this.safe);

  final Rect anchor;
  final PopoverSide side;
  final double gap;
  final double align;

  /// The parts of the window's edges taken by system bars and the keyboard.
  final EdgeInsets safe;

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - 2 * _margin - safe.horizontal),
        maxHeight: math.max(0, constraints.maxHeight - 2 * _margin - safe.vertical),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final minX = safe.left + _margin, minY = safe.top + _margin;
    final maxX = size.width - safe.right - _margin - child.width;
    final maxY = size.height - safe.bottom - _margin - child.height;
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
    if (side == PopoverSide.below && y > maxY) {
      final above = anchor.top - gap - child.height;
      if (above >= minY) y = above;
    } else if (side == PopoverSide.above && y < minY) {
      final below = anchor.bottom + gap;
      if (below <= maxY) y = below;
    }
    x = x.clamp(minX, math.max(minX, maxX));
    y = y.clamp(minY, math.max(minY, maxY));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor ||
      old.side != side ||
      old.gap != gap ||
      old.align != align ||
      old.safe != safe;
}

/// Lays a dialog out in the part of the window left free by the status bar,
/// display cutouts and the on-screen keyboard, and tells it that this part
/// is the whole window. Only the navigation bar's height is passed on (as
/// bottom padding): a bottom sheet runs underneath that bar.
class DialogArea extends StatelessWidget {
  const DialogArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final taken = EdgeInsets.fromLTRB(
        media.padding.left, media.padding.top, media.padding.right, keyboard);
    final below = EdgeInsets.only(bottom: keyboard > 0 ? 0 : media.padding.bottom);
    return Padding(
      padding: taken,
      child: MediaQuery(
        data: media.copyWith(
          size: taken.deflateSize(media.size),
          padding: below,
          viewPadding: below,
          viewInsets: EdgeInsets.zero,
        ),
        child: child,
      ),
    );
  }
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
