import 'package:ez_tunein/csv_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCsv', () {
    test('parses plain rows', () {
      expect(parseCsv('a,b,c\n1,2,3\n'), [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('handles quoted fields with embedded commas', () {
      expect(parseCsv('"a,1","b,2"\n'), [
        ['a,1', 'b,2'],
      ]);
    });

    test('handles escaped double quotes', () {
      expect(parseCsv('"she said ""hi"""\n'), [
        ['she said "hi"'],
      ]);
    });

    test('handles embedded newlines inside quotes', () {
      expect(parseCsv('"line1\nline2",end\n'), [
        ['line1\nline2', 'end'],
      ]);
    });

    test('ignores CR in CRLF line endings', () {
      expect(parseCsv('a,b\r\nc,d\r\n'), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });

    test('keeps a final row without a trailing newline', () {
      expect(parseCsv('a,b'), [
        ['a', 'b'],
      ]);
    });
  });

  group('csvField', () {
    test('leaves a plain value unquoted', () {
      expect(csvField('hello'), 'hello');
    });

    test('quotes a value with a comma', () {
      expect(csvField('a,b'), '"a,b"');
    });

    test('quotes and doubles embedded quotes', () {
      expect(csvField('a"b'), '"a""b"');
    });

    test('quotes values with newlines', () {
      expect(csvField('a\nb'), '"a\nb"');
    });

    test('round-trips through parseCsv', () {
      const fields = ['plain', 'a,b', 'has "quote"', 'multi\nline'];
      final line = fields.map(csvField).join(',');
      expect(parseCsv('$line\n'), [fields]);
    });
  });

  group('csvField formula-injection guard (S1)', () {
    test('prefixes a leading formula trigger with a single quote', () {
      expect(csvField('=1+2'), "'=1+2");
      expect(csvField('+1'), "'+1");
      expect(csvField('-M-'), "'-M-");
      expect(csvField('@SUM(A1)'), "'@SUM(A1)");
      expect(csvField('\tvalue'), "'\tvalue");
      // A leading CR is both a formula trigger and an RFC quote-trigger, so it's
      // prefixed AND wrapped in quotes.
      expect(csvField('\rvalue'), '"\'\rvalue"');
    });

    test('combines the guard with RFC 4180 quoting', () {
      // Leading = plus an embedded comma ⇒ prefixed AND quoted.
      expect(csvField('=1,2'), '"\'=1,2"');
      // The classic exploit payload survives as literal, quoted text.
      expect(csvField('=cmd|\'/C calc\'!A0'), "'=cmd|'/C calc'!A0");
    });

    test('leaves normal values, URLs and timestamps untouched', () {
      expect(csvField('Daft Punk'), 'Daft Punk');
      expect(csvField('https://stream.example.com/x.mp3'),
          'https://stream.example.com/x.mp3');
      expect(csvField('2026-07-06T12:00:00.000'), '2026-07-06T12:00:00.000');
      // A trigger only matters as the *first* character.
      expect(csvField('A=B'), 'A=B');
    });

    test('is idempotent (re-export never stacks quotes)', () {
      expect(csvField(csvField('=x')), "'=x");
    });

    test('a guarded value still round-trips through parseCsv', () {
      expect(parseCsv('${csvField('=danger')}\n'), [
        ["'=danger"],
      ]);
    });
  });
}
