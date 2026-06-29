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
