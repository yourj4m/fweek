import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A place found by the search: what to show and where it is.
class Place {
  const Place({
    required this.name,
    required this.detail,
    required this.lat,
    required this.lon,
  });

  /// The place's own name, or its street address when it has none.
  final String name;

  /// The rest of the address, for telling places of one name apart.
  final String detail;

  final double lat;
  final double lon;

  /// What is stored on a task: name and address in one line.
  String get label => detail.isEmpty ? name : '$name, $detail';

  /// Coordinates as stored on a task: `lat,lon`.
  String get geo => '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

  @override
  String toString() => 'Place($label @ $geo)';
}

/// Parses stored coordinates (`lat,lon`); null if there are none or they are
/// not a position on Earth.
(double, double)? parseGeo(String? geo) {
  if (geo == null) return null;
  final parts = geo.split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0].trim()), lon = double.tryParse(parts[1].trim());
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat, lon);
}

/// Tidies a search server's address as typed. Throws [FormatException] with
/// a message for the user if it cannot be used.
Uri placeServer(String typed) {
  var text = typed.trim();
  if (text.isEmpty) return Uri.parse(PlaceSearch.defaultServer);
  if (!text.contains('://')) text = 'https://$text';
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    throw const FormatException('That is not a valid address.');
  }
  if (uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const FormatException('That is not a valid address.');
  }
  // What is typed into a location field travels to this server; it must not
  // go in the clear, except to a server on this machine.
  const local = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
  if (uri.scheme == 'http' && !local.contains(uri.host)) {
    throw const FormatException('Use an https address.');
  }
  return uri;
}

/// Looks places up by name while the user types, in OpenStreetMap's data,
/// through a Photon server (https://photon.komoot.io by default).
///
/// The only things sent are the text typed so far, the wanted language and,
/// if given, a position to prefer nearby results. Nominatim, OpenStreetMap's
/// own search, is not used: its usage policy forbids searching on every
/// keystroke.
class PlaceSearch {
  PlaceSearch({
    HttpClient? client,
    this.timeout = const Duration(seconds: 6),
  })  : _client = client ?? HttpClient(),
        _ownsClient = client == null {
    _client.userAgent = 'WeekToDo';
    _client.connectionTimeout = timeout;
  }

  static const defaultServer = 'https://photon.komoot.io';

  /// Fewer letters than this find half the world.
  static const minLength = 3;

  /// Results asked for: a short list is all a suggestion box shows.
  static const limit = 6;

  /// Languages the public server can answer in; for any other, places keep
  /// their local names.
  static const languages = {'en', 'de', 'fr'};

  final HttpClient _client;
  final bool _ownsClient;
  final Duration timeout;

  final _cache = <String, List<Place>>{};

  /// Why the last search gave nothing, when that was a failure rather than
  /// an empty answer; null otherwise.
  String? lastError;

  /// Places matching [query]. Never throws: without a connection, or when
  /// the server is busy, the answer is an empty list and [lastError] says so.
  Future<List<Place>> search(
    String query, {
    String server = defaultServer,
    String? language,
    (double, double)? near,
  }) async {
    final text = query.trim();
    if (text.length < minLength) return const [];
    final Uri base;
    try {
      base = placeServer(server);
    } on FormatException catch (error) {
      lastError = error.message;
      return const [];
    }
    final lang = languages.contains(language) ? language : null;
    final url = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/api/',
      queryParameters: {
        'q': text,
        'limit': '$limit',
        'lang': ?lang,
        if (near != null) ...{
          'lat': near.$1.toStringAsFixed(3),
          'lon': near.$2.toStringAsFixed(3),
        },
      },
    );
    final key = url.toString();
    final known = _cache.remove(key);
    if (known != null) {
      _cache[key] = known; // most recently used last
      lastError = null;
      return known;
    }
    try {
      final request = await _client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(timeout);
        lastError = response.statusCode == 429 || response.statusCode == 403
            ? 'The place search is busy; try again in a moment.'
            : 'The place search answered with an error (${response.statusCode}).';
        return const [];
      }
      final body = await utf8.decodeStream(response.timeout(timeout));
      final places = parse(jsonDecode(body));
      _cache[key] = places;
      if (_cache.length > 64) _cache.remove(_cache.keys.first);
      lastError = null;
      return places;
    } on TimeoutException {
      lastError = 'The place search did not answer in time.';
    } on FormatException {
      lastError = 'The place search sent an answer that could not be read.';
    } on IOException {
      lastError = 'No connection to the place search.';
    } on StateError {
      lastError = 'No connection to the place search.';
    }
    return const [];
  }

  /// Countries that write the house number before the street.
  static const _numberFirst = {
    'FR', 'GB', 'US', 'CA', 'AU', 'NZ', 'IE', 'LU', 'IN', 'ZA', 'SG', 'MA', 'TN', 'DZ', //
  };

  /// Reads a Photon answer (a GeoJSON feature collection). Entries without
  /// usable coordinates or any name are left out, as are exact repeats.
  static List<Place> parse(Object? json) {
    if (json is! Map) return const [];
    final features = json['features'];
    if (features is! List) return const [];
    final out = <Place>[];
    final seen = <String>{};
    for (final feature in features) {
      if (feature is! Map) continue;
      final geometry = feature['geometry'];
      final coords = geometry is Map ? geometry['coordinates'] : null;
      if (coords is! List || coords.length < 2) continue;
      final lon = coords[0], lat = coords[1];
      if (lon is! num || lat is! num || lat.abs() > 90 || lon.abs() > 180) continue;
      final props = feature['properties'];
      if (props is! Map) continue;
      String? text(String key) {
        final value = props[key];
        return value is String && value.trim().isNotEmpty ? value.trim() : null;
      }

      final street = text('street');
      final number = text('housenumber');
      final country = text('country');
      final code = text('countrycode')?.toUpperCase();
      final streetLine = street == null
          ? null
          : number == null
              ? street
              : _numberFirst.contains(code)
                  ? '$number $street'
                  : '$street $number';
      final city = text('city') ?? text('locality') ?? text('district') ?? text('county');
      final name = text('name') ?? streetLine ?? city ?? text('state') ?? country;
      if (name == null) continue;
      final postcode = text('postcode');
      final town = [?postcode, ?city].join(' ');
      final parts = <String>[
        ?streetLine,
        if (town.isNotEmpty) town,
        if (city == null) ?text('state'),
        ?country,
      ];
      final detail = <String>[];
      for (final part in parts) {
        if (part == name || detail.contains(part)) continue;
        detail.add(part);
      }
      final place = Place(
        name: name,
        detail: detail.join(', '),
        lat: lat.toDouble(),
        lon: lon.toDouble(),
      );
      if (seen.add(place.label)) out.add(place);
    }
    return out;
  }

  void dispose() {
    if (_ownsClient) _client.close(force: true);
  }
}
