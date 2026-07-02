import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Online station lookup via the free, no-key **Radio Browser API**
/// (https://api.radio-browser.info). Deliberately UI-free and dependency-free:
/// it uses the same `dart:io HttpClient` the ICY reader already relies on (no
/// `package:http`), and returns plain data the caller turns into `Station`s.
/// The pure [parseRadioBrowserStations] is unit-tested; the network call isn't.

/// One station as returned by the API. Tolerant of the API's mixed types —
/// several fields that were once strings are now numbers/bools.
class RadioBrowserStation {
  const RadioBrowserStation({
    required this.name,
    required this.url,
    required this.urlResolved,
    required this.codec,
    required this.bitrate,
    required this.country,
    required this.countryCode,
    required this.tags,
    required this.favicon,
    required this.votes,
    required this.lastCheckOk,
  });

  final String name;
  final String url;
  final String urlResolved; // the already-unwrapped *direct* stream URL
  final String codec; // e.g. MP3, AAC
  final int bitrate; // kbps (0 = unknown)
  final String country;
  final String countryCode; // ISO 3166-1 alpha-2
  final String tags; // comma-separated
  final String favicon; // station logo URL (may be empty)
  final int votes;
  final bool lastCheckOk; // was the stream reachable at last check?

  /// The URL to actually play: prefer [urlResolved] (Radio Browser has already
  /// unwrapped any `.pls`/`.m3u` playlist to a direct stream — exactly what this
  /// app requires), falling back to [url] when it's blank.
  String get streamUrl => urlResolved.trim().isNotEmpty ? urlResolved : url;

  /// A one-line description for the result row, e.g.
  /// "US · MP3 · 128 kbps · jazz, smooth". Blank fields are skipped.
  String get subtitle {
    final parts = <String>[];
    final where = country.trim().isNotEmpty
        ? country.trim()
        : countryCode.trim().toUpperCase();
    if (where.isNotEmpty) parts.add(where);
    if (codec.trim().isNotEmpty) parts.add(codec.trim().toUpperCase());
    if (bitrate > 0) parts.add('$bitrate kbps');
    if (tags.trim().isNotEmpty) parts.add(tags.trim());
    return parts.join(' · ');
  }

  factory RadioBrowserStation.fromJson(Map<String, dynamic> j) {
    String str(Object? v) => v == null ? '' : v.toString();
    return RadioBrowserStation(
      name: str(j['name']).trim(),
      url: str(j['url']).trim(),
      urlResolved: str(j['url_resolved']).trim(),
      codec: str(j['codec']).trim(),
      bitrate: (j['bitrate'] as num?)?.toInt() ?? 0,
      country: str(j['country']).trim(),
      countryCode: str(j['countrycode']).trim(),
      tags: str(j['tags']).trim(),
      favicon: str(j['favicon']).trim(),
      votes: (j['votes'] as num?)?.toInt() ?? 0,
      // Tolerate 0/1, true/false, or "1"/"0".
      lastCheckOk: j['lastcheckok'] == 1 ||
          j['lastcheckok'] == true ||
          j['lastcheckok'] == '1',
    );
  }
}

/// Parse the API's JSON array body into stations, skipping anything malformed
/// or lacking a playable URL. Pure — no network — so it's unit-tested.
List<RadioBrowserStation> parseRadioBrowserStations(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <RadioBrowserStation>[];
  for (final e in decoded) {
    if (e is! Map<String, dynamic>) continue;
    try {
      final s = RadioBrowserStation.fromJson(e);
      if (s.name.isEmpty || s.streamUrl.isEmpty) continue;
      out.add(s);
    } catch (_) {
      // Skip a row we couldn't read rather than failing the whole search.
    }
  }
  return out;
}

/// Radio Browser mirrors. `all.api.…` is round-robin DNS across all servers;
/// the rest are named fallbacks tried in order if a host can't be reached.
/// (The API asks clients to discover servers dynamically and retry others.)
const _radioBrowserHosts = <String>[
  'all.api.radio-browser.info',
  'de1.api.radio-browser.info',
  'de2.api.radio-browser.info',
  'nl1.api.radio-browser.info',
];

/// The API asks apps to send an identifying ("speaking") User-Agent.
const _userAgent = 'ez_tunein/0.8.1';

/// Search stations by keyword. Returns the most-voted, non-broken matches.
/// Throws if every mirror fails; the caller turns that into a friendly message.
/// [client] is injectable for tests (the default owns + closes its own client).
Future<List<RadioBrowserStation>> searchRadioBrowser(
  String query, {
  HttpClient? client,
  int limit = 60,
}) async {
  final q = query.trim();
  if (q.isEmpty) return const [];

  final http = client ?? HttpClient();
  http.userAgent = _userAgent;
  http.connectionTimeout = const Duration(seconds: 8);

  try {
    Object? lastError;
    for (final host in _radioBrowserHosts) {
      final uri = Uri.https(host, '/json/stations/search', {
        'name': q,
        'limit': '$limit',
        'hidebroken': 'true',
        'order': 'votes',
        'reverse': 'true', // most-voted first
      });
      try {
        final req = await http.getUrl(uri).timeout(const Duration(seconds: 8));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) {
          lastError = HttpException('HTTP ${resp.statusCode}', uri: uri);
          continue; // try the next mirror
        }
        final body = await resp.transform(utf8.decoder).join();
        return parseRadioBrowserStations(body);
      } catch (e) {
        lastError = e; // connection/timeout — fall through to the next mirror
      }
    }
    throw Exception('Could not reach the station directory ($lastError)');
  } finally {
    if (client == null) http.close(force: true);
  }
}
