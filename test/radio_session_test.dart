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

  group('sameStationTapAction', () {
    test('a different (or no) station always retunes', () {
      expect(
        sameStationTapAction(
            currentUrl: null,
            tappedUrl: 'a',
            paused: false,
            streamError: false),
        TapAction.retune,
      );
      expect(
        sameStationTapAction(
            currentUrl: 'b', tappedUrl: 'a', paused: false, streamError: false),
        TapAction.retune,
      );
    });

    test('the current station, loading or playing, is ignored', () {
      expect(
        sameStationTapAction(
            currentUrl: 'a', tappedUrl: 'a', paused: false, streamError: false),
        TapAction.ignore,
      );
    });

    test('the current station, paused, resumes', () {
      expect(
        sameStationTapAction(
            currentUrl: 'a', tappedUrl: 'a', paused: true, streamError: false),
        TapAction.resume,
      );
    });

    test('the current station, after a stream error, retunes', () {
      expect(
        sameStationTapAction(
            currentUrl: 'a', tappedUrl: 'a', paused: false, streamError: true),
        TapAction.retune,
      );
    });
  });

  group('TrackChangeDedup', () {
    test('first title of a session is "first", repeats are ignored', () {
      final d = TrackChangeDedup();
      expect(d.next('A - B'), TrackChangeKind.first);
      expect(d.next('A - B'), TrackChangeKind.repeat);
      expect(d.next('A - B'), TrackChangeKind.repeat);
    });

    test('a different title is a change', () {
      final d = TrackChangeDedup();
      d.next('A - B');
      expect(d.next('C - D'), TrackChangeKind.changed);
      expect(d.next('C - D'), TrackChangeKind.repeat);
    });

    test('reset makes the next title "first" again (new session)', () {
      final d = TrackChangeDedup();
      d.next('A - B');
      d.reset();
      expect(d.next('A - B'), TrackChangeKind.first);
    });
  });

  group('HistoryDedup', () {
    test('logs each distinct title once', () {
      final d = HistoryDedup();
      expect(d.shouldLog('A - B', enabled: true), isTrue);
      expect(d.shouldLog('A - B', enabled: true), isFalse);
      expect(d.shouldLog('C - D', enabled: true), isTrue);
    });

    test('never logs an empty title', () {
      expect(HistoryDedup().shouldLog('', enabled: true), isFalse);
    });

    test('re-enabling logging mid-song still logs the current track', () {
      final d = HistoryDedup();
      expect(d.shouldLog('A - B', enabled: false), isFalse);
      expect(d.shouldLog('A - B', enabled: true), isTrue);
    });

    test('reset lets the same title log again (new session)', () {
      final d = HistoryDedup();
      d.shouldLog('A - B', enabled: true);
      d.reset();
      expect(d.shouldLog('A - B', enabled: true), isTrue);
    });
  });

  group('historyCsvRow', () {
    test('timestamp,station,artist,title,album,raw — quoted where needed', () {
      final row = historyCsvRow(
        now: DateTime(2026, 9, 19, 14, 5, 6),
        station: 'Soma, FM',
        rawTitle: 'Daft Punk - Aerodynamic',
      );
      expect(row,
          '2026-09-19T14:05:06.000,"Soma, FM",Daft Punk,Aerodynamic,,Daft Punk - Aerodynamic');
    });
  });

  group('finalizeMessage', () {
    test('null when nothing was armed', () {
      expect(finalizeMessage((path: null, error: null)), isNull);
    });

    test('names the saved file', () {
      expect(
          finalizeMessage(
              (path: '/x/y/Daft Punk - Aerodynamic.mp3', error: null)),
          'Saved recording: Daft Punk - Aerodynamic.mp3');
    });

    test('surfaces the error', () {
      expect(finalizeMessage((path: null, error: 'disk full')),
          'Recording failed: disk full');
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
