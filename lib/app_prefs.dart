import 'package:flutter/material.dart';

import 'audio_handler.dart';

// App-wide preference keys, defaults, and the two app-level singletons
// (`accentColor`, `audioHandler`). Centralised here so every page reads the
// same key/default without reaching into another widget's private scope.

const winWidthKey = 'win_w';
const winHeightKey = 'win_h';

// Accent color (the Material 3 seed): drives sliders, switches, and filled
// buttons app-wide. Stored as an ARGB int; the notifier lets a change in the
// Settings view re-theme the whole app live. Default is teal (0xFF009688).
const accentColorKey = 'accent_color';
const defaultAccentValue = 0xFF009688;
final accentColor = ValueNotifier<Color>(const Color(defaultAccentValue));

// Whether the player logs played songs to the history CSV. Toggled from the
// History view, read by the player; defaults to on. Top-level so both screens
// share it (shared_preferences returns one cached instance, so a write here is
// immediately visible to the player without extra plumbing).
const historyLoggingKey = 'history_logging';

// Player volume (0.0–1.0); shared by the radio player and the recordings library.
const volumeKey = 'volume';

// The saved station list (JSON); seeded from the defaults on first launch.
const stationsKey = 'stations';

// Recording settings (shared across the player and the recording-settings view,
// same single-cached-instance trick as the history toggle above).
//  - rec_buffering: whether the stream is buffered (off ⇒ no Record button).
//  - rec_buffer_mb: buffer cap in MB (the "rewind" window before recording).
//  - rec_dir:       output folder; null/empty ⇒ the OS Downloads folder.
const recBufferingKey = 'rec_buffering';
const recBufferMbKey = 'rec_buffer_mb';
// rec_dir lives in storage_paths.dart (recDirKey) since recordingsDir() reads it.
const recBufferMbDefault = 35;
// Cap the buffer to bound disk use + the finalize copy (the ring buffer drops
// whole old segments to stay near the cap — no full-buffer rewrite). See
// doc/implementation-notes.md.
const recBufferMbMax = 128;
// Lead-in cap (seconds) for *manual* recordings on title-less stations: how much
// already-buffered audio to keep before the Record tap. -1 ⇒ the whole buffer.
const recLeadSecondsKey = 'rec_lead_seconds';
const recLeadSecondsDefault = 60;
// The slider stops (seconds; -1 = whole buffer), in order.
const recLeadOptions = [0, 30, 60, 120, 180, 240, -1];
// Recordings-library playback toggles (the RecordingsPage view).
const recNeverStopsKey = 'rec_never_stops'; // auto-play the next file at end
const recRandomizeKey = 'rec_randomize'; // pick the next file at random

/// The app's single media-session handler. It owns the Android MediaSession
/// (rich notification, lock-screen, Bluetooth/car controls) and routes transport
/// to whichever page is currently driving audio. On mobile it's created via
/// `AudioService.init`; on desktop it's plain-constructed (no native session).
late EzAudioHandler audioHandler;

// Identifying User-Agent for outbound HTTP (the ICY metadata socket + the Radio
// Browser directory, which asks for a "speaking" agent). Set once in main() from
// package_info_plus to `ez_tunein/<version>`; the fallback covers any path that
// runs before main() sets it.
var appUserAgent = 'ez_tunein';
