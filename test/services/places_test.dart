import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weektodo/services/places.dart';

/// A Photon answer, cut down to what the app reads.
Map<String, Object?> feature(Map<String, Object?> properties, [List<Object?> at = const [5.7245, 45.1885]]) => {
      'type': 'Feature',
      'geometry': {'type': 'Point', 'coordinates': at},
      'properties': properties,
    };

void main() {
  group('reading an answer', () {
    test('a named place shows its name, then its address', () {
      final places = PlaceSearch.parse({
        'features': [
          feature({
            'name': 'Café de la Table Ronde',
            'street': 'Place Saint-André',
            'housenumber': '7',
            'postcode': '38000',
            'city': 'Grenoble',
            'country': 'France',
            'countrycode': 'FR',
          }),
        ],
      });
      expect(places.single.name, 'Café de la Table Ronde');
      expect(places.single.detail, '7 Place Saint-André, 38000 Grenoble, France');
      expect(places.single.label,
          'Café de la Table Ronde, 7 Place Saint-André, 38000 Grenoble, France');
      expect(places.single.geo, '45.188500,5.724500');
    });

    test('an address without a name is named by its street, number last where that is the custom', () {
      final places = PlaceSearch.parse({
        'features': [
          feature({
            'street': 'Unter den Linden',
            'housenumber': '6',
            'postcode': '10117',
            'city': 'Berlin',
            'country': 'Germany',
            'countrycode': 'DE',
          }),
        ],
      });
      expect(places.single.name, 'Unter den Linden 6');
      expect(places.single.detail, '10117 Berlin, Germany');
    });

    test('a city is not repeated in its own address', () {
      final places = PlaceSearch.parse({
        'features': [
          feature({'name': 'Grenoble', 'city': 'Grenoble', 'state': 'Auvergne-Rhône-Alpes', 'country': 'France'}),
        ],
      });
      expect(places.single.label, 'Grenoble, France');
    });

    test('entries without a position or a name, and repeats, are left out', () {
      final places = PlaceSearch.parse({
        'features': [
          feature({'name': 'A', 'country': 'X'}),
          feature({'name': 'A', 'country': 'X'}),
          feature({'osm_key': 'place'}),
          feature({'name': 'Nowhere'}, const [200, 95]),
          {'properties': {'name': 'No geometry'}},
          'junk',
        ],
      });
      expect(places.map((p) => p.label), ['A, X']);
    });

    test('anything that is not an answer gives no places', () {
      expect(PlaceSearch.parse(null), isEmpty);
      expect(PlaceSearch.parse({'features': 'no'}), isEmpty);
      expect(PlaceSearch.parse([1, 2]), isEmpty);
    });
  });

  test('stored coordinates are read back, junk is not', () {
    expect(parseGeo('45.188500,5.724500'), (45.1885, 5.7245));
    expect(parseGeo(null), isNull);
    expect(parseGeo('91,0'), isNull);
    expect(parseGeo('here'), isNull);
  });

  group('server address', () {
    test('defaults to the public server and requires https', () {
      expect(placeServer('').toString(), PlaceSearch.defaultServer);
      expect(placeServer('photon.example.org').scheme, 'https');
      expect(() => placeServer('http://photon.example.org'), throwsFormatException);
      expect(placeServer('http://127.0.0.1:2322').port, 2322);
    });
  });

  group('searching', () {
    late HttpServer server;
    final requests = <Uri>[];
    var status = 200;

    setUp(() async {
      requests.clear();
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request.uri);
        expect(request.headers.value(HttpHeaders.userAgentHeader), 'WeekToDo');
        request.response.statusCode = status;
        if (status == 200) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'features': [
              feature({'name': 'Result for ${request.uri.queryParameters['q']}', 'country': 'X'}),
            ],
          }));
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    String address() => 'http://127.0.0.1:${server.port}';

    test('sends the text, a limit and nothing that identifies the user', () async {
      final search = PlaceSearch();
      addTearDown(search.dispose);
      final places = await search.search('gare de', server: address(), language: 'fr', near: (45.19, 5.72));
      expect(places.single.name, 'Result for gare de');
      final sent = requests.single;
      expect(sent.path, '/api/');
      expect(sent.queryParameters, {
        'q': 'gare de',
        'limit': '6',
        'lang': 'fr',
        'lat': '45.190',
        'lon': '5.720',
      });
    });

    test('a language the server does not know is not sent', () async {
      final search = PlaceSearch();
      addTearDown(search.dispose);
      await search.search('plaza mayor', server: address(), language: 'es');
      expect(requests.single.queryParameters.containsKey('lang'), isFalse);
    });

    test('too few letters ask nothing', () async {
      final search = PlaceSearch();
      addTearDown(search.dispose);
      expect(await search.search('ga', server: address()), isEmpty);
      expect(requests, isEmpty);
    });

    test('the same question is asked once', () async {
      final search = PlaceSearch();
      addTearDown(search.dispose);
      await search.search('grenoble', server: address());
      await search.search(' grenoble ', server: address());
      expect(requests, hasLength(1));
    });

    test('a refusal or a dead server gives an empty list and a reason, never an error', () async {
      final search = PlaceSearch(timeout: const Duration(seconds: 2));
      addTearDown(search.dispose);
      final at = address();
      status = 429;
      expect(await search.search('grenoble', server: at), isEmpty);
      expect(search.lastError, contains('busy'));
      await server.close(force: true);
      expect(await search.search('lyon part-dieu', server: at), isEmpty);
      expect(search.lastError, isNotNull);
    });
  });
}
