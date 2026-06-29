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

/// Escapes a single CSV field per RFC 4180 (quote if it contains a comma,
/// quote, or newline; double any embedded quotes).
String csvField(String value) {
  if (value.contains(RegExp(r'[",\n\r]'))) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
