import 'package:ez_tunein/icy_reader.dart';
import 'package:ez_tunein/radio_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nowPlayingLine', () {
    String line({
      bool loading = false,
      bool playing = true,
      bool streamError = false,
      bool trackInfoFresh = false,
      String nowPlaying = '',
      MetadataStatus metaStatus = MetadataStatus.active,
    }) =>
        nowPlayingLine(
          loading: loading,
          playing: playing,
          streamError: streamError,
          trackInfoFresh: trackInfoFresh,
          nowPlaying: nowPlaying,
          metaStatus: metaStatus,
        );

    test('loading wins over everything', () {
      expect(line(loading: true, nowPlaying: 'A - B', trackInfoFresh: true),
          'Connecting…');
    });

    test('not playing shows a dash', () {
      expect(line(playing: false, nowPlaying: 'A - B'), '—');
    });

    test('stream error beats a stale (auto-reconnecting) title', () {
      expect(
        line(streamError: true, nowPlaying: 'A - B', trackInfoFresh: true),
        'Stream lost — tap the station to reconnect.',
      );
    });

    test('a fresh title is shown verbatim', () {
      expect(line(nowPlaying: 'Daft Punk - Aerodynamic', trackInfoFresh: true),
          'Daft Punk - Aerodynamic');
    });

    test('a failed feed flags the last title as stale', () {
      expect(
        line(nowPlaying: 'A - B', metaStatus: MetadataStatus.failed),
        'Track info unavailable — last: A - B',
      );
    });

    test('a reconnecting gap keeps the stale title (no flicker)', () {
      expect(line(nowPlaying: 'A - B', metaStatus: MetadataStatus.connecting),
          'A - B');
    });

    test('falls back to the per-status message when there is no title', () {
      expect(line(metaStatus: MetadataStatus.unsupported),
          'This station doesn\'t provide track info.');
      expect(line(metaStatus: MetadataStatus.waitingForFirstTitle),
          'Waiting for track info…');
      expect(line(metaStatus: MetadataStatus.connecting), 'Connecting…');
    });
  });

  group('canRecordNow', () {
    test('needs buffering on', () {
      expect(
        canRecordNow(
            recBuffering: false,
            hasStation: true,
            trackInfoFresh: true,
            metaStatus: MetadataStatus.active),
        isFalse,
      );
    });

    test('needs a station', () {
      expect(
        canRecordNow(
            recBuffering: true,
            hasStation: false,
            trackInfoFresh: true,
            metaStatus: MetadataStatus.active),
        isFalse,
      );
    });

    test('allowed on a fresh live title (auto mode)', () {
      expect(
        canRecordNow(
            recBuffering: true,
            hasStation: true,
            trackInfoFresh: true,
            metaStatus: MetadataStatus.active),
        isTrue,
      );
    });

    test('allowed on a title-less (unsupported) station (manual mode)', () {
      expect(
        canRecordNow(
            recBuffering: true,
            hasStation: true,
            trackInfoFresh: false,
            metaStatus: MetadataStatus.unsupported),
        isTrue,
      );
    });

    test('blocked on a stale title that is not unsupported', () {
      expect(
        canRecordNow(
            recBuffering: true,
            hasStation: true,
            trackInfoFresh: false,
            metaStatus: MetadataStatus.connecting),
        isFalse,
      );
    });
  });

  group('leadInBytes', () {
    test('kbps × 125 × seconds', () {
      expect(leadInBytes(128, 60), 128 * 125 * 60); // 960000
      expect(leadInBytes(320, 30), 320 * 125 * 30);
      expect(leadInBytes(128, 0), 0);
    });
  });

  group('streamFormatLabel', () {
    test('maps known content types', () {
      expect(streamFormatLabel('audio/mpeg'), 'MP3');
      expect(streamFormatLabel('audio/aac'), 'AAC');
      expect(streamFormatLabel('application/ogg'), 'OGG');
    });

    test('null for empty or unknown', () {
      expect(streamFormatLabel(null), isNull);
      expect(streamFormatLabel(''), isNull);
      expect(streamFormatLabel('application/octet-stream'), isNull);
    });
  });
}
