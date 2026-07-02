import 'dart:convert';

import 'package:ez_tunein/radio_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRadioBrowserStations', () {
    test('parses a realistic array with mixed field types', () {
      final body = jsonEncode([
        {
          'name': 'Smooth Jazz Florida',
          'url': 'http://example.com/playlist.pls',
          'url_resolved': 'http://stream.example.com/jazz.mp3',
          'codec': 'MP3',
          'bitrate': 128,
          'country': 'The United States Of America',
          'countrycode': 'US',
          'tags': 'jazz,smooth',
          'favicon': 'http://example.com/logo.png',
          'votes': 42,
          'lastcheckok': 1,
        },
        {
          'name': 'Radio Bob',
          'url': 'https://streams.example.de/bob.mp3',
          'url_resolved': '',
          'codec': 'aac',
          'bitrate': 192,
          'country': 'Germany',
          'countrycode': 'DE',
          'tags': 'rock',
          'favicon': '',
          'votes': 7,
          'lastcheckok': 0,
        },
      ]);
      final stations = parseRadioBrowserStations(body);
      expect(stations.length, 2);

      final jazz = stations[0];
      expect(jazz.name, 'Smooth Jazz Florida');
      expect(jazz.bitrate, 128);
      expect(jazz.lastCheckOk, isTrue);

      final bob = stations[1];
      expect(bob.lastCheckOk, isFalse);
    });

    test('streamUrl prefers url_resolved, falls back to url', () {
      final body = jsonEncode([
        {
          'name': 'Resolved',
          'url': 'http://a/playlist.pls',
          'url_resolved': 'http://a/direct.mp3',
        },
        {
          'name': 'FallbackOnly',
          'url': 'http://b/direct.mp3',
          'url_resolved': '',
        },
      ]);
      final stations = parseRadioBrowserStations(body);
      expect(stations[0].streamUrl, 'http://a/direct.mp3');
      expect(stations[1].streamUrl, 'http://b/direct.mp3');
    });

    test('skips rows with no name or no playable URL', () {
      final body = jsonEncode([
        {'name': '', 'url': 'http://x/s.mp3', 'url_resolved': ''},
        {'name': 'No URL', 'url': '', 'url_resolved': ''},
        {'name': 'Good', 'url': 'http://y/s.mp3', 'url_resolved': ''},
      ]);
      final stations = parseRadioBrowserStations(body);
      expect(stations.length, 1);
      expect(stations.single.name, 'Good');
    });

    test('tolerates missing/partial fields', () {
      final body = jsonEncode([
        {'name': 'Bare', 'url_resolved': 'http://z/s.mp3'},
      ]);
      final stations = parseRadioBrowserStations(body);
      expect(stations.length, 1);
      final s = stations.single;
      expect(s.bitrate, 0);
      expect(s.tags, '');
      expect(s.votes, 0);
      expect(s.lastCheckOk, isFalse);
    });

    test('returns empty on non-array or malformed JSON', () {
      expect(parseRadioBrowserStations('not json'), isEmpty);
      expect(parseRadioBrowserStations('{"name":"obj"}'), isEmpty);
      expect(parseRadioBrowserStations('[]'), isEmpty);
    });
  });

  group('subtitle', () {
    RadioBrowserStation one(String body) =>
        parseRadioBrowserStations('[$body]').single;

    test('assembles country · codec · bitrate · tags', () {
      final s = one(jsonEncode({
        'name': 'X',
        'url_resolved': 'http://x/s.mp3',
        'codec': 'mp3',
        'bitrate': 128,
        'country': 'United States',
        'countrycode': 'US',
        'tags': 'jazz, smooth',
      }));
      expect(s.subtitle, 'United States · MP3 · 128 kbps · jazz, smooth');
    });

    test('skips blank fields and uses countrycode when country is blank', () {
      final s = one(jsonEncode({
        'name': 'X',
        'url_resolved': 'http://x/s.mp3',
        'codec': '',
        'bitrate': 0,
        'country': '',
        'countrycode': 'de',
        'tags': '',
      }));
      expect(s.subtitle, 'DE');
    });
  });

  group('searchRadioBrowser', () {
    test('empty query returns empty without hitting the network', () async {
      expect(await searchRadioBrowser('   '), isEmpty);
    });
  });
}
