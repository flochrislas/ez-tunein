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
  });

  group('extForContentType', () {
    test('maps known MIME types', () {
      expect(StreamRecorder.extForContentType('audio/aacp'), 'aac');
      expect(StreamRecorder.extForContentType('audio/ogg'), 'ogg');
      expect(StreamRecorder.extForContentType('audio/mpeg'), 'mp3');
    });

    test('defaults to mp3', () {
      expect(StreamRecorder.extForContentType(null), 'mp3');
      expect(StreamRecorder.extForContentType('application/octet-stream'), 'mp3');
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
      File('${dir.path}${Platform.pathSeparator}Song.mp3').writeAsStringSync('x');
      final p2 = await StreamRecorder.uniqueFilePath(dir, 'Song', 'mp3');
      expect(p2, '${dir.path}${Platform.pathSeparator}Song (2).mp3');

      File(p2).writeAsStringSync('y');
      final p3 = await StreamRecorder.uniqueFilePath(dir, 'Song', 'mp3');
      expect(p3, '${dir.path}${Platform.pathSeparator}Song (3).mp3');
    });
  });
}
