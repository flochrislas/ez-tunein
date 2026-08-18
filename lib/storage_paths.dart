import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage locations and platform helpers shared across the app. This is the
/// lowest-level module — everything else may depend on it.

/// Desktop platforms have a resizable OS window to manage; mobile does not.
final bool isDesktop =
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Output folder for recordings; null/empty ⇒ `Downloads/[recSubdirName]`
/// (desktop) or the app documents folder (mobile). Shared with the player and
/// the recordings library, so the pref key lives here.
const recDirKey = 'rec_dir';

/// Our own subfolder inside the shared user folder recordings land in (Downloads,
/// or Documents when there's no Downloads). Recording straight into that folder
/// made the library list (and offer to delete) every unrelated mp3 sitting there,
/// so the default output is a folder the app owns.
const recSubdirName = 'EZ-TuneIn';

/// Where recordings go when [recDirKey] isn't set: `Downloads/[recSubdirName]` on
/// desktop (`Documents/[recSubdirName]` if the platform can't report a Downloads
/// folder), or the app documents folder on mobile. Public so the settings page can
/// label the default with its real path instead of guessing.
Future<Directory> defaultRecordingsDir() async {
  if (isDesktop) {
    // Downloads, or Documents when the platform can't report one. Both are
    // shared user folders, so always land in our own subfolder — the library
    // lists (and can delete) every audio file in whatever folder this returns.
    final base = (await getDownloadsDirectory()) ??
        await getApplicationDocumentsDirectory();
    return Directory('${base.path}/$recSubdirName');
  }
  // Mobile: the app documents dir is app-private, so there's nothing unrelated
  // in it and a subfolder would only orphan existing recordings.
  return getApplicationDocumentsDirectory();
}

/// Folder recordings are written to: the user's chosen [recDirKey] if set,
/// otherwise [defaultRecordingsDir]. Used by both the recorder and the recordings
/// library view. May not exist yet — the recorder creates it when it saves the
/// first file.
Future<Directory> recordingsDir() async {
  final prefs = await SharedPreferences.getInstance();
  final custom = prefs.getString(recDirKey);
  if (custom != null && custom.trim().isNotEmpty) return Directory(custom);
  return defaultRecordingsDir();
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
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
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

/// Open [dirPath] in the desktop file manager (xdg-open / explorer / open).
/// Best-effort and Flutter-free; throws on failure so the caller can decide
/// whether to surface it. Shared by the recordings view and the tracks view.
Future<void> revealInFileManager(String dirPath) async {
  if (Platform.isLinux) {
    await Process.run('xdg-open', [dirPath]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', [dirPath]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [dirPath]);
  }
}
