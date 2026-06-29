import 'dart:convert';

import 'package:ez_tunein/icy_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build one ICY metadata block: a length byte (block size / 16, rounded up with
/// null padding) followed by the (padded) bytes. Mirrors what an Icecast server
/// interleaves into the audio every `icy-metaint` bytes.
List<int> metaBlock(String payload) {
  final bytes = utf8.encode(payload);
  final blocks = (bytes.length / 16).ceil();
  final padded = List<int>.filled(blocks * 16, 0);
  for (var i = 0; i < bytes.length; i++) {
    padded[i] = bytes[i];
  }
  return [blocks, ...padded];
}

void main() {
  group('IcyParser', () {
    test('extracts StreamTitle when StreamUrl is present', () {
      final titles = <String>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add);
      p.addChunk([
        1, 2, 3, 4, // metaInt audio bytes
        ...metaBlock("StreamTitle='Daft Punk - Aerodynamic';StreamUrl='x';"),
      ]);
      expect(titles, ['Daft Punk - Aerodynamic']);
    });

    test('extracts StreamTitle when StreamUrl is absent', () {
      final titles = <String>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add);
      p.addChunk([
        1, 2, 3, 4,
        ...metaBlock("StreamTitle='Solo Title';"),
      ]);
      expect(titles, ['Solo Title']);
    });

    test('handles metadata split across chunks', () {
      final titles = <String>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add);
      final stream = [
        1, 2, 3, 4,
        ...metaBlock("StreamTitle='Across Chunks';StreamUrl='';"),
      ];
      // Feed it one byte at a time — the state machine must reassemble it.
      for (final b in stream) {
        p.addChunk([b]);
      }
      expect(titles, ['Across Chunks']);
    });

    test('handles audio split exactly at the metaint boundary', () {
      final titles = <String>[];
      final audio = <int>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add, onAudio: audio.addAll);
      // First chunk is exactly the audio run; the metadata block follows.
      p.addChunk([10, 20, 30, 40]);
      p.addChunk(metaBlock("StreamTitle='Boundary';"));
      expect(audio, [10, 20, 30, 40]);
      expect(titles, ['Boundary']);
    });

    test('zero-length metadata blocks emit no title and resume audio', () {
      final titles = <String>[];
      final audio = <int>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add, onAudio: audio.addAll);
      p.addChunk([
        1, 2, 3, 4,
        0, // empty metadata block (length byte 0)
        5, 6, 7, 8, // next audio run
        0, // empty again
      ]);
      expect(titles, isEmpty);
      expect(audio, [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('does not emit empty titles', () {
      final titles = <String>[];
      final p = IcyParser(metaInt: 4, onTitle: titles.add);
      p.addChunk([
        1, 2, 3, 4,
        ...metaBlock("StreamTitle='';StreamUrl='';"),
      ]);
      expect(titles, isEmpty);
    });

    test('emits successive titles across the stream', () {
      final titles = <String>[];
      final p = IcyParser(metaInt: 2, onTitle: titles.add);
      p.addChunk([
        1, 2,
        ...metaBlock("StreamTitle='First';"),
        3, 4,
        ...metaBlock("StreamTitle='Second';"),
      ]);
      expect(titles, ['First', 'Second']);
    });
  });
}
