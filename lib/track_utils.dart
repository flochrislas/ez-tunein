// Small, pure text/format helpers shared by the player, the views, and the
// recorder. Kept dependency-free (no Flutter import) so they're trivially
// unit-testable.

/// Split a raw ICY "Artist - Title" string on the first " - "; if there's no
/// separator the whole string is the title and the artist is empty.
({String artist, String title}) splitArtistTitle(String raw) {
  final sep = raw.indexOf(' - ');
  if (sep > 0) {
    return (
      artist: raw.substring(0, sep).trim(),
      title: raw.substring(sep + 3).trim(),
    );
  }
  return (artist: '', title: raw);
}

/// Format an ISO-8601 timestamp as `YYYY-MM-DD HH:MM` for the track tables.
/// Returns the input unchanged if it doesn't parse.
String fmtDateTime(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// Format a duration as `M:SS` (or `H:MM:SS` for an hour or more) for the
/// recordings seek bar.
String fmtDuration(Duration d) {
  final h = d.inHours;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (h > 0) {
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
  return '${d.inMinutes}:$s';
}
