import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// State of the ICY metadata side-channel, surfaced so the UI can tell apart the
/// cases that all used to read "Waiting for track info…": still connecting, a
/// station that doesn't send inline metadata at all, a metadata connection that
/// failed, and a live title.
enum MetadataStatus {
  idle,
  connecting,
  waitingForFirstTitle,
  unsupported,
  failed,
  active,
}

/// Pure byte-level ICY (Shoutcast/Icecast) metadata state machine, isolated from
/// all I/O so it can be unit-tested by feeding it chunks. Feed bytes via
/// [addChunk]; it forwards contiguous runs of pure audio bytes (metadata
/// stripped) to [onAudio] and each decoded `StreamTitle` to [onTitle].
class IcyParser {
  IcyParser({required this.metaInt, this.onTitle, this.onAudio});

  final int metaInt;
  final void Function(String title)? onTitle;
  final void Function(List<int> audioBytes)? onAudio;

  // Skip `metaInt` audio bytes, read 1 length byte (× 16 = metadata block size),
  // read that many metadata bytes, repeat.
  late int _bytesUntilMeta = metaInt;
  int _metaRemaining = 0;
  final List<int> _metaBuf = [];
  bool _inMeta = false;
  bool _readingLen = false;

  void addChunk(List<int> chunk) {
    // Forward contiguous runs of audio bytes (everything that isn't a length
    // byte or metadata) in batches rather than byte-by-byte.
    var audioStart = -1;
    void flushAudio(int end) {
      if (audioStart >= 0) {
        onAudio?.call(chunk.sublist(audioStart, end));
        audioStart = -1;
      }
    }

    for (var i = 0; i < chunk.length; i++) {
      final b = chunk[i];
      if (_readingLen) {
        flushAudio(i); // the length byte ends the current audio run
        _metaRemaining = b * 16;
        _readingLen = false;
        if (_metaRemaining == 0) {
          _bytesUntilMeta = metaInt;
        } else {
          _metaBuf.clear();
          _inMeta = true;
        }
      } else if (_inMeta) {
        _metaBuf.add(b);
        _metaRemaining--;
        if (_metaRemaining == 0) {
          _emit(_metaBuf);
          _inMeta = false;
          _bytesUntilMeta = metaInt;
        }
      } else {
        if (audioStart < 0) audioStart = i;
        _bytesUntilMeta--;
        if (_bytesUntilMeta == 0) {
          _readingLen = true;
        }
      }
    }
    flushAudio(chunk.length); // trailing audio run in this chunk
  }

  void _emit(List<int> bytes) {
    // Strip the null/space padding the server appends after the fields.
    final text =
        utf8.decode(bytes, allowMalformed: true).replaceAll('\x00', '');
    // Prefer anchoring the end on the next field (StreamUrl=) so a title that
    // itself contains "';" isn't cut short; fall back to a plain match.
    final match = RegExp("StreamTitle='(.*?)';StreamUrl=").firstMatch(text) ??
        RegExp("StreamTitle='(.*?)';").firstMatch(text);
    final title = match?.group(1)?.trim() ?? '';
    if (title.isNotEmpty) onTitle?.call(title);
  }
}

/// Reads ICY inline metadata (and the audio bytes, for the recorder) from a
/// stream URL.
///
/// This is intentionally independent of the audio backend: it opens its own
/// HTTP connection with the `Icy-MetaData: 1` header and parses the metadata
/// blocks the server interleaves into the audio (via [IcyParser]). Because of
/// that it behaves identically on Windows, Linux, and Android — unlike
/// just_audio's icyMetadataStream, which is only populated on mobile/macOS.
///
/// Trade-off: this downloads the stream a second time (audio bytes are read and
/// either forwarded to the recorder or discarded). At ~128 kbps that's
/// negligible.
///
/// Lifecycle safety: every connection is tagged with a monotonically increasing
/// [_generation]; [start]/[stop] bump it, so a superseded connection — and any
/// pending reconnect timer — becomes inert and can't deliver a stale title or
/// step on a newer one. The caller should *additionally* guard its callbacks by
/// its own play-session id for defence in depth on fast station switches.
class IcyReader {
  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  Timer? _reconnectTimer;

  /// MIME type (e.g. `audio/mpeg`) and bitrate of the current stream, taken from
  /// the response headers. Best-effort: either may be null. Used to choose the
  /// recording file extension and to show the rate in the recording settings.
  String? contentType;
  int? bitrateKbps;

  // Connection identity — bumped on every start()/stop().
  int _generation = 0;

  // Retained so a dropped metadata connection can be reconnected.
  String? _url;
  void Function(String title)? _onTitle;
  void Function(List<int> audioBytes)? _onAudio;
  void Function(MetadataStatus status)? _onStatus;
  int _attempts = 0;

  // Bounded, conservative reconnect: don't hammer the station.
  static const _maxAttempts = 5;

