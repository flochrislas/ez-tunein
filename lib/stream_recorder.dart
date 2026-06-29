import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'track_utils.dart';

/// One on-disk buffer segment: a file plus how many bytes have been written to
/// it. The live track's audio is spread across a sequence of these.
class _Segment {
  _Segment(this.file);
  final File file;
  int bytes = 0;
}

/// Buffers the live audio of the current track to disk so the user can record a
/// song they're already partway through, then writes the finished song to the
/// output folder. The player feeds it audio via [IcyReader.onAudio] and tells it
/// when the track changes or playback stops.
///
/// **Segmented ring buffer.** Rather than one growing file that gets rewritten
/// to enforce the cap (a big synchronous read + rewrite — and RAM spike — on the
/// UI isolate), the buffer is a sequence of fixed-size segment files. New audio
/// appends to the active segment; when it fills, a new one is rolled. Until
/// recording is armed, the *oldest* whole segment is dropped (an O(1) file
/// delete, no read) once the remaining segments still cover [bufferCapBytes], so
/// the retained "rewind" window stays in `[cap, cap + segment)` with no spike.
/// When [arm]ed, nothing is dropped (the whole song is kept) and, on finalize,
/// the live segments are concatenated (streamed in 1 MB chunks — bounded memory)
/// into `<output>/Artist - Title.<ext>`.
///
/// Recording is lossless: Icecast/Shoutcast bytes are already compressed
/// (MP3/AAC), so they're written verbatim — no decoding or re-encoding.
class StreamRecorder {
  // Config, pushed in from prefs by the player.
  bool bufferingEnabled = true;
  int bufferCapBytes = 50 * 1024 * 1024;
  Future<Directory> Function()? outputDirResolver;

  /// Folder for the on-disk buffer segments. Overridable for tests; defaults to
  /// the OS temp dir.
  Future<Directory> Function() bufferDirResolver = getTemporaryDirectory;

  /// Segment size override (bytes). Tests set a tiny value to exercise rolling /
  /// dropping; null ⇒ derived from [bufferCapBytes] (see [_segmentSizeBytes]).
  int? segmentBytesOverride;

  Directory? _tmpDir;
  final List<_Segment> _segments = [];
  RandomAccessFile? _raf; // append handle to _segments.last
  int _segSeq = 0; // names segment files uniquely within a session
  int _totalBytes = 0; // sum across all current segments
  bool _swept = false; // cleaned crash-leftover segment files once?
  bool _armed = false;
  String _title = '';
  String _station = '';
  String _ext = 'mp3';

  bool get isRecording => _armed;

  /// Total bytes currently buffered across all segments. Exposed for tests.
  int get bufferedBytes => _totalBytes;

  static const _segmentFilePrefix = 'ez_record_buffer.';

  /// Active segment size. Derived as ~⅛ of the cap (so ~8 segments span the
  /// window) but clamped to a sane 1–16 MB; overridable for tests.
  int get _segmentSizeBytes {
    if (segmentBytesOverride != null) return segmentBytesOverride!;
    const mb = 1024 * 1024;
    return (bufferCapBytes ~/ 8).clamp(mb, 16 * mb);
  }

  // Serializes the async lifecycle operations (start/finalize/teardown) so two
  // of them can't interleave across awaits and corrupt the shared segment state
  // — e.g. a metadata-driven onTrackChanged finalizing while _stop's
  // onStreamStopped is also finalizing the same segments. Each public op runs to
  // completion before the next starts. (addAudio is synchronous and not queued;
  // it no-ops whenever there's no open active segment — i.e. during teardown.)
  Future<void> _op = Future.value();

