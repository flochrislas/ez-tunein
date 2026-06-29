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
}
