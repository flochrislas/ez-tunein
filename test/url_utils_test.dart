import 'package:ez_tunein/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isValidStreamUrl', () {
    test('accepts http and https URLs', () {
      expect(isValidStreamUrl('http://relay1.swissgroove.ch:80'), isTrue);
      expect(isValidStreamUrl('https://stream.nightride.fm/nightride.mp3'),
          isTrue);
      expect(isValidStreamUrl('http://1.2.3.4:8000/stream'), isTrue);
      expect(isValidStreamUrl('HTTPS://Host.Example/x'), isTrue); // scheme case
    });

    test('trims surrounding whitespace', () {
      expect(isValidStreamUrl('  https://host/x  '), isTrue);
    });

    test('rejects non-http(s) schemes', () {
      expect(isValidStreamUrl('file:///etc/passwd'), isFalse);
      expect(isValidStreamUrl('javascript:alert(1)'), isFalse);
      expect(isValidStreamUrl('data:audio/mp3;base64,AAAA'), isFalse);
      expect(isValidStreamUrl('concat:a.mp3|b.mp3'), isFalse);
      expect(isValidStreamUrl('ftp://host/x'), isFalse);
    });

    test('rejects schemeless, hostless, empty and garbage input', () {
      expect(isValidStreamUrl('host.example/path'), isFalse); // no scheme
      expect(isValidStreamUrl('http://'), isFalse); // no host
      expect(isValidStreamUrl(''), isFalse);
      expect(isValidStreamUrl('   '), isFalse);
      expect(isValidStreamUrl('=cmd'), isFalse);
    });
  });

  group('isPlaylistUrl', () {
    test('detects playlist extensions (any case, with query strings)', () {
      expect(isPlaylistUrl('http://host/list.pls'), isTrue);
      expect(isPlaylistUrl('https://host/x.m3u'), isTrue);
      expect(isPlaylistUrl('https://host/x.m3u8'), isTrue);
      expect(isPlaylistUrl('https://host/PATH/Stream.M3U'), isTrue);
      expect(isPlaylistUrl('https://host/list.pls?token=1'), isTrue);
    });

    test('is false for direct streams and bare hosts', () {
      expect(isPlaylistUrl('http://host/stream.mp3'), isFalse);
      expect(isPlaylistUrl('https://host/audio.aac'), isFalse);
      expect(isPlaylistUrl('http://relay1.swissgroove.ch:80'), isFalse);
    });
  });
}
