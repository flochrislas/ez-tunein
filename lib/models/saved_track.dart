/// One saved track. [timestamp] is kept as the raw ISO-8601 string (which sorts
/// chronologically as plain text).
class SavedTrack {
  SavedTrack(this.timestamp, this.station, this.artist, this.title);
  final String timestamp;
  final String station;
  final String artist;
  final String title;
}