  /// Backoff before reconnect attempt [attempt] (0-based). Overridable for tests
  /// (so they don't wait real seconds); defaults to exponential, capped at 30 s.
  Duration Function(int attempt) reconnectDelay =
      (attempt) => Duration(seconds: (1 << attempt).clamp(1, 30));

  // When the stream has no inline metadata (no `icy-metaint`), whether to keep
  // the connection open and forward the raw audio anyway (so the recorder can
  // buffer/record title-less stations). The caller sets this from its buffering
  // pref so we don't double-download a station we'll never record from.
  bool _bufferWithoutMetadata = false;

  Future<void> start(
    String url, {
    required void Function(String title) onTitle,
    void Function(List<int> audioBytes)? onAudio,
    void Function(MetadataStatus status)? onStatus,
    bool bufferWithoutMetadata = false,
  }) async {
    await stop(); // bumps the generation, cancels any prior connection/timer
    final gen = _generation;
    _url = url;
    _onTitle = onTitle;
    _onAudio = onAudio;
    _onStatus = onStatus;
    _bufferWithoutMetadata = bufferWithoutMetadata;
    _attempts = 0;
    await _connect(gen);
  }

  Future<void> _connect(int gen) async {
    if (gen != _generation) return;
    contentType = null;
    bitrateKbps = null;
    _onStatus?.call(MetadataStatus.connecting);
    final client = HttpClient();
    _client = client;
    try {
      final req = await client.getUrl(Uri.parse(_url!));
      req.headers.set('Icy-MetaData', '1');
      req.headers.set('User-Agent', 'radio-app');
      final resp = await req.close();
      if (gen != _generation) {
        client.close(force: true);
        return;
      }
      contentType = resp.headers.value('content-type')?.trim();
      bitrateKbps = int.tryParse(resp.headers.value('icy-br') ?? '');
      final metaInt =
          int.tryParse(resp.headers.value('icy-metaint') ?? '') ?? 0;
      if (metaInt <= 0) {
        // No interleaved metadata (no titles to parse). It's a stable station
        // fact, so `unsupported` either way. But the whole body is pure audio —
        // when asked, keep streaming it to the recorder (manual recording of
        // title-less stations); otherwise close to save the bandwidth.
        _onStatus?.call(MetadataStatus.unsupported);
        if (_bufferWithoutMetadata) {
          _listenRaw(resp, gen);
        } else {
          client.close(force: true);
          _client = null;
        }
        return;
      }
      _onStatus?.call(MetadataStatus.waitingForFirstTitle);
      _listen(resp, metaInt, gen);
    } catch (_) {
      // Metadata is best-effort; playback continues regardless. Try to recover.
      _scheduleReconnect(gen);
    }
  }

  void _listen(Stream<List<int>> stream, int metaInt, int gen) {
    var gotTitle = false;
    final parser = IcyParser(
      metaInt: metaInt,
      onTitle: (title) {
        if (gen != _generation) return;
        if (!gotTitle) {
          gotTitle = true;
          _attempts = 0; // a working connection refills the retry budget
          _onStatus?.call(MetadataStatus.active);
        }
        _onTitle?.call(title);
      },
      onAudio: (bytes) {
        if (gen != _generation) return;
        _onAudio?.call(bytes);
      },
    );
    _sub = stream.listen(
      (chunk) {
        if (gen != _generation) return;
        parser.addChunk(chunk);
      },
      // The metadata connection died while audio (likely) keeps playing on the
      // backend's own connection — recover so track info/recording resume.
      onError: (_) => _scheduleReconnect(gen),
      onDone: () => _scheduleReconnect(gen),
      cancelOnError: true,
    );
  }

  /// For streams with no inline metadata: forward every byte as audio (there's
  /// nothing to parse out), reconnecting on a drop just like [_listen].
  void _listenRaw(Stream<List<int>> stream, int gen) {
    _sub = stream.listen(
      (chunk) {
        if (gen != _generation) return;
        _onAudio?.call(chunk);
      },
      onError: (_) => _scheduleReconnect(gen),
      onDone: () => _scheduleReconnect(gen),
      cancelOnError: true,
    );
  }

  void _scheduleReconnect(int gen) {
    if (gen != _generation) return;
    // Tear down the current (dead) connection before retrying.
    _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    _reconnectTimer?.cancel();
    if (_attempts >= _maxAttempts) {
      _onStatus?.call(MetadataStatus.failed);
      return;
    }
    // Report the gap right away (not just when the retry fires) so the UI marks
    // the title stale and disables Save/Record for the whole backoff window —
    // otherwise status would linger on `active` until _connect() runs.
    _onStatus?.call(MetadataStatus.connecting);
    final delay = reconnectDelay(_attempts);
    _attempts++;
    _reconnectTimer = Timer(delay, () => _connect(gen));
  }

  Future<void> stop() async {
    _generation++; // invalidate the live connection and any pending reconnect
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    // Clear so a previous station's format/bitrate can't show while the next one
    // is still connecting (they're repopulated from the new response headers).
    contentType = null;
    bitrateKbps = null;
    _onStatus?.call(MetadataStatus.idle);
  }
}
