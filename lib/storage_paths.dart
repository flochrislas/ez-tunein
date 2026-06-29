import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage locations and platform helpers shared across the app. This is the
/// lowest-level module — everything else may depend on it.

/// Desktop platforms have a resizable OS window to manage; mobile does not.
final bool isDesktop =
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Output folder for recordings; null/empty ⇒ the OS Downloads folder (desktop)
/// or the app documents folder (mobile). Shared with the player and the
/// recordings library, so the pref key lives here.
const recDirKey = 'rec_dir';

/// Folder recordings are written to: the user's chosen [recDirKey] if set,
/// otherwise the Downloads folder on desktop, falling back to the app documents
/// folder. Used by both the recorder and the recordings library view.
Future<Directory> recordingsDir() async {
  final prefs = await SharedPreferences.getInstance();
  final custom = prefs.getString(recDirKey);
  if (custom != null && custom.trim().isNotEmpty) return Directory(custom);
  if (isDesktop) {
    final dl = await getDownloadsDirectory();
    if (dl != null) return dl;
  }
  return getApplicationDocumentsDirectory();
}

/// Audio file extensions the recordings library will list and play.
const audioExtensions = {
  '.mp3',
  '.aac',
  '.m4a',
  '.ogg',
  '.opus',
  '.flac',
  '.wav',
};

bool isAudioFile(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return audioExtensions.contains(path.substring(dot).toLowerCase());
}

/// List the audio files in the recordings folder, sorted by name (≈ artist then
/// title, since recordings are named "Artist - Title.ext"). Best-effort: returns
/// an empty list if the folder is missing or unreadable.
Future<List<File>> listRecordings() async {
  try {
    final dir = await recordingsDir();
    if (!await dir.exists()) return [];
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && isAudioFile(e.path)) files.add(e);
    }
    files.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return files;
  } catch (_) {
    return [];
  }
}

/// The CSV file where saved tracks are appended. Shared by the player (writes)
/// and the saved-tracks view (reads / clears).
Future<File> savedTracksFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/radio_saved_tracks.csv');
}

/// The CSV file where every played song is logged automatically. Same format as
/// the saved-tracks CSV; written by the player, read/cleared by the history view.
Future<File> historyFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/radio_history.csv');
}
