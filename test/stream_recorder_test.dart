import 'dart:io';

import 'package:ez_tunein/stream_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeFileName', () {
    test('replaces Windows-illegal characters', () {
      expect(
        StreamRecorder.sanitizeFileName(r'a\b/c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test('replaces control codes and collapses whitespace', () {
      expect(
        StreamRecorder.sanitizeFileName('a\x00b\tc   d'),
        'a_b_c d',
      );
    });

    test('caps the length at 120 chars', () {
      final long = 'x' * 200;
      expect(StreamRecorder.sanitizeFileName(long).length, 120);
    });

    test('leaves a clean name untouched', () {
      expect(
        StreamRecorder.sanitizeFileName('Daft Punk - Aerodynamic'),
        'Daft Punk - Aerodynamic',
      );
    });

    test('dodges Windows reserved device names (S8)', () {
      expect(StreamRecorder.sanitizeFileName('NUL'), '_NUL');
      expect(StreamRecorder.sanitizeFileName('con'), '_con');
      expect(StreamRecorder.sanitizeFileName('CON.mp3'), '_CON.mp3');
      expect(StreamRecorder.sanitizeFileName('COM1'), '_COM1');
      // A normal name that merely contains a reserved word is untouched.
      expect(StreamRecorder.sanitizeFileName('CONCERT'), 'CONCERT');
    });

    test('strips a trailing dot (S8)', () {
      expect(StreamRecorder.sanitizeFileName('name.'), 'name');
      expect(StreamRecorder.sanitizeFileName('a...'), 'a');
    });
  });

  group('extForContentType', () {
    test('maps known MIME types', () {
      expect(StreamRecorder.extForContentType('audio/aacp'), 'aac');
      expect(StreamRecorder.extForContentType('audio/ogg'), 'ogg');
      expect(StreamRecorder.extForContentType('audio/mpeg'), 'mp3');
    });

    test('defaults to mp3', () {
      expect(StreamRecorder.extForContentType(null), 'mp3');
      expect(
          StreamRecorder.extForContentType('application/octet-stream'), 'mp3');
    });
  });

  group('segmented ring buffer', () {
    late Directory buf;
    late Directory out;
    late StreamRecorder r;

    setUp(() {
      buf = Directory.systemTemp.createTempSync('ez_buf');
      out = Directory.systemTemp.createTempSync('ez_out');
      r = StreamRecorder()
        ..bufferingEnabled = true
        ..bufferCapBytes = 1000
        ..segmentBytesOverride = 200
        ..bufferDirResolver = (() async => buf)
        ..outputDirResolver = (() async => out);
    });
    tearDown(() {
      for (final d in [buf, out]) {
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
    });

    // Write `total` bytes whose value encodes position, in `chunk`-sized batches.
    void feed(StreamRecorder rec, int total, {int chunk = 50, int tag = 0}) {
      var written = 0;
      while (written < total) {
        final n = (total - written).clamp(0, chunk);
        rec.addAudio(List.filled(n, tag));
        written += n;
      }
    }

    test('retains roughly the cap while not armed (drops oldest segments)',
        () async {
      await r.startBuffering();
      feed(r, 3000); // well over the 1000-byte cap
      // Window stays within [cap, cap + segment): never below cap, never unbounded.
      expect(r.bufferedBytes, greaterThanOrEqualTo(1000));
      expect(r.bufferedBytes, lessThan(1000 + 200));
      // Old segment files were deleted, not left to accumulate.
      final parts =
          r.bufferDir!.listSync().where((e) => e.path.endsWith('.part')).length;
      expect(parts, lessThanOrEqualTo(1000 ~/ 200 + 2));
    });

    test('armed recording keeps everything and finalizes in order', () async {
      await r.startBuffering();
      r.addAudio(
          List.filled(150, 1)); // pre-arm audio (within cap, not dropped)
      await r.arm('Artist - Song', 'Station', 'audio/mpeg');
      feed(r, 500, tag: 2); // post-arm audio, spans several segments
      final path = (await r.onTrackChanged()).path;

      expect(path, isNotNull);
      expect(path, endsWith('.mp3'));
      final bytes = File(path!).readAsBytesSync();
      expect(bytes.length, 650); // nothing dropped while armed
      expect(bytes.sublist(0, 150), everyElement(1));
      expect(bytes.sublist(150), everyElement(2));
      // Buffer reset for the next track: a fresh, empty segment — the consumed
      // recording's segments aren't left lying around.
      expect(r.bufferedBytes, 0);
      final parts =
          r.bufferDir!.listSync().where((e) => e.path.endsWith('.part')).length;
      expect(parts, 1); // just the new active segment
    });

    test('lead-in cap keeps only the most recent pre-arm bytes', () async {
      await r.startBuffering();
      feed(r, 600, tag: 1); // pre-arm audio (within the 1000-byte cap)
      // Keep only the last 100 bytes of lead-in, then record 200 more.
      await r.arm('A - B', 'S', 'audio/mpeg', leadInBytes: 100);
      feed(r, 200, tag: 2);
      final path = (await r.onStreamStopped()).path;

      expect(path, isNotNull);
      final bytes = File(path!).readAsBytesSync();
      expect(bytes.length, 300); // 100 lead-in + 200 post-arm (not all 800)
      expect(bytes.sublist(0, 100), everyElement(1)); // tail of the lead-in
      expect(bytes.sublist(100), everyElement(2)); // everything after arm
    });

    test('lead-in cap of zero records only from the tap', () async {
      await r.startBuffering();
      feed(r, 500, tag: 1); // pre-arm audio — should be excluded entirely
      await r.arm('A - B', 'S', 'audio/mpeg', leadInBytes: 0);
      feed(r, 200, tag: 2);
      final path = (await r.onStreamStopped()).path;
      final bytes = File(path!).readAsBytesSync();
      expect(bytes, hasLength(200));
      expect(bytes, everyElement(2));
    });

    test('null lead-in keeps the whole buffered song', () async {
      await r.startBuffering();
      feed(r, 300, tag: 5); // pre-arm (within cap ⇒ retained)
      await r.arm(
          'A - B', 'S', 'audio/mpeg'); // leadInBytes: null ⇒ whole buffer
      feed(r, 200, tag: 6);
      final path = (await r.onStreamStopped()).path;
      final bytes = File(path!).readAsBytesSync();
      expect(bytes, hasLength(500));
      expect(bytes.sublist(0, 300), everyElement(5));
      expect(bytes.sublist(300), everyElement(6));
    });

    test('single-segment recording takes the rename fast path', () async {
      await r.startBuffering();
      await r.arm('A - B', 'S', 'audio/mpeg');
      r.addAudio(List.filled(100, 7)); // < segment size ⇒ one segment
      final path = (await r.onStreamStopped()).path;
      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), hasLength(100));
    });

    test('cancel disarms and the cap applies again', () async {
      await r.startBuffering();
      await r.arm('A - B', 'S', null);
      feed(r, 2000, tag: 3); // armed ⇒ grows past cap
      expect(r.bufferedBytes, greaterThan(1000));
      r.cancel();
      feed(r, 1000, tag: 4); // disarmed ⇒ trims back toward cap
      expect(r.bufferedBytes, lessThan(1000 + 200));
    });

    test('overlapping finalize ops are serialized into one valid recording',
        () async {
      await r.startBuffering();
      await r.arm('A - B', 'S', 'audio/mpeg');
      r.addAudio(List.filled(300, 9));
      // Fire both without awaiting — they must serialize, not corrupt segments.
      final f1 = r.onTrackChanged();
      final f2 = r.onStreamStopped();
      final p1 = await f1;
      final p2 = await f2;
      // Exactly one produced the recording (the first); the other is a clean
      // no-op (nothing armed by then) — never partial/duplicate output.
      final paths = [p1.path, p2.path].whereType<String>().toList();
      expect(paths, hasLength(1));
      expect(File(paths.single).readAsBytesSync(), hasLength(300));
      expect(r.bufferedBytes, 0); // torn down last
    });

    test('a failed finalize surfaces the error and leaves no output (C1/C7)',
        () async {
      // Make the output resolver throw so finalize fails deterministically.
      r.outputDirResolver = () async => throw const FileSystemException('boom');
      await r.startBuffering();
      await r.arm('A - B', 'S', 'audio/mpeg');
      r.addAudio(List.filled(100, 1));
      final result = await r.onStreamStopped();
      // C1: the failure is reported (not a silent null that reads as "nothing").
      expect(result.path, isNull);
      expect(result.error, isNotNull);
      // C7: no partial/corrupt file left behind in the output folder.
      final leftovers =
          out.listSync().where((e) => e.path.endsWith('.mp3')).toList();
      expect(leftovers, isEmpty);
    });

    test('arm queued during an in-flight op still records (C2)', () async {
      await r.startBuffering();
      r.addAudio(List.filled(100, 1)); // pre-op audio (wiped by startBuffering)
      // Fire a track-change (finalize-less here + startBuffering) WITHOUT
      // awaiting, then arm before it resolves. arm must wait for the fresh
      // buffer and succeed, not silently no-op while _raf is momentarily null.
      final tc = r.onTrackChanged();
      final armed = await r.arm('A - B', 'S', 'audio/mpeg'); // queued behind tc
      await tc;
      expect(armed, isTrue);
      expect(r.isRecording, isTrue);
      r.addAudio(List.filled(50, 2)); // post-arm audio on the fresh buffer
      final path = (await r.onStreamStopped()).path;
      expect(path, isNotNull);
      // Only the post-arm bytes on the fresh buffer — the pre-op 100 were wiped.
      expect(File(path!).readAsBytesSync(), hasLength(50));
    });

    test('arm returns false when the buffer is gone (C2 safe no-op)', () async {
      await r.startBuffering();
      await r.onStreamStopped(); // tears the buffer down (_raf is null)
      final armed = await r.arm('A - B', 'S', 'audio/mpeg');
      expect(armed, isFalse); // signals failure so the UI won't stick
      expect(r.isRecording, isFalse);
    });

    test(
        'segments live in a private per-process subdir, not the shared base '
        '(S3/C6)', () async {
      await r.startBuffering();
      r.addAudio(List.filled(100, 1));
      // No segment files sit directly in the shared base dir…
      final baseParts =
          buf.listSync().where((e) => e.path.endsWith('.part')).toList();
      expect(baseParts, isEmpty);
      // …instead the base holds exactly one private ez_tunein_* subdir…
      final subdirs = buf
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('ez_tunein_'))
          .toList();
      expect(subdirs, hasLength(1));
      expect(r.bufferDir!.path, subdirs.single.path);
      // …and the .part files are inside it.
      expect(
        r.bufferDir!.listSync().where((e) => e.path.endsWith('.part')),
        isNotEmpty,
      );
    });

    test(
        'two recorders sharing a base dir get separate dirs (no collision, C6)',
        () async {
      final r2 = StreamRecorder()
        ..bufferingEnabled = true
        ..bufferCapBytes = 1000
        ..segmentBytesOverride = 200
        ..bufferDirResolver = (() async => buf)
        ..outputDirResolver = (() async => out);
      await r.startBuffering();
      await r2.startBuffering();
      // Distinct private dirs ⇒ neither truncates or sweeps the other's buffer.
      expect(r.bufferDir!.path, isNot(r2.bufferDir!.path));

      await r.arm('A - B', 'S', 'audio/mpeg');
      r.addAudio(List.filled(120, 1));
      await r2.arm('C - D', 'S', 'audio/mpeg');
      r2.addAudio(List.filled(80, 2));
      final p1 = (await r.onStreamStopped()).path;
      final p2 = (await r2.onStreamStopped()).path;
      expect(File(p1!).readAsBytesSync(), hasLength(120));
      expect(File(p2!).readAsBytesSync(), hasLength(80));
      await r2.dispose();
    });

    test('an armed recording is bounded by the absolute ceiling (S9b)',
        () async {
      r.armedMaxBytesOverride = 300; // tiny ceiling for the test
      await r.startBuffering();
      await r.arm('A - B', 'S', 'audio/mpeg');
      feed(r, 1000, tag: 1); // far past the ceiling
      // Frozen: retained bytes stopped near the ceiling, not the full 1000.
      expect(r.bufferedBytes, lessThan(1000));
      expect(r.bufferedBytes, greaterThanOrEqualTo(300));
      final path = (await r.onStreamStopped()).path;
      expect(path, isNotNull);
      expect(File(path!).lengthSync(), lessThan(1000));
    });

    test('dispose removes the private per-process dir', () async {
      await r.startBuffering();
      r.addAudio(List.filled(50, 1));
      final dir = r.bufferDir!;
      expect(dir.existsSync(), isTrue);
      await r.dispose();
      expect(dir.existsSync(), isFalse);
      expect(r.bufferDir, isNull);
    });

    test('rapid startBuffering / onStreamStopped sequences cleanly', () async {
      final a = r.startBuffering();
      final b = r.onStreamStopped();
      final c = r.startBuffering();
      await Future.wait([a, b, c]);
      // Last op was startBuffering ⇒ a fresh, writable buffer, nothing buffered.
      expect(r.bufferedBytes, 0);
      r.addAudio(List.filled(10, 1));
      expect(r.bufferedBytes, 10);
    });
  });

  group('uniqueFilePath', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ez_rec_test');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('uses the plain name when nothing exists', () async {
      final p = await StreamRecorder.uniqueFilePath(dir, 'Song', 'mp3');
      expect(p, '${dir.path}${Platform.pathSeparator}Song.mp3');
    });

    test('avoids overwriting existing files by suffixing (n)', () async {
      File('${dir.path}${Platform.pathSeparator}Song.mp3')
          .writeAsStringSync('x');
      final p2 = await StreamRecorder.uniqueFilePath(dir, 'Song', 'mp3');
      expect(p2, '${dir.path}${Platform.pathSeparator}Song (2).mp3');

      File(p2).writeAsStringSync('y');
      final p3 = await StreamRecorder.uniqueFilePath(dir, 'Song', 'mp3');
      expect(p3, '${dir.path}${Platform.pathSeparator}Song (3).mp3');
    });
  });
}
