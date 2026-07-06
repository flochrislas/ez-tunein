import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_prefs.dart';
import '../storage_paths.dart';
import 'color_swatch.dart';

/// The GitHub Releases page — where newer builds are published.
const _releasesUrl = 'https://github.com/flochrislas/ez-tunein/releases';

/// Settings for the song recorder: buffering on/off, buffer size, and where
/// recordings are saved. Persists straight to shared_preferences (the player
/// re-reads them via _applyRecordingPrefs when this page is popped).
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SharedPreferences? _prefs;
  bool _buffering = true;
  int _bufferMb = recBufferMbDefault;
  int _leadSeconds = recLeadSecondsDefault; // -1 ⇒ whole buffer
  String? _dir; // null/empty ⇒ Downloads (desktop) / app folder (mobile)
  Color _accent = const Color(defaultAccentValue);
  String _version = ''; // app version string, e.g. "0.9.3" (from the bundle)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _buffering = prefs.getBool(recBufferingKey) ?? true;
      _bufferMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
          .clamp(5, recBufferMbMax);
      _leadSeconds = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;
      _dir = prefs.getString(recDirKey);
      _accent = accentColor.value;
      _version = info.version;
    });
  }

  /// Open the GitHub Releases page in the browser (best-effort).
  Future<void> _openReleases() async {
    // launchUrl returns false (rather than throwing) on several platforms when
    // it can't launch, so check the bool too — not just catch.
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(_releasesUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the browser.')),
      );
    }
  }

  // Re-theme the whole app live as the user drags, without hammering prefs.
  void _previewAccent(Color c) {
    setState(() => _accent = c);
    accentColor.value = c;
  }

  // Persist the choice (on release / swatch tap).
  Future<void> _commitAccent(Color c) async {
    _previewAccent(c);
    await _prefs?.setInt(accentColorKey, c.toARGB32());
  }

  int _chan(double v) => (v * 255).round(); // Color component (0..1) → 0..255

  Future<void> _setBuffering(bool v) async {
    setState(() => _buffering = v);
    await _prefs?.setBool(recBufferingKey, v);
  }

  Future<void> _setBufferMb(int mb) async {
    setState(() => _bufferMb = mb);
    await _prefs?.setInt(recBufferMbKey, mb);
  }

  Future<void> _setLeadSeconds(int sec) async {
    setState(() => _leadSeconds = sec);
    await _prefs?.setInt(recLeadSecondsKey, sec);
  }

  /// Human label for a lead-in value (seconds; -1 = whole buffer).
  static String _leadLabel(int sec) {
    if (sec < 0) return 'Max (whole buffer)';
    if (sec == 0) return 'None';
    if (sec < 60) return '${sec}s';
    return '${sec ~/ 60} min';
  }

  Future<void> _pickDir() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where to save recordings',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open folder picker: $e')),
        );
      }
      return;
    }
    final picked = path;
    if (picked == null) return; // cancelled
    setState(() => _dir = picked);
    await _prefs?.setString(recDirKey, picked);
  }

  Future<void> _resetDir() async {
    setState(() => _dir = null);
    await _prefs?.remove(recDirKey);
  }

  /// A compact reference so the user can size the buffer sensibly: how much a
  /// minute of MP3 costs at common bitrates, and what the current buffer holds.
  /// (A minute = kbps × 7500 bytes; MB here is MiB, matching the cap maths.)
  Widget _bufferGuide(Color muted) {
    String perMin(int kbps) => (kbps * 7500 / 1048576).toStringAsFixed(1);
    String mins(int kbps) =>
        (_bufferMb * 1048576 / (kbps * 7500)).round().toString();
    final style = TextStyle(color: muted, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1 min of MP3 ≈ ${perMin(128)} MB (128k) · '
            '${perMin(256)} MB (256k) · ${perMin(320)} MB (320k)',
            style: style,
          ),
          const SizedBox(height: 2),
          Text(
            '→ $_bufferMb MB rewinds ≈ ${mins(128)} / ${mins(256)} / ${mins(320)} '
            'min (128 / 256 / 320k)',
            style: style,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final hasDir = _dir != null && _dir!.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // Wait for prefs before building the controls — otherwise the slider paints
      // at the default and then visibly animates to the saved value on open.
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : _buildSettings(muted, hasDir),
    );
  }

  /// One tappable accent swatch (selected one shows a check + ring).
  Widget _swatch(Color c) => AccentSwatch(
        color: c,
        selected: c.toARGB32() == _accent.toARGB32(),
        onTap: () => _commitAccent(c),
      );

  /// One R/G/B channel slider tinted with the live accent. [build] maps a new
  /// channel value (0..255) to the resulting color.
  Widget _channelSlider(String label, int value, Color Function(int) build) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          SizedBox(width: 14, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              max: 255,
              onChanged: (v) => _previewAccent(build(v.round())),
              onChangeEnd: (v) => _commitAccent(build(v.round())),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('$value', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings(Color muted, bool hasDir) {
    final r = _chan(_accent.r), g = _chan(_accent.g), b = _chan(_accent.b);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        const ListTile(
          title: Text('Accent color'),
          subtitle: Text('Tints the sliders, switches, and buttons.'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (final c in colorPresets) _swatch(c)],
          ),
        ),
        // Fine control: any color. Channel builders rebuild from the other two.
        _channelSlider('R', r, (v) => Color.fromARGB(255, v, g, b)),
        _channelSlider('G', g, (v) => Color.fromARGB(255, r, v, b)),
        _channelSlider('B', b, (v) => Color.fromARGB(255, r, g, v)),
        const Divider(),
        SwitchListTile(
          title: const Text('Buffer the stream'),
          subtitle: const Text(
              'Required to record. When off, the Record button is hidden.'),
          value: _buffering,
          onChanged: _setBuffering,
        ),
        const Divider(),
        ListTile(
          title: const Text('Buffer size'),
          subtitle: Text(
            '$_bufferMb MB — how far back into a song you can reach when you '
            'hit Record.',
            style: TextStyle(color: _buffering ? null : muted),
          ),
        ),
        Slider(
          value: _bufferMb.clamp(5, recBufferMbMax).toDouble(),
          min: 5,
          max: recBufferMbMax.toDouble(),
          divisions: recBufferMbMax - 5, // 1 MB steps
          label: '$_bufferMb MB',
          onChanged:
              _buffering ? (v) => setState(() => _bufferMb = v.round()) : null,
          onChangeEnd: _buffering ? (v) => _setBufferMb(v.round()) : null,
        ),
        _bufferGuide(muted),
        const Divider(),
        ListTile(
          title: const Text('Lead-in for stations without track names'),
          subtitle: Text(
            'Some stations broadcast no song titles. There, Record keeps the '
            'last ${_leadLabel(_leadSeconds)} before you tapped (then everything '
            'until you tap save). Stations that do send titles always capture '
            'the whole song from its start, regardless of this.',
            style: TextStyle(color: _buffering ? null : muted),
          ),
        ),
        Slider(
          value: recLeadOptions
              .indexOf(_leadSeconds)
              .clamp(0, recLeadOptions.length - 1)
              .toDouble(),
          min: 0,
          max: (recLeadOptions.length - 1).toDouble(),
          divisions: recLeadOptions.length - 1,
          label: _leadLabel(_leadSeconds),
          onChanged: _buffering
              ? (v) => setState(() => _leadSeconds = recLeadOptions[v.round()])
              : null,
          onChangeEnd: _buffering
              ? (v) => _setLeadSeconds(recLeadOptions[v.round()])
              : null,
        ),
        const Divider(),
        ListTile(
          title: const Text('Save recordings to'),
          subtitle: Text(
            hasDir
                ? _dir!
                : (isDesktop
                    ? 'Downloads folder (default)'
                    : 'App folder — share recordings from the file manager'),
          ),
          trailing: isDesktop
              ? Wrap(
                  spacing: 4,
                  children: [
                    if (hasDir)
                      TextButton(
                        onPressed: _resetDir,
                        child: const Text('Reset'),
                      ),
                    FilledButton.tonal(
                      onPressed: _pickDir,
                      child: const Text('Change…'),
                    ),
                  ],
                )
              : null,
        ),
        if (!isDesktop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'On Android, recordings save to the app folder; picking an '
              'arbitrary folder isn\'t supported yet.',
              style: TextStyle(color: muted, fontStyle: FontStyle.italic),
            ),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Recordings do not re-encode the stream. They are saved directly at '
            'the same bitrate and audio format than what the radio station '
            'broadcasted.',
            style: TextStyle(color: muted),
          ),
        ),
        const Divider(),
        _about(muted),
      ],
    );
  }

  /// Bottom "about" band: the installed version + a pointer to GitHub Releases
  /// (this app self-updates only by sideloading a newer build).
  Widget _about(Color muted) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          Text(
            _version.isEmpty ? 'EZ-TuneIn' : 'EZ-TuneIn  v$_version',
            style: TextStyle(color: muted, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            'A newer release may be available on GitHub.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: _openReleases,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Releases on GitHub'),
          ),
        ],
      ),
    );
  }
}