  Future<T> _runExclusive<T>(Future<T> Function() body) {
    final next = _op.then((_) => body());
    _op = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Begin (or restart) buffering for a fresh track. No-op when buffering is off.
  Future<void> startBuffering() => _runExclusive(_startBuffering);

  Future<void> _startBuffering() async {
    if (!bufferingEnabled) return;
    _armed = false;
    await _closeAndDeleteAll();
    _tmpDir ??= await bufferDirResolver();
    if (!_swept) {
      _sweepStaleSegments(); // remove any leftovers from a crashed session
      _swept = true;
    }
    _segSeq = 0;
    _totalBytes = 0;
    _openNewSegment();
  }

  /// Append a batch of audio bytes (called from [IcyReader.onAudio]). Synchronous
  /// so the stream stays in order; best-effort, write errors ignored. All the
  /// work here is cheap — an append, an occasional segment roll (open/close), and
  /// O(1) deletes of whole old segments. No big read/rewrite, so no UI hitch.
  void addAudio(List<int> bytes) {
    final raf = _raf;
    if (!bufferingEnabled || raf == null) return;
    try {
      raf.writeFromSync(bytes);
      _segments.last.bytes += bytes.length;
      _totalBytes += bytes.length;
      if (_segments.last.bytes >= _segmentSizeBytes) _rollSegment();
      // While not armed, drop the oldest whole segment(s) once the rest still
      // covers the rewind window. While armed we keep everything.
      if (!_armed) _dropOldSegments();
    } catch (_) {
      // Buffering is best-effort, like metadata — ignore write failures.
    }
  }

  void _openNewSegment() {
    final f = File('${_tmpDir!.path}/$_segmentFilePrefix$_segSeq.part');
    _segSeq++;
    // FileMode.write truncates any stale file and allows reading (for finalize).
    _raf = f.openSync(mode: FileMode.write);
    _segments.add(_Segment(f));
  }

  void _rollSegment() {
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    _openNewSegment();
  }

  void _dropOldSegments() {
    // Never drop the active (last) segment; drop the oldest only while doing so
    // still leaves >= cap bytes, so the retained window never falls below cap.
    while (_segments.length > 1 &&
        _totalBytes - _segments.first.bytes >= bufferCapBytes) {
      final old = _segments.removeAt(0);
      _totalBytes -= old.bytes;
      _deleteFileQuietly(old.file);
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
  Future<String?> onTrackChanged() => _runExclusive(() async {
        final path = await _finalizeIfArmed();
        await _startBuffering();
        return path;
      });

  /// Finalize an armed recording (if any) and tear the buffer down (stream ended
  /// or the station was switched).
  Future<String?> onStreamStopped() => _runExclusive(() async {
        final path = await _finalizeIfArmed();
        await _closeAndDeleteAll();
        return path;
      });

  Future<void> dispose() => _runExclusive(_closeAndDeleteAll);

  Future<String?> _finalizeIfArmed() async {
    if (!_armed) return null;
    _armed = false;
    await _closeRaf(); // close the active segment; keep the files for the move
    if (_segments.isEmpty) return null;
    try {
      final dir = await outputDirResolver!();
      if (!await dir.exists()) await dir.create(recursive: true);
      final outPath = await uniqueFilePath(dir, _fileNameBase(), _ext);
      if (_segments.length == 1) {
        // Fast path (short song = one segment): move it, no copy.
        final src = _segments.first.file;
        try {
          await src.rename(outPath);
        } on FileSystemException {
          await src.copy(outPath);
          _deleteFileQuietly(src);
        }
      } else {
        // Concatenate segments in order, streamed in chunks (bounded memory).
        final out = File(outPath).openSync(mode: FileMode.write);
        try {
          for (final seg in _segments) {
            if (!seg.file.existsSync()) continue;
            final src = seg.file.openSync(mode: FileMode.read);
            try {
              const chunk = 1024 * 1024;
              while (true) {
                final data = src.readSync(chunk);
                if (data.isEmpty) break;
                out.writeFromSync(data);
              }
            } finally {
              src.closeSync();
            }
          }
        } finally {
          out.closeSync();
        }
        _deleteAllSegments();
      }
      _segments.clear();
      _totalBytes = 0;
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

  Future<void> _closeAndDeleteAll() async {
    await _closeRaf();
    _deleteAllSegments();
    _totalBytes = 0;
  }

  void _deleteAllSegments() {
    for (final seg in _segments) {
      _deleteFileQuietly(seg.file);
    }
    _segments.clear();
  }

  void _deleteFileQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Remove buffer segment files left over from a previous (crashed) session.
  void _sweepStaleSegments() {
    final dir = _tmpDir;
    if (dir == null) return;
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File &&
            e.uri.pathSegments.last.startsWith(_segmentFilePrefix) &&
            e.path.endsWith('.part')) {
          _deleteFileQuietly(e);
        }
      }
    } catch (_) {}
  }

  String _fileNameBase() {
    final parts = splitArtistTitle(_title);
    final raw =
        parts.artist.isEmpty ? parts.title : '${parts.artist} - ${parts.title}';
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
