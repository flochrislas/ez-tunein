import 'package:ez_tunein/storage_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isAudioFile', () {
    test('accepts the known extensions, case-insensitively', () {
      expect(isAudioFile('/x/Artist - Title.mp3'), isTrue);
      expect(isAudioFile('/x/Artist - Title.MP3'), isTrue);
      expect(isAudioFile('/x/a.aac'), isTrue);
      expect(isAudioFile('/x/a.ogg'), isTrue);
      expect(isAudioFile('/x/a.flac'), isTrue);
    });

    test('rejects other files and files with no extension', () {
      expect(isAudioFile('/x/notes.txt'), isFalse);
      expect(isAudioFile('/x/README'), isFalse);
      expect(isAudioFile('/x.dir/README'), isFalse); // dot in a folder name
      expect(isAudioFile(''), isFalse);
    });
  });
}
