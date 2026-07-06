import '../models/station.dart';

/// Merge [parsed] stations into [existing], skipping any whose URL is already
/// present — in [existing] or earlier within [parsed] (so intra-file duplicates
/// are dropped too). Returns the additions and how many were skipped as
/// duplicates. Pure (no I/O): the caller persists and reports. Used by both the
/// online-search add and the CSV import so their dedup can't drift.
({List<Station> added, int skipped}) mergeStations(
    List<Station> existing, List<Station> parsed) {
  final seen = existing.map((s) => s.url).toSet();
  final added = <Station>[];
  var skipped = 0;
  for (final s in parsed) {
    if (seen.add(s.url)) {
      added.add(s);
    } else {
      skipped++;
    }
  }
  return (added: added, skipped: skipped);
}
