import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/text/links.dart';

void main() {
  List<String?> urls(String text) => [for (final p in linkify(text)) p.url];
  String joined(String text) => linkify(text).map((p) => p.text).join();

  group('linkify', () {
    test('text without links is one plain piece', () {
      expect(linkify('Bring the draft.'), [const TextPiece('Bring the draft.')]);
      expect(linkify(''), isEmpty);
    });

    test('finds web addresses and keeps the text around them', () {
      expect(linkify('See https://example.org/a?b=1#c for more'), [
        const TextPiece('See '),
        const TextPiece('https://example.org/a?b=1#c', 'https://example.org/a?b=1#c'),
        const TextPiece(' for more'),
      ]);
    });

    test('an address starting www. opens over https', () {
      expect(urls('www.example.org'), ['https://www.example.org']);
    });

    test('mail addresses open the mail app', () {
      expect(linkify('ask anna.b+x@example.co.uk today'), [
        const TextPiece('ask '),
        const TextPiece('anna.b+x@example.co.uk', 'mailto:anna.b+x@example.co.uk'),
        const TextPiece(' today'),
      ]);
    });

    test('punctuation after an address is not part of it', () {
      expect(urls('Go to https://example.org/x.'), [null, 'https://example.org/x', null]);
      expect(urls('(see https://example.org/x)'), [null, 'https://example.org/x', null]);
      expect(urls('Is it https://example.org/x?'), [null, 'https://example.org/x', null]);
      expect(urls('"https://example.org/x",'), [null, 'https://example.org/x', null]);
    });

    test('brackets that belong to the address stay', () {
      expect(urls('https://en.wikipedia.org/wiki/Ice_(disambiguation)'),
          ['https://en.wikipedia.org/wiki/Ice_(disambiguation)']);
    });

    test('several links, on several lines', () {
      const text = 'a https://a.example/1\nb http://b.example/2, c@d.example';
      expect(urls(text).whereType<String>(),
          ['https://a.example/1', 'http://b.example/2', 'mailto:c@d.example']);
      expect(joined(text), text);
    });

    test('the pieces always join back to the text', () {
      for (final text in [
        'x@y',
        'http://',
        'www.',
        'https://example.org).',
        'täglich: https://example.org/ä — ok',
        'a@b.c, d@e.f.',
      ]) {
        expect(joined(text), text, reason: text);
      }
    });

    test('things that only look like addresses are left alone', () {
      expect(urls('v1.2@home'), [null]);
      expect(urls('http://nohost'), [null]);
      expect(hasLinks('12:30 @ office'), isFalse);
    });
  });

  group('plainFromHtml', () {
    test('plain text is returned untouched, entities and all', () {
      const text = 'Fish & chips <3 at 5 &amp; 6';
      expect(plainFromHtml(text), text);
    });

    test('line breaks, paragraphs and lists become lines', () {
      expect(
        plainFromHtml('<p>Agenda</p><ul><li>One</li><li>Two &amp; three</li></ul>Bye<br>now'),
        'Agenda\n• One\n• Two & three\nBye\nnow',
      );
    });

    test('a link keeps its text and its address', () {
      expect(plainFromHtml('Join <a href="https://meet.example/abc">the call</a>.'),
          'Join the call (https://meet.example/abc).');
    });

    test('a link whose text is its address is written once', () {
      expect(plainFromHtml('<a href="https://meet.example/abc">https://meet.example/abc</a>'),
          'https://meet.example/abc');
      expect(plainFromHtml('<a href="https://meet.example">meet.example</a>'),
          'https://meet.example');
      expect(plainFromHtml("<a href='mailto:a@b.example'>a@b.example</a>"), 'a@b.example');
    });

    test('a redirect through the calendar service is unwrapped', () {
      expect(
        plainFromHtml('<a href="https://www.google.com/url?q=https://example.org/x&amp;sa=D&amp;usg=abc">x</a>'),
        'x (https://example.org/x)',
      );
    });

    test('other markup is dropped and numeric entities are read', () {
      expect(plainFromHtml('<b>Bold</b> <span style="x">caf&#233;</span> &#x2014; ok<!-- note -->'),
          'Bold café — ok');
    });

    test('the result can be linkified', () {
      final pieces = linkify(plainFromHtml('Room 2<br><a href="https://x.example/r">map</a>'));
      expect(pieces.where((p) => p.isLink).single.url, 'https://x.example/r');
    });
  });

  group('a web address in a title', () {
    test('reads as its site and the start of its path', () {
      expect(shortLink('https://www.nature.com/articles/s41586-024-07000-1'),
          'nature.com/articles/s41586-02…');
      expect(shortLink('https://example.org'), 'example.org');
      expect(shortLink('https://example.org/'), 'example.org');
      expect(shortLink('http://WWW.Example.org/a/b/'), 'example.org/a/b');
      // What follows a ? or # is left out, and said to be.
      expect(shortLink('https://youtube.com/watch?v=dQw4w9WgXcQ'), 'youtube.com/watch…');
      expect(shortLink('https://en.wikipedia.org/wiki/Sea_ice#Formation'),
          'en.wikipedia.org/wiki/Sea_ice…');
      // Percent signs are read out.
      expect(shortLink('https://example.org/caf%C3%A9'), 'example.org/café');
      expect(shortLink('mailto:ada@example.org'), 'ada@example.org');
      expect(shortLink('https://example.org/a-very-long-path', limit: 16), 'example.org/a-v…');
    });

    test('the words around it stay as they are', () {
      const title = 'Read https://www.example.org/papers/2026/ice-thickness.pdf before Friday';
      expect(tidyText(title), 'Read example.org/papers/2026/ice-t… before Friday');
      final pieces = tidyLinks(title);
      expect(pieces.map((p) => p.isLink), [false, true, false]);
      // What a click opens is the whole address.
      expect(pieces[1].url, 'https://www.example.org/papers/2026/ice-thickness.pdf');
      expect(tidyText('No address here.'), 'No address here.');
      expect(tidyText('www.example.org'), 'example.org');
    });

    test('a quick look tells which texts can have none', () {
      expect(mayHaveLinks('Buy oat milk'), isFalse);
      expect(mayHaveLinks('see https://example.org'), isTrue);
      expect(mayHaveLinks('WWW.example.org'), isTrue);
      expect(mayHaveLinks('ada@example.org'), isTrue);
    });
  });
}
