import 'package:ez_tunein/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records which transport calls reached this driver.
class _FakeDriver implements AudioModeDriver {
  final calls = <String>[];
  @override
  Future<void> driverPlay() async => calls.add('play');
  @override
  Future<void> driverPause() async => calls.add('pause');
  @override
  Future<void> driverStop() async => calls.add('stop');
  @override
  Future<void> driverSeek(Duration position) async =>
      calls.add('seek:${position.inSeconds}');
  @override
  Future<void> driverSkipNext() async => calls.add('skip');
}

void main() {
  // WifiLock is Android-only (no-op here) and BaseAudioHandler is plain Dart
  // streams, so the handler constructs without a native session in tests.
  group('EzAudioHandler driver handoff', () {
    test('transport calls route to the attached driver', () async {
      final h = EzAudioHandler();
      final radio = _FakeDriver();
      h.attach(PlaybackMode.radio, radio);
      expect(h.mode, PlaybackMode.radio);
      await h.play();
      await h.pause();
      await h.seek(const Duration(seconds: 3));
      await h.skipToNext();
      await h.stop();
      expect(radio.calls, ['play', 'pause', 'seek:3', 'skip', 'stop']);
    });

    test('transport with no driver is a harmless no-op', () async {
      final h = EzAudioHandler();
      await h.play();
      await h.stop();
      expect(h.mode, PlaybackMode.idle);
    });

    test('a late detach from the previous driver does not wipe the new one',
        () async {
      final h = EzAudioHandler();
      final radio = _FakeDriver();
      final recs = _FakeDriver();
      h.attach(PlaybackMode.radio, radio);
      h.attach(PlaybackMode.recordings, recs); // handoff
      h.detach(radio); // the radio page's stop lands after the handoff
      expect(h.mode, PlaybackMode.recordings);
      await h.play();
      expect(recs.calls, ['play']);
      expect(radio.calls, isEmpty);
    });

    test('detach by the active driver clears the session', () async {
      final h = EzAudioHandler();
      final recs = _FakeDriver();
      h.attach(PlaybackMode.recordings, recs);
      h.detach(recs);
      expect(h.mode, PlaybackMode.idle);
      expect(h.mediaItem.value, isNull);
      expect(h.playbackState.value.playing, isFalse);
      await h.play();
      expect(recs.calls, isEmpty);
    });

    test('swipe-away (onTaskRemoved) stops the active driver', () async {
      final h = EzAudioHandler();
      final radio = _FakeDriver();
      h.attach(PlaybackMode.radio, radio);
      await h.onTaskRemoved();
      expect(radio.calls, ['stop']);
    });
  });
}
