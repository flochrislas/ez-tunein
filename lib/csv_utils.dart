// Minimal RFC 4180 CSV read/write helpers, shared by the station list, the
// saved-tracks/history tables, and the recordings export. Dependency-free so
// they can be unit-tested directly.

/// Minimal RFC 4180 CSV parser: handles quoted fields, escaped quotes (""),
/// and embedded commas/newlines. Returns rows of string fields.
List<List<String>> parseCsv(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (c == '\n') {
      row.add(field.toString());
      field = StringBuffer();
      rows.add(row);
      row = <String>[];
    } else if (c != '\r') {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
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
