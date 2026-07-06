import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'track_utils.dart';

/// Outcome of a finalize: [path] set ⇒ saved; both null ⇒ nothing was armed
/// (normal no-op); [error] set ⇒ the finalize failed (surface it to the user).
typedef FinalizeResult = ({String? path, Object? error});

/// One on-disk buffer segment: a file, how many bytes it holds, and the logical
/// offset of its first byte within the session's monotonic byte stream (used to
/// honour a lead-in cap at finalize). The live track's audio spans a sequence.
class _Segment {
  _Segment(this.file, this.startOffset);
  final File file;
  final int startOffset;
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

  /// Absolute ceiling for an *armed* recording. The buffer normally drops old
  /// bytes to stay near [bufferCapBytes], but while armed nothing is dropped —
  /// so a station whose ICY title never changes (or a manual recording never
  /// saved) would grow until the disk fills. Past this we stop appending,
  /// freezing the recording at its first N bytes (still valid) (S9b).
  static const _armedMaxBytes = 500 * 1024 * 1024;
  Future<Directory> Function()? outputDirResolver;

  /// Folder for the on-disk buffer segments. Overridable for tests; defaults to
  /// the OS temp dir.
  Future<Directory> Function() bufferDirResolver = getTemporaryDirectory;

  /// Segment size override (bytes). Tests set a tiny value to exercise rolling /
  /// dropping; null ⇒ derived from [bufferCapBytes] (see [_segmentSizeBytes]).
  int? segmentBytesOverride;

  /// Armed-recording ceiling override (bytes) for tests; null ⇒ [_armedMaxBytes].
  int? armedMaxBytesOverride;

  Directory? _tmpDir;
  final List<_Segment> _segments = [];
  RandomAccessFile? _raf; // append handle to _segments.last
  int _segSeq = 0; // names segment files uniquely within a session
  int _totalBytes = 0; // sum across all current segments
  // Monotonic count of bytes written since startBuffering (NOT decremented when
  // old segments drop) — the coordinate space for segment offsets / lead-in.
  int _writtenBytes = 0;
  // Logical offset from which an armed recording should be saved (a lead-in cap
  // moves it forward; the default is the oldest retained byte = whole buffer).
  int _recordStartOffset = 0;
  bool _armed = false;
  String _title = '';
  String _station = '';
  String _ext = 'mp3';

  bool get isRecording => _armed;

  /// Total bytes currently buffered across all segments. Exposed for tests.
  int get bufferedBytes => _totalBytes;

