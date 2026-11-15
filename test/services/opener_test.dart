import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/services/opener.dart';

void main() {
  group('on a phone', () {
    test('a place with a position asks the map app for it, by name', () async {
      final asked = <String>[];
      final opener = Opener(android: (uri) async {
        asked.add(uri);
        return true;
      });
      expect(await opener.openMap(label: 'Café (old town)', geo: '45.188500,5.724500'), isTrue);
      expect(asked, ['geo:45.188500,5.724500?q=45.188500,5.724500(Caf%C3%A9%20%20old%20town)']);
    });

    test('a place known only by its text is searched for', () async {
      final asked = <String>[];
      final opener = Opener(android: (uri) async {
        asked.add(uri);
        return true;
      });
      await opener.openMap(label: 'Room 204, Main building');
      expect(asked, ['geo:0,0?q=Room%20204%2C%20Main%20building']);
    });

    test('without a map app the place opens on OpenStreetMap in the browser', () async {
      final asked = <String>[];
      final opener = Opener(android: (uri) async {
        asked.add(uri);
        return !uri.startsWith('geo:');
      });
      expect(await opener.openMap(label: 'Somewhere', geo: '45.1885,5.7245'), isTrue);
      expect(asked.last,
          'https://www.openstreetmap.org/?mlat=45.18850&mlon=5.72450#map=17/45.18850/5.72450');
    });

    test('links open through the system; anything else is refused', () async {
      final asked = <String>[];
      final opener = Opener(android: (uri) async {
        asked.add(uri);
        return true;
      });
      expect(await opener.open('https://example.org/a'), isTrue);
      expect(await opener.open('mailto:a@example.org'), isTrue);
      expect(await opener.open('file:///etc/passwd'), isFalse);
      expect(await opener.open('javascript:alert(1)'), isFalse);
      expect(asked, ['https://example.org/a', 'mailto:a@example.org']);
    });
  });

  group('on the desktop', () {
    Opener desktop(List<String> ran, {required bool mapProgram}) => Opener(
          run: (program, arguments) async {
            ran.add('$program ${arguments.join(' ')}');
            if (program == 'xdg-mime') {
              return (exitCode: 0, output: mapProgram ? 'org.gnome.Maps.desktop\n' : '\n');
            }
            return (exitCode: 0, output: '');
          },
        );

    test('a map program gets the bare position', () async {
      final ran = <String>[];
      await desktop(ran, mapProgram: true).openMap(label: 'Café', geo: '45.1885,5.7245');
      expect(ran, [
        'xdg-mime query default x-scheme-handler/geo',
        'xdg-open geo:45.188500,5.724500',
      ]);
    }, testOn: 'linux');

    test('without one, or without a position, the browser shows OpenStreetMap', () async {
      final ran = <String>[];
      await desktop(ran, mapProgram: false).openMap(label: 'Café', geo: '45.1885,5.7245');
      expect(ran.last, startsWith('xdg-open https://www.openstreetmap.org/?mlat=45.18850'));
      ran.clear();
      await desktop(ran, mapProgram: true).openMap(label: 'Gare de Grenoble');
      expect(ran, ['xdg-open https://www.openstreetmap.org/search?query=Gare+de+Grenoble']);
    }, testOn: 'linux');
  });

  test('an empty place opens nothing', () async {
    final opener = Opener(android: (uri) async => fail('asked for $uri'));
    expect(await opener.openMap(label: '  '), isFalse);
  });
}
