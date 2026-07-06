import 'package:ez_tunein/models/station.dart';
import 'package:ez_tunein/stations/station_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeStations', () {
    test('adds new stations and skips URLs already present', () {
      final existing = [const Station('A', 'http://a')];
      final parsed = [
        const Station('A dup', 'http://a'), // already present ⇒ skipped
        const Station('B', 'http://b'), // new
      ];
      final r = mergeStations(existing, parsed);
      expect(r.added.map((s) => s.url), ['http://b']);
      expect(r.skipped, 1);
    });

    test('drops duplicates within the parsed list too', () {
      final r = mergeStations(
        const [],
        [
          const Station('B', 'http://b'),
          const Station('B again', 'http://b'),
          const Station('C', 'http://c'),
        ],
      );
      expect(r.added.map((s) => s.url), ['http://b', 'http://c']);
      expect(r.skipped, 1);
    });

    test('everything new when existing is empty', () {
      final parsed = [
        const Station('A', 'http://a'),
        const Station('B', 'http://b'),
      ];
      final r = mergeStations(const [], parsed);
      expect(r.added, hasLength(2));
      expect(r.skipped, 0);
    });

    test('nothing added when all are duplicates', () {
      final existing = [const Station('A', 'http://a')];
      final r = mergeStations(existing, [const Station('A2', 'http://a')]);
      expect(r.added, isEmpty);
      expect(r.skipped, 1);
    });
  });
}
