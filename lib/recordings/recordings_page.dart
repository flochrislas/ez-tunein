import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_prefs.dart';
import '../audio_handler.dart';
import '../csv_utils.dart';
import '../settings/settings_page.dart';
import '../storage_paths.dart';
import '../track_utils.dart';

/// Browse and play the recorded songs in the output folder — a tiny local
/// jukebox. Owns its **own** [AudioPlayer] (separate from the radio's) and stops
/// playback when the view is left. Starting a song stops the live radio first
/// (passed in as [stopRadio]) so the two never play at once. Track names come
/// from the filenames; "never stops" auto-advances and "randomize" shuffles.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key, required this.stopRadio});

  /// Stops the live radio stream; called once before the first recording plays.
  final Future<void> Function() stopRadio;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage>
    implements AudioModeDriver {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<Duration>? _posSub;
  int _lastPushedSec = -1; // throttle lock-screen position pushes to ~1/sec
  SharedPreferences? _prefs;

  List<File> _files = [];
  int _index = -1; // currently playing file, or -1
  double _volume = 1.0; // 0.0–1.0; shares the radio's `volume` pref
  bool _isPlaying = false;
  Duration? _duration; // length of the current file (from durationStream)
  double?
      _seekDragMs; // slider position while the user is dragging the seek bar
  ProcessingState? _lastState; // to act on the transition *into* completed only
  bool _neverStops = false;
  bool _randomize = false;
  bool _radioStopped = false; // stop the radio only once, on first play

  @override
  void initState() {
    super.initState();
    _init();
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      final ps = s.processingState;
      // "Playing" is false once a track completes (the icon should read play).
      setState(() => _isPlaying = s.playing && ps != ProcessingState.completed);
      // Keep the media card (play/pause label, etc.) in step.
      _publishRecording();
      // Local files are finite, so completed fires at the end → auto-advance.
      // Only on the *transition* into completed (it can re-emit), and deferred
      // off this callback: driving the player from inside its own event leaves
      // the next track loaded-but-parked (was the "shows next song, stuck at
      // 0:00" bug).
      if (ps == ProcessingState.completed &&
          _lastState != ProcessingState.completed &&
          _neverStops) {
        Future.delayed(Duration.zero, _advance);
      }
      _lastState = ps;
    });
    // Duration isn't reliably returned by setFilePath on the media_kit backend —
    // it arrives here instead.
    _durSub = _player.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    // Feed the lock-screen scrubber. positionStream ticks often, so push only
    // when the whole-second changes (best-effort, mobile-only).
    _posSub = _player.positionStream.listen((pos) {
      if (!(Platform.isAndroid || Platform.isIOS)) return;
      if (audioHandler.mode != PlaybackMode.recordings) return;
      final sec = pos.inSeconds;
      if (sec == _lastPushedSec) return;
      _lastPushedSec = sec;
      audioHandler.updateRecordingPosition(
        position: pos,
        buffered: _player.bufferedPosition,
        playing: _player.playing,
      );
    });
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final files = await listRecordings();
    final vol = prefs.getDouble(volumeKey);
    if (vol != null) await _player.setVolume(vol);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _files = files;
      if (vol != null) _volume = vol;
      _neverStops = prefs.getBool(recNeverStopsKey) ?? false;
      _randomize = prefs.getBool(recRandomizeKey) ?? false;
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _durSub?.cancel();
    _posSub?.cancel();
    _player.dispose(); // stops playback when leaving the view
    // Leaving the view stops playback, so drop the media session too.
    audioHandler.detach(this);
    super.dispose();
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

  ({String artist, String title}) _parts(File f) {
    final name = _fileName(f);
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return splitArtistTitle(base);
  }

  String _label(File f) {
    final p = _parts(f);
    return p.artist.isEmpty ? p.title : '${p.artist} — ${p.title}';
  }

  Future<void> _playAt(int i) async {
    if (i < 0 || i >= _files.length) return;
    if (!_radioStopped) {
      await widget.stopRadio(); // first play silences the live radio
      _radioStopped = true;
    }
    // Re-selecting the file that's already loaded (e.g. a one-song list under
    // "never stops", which loops back to the same index) — just restart it.
    // setFilePath on the same, already-completed source wouldn't replay.
    if (i == _index) {
      await _player.seek(Duration.zero);
      unawaited(_player.play());
      return;
    }
    try {
      final dur = await _player.setFilePath(_files[i].path);
      // Don't await play() (see the stream gotcha) — completion arrives on the
      // player-state stream, which drives "never stops".
      unawaited(_player.play());
      if (mounted) {
        setState(() {
          _index = i;
          _duration = dur;
          _seekDragMs = null;
        });
      }
      _lastPushedSec = -1; // new track ⇒ allow an immediate position push
      _publishRecording(); // reflect the new track in the card
    } catch (e) {
      if (mounted) {
        setState(() {
          _index = -1;
          _duration = null;
        });
        _snack('Could not play that file: $e');
      }
    }
  }

  int _nextIndex() {
    final n = _files.length;
    if (n == 0) return -1;
    if (_randomize) {
      if (n == 1) return 0;
      var r = Random().nextInt(n);
      if (r == _index) r = (r + 1) % n; // avoid an immediate repeat
      return r;
    }
    return _index < 0 ? 0 : (_index + 1) % n;
  }

  void _advance() => _playAt(_nextIndex());
  void _skip() => _playAt(_nextIndex());

  void _togglePlayPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      unawaited(_player.play());
    }
  }

  /// Stop playback entirely (the lock-screen Stop button). Clears the now-playing
  /// row, which also tears the media session down via [_publishRecording].
  Future<void> _stopPlayback() async {
    await _player.stop();
    if (mounted) {
      setState(() {
        _index = -1;
        _duration = null;
        _seekDragMs = null;
        _isPlaying = false;
      });
    }
    _publishRecording();
  }

  /// Publish recordings-playback state to the media session: while a file is
  /// loaded it shows a rich notification (current track + Play/Pause + Skip +
  /// Stop + scrubber) and holds the process in the foreground so playback
  /// survives the screen turning off; with nothing loaded it tears the session
  /// down. No-op off mobile; best-effort.
  void _publishRecording() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (_index < 0 || _index >= _files.length) {
      audioHandler.detach(this);
      return;
    }
    audioHandler.attach(PlaybackMode.recordings, this);
    audioHandler.publishRecording(
      label: _label(_files[_index]),
      duration: _duration,
      playing: _isPlaying,
    );
  }

  // --- AudioModeDriver: transport from the media session / Bluetooth / car ---

  @override
  Future<void> driverPlay() async => unawaited(_player.play());

  @override
  Future<void> driverPause() async => _player.pause();

  @override
  Future<void> driverStop() => _stopPlayback();

  @override
  Future<void> driverSeek(Duration position) => _player.seek(position);

  @override
  Future<void> driverSkipNext() async => _skip();

  Future<void> _setNeverStops(bool v) async {
    setState(() => _neverStops = v);
    await _prefs?.setBool(recNeverStopsKey, v);
  }

  Future<void> _setRandomize(bool v) async {
    setState(() => _randomize = v);
    await _prefs?.setBool(recRandomizeKey, v);
  }

  Future<void> _setVolume(double v) async {
    setState(() => _volume = v);
    await _player.setVolume(v);
    await _prefs?.setDouble(volumeKey, v); // shared with the radio player
  }

  /// Export the list as a two-column `artist,title` CSV (same file-picker flow as
  /// the station export: desktop writes the path, mobile gets the bytes).
  Future<void> _export() async {
    if (_files.isEmpty) {
      _snack('No recordings to export.');
      return;
    }
    final csv = StringBuffer('artist,title\n');
    for (final f in _files) {
      final p = _parts(f);
      csv.writeln('${csvField(p.artist)},${csvField(p.title)}');
    }
    final bytes = utf8.encode(csv.toString());
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export recordings list',
        fileName: 'ez_tunein_recordings.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        bytes: isDesktop ? null : bytes,
      );
    } catch (e) {
      _snack('Export failed: $e');
      return;
    }
    if (path == null) return; // cancelled
    try {
      if (isDesktop) await File(path).writeAsString(csv.toString());
      _snack('Exported ${_files.length} recording(s).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Permanently delete a recording (with confirmation) to free up space — the
  /// in-app way to manage files, which matters on Android where the folder isn't
  /// browsable. Stops playback first if it's the track currently playing.
  Future<void> _deleteFile(int i) async {
    if (i < 0 || i >= _files.length) return;
    final file = _files[i];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text('Permanently delete “${_label(file)}”?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final wasCurrent = i == _index;
    try {
      if (wasCurrent) await _player.stop();
      if (await file.exists()) await file.delete();
    } catch (e) {
      _snack('Could not delete: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _files.removeAt(i);
      if (wasCurrent) {
        _index = -1;
        _duration = null;
      } else if (i < _index) {
        _index -= 1; // keep pointing at the same playing file
      }
    });
    _snack('Deleted.');
  }

  /// Share a recording via the OS share sheet — lets the user move/copy it off
  /// the device (the practical "save elsewhere" on mobile).
  Future<void> _shareFile(int i) async {
    if (i < 0 || i >= _files.length) return;
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(_files[i].path)],
        subject: _label(_files[i]),
      ));
    } catch (e) {
      _snack('Share failed: $e');
    }
  }

  /// Open the recordings folder in the desktop file manager so the user can
  /// rename / delete files directly. Best-effort, desktop only.
  Future<void> _openFolder() async {
    try {
      final dir = (await recordingsDir()).path;
      if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      }
    } catch (e) {
      _snack('Could not open the folder: $e');
    }
  }

  /// A draggable progress bar for the playing file: current position on the left,
  /// total length on the right, slide anywhere to seek. Position ticks come from
  /// the player; while dragging we show the drag value and seek on release.
  Widget _seekBar() {
    final total = _duration ?? Duration.zero;
    final maxMs = total.inMilliseconds.toDouble();
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, snap) {
        final posMs = (snap.data ?? Duration.zero)
            .inMilliseconds
            .clamp(0, maxMs.toInt())
            .toDouble();
        final value = _seekDragMs ?? posMs;
        return Row(
          children: [
            Text(fmtDuration(Duration(milliseconds: value.round())),
                style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              // The default inactive track is the surface-variant grey, which is
              // the same as this panel's background — override it so the unplayed
              // portion is visible.
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  inactiveTrackColor:
                      Theme.of(context).colorScheme.onSurface.withValues(
                            alpha: 0.30,
                          ),
                ),
                child: Slider(
                  value: maxMs == 0 ? 0 : value.clamp(0, maxMs),
                  max: maxMs == 0 ? 1 : maxMs,
                  onChanged: maxMs == 0
                      ? null
                      : (v) => setState(() => _seekDragMs = v),
                  onChangeEnd: maxMs == 0
                      ? null
                      : (v) async {
                          await _player.seek(Duration(milliseconds: v.round()));
                          if (mounted) setState(() => _seekDragMs = null);
                        },
                ),
              ),
            ),
            Text(fmtDuration(total),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }

  /// A compact switch sitting right next to its label (the whole row toggles).
  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          if (isDesktop)
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Open recordings folder',
              onPressed: _openFolder,
            ),
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Export list to CSV',
            onPressed: _files.isEmpty ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsPage(),
                ),
              );
              // The output folder may have changed — re-list, but only while
              // idle so we don't disturb the index of an in-progress playback.
              if (!mounted || _index >= 0) return;
              final files = await listRecordings();
              if (mounted) setState(() => _files = files);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final volIcon = Icon(
                  _volume == 0
                      ? Icons.volume_off
                      : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
                );
                final slider = Slider(value: _volume, onChanged: _setVolume);
                final toggles = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _toggle('Never stops', _neverStops, _setNeverStops),
                    const SizedBox(width: 16),
                    _toggle('Randomize', _randomize, _setRandomize),
                  ],
                );
                // Approx fixed width of the icon + spacing + both toggles. If the
                // slider couldn't get at least half the row, drop the toggles to
                // a second row and let the slider span the full width.
                const reserved = 320.0;
                final sliderGetsHalf =
                    constraints.maxWidth - reserved >= constraints.maxWidth / 2;
                if (sliderGetsHalf) {
                  return Row(
                    children: [
                      volIcon,
                      Expanded(child: slider),
                      const SizedBox(width: 8),
                      toggles,
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        volIcon,
                        Expanded(child: slider),
                      ],
                    ),
                    Align(alignment: Alignment.centerRight, child: toggles),
                  ],
                );
              },
            ),
          ),
          if (_index >= 0 && _index < _files.length)
            Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _label(_files[_index]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        tooltip: _isPlaying ? 'Pause' : 'Play',
                        onPressed: _togglePlayPause,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        tooltip: 'Skip',
                        onPressed: _files.length > 1 ? _skip : null,
                      ),
                    ],
                  ),
                  _seekBar(),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _files.isEmpty
                ? Center(
                    child: Text(
                      'No recordings yet — record a song first.',
                      style:
                          TextStyle(color: muted, fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (context, i) {
                      final current = i == _index;
                      return ListTile(
                        leading: Icon(
                          current ? Icons.graphic_eq : Icons.music_note,
                          color: current ? scheme.primary : null,
                        ),
                        title: Text(_label(_files[i])),
                        subtitle: Text(
                          _fileName(_files[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                        selected: current,
                        onTap: () => _playAt(i),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'More',
                          icon: const Icon(Icons.more_vert),
                          onSelected: (v) {
                            if (v == 'delete') _deleteFile(i);
                            if (v == 'share') _shareFile(i);
                          },
                          itemBuilder: (ctx) => [
                            // Sharing files isn't supported by share_plus on
                            // desktop Linux; the folder button covers that there.
                            if (!isDesktop)
                              const PopupMenuItem(
                                value: 'share',
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.share_outlined),
                                  title: Text('Share / move…'),
                                ),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.delete_outline),
                                title: Text('Delete'),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
