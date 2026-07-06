// Minimal RFC 4180 CSV read/write helpers, shared by the station list, the
// saved-tracks/history tables, and the recordings export. Dependency-free so
// they can be unit-tested directly.

/// Minimal RFC 4180 CSV parser: handles quoted fields, escaped quotes (""),
/// and embedded commas/newlines. Returns rows of string fields.
///
/// Scans by `codeUnitAt` (int comparisons, no per-character `String`) and slices
/// whole fields with `substring`; a `StringBuffer` is only used inside a quoted
/// field that actually contains an escaped `""`. This keeps a large-history parse
/// allocation-light (the old char-by-char version allocated ~1 String per input
/// char — the dominant History-open cost).
List<List<String>> parseCsv(String input) {
  const quote = 0x22, comma = 0x2C, lf = 0x0A, cr = 0x0D;
  final rows = <List<String>>[];
  final len = input.length;
  var row = <String>[];
  var i = 0;

  while (i < len) {
    // --- parse one field starting at i ---
    String value;
    if (input.codeUnitAt(i) == quote) {
      i++; // skip the opening quote
      var spanStart = i;
      StringBuffer? buf; // created only when an escaped "" is hit
      while (true) {
        if (i >= len) {
          // Unterminated quote: take the rest of the input (lenient).
          final tail = input.substring(spanStart, len);
          value = buf == null ? tail : (buf..write(tail)).toString();
          break;
        }
        if (input.codeUnitAt(i) == quote) {
          if (i + 1 < len && input.codeUnitAt(i + 1) == quote) {
            // "" ⇒ one literal quote: keep content up to and including it.
            buf ??= StringBuffer();
            buf.write(input.substring(spanStart, i + 1));
            i += 2;
            spanStart = i;
          } else {
            final span = input.substring(spanStart, i);
            value = buf == null ? span : (buf..write(span)).toString();
            i++; // consume the closing quote
            break;
          }
        } else {
          i++;
        }
      }
    } else {
      final start = i;
      while (i < len) {
        final ch = input.codeUnitAt(i);
        if (ch == comma || ch == lf || ch == cr) break;
        i++;
      }
      value = input.substring(start, i);
    }
    row.add(value);

    // --- delimiter after the field ---
    if (i >= len) break; // EOF right after a field ⇒ flush the row below
    final d = input.codeUnitAt(i);
    if (d == comma) {
      i++;
      if (i >= len) {
        row.add(''); // trailing comma ⇒ one empty field, then flush
        break;
      }
    } else if (d == lf) {
      i++;
      rows.add(row);
      row = <String>[];
    } else if (d == cr) {
      i++;
      if (i < len && input.codeUnitAt(i) == lf) i++; // CRLF ⇒ one terminator
      rows.add(row);
      row = <String>[];
    }
  }
  if (row.isNotEmpty) rows.add(row);
  return rows;
}

/// Leading characters a spreadsheet may treat as a formula, even inside a quoted
/// field — values starting with one get a `'` prefix so they're literal text.
const _csvFormulaLeads = {'=', '+', '-', '@', '\t', '\r'};

/// Escapes a single CSV field: first neutralizes spreadsheet formula injection
/// (OWASP — a leading `=` `+` `-` `@` TAB or CR is prefixed with a single quote
/// so it's treated as literal text), then applies RFC 4180 quoting (quote if it
/// contains a comma, quote, or newline; double any embedded quotes). This is the
/// single choke point for every CSV write, and untrusted values (ICY
/// `StreamTitle`, Radio Browser station names) flow through it. Idempotent: a
/// `'`-prefixed value no longer starts with a trigger, so re-export never stacks
/// quotes; normal titles, `http(s)://` URLs and ISO timestamps are untouched.
String csvField(String value) {
  var v = value;
  if (v.isNotEmpty && _csvFormulaLeads.contains(v[0])) v = "'$v";
  if (v.contains(RegExp(r'[",\n\r]'))) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}
