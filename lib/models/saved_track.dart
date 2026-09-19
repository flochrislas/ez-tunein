/// One saved track. [timestamp] is kept as the raw ISO-8601 string (which sorts
/// chronologically as plain text).
class SavedTrack {
  SavedTrack(this.timestamp, this.station, this.artist, this.title)
      : stationLower = station.toLowerCase(),
        artistLower = artist.toLowerCase(),
        titleLower = title.toLowerCase();
  final String timestamp;
  final String station;
  final String artist;
  final String title;
  // Precomputed lowercase keys so the type-to-search filter and the column sort
  // don't allocate a fresh lowercased string per row on every build/comparison.
  final String stationLower;
  final String artistLower;
  final String titleLower;
}

/// Sortable columns of the saved-tracks / history table. **Order matters:** the
/// desktop `DataTable` and the mobile sort menu pass a column index that maps
/// to `TrackSortKey.values[index]`.
enum TrackSortKey { when, artist, title, station }

/// The rows matching [query] (case-insensitive substring on artist / title /
/// station), in their original order. An empty query returns [tracks] itself.
List<SavedTrack> filterTracks(List<SavedTrack> tracks, String query) {
  if (query.isEmpty) return tracks;
  final q = query.toLowerCase();
  return tracks
      .where((t) =>
          t.artistLower.contains(q) ||
          t.titleLower.contains(q) ||
          t.stationLower.contains(q))
      .toList();
}

/// Sort [tracks] in place by [key]. Timestamps are ISO-8601 strings, so plain
/// string order is chronological.
void sortTracks(List<SavedTrack> tracks, TrackSortKey key,
    {required bool ascending}) {
  tracks.sort((a, b) {
    final r = switch (key) {
      TrackSortKey.artist => a.artistLower.compareTo(b.artistLower),
      TrackSortKey.title => a.titleLower.compareTo(b.titleLower),
      TrackSortKey.station => a.stationLower.compareTo(b.stationLower),
      TrackSortKey.when => a.timestamp.compareTo(b.timestamp),
    };
    return ascending ? r : -r;
  });
}
