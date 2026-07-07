import 'package:ez_tunein/track_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pad2', () {
    test('zero-pads to two digits', () {
      expect(pad2(3), '03');
      expect(pad2(12), '12');
      expect(pad2(0), '00');
    });
  });

  group('baseName', () {
    test('returns the last segment for / and \\ paths', () {
      expect(baseName('/home/u/Music/Song.mp3'), 'Song.mp3');
      expect(baseName(r'C:\Users\u\Song.mp3'), 'Song.mp3');
    });

    test('returns the input when there is no separator', () {
      expect(baseName('Song.mp3'), 'Song.mp3');
    });
  });

  group('splitArtistTitle', () {
    test('splits on the first " - "', () {
      final r = splitArtistTitle('Daft Punk - Aerodynamic');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'Aerodynamic');
    });

    test('keeps later " - " inside the title', () {
      final r = splitArtistTitle('Artist - Track - Remix');
      expect(r.artist, 'Artist');
      expect(r.title, 'Track - Remix');
    });

    test('no separator ⇒ whole string is the title', () {
      final r = splitArtistTitle('Just A Title');
      expect(r.artist, '');
      expect(r.title, 'Just A Title');
    });

    test('trims surrounding whitespace', () {
      final r = splitArtistTitle('  A  -  B  ');
      expect(r.artist, 'A');
      expect(r.title, 'B');
    });
  });

  group('fmtDuration', () {
    test('pads seconds', () {
      expect(fmtDuration(const Duration(minutes: 3, seconds: 5)), '3:05');
    });

    test('zero', () {
      expect(fmtDuration(Duration.zero), '0:00');
    });

    test('shows an hours field once past an hour', () {
      expect(fmtDuration(const Duration(minutes: 75, seconds: 30)), '1:15:30');
      expect(fmtDuration(const Duration(hours: 2, minutes: 3, seconds: 4)),
          '2:03:04');
      // Just under an hour still uses M:SS.
      expect(fmtDuration(const Duration(minutes: 59, seconds: 59)), '59:59');
    });
  });
}
