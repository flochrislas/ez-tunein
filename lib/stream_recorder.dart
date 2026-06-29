import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'track_utils.dart';

/// Buffers the live audio of the current track to a temp file so the user can
/// record a song they're already partway through, then writes the finished song
/// to the output folder. The player feeds it audio via [IcyReader.onAudio] and
/// tells it when the track changes or playback stops.
///
/// Per track: bytes accumulate into a temp buffer file (capped at
/// [bufferCapBytes] until armed; oldest bytes dropped). [arm] marks "record this
/// song" — the buffer already holds the song so far and keeps growing, ignoring
/// the cap. [onTrackChanged]/[onStreamStopped] finalize an armed recording (move
/// the buffer into the output folder) and clear the buffer for the next track.
///
/// Recording is lossless: Icecast/Shoutcast bytes are already compressed
/// (MP3/AAC), so they're written verbatim — no decoding or re-encoding.
class StreamRecorder {
  // Config, pushed in from prefs by the player.
  bool bufferingEnabled = true;
  int bufferCapBytes = 50 * 1024 * 1024;
  Future<Directory> Function()? outputDirResolver;

  File? _buffer;
  RandomAccessFile? _raf;
  int _bytes = 0;
  bool _armed = false;
  // The cap-trim is heavy (it reads up to bufferCapBytes), so it must not run
  // inside the hot audio callback. We defer it with Timer.run and guard against
  // overlapping trims with this flag. Trim still runs synchronously once it
  // starts, so it stays atomic against the (synchronous) appends on this isolate.
  bool _trimScheduled = false;
  String _title = '';
  String _station = '';
  String _ext = 'mp3';

  bool get isRecording => _armed;

  Future<File> _bufferFile() async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/ez_record_buffer.part');
  }

  /// Begin (or restart) buffering for a fresh track. No-op when buffering is off.
  Future<void> startBuffering() async {
    if (!bufferingEnabled) return;
    _armed = false;
    await _closeRaf();
    final f = await _bufferFile();
    // FileMode.write truncates and allows reading (needed by the cap trim).
    _raf = f.openSync(mode: FileMode.write);
    _buffer = f;
    _bytes = 0;
  }

  /// Append a batch of audio bytes (called from [IcyReader.onAudio]). The write
  /// is synchronous so the stream stays in order; best-effort, errors ignored.
  void addAudio(List<int> bytes) {
    final raf = _raf;
    if (!bufferingEnabled || raf == null) return;
    try {
      raf.writeFromSync(bytes);
      _bytes += bytes.length;
      // Until recording is armed, keep only the most recent ~bufferCapBytes so a
      // marathon single "track" can't grow without bound. Hysteresis (1.25×)
      // keeps the rare rewrite infrequent. While armed we keep everything.
      // Defer the (heavy) trim off this hot callback and coalesce bursts.
      if (!_armed &&
          !_trimScheduled &&
          _bytes > bufferCapBytes + (bufferCapBytes >> 2)) {
        _trimScheduled = true;
        Timer.run(_trimToTail);
      }
    } catch (_) {
      // Buffering is best-effort, like metadata — ignore write failures.
    }
  }

  void _trimToTail() {
    try {
      final raf = _raf;
      // Recording may have been armed/stopped between scheduling and running.
      if (raf == null || _armed) return;
      raf.flushSync();
      final len = raf.lengthSync();
      if (len <= bufferCapBytes) return;
      raf.setPositionSync(len - bufferCapBytes);
      final tail = raf.readSync(bufferCapBytes);
      raf.truncateSync(0);
      raf.setPositionSync(0);
      raf.writeFromSync(tail);
      _bytes = tail.length;
    } catch (_) {
      // If the trim fails, leave the buffer as-is rather than dropping it.
    } finally {
      _trimScheduled = false;
    }
  }

  /// Mark the current track to be recorded. The buffer already holds the song so
  /// far; from now on bytes are kept regardless of the cap.
  void arm(String title, String station, String? contentType) {
    if (!bufferingEnabled || _raf == null) return;
    _armed = true;
    _title = title;
    _station = station;
    _ext = extForContentType(contentType);
  }

  /// Discard an in-progress recording but keep buffering the same track (so the
  /// user can re-arm). The cap applies again once disarmed.
  void cancel() => _armed = false;

  /// Finalize an armed recording (if any) and start a clean buffer for the next
  /// track. Returns the saved file path, or null if nothing was recording.
  Future<String?> onTrackChanged() async {
    final path = await _finalizeIfArmed();
    await startBuffering();
    return path;
  }

  /// Finalize an armed recording (if any) and tear the buffer down (stream ended
  /// or the station was switched).
  Future<String?> onStreamStopped() async {
    final path = await _finalizeIfArmed();
    await _closeRaf();
    await _deleteBuffer();
    return path;
  }

  Future<void> dispose() async {
    await _closeRaf();
    await _deleteBuffer();
  }

  Future<String?> _finalizeIfArmed() async {
    if (!_armed) return null;
    _armed = false;
    await _closeRaf();
    final src = _buffer;
    if (src == null || !await src.exists()) return null;
    try {
      final dir = await outputDirResolver!();
      if (!await dir.exists()) await dir.create(recursive: true);
      final outPath = await uniqueFilePath(dir, _fileNameBase(), _ext);
      // Move the buffer into place: rename on the same volume, else copy+delete.
      try {
        await src.rename(outPath);
      } on FileSystemException {
        await src.copy(outPath);
        try {
          await src.delete();
        } catch (_) {}
      }
      _buffer = null; // moved away; startBuffering() will make a fresh one
      return outPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _closeRaf() async {
    final raf = _raf;
    _raf = null;
    if (raf == null) return;
    try {
      raf.flushSync();
      raf.closeSync();
    } catch (_) {}
  }

  Future<void> _deleteBuffer() async {
    final f = _buffer;
    _buffer = null;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String _fileNameBase() {
    final parts = splitArtistTitle(_title);
    final raw = parts.artist.isEmpty
        ? parts.title
        : '${parts.artist} - ${parts.title}';
    final cleaned = sanitizeFileName(raw);
    if (cleaned.isNotEmpty) return cleaned;
    return sanitizeFileName(_station.isEmpty ? 'recording' : _station);
  }

  /// Strip filesystem-illegal characters and control codes; collapse whitespace
  /// and cap the length so the name is safe on Windows, Linux, and Android.
  static String sanitizeFileName(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length > 120 ? cleaned.substring(0, 120).trim() : cleaned;
  }

  static String extForContentType(String? contentType) {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.contains('aac')) return 'aac'; // audio/aac, audio/aacp
    if (ct.contains('ogg')) return 'ogg';
    if (ct.contains('mpeg') || ct.contains('mp3')) return 'mp3';
    return 'mp3'; // sensible default; most stations are MP3
  }

  static Future<String> uniqueFilePath(
      Directory dir, String base, String ext) async {
    final sep = Platform.pathSeparator;
    var candidate = '${dir.path}$sep$base.$ext';
    if (!await File(candidate).exists()) return candidate;
    for (var n = 2;; n++) {
      candidate = '${dir.path}$sep$base ($n).$ext';
      if (!await File(candidate).exists()) return candidate;
    }
  }
}
