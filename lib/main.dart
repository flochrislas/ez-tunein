import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_prefs.dart';
import 'audio_handler.dart';
import 'storage_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register the libmpv-based backend for desktop. On Android/iOS this is a
  // no-op — just_audio uses ExoPlayer/AVPlayer there.
  JustAudioMediaKit.ensureInitialized(
    linux: true,
    windows: true,
    macOS: true,
  );

  // Set up the media session. On Android/iOS AudioService.init binds the native
  // MediaSession + mediaPlayback foreground service (keeps playback + the
  // recording/metadata socket alive with the screen off, and exposes lock-screen
  // / Bluetooth / car controls). On desktop we construct the same handler
  // directly — no native session — so playback and the exit(0) close path are
  // unaffected.
  if (Platform.isAndroid || Platform.isIOS) {
    audioHandler = await AudioService.init(
      builder: () => EzAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'io.github.flochrislas.eztunein.audio',
        androidNotificationChannelName: 'Playback',
        // Keep the foreground service alive when paused so a paused radio stream
        // still records in the background; ongoing must be false to satisfy
        // audio_service's assertion (ongoing ⇒ stopForegroundOnPause).
        androidStopForegroundOnPause: false,
        androidNotificationOngoing: false,
        // A monochrome small status icon (the multicolour launcher would render
        // as a white square in the status bar).
        androidNotificationIcon: 'drawable/ic_stat_media',
      ),
    );
  } else {
    audioHandler = EzAudioHandler();
  }

  // Materialise the bundled app icon to a cache file once, for a consistent
  // media-card artwork across both radio and recordings modes.
  await _prepareArtUri();

  // Restore the saved accent color before the first frame.
  final prefs = await SharedPreferences.getInstance();
  accentColor.value = Color(prefs.getInt(accentColorKey) ?? defaultAccentValue);

  // On desktop, restore the saved window size before showing the window.
  if (isDesktop) {
    await windowManager.ensureInitialized();
    final w = prefs.getDouble(winWidthKey);
    final h = prefs.getDouble(winHeightKey);
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: (w != null && h != null) ? Size(w, h) : const Size(640, 720),
        minimumSize: const Size(420, 480),
        title: 'EZ-TuneIn Radio',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const RadioApp());
}

/// Copy the bundled launcher icon to a real file once and hand its `file://` URI
/// to the media handler as the notification/lock-screen artwork. audio_service
/// needs a loadable bitmap (file/http/content), not an `asset:` path. Best-effort
/// — if it fails the card simply shows no art.
Future<void> _prepareArtUri() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/media_art.png');
    if (!await f.exists()) {
      final data = await rootBundle.load('assets/icon/app_icon_256.png');
      await f.writeAsBytes(data.buffer.asUint8List());
    }
    audioHandler.setArtUri(f.uri);
  } catch (_) {}
}
