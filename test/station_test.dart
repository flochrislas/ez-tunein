import 'package:ez_tunein/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Station JSON', () {
    test('round-trips name, url, and colour', () {
      const s = Station('Jazz FM', 'http://x/stream', color: 0xFF009688);
      final back = Station.fromJson(s.toJson());
      expect(back.name, 'Jazz FM');
      expect(back.url, 'http://x/stream');
      expect(back.color, 0xFF009688);
    });

    test('omits colour from JSON when unset', () {
      const s = Station('Plain', 'http://x');
      expect(s.toJson().containsKey('color'), isFalse);
      expect(Station.fromJson(s.toJson()).color, isNull);
    });

    test('tolerates older saved data with no colour field', () {
      final s = Station.fromJson({'name': 'Old', 'url': 'http://x'});
      expect(s.color, isNull);
    });
  });
}
