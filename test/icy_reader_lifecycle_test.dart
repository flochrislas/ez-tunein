import 'dart:convert';
import 'dart:io';

import 'package:ez_tunein/icy_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Integration tests for `IcyReader`'s connection/status lifecycle, driven by a
/// real loopback `HttpServer` that speaks just enough ICY to exercise the
/// connect → active → reconnect → fail path (and the unsupported path). The pure
/// byte-parsing is covered separately in icy_reader_test.dart.

/// One ICY metadata block: a length byte (block size / 16) + null-padded bytes.
List<int> metaBlock(String payload) {
  final bytes = utf8.encode(payload);
  final blocks = (bytes.length / 16).ceil();
  final padded = List<int>.filled(blocks * 16, 0);
  for (var i = 0; i < bytes.length; i++) {
    padded[i] = bytes[i];
  }
  return [blocks, ...padded];
}

String urlFor(HttpServer s) => 'http://${s.address.host}:${s.port}/';

/// Poll until [cond] holds, yielding to the event loop so timers/sockets run.
Future<void> pumpUntil(bool Function() cond, {String? reason}) async {
  for (var i = 0; i < 300; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within timeout${reason == null ? '' : ': $reason'}');
}

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  test('no icy-metaint ⇒ reports unsupported', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      // Deliberately no icy-metaint header.
      req.response.headers.set('content-type', 'audio/mpeg');
      req.response.add([1, 2, 3, 4]);
      await req.response.close();
    });

    final statuses = <MetadataStatus>[];
    final reader = IcyReader();
    await reader.start(urlFor(server), onTitle: (_) {}, onStatus: statuses.add);

    await pumpUntil(() => statuses.contains(MetadataStatus.unsupported),
        reason: 'unsupported');
    expect(statuses, contains(MetadataStatus.unsupported));

    await reader.stop();
    expect(statuses.last, MetadataStatus.idle);
  });

  test('no metadata + bufferWithoutMetadata forwards the raw audio', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.set('content-type', 'audio/mpeg');
      req.response.add([1, 2, 3, 4, 5]);
      await req.response.close(); // bytes are delivered before the stream ends
    });

    final audio = <int>[];
    final statuses = <MetadataStatus>[];
    // Long backoff so the post-close reconnect doesn't churn during the test.
    final reader = IcyReader()
      ..reconnectDelay = (_) => const Duration(seconds: 60);
    await reader.start(urlFor(server),
        onTitle: (_) {},
        onAudio: audio.addAll,
        onStatus: statuses.add,
        bufferWithoutMetadata: true);

    await pumpUntil(() => audio.length >= 5, reason: 'raw audio');
    expect(audio, [1, 2, 3, 4, 5]);
    expect(statuses, contains(MetadataStatus.unsupported)); // still no titles

    await reader.stop();
  });

  test('no metadata without the flag downloads nothing', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.set('content-type', 'audio/mpeg');
      req.response.add([1, 2, 3, 4, 5]);
      await req.response.close();
    });

    final audio = <int>[];
    final statuses = <MetadataStatus>[];
    final reader = IcyReader();
    await reader.start(urlFor(server),
        onTitle: (_) {}, onAudio: audio.addAll, onStatus: statuses.add);

    await pumpUntil(() => statuses.contains(MetadataStatus.unsupported),
        reason: 'unsupported');
    // The connection is dropped after headers; no audio is ever forwarded.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(audio, isEmpty);

    await reader.stop();
  });

  test('first title ⇒ active; a dropped feed reports connecting immediately',
      () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      r.headers.set('icy-metaint', '4');
      r.headers.set('content-type', 'audio/mpeg');
      r.add([1, 2, 3, 4]); // metaInt audio bytes
      r.add(metaBlock("StreamTitle='Live Song';StreamUrl='';"));
      await r.flush();
      await r.close(); // end the response ⇒ the reader sees the feed drop
    });

    final statuses = <MetadataStatus>[];
    final titles = <String>[];
    final reader = IcyReader()
      // Long backoff so the retry never fires mid-test; we only assert that the
      // drop *immediately* downgrades to connecting, then stop() cancels it.
      ..reconnectDelay = (_) => const Duration(seconds: 60);
    await reader.start(urlFor(server),
        onTitle: titles.add, onStatus: statuses.add);

    await pumpUntil(() => statuses.contains(MetadataStatus.active),
        reason: 'active');
    expect(titles, contains('Live Song'));

    // The key assertion (the review-2 fix): once the feed drops, connecting is
    // reported right away — not only when the reconnect timer eventually fires.
    await pumpUntil(() {
      final a = statuses.indexOf(MetadataStatus.active);
      return a >= 0 && statuses.skip(a + 1).contains(MetadataStatus.connecting);
    }, reason: 'connecting after active');

    await reader.stop();
    expect(statuses.last, MetadataStatus.idle);
  });

  test('a duplicated icy-br header still reaches active (Nightride/Rekt)',
      () async {
    // Regression: Nightride/Rekt Icecast mounts send `icy-br` on TWO separate
    // header lines. Dart's client keeps those as a 2-element list, and reading
    // it with HttpHeaders.value() throws ("more than one value"). The connect
    // path swallowed that and turned it into an endless reconnect — the station
    // was stuck on "Connecting…" forever despite perfectly valid ICY metadata.
    // The reader must read the first value instead and proceed normally.
    //
    // A raw ServerSocket is used (not HttpServer) because HttpServer folds
    // duplicate headers into one comma-joined value, which does NOT reproduce
    // the two-separate-lines framing nginx actually emits.
    final socketServer =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Keep the shared tearDown happy (it closes `server`); this test manages its
    // own raw server, so give `server` a throwaway bound HttpServer.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    socketServer.listen((socket) async {
      final body = <int>[
        1, 2, 3, 4, // metaInt audio bytes
        ...metaBlock("StreamTitle='Venturer - Fugitive';StreamUrl='';"),
      ];
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\n'
          'content-type: audio/mpeg\r\n'
          'icy-metaint: 4\r\n'
          'icy-br: 320\r\n' // two separate lines, exactly like nginx
          'icy-br: 320\r\n'
          '\r\n'));
      socket.add(body);
      await socket.flush();
      // Hold the connection open so we don't churn into a reconnect mid-test.
      await Future<void>.delayed(const Duration(seconds: 2));
      await socket.close();
    });

    final statuses = <MetadataStatus>[];
    final titles = <String>[];
    final reader = IcyReader()
      ..reconnectDelay = (_) => const Duration(seconds: 60);
    final url = 'http://${socketServer.address.host}:${socketServer.port}/';
    await reader.start(url, onTitle: titles.add, onStatus: statuses.add);

    await pumpUntil(() => statuses.contains(MetadataStatus.active),
        reason: 'active despite duplicate icy-br');
    expect(titles, contains('Venturer - Fugitive'));
    expect(reader.bitrateKbps, 320); // the duplicated header still parsed

    await reader.stop();
    expect(statuses.last, MetadataStatus.idle);
    await socketServer.close();
  });

  test('keeps reconnecting, then reports failed after the attempt budget',
      () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      // Advertise metadata but immediately end the body ⇒ a drop every attempt.
      req.response.headers.set('icy-metaint', '4');
      await req.response.close();
    });

    final statuses = <MetadataStatus>[];
    final reader = IcyReader()
      ..reconnectDelay = (_) => Duration.zero; // exhaust the budget fast
    await reader.start(urlFor(server), onTitle: (_) {}, onStatus: statuses.add);

    await pumpUntil(() => statuses.contains(MetadataStatus.failed),
        reason: 'failed');
    expect(statuses, contains(MetadataStatus.failed));
    // It tried to recover before giving up.
    expect(statuses.where((s) => s == MetadataStatus.connecting), isNotEmpty);

    await reader.stop();
  });
}