  /// The private per-process directory holding the buffer segments (or null
  /// before the first [startBuffering] / after [dispose]). Exposed for tests.
  Directory? get bufferDir => _tmpDir;

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
    if (_tmpDir == null || !_tmpDir!.existsSync()) {
      // Private per-process dir (createTemp ⇒ unpredictable name, 0700 on POSIX):
      // no symlink pre-creation in shared /tmp (S3), no cross-instance collision
      // (C6). Lives inside the (injectable) base temp dir.
      _tmpDir = await (await bufferDirResolver()).createTemp('ez_tunein_');
    }
    _segSeq = 0;
    _totalBytes = 0;
    _writtenBytes = 0;
    _recordStartOffset = 0;
    _openNewSegment();
  }

  /// Append a batch of audio bytes (called from [IcyReader.onAudio]). Synchronous
  /// so the stream stays in order; best-effort, write errors ignored. All the
  /// work here is cheap — an append, an occasional segment roll (open/close), and
  /// O(1) deletes of whole old segments. No big read/rewrite, so no UI hitch.
  void addAudio(List<int> bytes) {
    final raf = _raf;
    if (!bufferingEnabled || raf == null) return;
    // Freeze an armed recording at the absolute ceiling so an endless title
    // can't fill the disk (S9b). Unarmed, _dropOldSegments bounds it instead.
    if (_armed && _totalBytes >= (armedMaxBytesOverride ?? _armedMaxBytes)) {
      return;
    }
    try {
      raf.writeFromSync(bytes);
      _segments.last.bytes += bytes.length;
      _totalBytes += bytes.length;
      _writtenBytes += bytes.length;
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
    _segments.add(_Segment(f, _writtenBytes));
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
  ///
  /// [leadInBytes] caps how much of the already-buffered audio (from *before*
  /// this call) is included: only the most recent [leadInBytes] are kept. Null
  /// means "the whole buffer" (used for titled recordings, where the buffer was
  /// reset at the song's start anyway). The cap can't reach past what's still
  /// retained in the ring buffer.
  ///
  /// Queued through [_runExclusive] so a tap landing during an in-flight
  /// finalize/startBuffering (e.g. right at a track change) *waits* for the fresh
  /// buffer and arms it, instead of silently no-opping while `_raf` is null
  /// (C2). Returns true if arming succeeded; false when buffering is off or the
  /// buffer is gone (e.g. the stream was stopped) — the caller uses this to only
  /// show the UI as recording on genuine success.
  Future<bool> arm(String title, String station, String? contentType,
          {int? leadInBytes}) =>
      _runExclusive(() async {
        if (!bufferingEnabled || _raf == null) return false;
        _armed = true;
        _title = title;
        _station = station;
        _ext = extForContentType(contentType);
        final earliest = _segments.isEmpty ? 0 : _segments.first.startOffset;
        _recordStartOffset = leadInBytes == null
            ? earliest
            : (_writtenBytes - leadInBytes).clamp(earliest, _writtenBytes);
        return true;
      });

  /// Discard an in-progress recording but keep buffering the same track (so the
  /// user can re-arm). The cap applies again once disarmed.
  void cancel() => _armed = false;

  /// Finalize an armed recording (if any) and start a clean buffer for the next
  /// track. Returns the finalize outcome (see [FinalizeResult]).
  Future<FinalizeResult> onTrackChanged() => _runExclusive(() async {
        final result = await _finalizeIfArmed();
        await _startBuffering();
        return result;
      });

  /// Finalize an armed recording (if any) and tear the buffer down (stream ended
  /// or the station was switched).
  Future<FinalizeResult> onStreamStopped() => _runExclusive(() async {
        final result = await _finalizeIfArmed();
        await _closeAndDeleteAll();
        return result;
      });

  Future<void> dispose() => _runExclusive(() async {
        await _closeAndDeleteAll();
        await _removeTmpDir(); // drop the private per-process dir
      });

  Future<FinalizeResult> _finalizeIfArmed() async {
    if (!_armed) return (path: null, error: null);
    _armed = false;
    await _closeRaf(); // close the active segment; keep the files for the move
    if (_segments.isEmpty) return (path: null, error: null);
    String? outPath; // declared here so the catch can delete a partial file
    try {
      final dir = await outputDirResolver!();
      if (!await dir.exists()) await dir.create(recursive: true);
      outPath = await uniqueFilePath(dir, _fileNameBase(), _ext);
      // Does a lead-in cap mean we must drop the front of the oldest segment?
      final needsFrontSkip = _segments.isNotEmpty &&
          _recordStartOffset > _segments.first.startOffset;
      if (_segments.length == 1 && !needsFrontSkip) {
        // Fast path (short song = one segment, nothing to trim): move it.
        final src = _segments.first.file;
        try {
          await src.rename(outPath);
        } on FileSystemException {
          await src.copy(outPath);
          _deleteFileQuietly(src);
        }
      } else {
        // Concatenate segments in order, streamed in 1 MB chunks (bounded
        // memory), skipping any bytes before _recordStartOffset (the lead-in
        // cap). Async I/O + a single reused buffer so a multi-MB copy at a track
        // change doesn't freeze the UI thread (P8); the op is serialized under
        // _runExclusive, so awaiting here preserves ordering.
        final out = await File(outPath).open(mode: FileMode.write);
        final buffer = Uint8List(1024 * 1024);
        try {
          for (final seg in _segments) {
            if (!seg.file.existsSync()) continue;
            if (seg.startOffset + seg.bytes <= _recordStartOffset) {
              continue; // entirely before the cut
            }
            final skip = _recordStartOffset - seg.startOffset;
            final src = await seg.file.open();
            try {
              if (skip > 0) await src.setPosition(skip);
              while (true) {
                final n = await src.readInto(buffer);
                if (n == 0) break;
                await out.writeFrom(buffer, 0, n);
              }
            } finally {
              await src.close();
            }
          }
        } finally {
          await out.close();
        }
        _deleteAllSegments();
      }
      _segments.clear();
      _totalBytes = 0;
      return (path: outPath, error: null);
    } catch (e) {
      // Finalize failed (disk full, unwritable folder, …). Delete any partial
      // output so it can't surface as a corrupt track (C7), and surface the
      // error to the caller instead of a silent null (C1). Leftover buffer
      // segments are cleaned by the caller's startBuffering/closeAndDeleteAll.
      if (outPath != null) _deleteFileQuietly(File(outPath));
      return (path: null, error: e);
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

  /// Remove the private per-process buffer dir (on dispose). Best-effort.
  Future<void> _removeTmpDir() async {
    final dir = _tmpDir;
    _tmpDir = null;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
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

  static final _illegalFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
  static final _whitespaceRun = RegExp(r'\s+');

  /// Windows reserved device basenames (case-insensitive, with or without an
  /// extension) — a file named e.g. `NUL` or `CON.mp3` can't be created.
  static const _winReserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Strip filesystem-illegal characters and control codes; collapse whitespace,
  /// drop a trailing dot, dodge Windows reserved device names, and cap the length
  /// so the name is safe on Windows, Linux, and Android.
  static String sanitizeFileName(String s) {
    var cleaned = s
        .replaceAll(_illegalFileChars, '_')
        .replaceAll(_whitespaceRun, ' ')
        .trim();
    // A trailing dot (or space, already trimmed) is illegal on Windows.
    while (cleaned.endsWith('.')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trim();
    }
    // Reserved device name? Compare the stem (before the first dot), prefix if so.
    final dot = cleaned.indexOf('.');
    final stem = (dot >= 0 ? cleaned.substring(0, dot) : cleaned).toUpperCase();
    if (_winReserved.contains(stem)) cleaned = '_$cleaned';
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
