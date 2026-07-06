import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'storage_paths.dart';

/// Outcome of [saveCsvViaPicker]: the user completed the save, or cancelled the
/// picker. Any real failure is thrown for the caller to catch.
enum CsvSaveOutcome { saved, cancelled }

/// Save [csv] to a user-chosen file via the native picker, shared by the station
/// and recordings exports. On mobile file_picker writes the bytes itself (no
/// readable path); on desktop it returns the path and we write there. Returns
/// [CsvSaveOutcome.cancelled] if the user dismissed the dialog; throws on an I/O
/// error so the caller can surface it.
Future<CsvSaveOutcome> saveCsvViaPicker({
  required String csv,
  required String fileName,
  required String dialogTitle,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['csv'],
    bytes: isDesktop ? null : utf8.encode(csv),
  );
  if (path == null) return CsvSaveOutcome.cancelled;
  if (isDesktop) await File(path).writeAsString(csv);
  return CsvSaveOutcome.saved;
}
