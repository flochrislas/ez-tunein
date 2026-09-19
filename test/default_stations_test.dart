import 'dart:io';

import 'package:ez_tunein/csv_utils.dart';
import 'package:ez_tunein/stations/default_stations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The first-launch seed list is curated in radios-selection.csv (repo root);
  // the Dart list is a hand-maintained mirror. Keep them identical, in order.
  test('defaultStations mirrors radios-selection.csv', () {
    final rows = parseCsv(File('radios-selection.csv').readAsStringSync());
    expect(rows.first, ['name', 'url'], reason: 'header row');
    final csv = rows.skip(1).map((r) => '${r[0]} | ${r[1]}').toList();
    final seed = defaultStations.map((s) => '${s.name} | ${s.url}').toList();
    expect(seed, csv);
  });

  test('seed URLs are unique and direct (no playlist links)', () {
    final urls = defaultStations.map((s) => s.url).toList();
    expect(urls.toSet().length, urls.length, reason: 'duplicate URL');
    for (final u in urls) {
      expect(u, isNot(matches(r'\.(pls|m3u8?)(\?|$)')), reason: u);
    }
  });
}
