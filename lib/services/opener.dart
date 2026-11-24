import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'places.dart';

/// Runs a program and reports its exit code and standard output.
typedef ProgramRunner = Future<({int exitCode, String output})> Function(
    String program, List<String> arguments);

Future<({int exitCode, String output})> _runProgram(
    String program, List<String> arguments) async {
  final result = await Process.run(program, arguments).timeout(const Duration(seconds: 10));
  return (exitCode: result.exitCode, output: '${result.stdout}');
}

/// Hands links and places to the programs the system has for them: the
/// browser, the mail program, the map app. The app shows no web pages or
/// maps of its own.
class Opener {
  Opener({this.android, ProgramRunner? run, TargetPlatform? platform})
      : _run = run ?? _runProgram,
        _platform = platform;

  /// The system whose programs are asked; by default the one the app runs
  /// on (tests name one).
  final TargetPlatform? _platform;
  TargetPlatform get _system => _platform ?? defaultTargetPlatform;

  /// On Android: asks the system to view an address; false when no app
  /// takes it. Null elsewhere.
  final Future<bool> Function(String uri)? android;
  final ProgramRunner _run;

  /// Whether the desktop has a program for `geo:` addresses; asked once.
  Future<bool>? _geoHandler;

  /// Opens a web, mail or phone address. False if nothing could take it.
  Future<bool> open(String address) async {
    final uri = Uri.tryParse(address);
    if (uri == null) return false;
    // Only what a note can sensibly link to; never a file or a program.
    const schemes = {'http', 'https', 'mailto', 'tel', 'geo'};
    if (!schemes.contains(uri.scheme)) return false;
    try {
      final android = this.android;
      if (android != null) return await android(address);
      return switch (_system) {
        TargetPlatform.linux => (await _run('xdg-open', [address])).exitCode == 0,
        // Windows' own way of handing an address to the program set for it
        // (browser, mail program). Unlike `start`, it takes the address as
        // one argument, so `&` and quotes in it are not read by a shell.
        TargetPlatform.windows =>
          (await _run('rundll32', ['url.dll,FileProtocolHandler', address])).exitCode == 0,
        _ => false,
      };
    } on Object catch (error) {
      debugPrint('Could not open $address: $error');
      return false;
    }
  }

  /// OpenStreetMap's page for a position or, without one, for a search.
  static String webMap(String label, (double, double)? at) {
    if (at != null) {
      final lat = at.$1.toStringAsFixed(5), lon = at.$2.toStringAsFixed(5);
      return 'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon';
    }
    return 'https://www.openstreetmap.org/search?query=${Uri.encodeQueryComponent(label)}';
  }

  /// The `geo:` address a phone's map app is asked to show.
  static String phoneMap(String label, (double, double)? at) {
    // Brackets end the label, so they cannot be part of it.
    final name = Uri.encodeComponent(label.replaceAll(RegExp(r'[()]'), ' ').trim());
    if (at == null) return 'geo:0,0?q=$name';
    final position = '${at.$1.toStringAsFixed(6)},${at.$2.toStringAsFixed(6)}';
    return name.isEmpty ? 'geo:$position' : 'geo:$position?q=$position($name)';
  }

  /// Shows a place in the map app: [geo] (`lat,lon`) when it is known, else
  /// a search for [label]. Falls back to OpenStreetMap in the browser when
  /// no map app is installed.
  Future<bool> openMap({required String label, String? geo}) async {
    final at = parseGeo(geo);
    if (at == null && label.trim().isEmpty) return false;
    if (android != null) {
      if (await open(phoneMap(label, at))) return true;
      return open(webMap(label, at));
    }
    // A desktop map program takes a bare position; the label and search
    // forms of geo: are extensions few of them understand.
    if (at != null && await (_geoHandler ??= _hasGeoHandler())) {
      final position = 'geo:${at.$1.toStringAsFixed(6)},${at.$2.toStringAsFixed(6)}';
      if (await open(position)) return true;
    }
    return open(webMap(label, at));
  }

  Future<bool> _hasGeoHandler() async {
    // Windows has no common map program for geo: addresses; its Maps app
    // takes addresses of its own. The web map is the dependable choice.
    if (_system != TargetPlatform.linux) return false;
    try {
      final answer = await _run('xdg-mime', ['query', 'default', 'x-scheme-handler/geo']);
      return answer.exitCode == 0 && answer.output.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }
}
