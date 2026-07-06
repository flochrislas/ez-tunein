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
