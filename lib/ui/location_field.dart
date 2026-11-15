import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show TextField, InputDecoration, TextFieldTapRegion;

import '../app_state.dart';
import '../data/planner_store.dart';
import '../platform.dart';
import '../services/places.dart';
import '../theme/app_theme.dart';
import 'icons.dart';
import 'widgets/controls.dart';

/// A place typed as free text, with suggestions from the place search
/// while typing. Whatever is typed is kept as the location; picking a
/// suggestion also records where it is, so that the map can open exactly
/// there.
class LocationField extends StatefulWidget {
  const LocationField({
    super.key,
    required this.location,
    required this.geo,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.onDone,
    this.hint = 'Add a place',
  });

  final String location;
  final String? geo;

  /// Called with the text and, when it came from a suggestion, its
  /// position as `lat,lon`.
  final void Function(String location, String? geo) onChanged;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Called when the field is finished with: Enter, or a suggestion picked.
  final VoidCallback? onDone;
  final String hint;

  @override
  State<LocationField> createState() => _LocationFieldState();
}

class _LocationFieldState extends State<LocationField> {
  /// Long enough that a word typed at normal speed is one question, not one
  /// per letter: the search server is shared and asks for fair use.
  static const _pause = Duration(milliseconds: 350);

  /// Where the last picked place was; nearby results come first next time.
  static (double, double)? _lastPicked;

  late final _controller = TextEditingController(text: widget.location);
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  Timer? _timer;
  int _question = 0;
  List<Place> _places = const [];
  int _marked = -1;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(LocationField old) {
    super.didUpdateWidget(old);
    // Changed elsewhere (another device), but never under the cursor.
    if (widget.location != old.location &&
        widget.location != _controller.text &&
        !_focus.hasFocus) {
      _controller.text = widget.location;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) {
      _timer?.cancel();
      _question++;
      if (mounted) setState(() => _places = const []);
    }
  }

  void _typed(String text) {
    widget.onChanged(text, null);
    _timer?.cancel();
    final store = context.readStore;
    if (!store.setting<bool>(Settings.placeSearch) ||
        text.trim().length < PlaceSearch.minLength) {
      _question++;
      setState(() {
        _places = const [];
        _problem = null;
      });
      return;
    }
    _timer = Timer(_pause, () => _ask(text));
  }

  Future<void> _ask(String text) async {
    final search = context.readPlaces;
    final store = context.readStore;
    final question = ++_question;
    final server = store.setting<String>(Settings.placeServer);
    final places = await search.search(
      text,
      server: server.isEmpty ? PlaceSearch.defaultServer : server,
      language: PlatformDispatcher.instance.locale.languageCode,
      near: parseGeo(widget.geo) ?? _lastPicked,
    );
    // An answer to an older question, or to a field that is gone.
    if (!mounted || question != _question) return;
    setState(() {
      _places = places;
      _marked = -1;
      _problem = places.isEmpty ? search.lastError : null;
    });
  }

  void _pick(Place place) {
    _timer?.cancel();
    _question++;
    _lastPicked = (place.lat, place.lon);
    _controller.value = TextEditingValue(
      text: place.label,
      selection: TextSelection.collapsed(offset: place.label.length),
    );
    widget.onChanged(place.label, place.geo);
    setState(() => _places = const []);
    widget.onDone?.call();
  }

  void _clear() {
    _timer?.cancel();
    _question++;
    _controller.clear();
    widget.onChanged('', null);
    setState(() => _places = const []);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _places.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _marked = (_marked + 1) % _places.length);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _marked = (_marked <= 0 ? _places.length : _marked) - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() => _places = const []);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final style = context.text.body17;
    final muted = context.text.caption14.copyWith(color: theme.ink(60));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 8),
              child: Icon(AppIcons.mapPin, size: 16, color: theme.ink(60)),
            ),
            Expanded(
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  style: style,
                  cursorColor: theme.text,
                  maxLines: null,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration.collapsed(
                    hintText: widget.hint,
                    hintStyle: style.copyWith(color: theme.ink(25)),
                  ),
                  onChanged: _typed,
                  onSubmitted: (_) {
                    if (_marked >= 0 && _marked < _places.length) {
                      _pick(_places[_marked]);
                    } else {
                      setState(() => _places = const []);
                      widget.onDone?.call();
                    }
                  },
                ),
              ),
            ),
            if (_controller.text.isNotEmpty && _focus.hasFocus)
              AppButton(
                icon: AppIcons.x,
                kind: ButtonKind.ghost,
                size: Dim.controlSmall,
                iconSize: 15,
                tooltip: 'Remove the place',
                foreground: theme.ink(40),
                onTap: _clear,
              ),
          ],
        ),
        if (_places.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final (i, place) in _places.indexed)
            // Part of the field as far as the keyboard focus goes: a click
            // on a suggestion must not count as clicking away from the
            // field, which would close the list before the click lands.
            TextFieldTapRegion(
              child: Pressable(
              onTap: () => _pick(place),
              focusable: false,
              semanticLabel: place.label,
              builder: (context, hovered, pressed) => Container(
                constraints: BoxConstraints(minHeight: isMobile ? 48 : 40),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: hovered || i == _marked ? theme.ink(5) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.small15.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (place.detail.isNotEmpty)
                      Text(
                        place.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                  ],
                ),
              ),
              ),
            ),
          // Search results come from OpenStreetMap's data, which asks to be
          // credited where they are shown.
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            child: Text(
              '© OpenStreetMap contributors',
              style: context.text.tiny12.copyWith(color: theme.ink(40)),
            ),
          ),
        ] else if (_problem != null && _focus.hasFocus)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 4),
            child: Text(_problem!, style: muted),
          ),
      ],
    );
  }
}
