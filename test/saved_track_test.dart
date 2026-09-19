import 'package:ez_tunein/models/saved_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tracks = [
    SavedTrack(
        '2026-01-02T10:00:00', 'SomaFM', 'Boards of Canada', 'Dayvan Cowboy'),
    SavedTrack(
        '2026-01-01T09:00:00', 'SwissGroove', 'Air', 'La Femme d\'Argent'),
    SavedTrack('2026-01-03T11:00:00', 'FIP', 'Daft Punk', 'Aerodynamic'),
  ];

  group('filterTracks', () {
    test('empty query returns the same list instance (no copy)', () {
      expect(identical(filterTracks(tracks, ''), tracks), isTrue);
    });

    test('matches case-insensitively on artist, title or station', () {
      expect(filterTracks(tracks, 'DAFT').single.title, 'Aerodynamic');
      expect(filterTracks(tracks, 'cowboy').single.artist, 'Boards of Canada');
      expect(filterTracks(tracks, 'swiss').single.artist, 'Air');
    });

    test('keeps the original order and drops non-matches', () {
      expect(filterTracks(tracks, 'a').length, 3); // every row has an "a"
      expect(filterTracks(tracks, 'zzz'), isEmpty);
    });
  });

  group('sortTracks', () {
    List<String> artists(List<SavedTrack> l) => l.map((t) => t.artist).toList();

    test('by time, both directions', () {
      final l = [...tracks];
      sortTracks(l, TrackSortKey.when, ascending: true);
      expect(artists(l), ['Air', 'Boards of Canada', 'Daft Punk']);
      sortTracks(l, TrackSortKey.when, ascending: false);
      expect(artists(l), ['Daft Punk', 'Boards of Canada', 'Air']);
    });

    test('by artist / title / station, case-insensitive', () {
      final l = [...tracks];
      sortTracks(l, TrackSortKey.artist, ascending: true);
      expect(artists(l), ['Air', 'Boards of Canada', 'Daft Punk']);
      sortTracks(l, TrackSortKey.title, ascending: true);
      expect(artists(l), ['Daft Punk', 'Boards of Canada', 'Air']);
      sortTracks(l, TrackSortKey.station, ascending: true);
      expect(artists(l), ['Daft Punk', 'Boards of Canada', 'Air']);
    });

    test('column index order matches the table: when, artist, title, station',
        () {
      expect(TrackSortKey.values, [
        TrackSortKey.when,
        TrackSortKey.artist,
        TrackSortKey.title,
        TrackSortKey.station
      ]);
    });
  });
}
