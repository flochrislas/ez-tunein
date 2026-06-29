import 'package:ez_tunein/track_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
