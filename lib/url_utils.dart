// Pure helpers for validating station stream URLs, shared by the add/edit
// dialog, CSV import, and the online-search result mapping. Dependency-free so
// they can be unit-tested directly.

/// True if [url] is an acceptable stream URL: parseable, `http`/`https`, with a
/// host. Rejects `file://`, `concat:`, `data:`, `javascript:`,
/// schemeless/relative, and garbage that libmpv/ffmpeg (desktop) or ExoPlayer
/// (Android) would otherwise accept — local-file reads, mild SSRF, playlist
/// expansion. Validation happens at the input boundaries only, so existing
/// saved stations are never re-checked.
bool isValidStreamUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return false;
  final s = uri.scheme.toLowerCase();
  return (s == 'http' || s == 'https') && uri.host.isNotEmpty;
}

/// True if [url]'s path ends in a playlist extension (`.pls`/`.m3u`/`.m3u8`) —
/// the app needs the *direct* stream URL, not a playlist wrapper (the #1 user
/// footgun). Not fatal (some backends follow them), so callers warn rather than
/// block.
bool isPlaylistUrl(String url) {
  final p = (Uri.tryParse(url.trim())?.path ?? '').toLowerCase();
  return p.endsWith('.pls') || p.endsWith('.m3u') || p.endsWith('.m3u8');
}
