/// A run of text, possibly a link.
class TextPiece {
  const TextPiece(this.text, [this.url]);

  /// What is shown.
  final String text;

  /// What a tap opens (`https://…`, `mailto:…`); null for plain text.
  final String? url;

  bool get isLink => url != null;

  @override
  bool operator ==(Object other) =>
      other is TextPiece && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);

  @override
  String toString() => isLink ? 'Link($text → $url)' : 'Text($text)';
}

/// Web addresses (with a scheme, or starting `www.`) and mail addresses.
final _link = RegExp(
  r'(?:https?://|www\.)[^\s<>" ]+'
  r'|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
  caseSensitive: false,
);

int _count(String text, String char) {
  var n = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == char) n++;
  }
  return n;
}

/// Splits [text] into plain runs and links. Joined, the pieces' texts give
/// [text] back exactly.
List<TextPiece> linkify(String text) {
  final out = <TextPiece>[];
  var at = 0;
  for (final match in _link.allMatches(text)) {
    if (match.start < at) continue;
    var found = match[0]!;
    // Punctuation after an address belongs to the sentence, and so does a
    // closing bracket whose opening one stands before the address.
    while (found.isNotEmpty) {
      final last = found[found.length - 1];
      final closes = last == ')' && _count(found, '(') < _count(found, ')') ||
          last == ']' && _count(found, '[') < _count(found, ']');
      if (!closes && !'.,;:!?\'"'.contains(last)) break;
      found = found.substring(0, found.length - 1);
    }
    final lower = found.toLowerCase();
    final String url;
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      url = found;
    } else if (lower.startsWith('www.')) {
      url = 'https://$found';
    } else {
      url = 'mailto:$found';
    }
    final parsed = Uri.tryParse(url);
    final usable = parsed != null &&
        (parsed.scheme == 'mailto' || parsed.host.contains('.') || parsed.host == 'localhost');
    if (found.isEmpty || !usable) continue;
    if (match.start > at) out.add(TextPiece(text.substring(at, match.start)));
    out.add(TextPiece(found, url));
    at = match.start + found.length;
  }
  if (at < text.length) out.add(TextPiece(text.substring(at)));
  return out;
}

/// Whether [text] holds at least one link.
bool hasLinks(String text) => linkify(text).any((p) => p.isLink);

final _tag = RegExp(r'</?[a-zA-Z][^>]*>|<!--.*?-->', dotAll: true);
final _anchor = RegExp(
  r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>''',
  caseSensitive: false,
  dotAll: true,
);
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

const _named = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
};

String _decode(String text) => text.replaceAllMapped(_entity, (m) {
      final name = m[1]!;
      if (name.startsWith('#')) {
        final code = name[1] == 'x' || name[1] == 'X'
            ? int.tryParse(name.substring(2), radix: 16)
            : int.tryParse(name.substring(1));
        if (code == null || code <= 0 || code > 0x10FFFF) return m[0]!;
        return String.fromCharCode(code);
      }
      return _named[name.toLowerCase()] ?? m[0]!;
    });

/// The address a link really leads to: calendar services wrap outside
/// links in a redirect through themselves.
String _unwrap(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return href;
  if (uri.host == 'www.google.com' && uri.path == '/url') {
    final target = uri.queryParameters['q'] ?? uri.queryParameters['url'];
    if (target != null && target.startsWith('http')) return target;
  }
  return href;
}

/// Plain text for a description that may be written in HTML, as calendar
/// services often send it: line breaks and list items kept as lines, a link
/// kept as its text followed by its address, everything else dropped.
/// Text without HTML tags is returned unchanged.
String plainFromHtml(String text) {
  if (!_tag.hasMatch(text)) return text;
  var s = text.replaceAllMapped(_anchor, (m) {
    final href = _unwrap(_decode((m[1] ?? m[2] ?? m[3] ?? '').trim()));
    final label = _decode(m[4]!.replaceAll(_tag, '')).trim();
    if (href.isEmpty) return label;
    final bare = href.replaceFirst(RegExp(r'^(mailto:|tel:|https?://)'), '');
    if (label.isEmpty || label == href || label == bare || '$label/' == bare) {
      return href.startsWith('mailto:') || href.startsWith('tel:') ? bare : href;
    }
    return '$label ($href)';
  });
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ');
  s = s.replaceAll(
      RegExp(r'</(p|div|li|tr|h[1-6]|blockquote)\s*>', caseSensitive: false), '\n');
  s = _decode(s.replaceAll(_tag, ''));
  return s
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
