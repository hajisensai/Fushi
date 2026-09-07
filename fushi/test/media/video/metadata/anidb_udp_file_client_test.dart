import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/anidb_udp_file_client.dart';

const String _hash = '0123456789abcdef0123456789abcdef';
const AnidbUdpConfig _config = AnidbUdpConfig(
  username: 'test_user',
  password: 'a&b+=日本語',
  clientName: 'testclient',
  clientVersion: 1,
);
const String _file = '100|200|300|Romaji|日本語|English|S01|Special|Tokubetsu|特別';

class _Fake implements AnidbUdpTransport {
  _Fake(this.respond);
  final String Function(String packet, String tag) respond;
  final List<String> packets = [];
  bool closed = false;
  @override
  void cancelPending() {}
  @override
  Future<void> send(String packet) async {
    packets.add(packet);
  }

  @override
  Future<String> exchange(String packet, String tag, Duration timeout) async {
    packets.add(packet);
    return respond(packet, tag);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

String _normal(String packet, String tag) {
  if (packet.startsWith('AUTH ')) return '$tag 200 Ab12 LOGIN ACCEPTED';
  if (packet.startsWith('LOGOUT ')) return '$tag 203 LOGGED OUT';
  return '$tag 220 FILE\n$_file';
}

void main() {
  test('configuration is checked before creating a socket', () async {
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: const AnidbUdpConfig(
        username: '',
        password: '',
        clientName: '',
        clientVersion: 0,
      ),
      transportFactory: (_) async => throw StateError('must not connect'),
    );
    await expectLater(
      client.lookup(size: 123, ed2k: _hash),
      throwsA(
        isA<AnidbUdpException>().having(
          (e) => e.reason,
          'reason',
          AnidbUdpFailure.unavailable,
        ),
      ),
    );
    await client.close();
  });

  test(
    'AUTH uses official HTML entities and FILE mask has exact ordered fields',
    () async {
      final _Fake fake = _Fake(_normal);
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      final AnidbFileIdentity? match = await client.lookup(
        size: 123,
        ed2k: _hash.toUpperCase(),
      );
      expect(fake.packets[0], contains('pass=a&amp;b+=日本語&protover=3'));
      expect(fake.packets[0], contains('enc=UTF-8&comp=0'));
      expect(
        fake.packets[1],
        contains(
          'FILE size=123&ed2k=$_hash&fmask=6000000000&amask=00e0f000&s=Ab12',
        ),
      );
      expect(match?.fileId, 100);
      expect(match?.animeId, 200);
      expect(match?.episodeId, 300);
      expect(match?.episodeNumber, 'S01');
      expect(match?.kanjiTitle, '日本語');
      expect(match?.episodeKanjiTitle, '特別');
      expect(await client.lookup(size: 123, ed2k: _hash), same(match));
      expect(fake.packets.length, 2);
      await client.close();
      expect(fake.packets.last, startsWith('LOGOUT s=Ab12'));
      expect(fake.closed, true);
    },
  );

  test('concurrent lookups share AUTH and cache the same hash', () async {
    final _Fake fake = _Fake(_normal);
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: _config,
      transportFactory: (_) async => fake,
    );
    await Future.wait([
      client.lookup(size: 123, ed2k: _hash),
      client.lookup(size: 123, ed2k: _hash),
    ]);
    expect(fake.packets.length, 2);
    await client.close();
  });

  test('320 is a cached miss, not an anime identity', () async {
    final _Fake fake = _Fake(
      (packet, tag) => packet.startsWith('FILE ')
          ? '$tag 320 NO SUCH FILE'
          : _normal(packet, tag),
    );
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: _config,
      transportFactory: (_) async => fake,
    );
    expect(await client.lookup(size: 123, ed2k: _hash), null);
    expect(await client.lookup(size: 123, ed2k: _hash), null);
    expect(fake.packets.length, 2);
    await client.close();
  });

  test(
    '201 records the client update notification and accepts tagged data',
    () async {
      final _Fake fake = _Fake(
        (packet, tag) => packet.startsWith('AUTH ')
            ? '$tag 201 Ab12 LOGIN ACCEPTED - NEW VERSION AVAILABLE'
            : packet.startsWith('FILE ')
                ? '$tag 220 FILE\n$tag $_file|future-field'
                : _normal(packet, tag),
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      expect((await client.lookup(size: 123, ed2k: _hash))?.fileId, 100);
      expect(client.clientUpdateAvailable, true);
      await client.close();
    },
  );

  for (final MapEntry<int, AnidbUdpFailure> error in {
    500: AnidbUdpFailure.authentication,
    503: AnidbUdpFailure.clientOutdated,
    504: AnidbUdpFailure.clientBanned,
    506: AnidbUdpFailure.session,
    555: AnidbUdpFailure.banned,
    601: AnidbUdpFailure.maintenance,
  }.entries) {
    test(
      '${error.key} is classified without exposing server text or retrying',
      () async {
        final _Fake fake = _Fake(
          (packet, tag) =>
              '${error.key == 601 ? '' : '$tag '}${error.key} secret-echo',
        );
        final AnidbUdpFileClient client = AnidbUdpFileClient(
          config: _config,
          transportFactory: (_) async => fake,
        );
        await expectLater(
          client.lookup(size: 123, ed2k: _hash),
          throwsA(
            isA<AnidbUdpException>()
                .having((e) => e.reason, 'reason', error.value)
                .having(
                  (e) => e.toString(),
                  'redacted',
                  isNot(contains('secret-echo')),
                ),
          ),
        );
        expect(fake.packets.length, 1);
        await client.close();
      },
    );
  }

  for (final String response in [
    'wrong 200 Ab12 LOGIN ACCEPTED',
    'f1 200 a&b LOGIN ACCEPTED',
    'f1 200 LOGIN ACCEPTED',
  ]) {
    test('rejects malformed AUTH $response', () async {
      final _Fake fake = _Fake((_, __) => response);
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      await expectLater(
        client.lookup(size: 123, ed2k: _hash),
        throwsA(
          isA<AnidbUdpException>().having(
            (e) => e.reason,
            'reason',
            AnidbUdpFailure.malformedResponse,
          ),
        ),
      );
      await client.close();
    });
  }

  test('FILE rejects truncated or shifted fields', () async {
    final _Fake fake = _Fake(
      (packet, tag) => packet.startsWith('FILE ')
          ? '$tag 220 FILE\n100|200|300|Romaji|Japanese|English|invalid|x|y|z'
          : _normal(packet, tag),
    );
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: _config,
      transportFactory: (_) async => fake,
    );
    await expectLater(
      client.lookup(size: 123, ed2k: _hash),
      throwsA(
        isA<AnidbUdpException>().having(
          (e) => e.reason,
          'reason',
          AnidbUdpFailure.malformedResponse,
        ),
      ),
    );
    await client.close();
  });

  test(
    'real UDP verifies tags, cancels receive and hands closing port to next client',
    () async {
      final RawDatagramSocket server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final RawDatagramSocket reservation = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int localPort = reservation.port;
      reservation.close();
      final List<String> packets = [];
      final List<int> ports = [];
      final Completer<void> logoutSeen = Completer<void>();
      final Completer<void> unansweredFileSeen = Completer<void>();
      final StreamSubscription<RawSocketEvent> subscription = server.listen((
        event,
      ) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final Datagram? datagram = server.receive();
          if (datagram == null) break;
          final String packet = utf8.decode(datagram.data);
          packets.add(packet);
          ports.add(datagram.port);
          if (packet.startsWith('LOGOUT ')) {
            if (!logoutSeen.isCompleted) logoutSeen.complete();
            continue; // No acknowledgement: close must still finish.
          }
          if (packet.startsWith('FILE size=124&')) {
            unansweredFileSeen.complete();
            continue;
          }
          final String tag = RegExp(r'&tag=(\w+)$').firstMatch(packet)![1]!;
          final List<int> stale = utf8.encode('stale 200 Zzzz LOGIN ACCEPTED');
          expect(
              server.send(
                stale,
                datagram.address,
                datagram.port,
              ),
              stale.length,
              reason: 'fixture must send the stale datagram');
          final List<int> reply = utf8.encode(_normal(packet, tag));
          expect(
              server.send(
                reply,
                datagram.address,
                datagram.port,
              ),
              reply.length,
              reason: 'fixture must send the current $tag response');
        }
      });
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: AnidbUdpConfig(
          username: _config.username,
          password: _config.password,
          clientName: _config.clientName,
          clientVersion: 1,
          host: '127.0.0.1',
          port: server.port,
          localPort: localPort,
        ),
      );
      final AnidbUdpFileClient replacement =
          AnidbUdpFileClient(config: client.config);
      try {
        expect(
          (await client.lookup(size: 123, ed2k: _hash))?.episodeNumber,
          'S01',
        );
        final Future<void> cancelledLookup = expectLater(
          client.lookup(size: 124, ed2k: _hash),
          throwsA(isA<AnidbUdpException>()
              .having((e) => e.reason, 'cancelled', AnidbUdpFailure.closed)),
        );
        await unansweredFileSeen.future;
        final Stopwatch closingTime = Stopwatch()..start();
        final Future<void> closing = client.close();
        // Deliberately start the new coordinator before awaiting old close.
        final Future<AnidbFileIdentity?> nextMatch =
            replacement.lookup(size: 123, ed2k: _hash);
        await closing;
        await cancelledLookup;
        expect(closingTime.elapsed, lessThan(const Duration(seconds: 7)));
        await logoutSeen.future.timeout(const Duration(seconds: 1));
        expect((await nextMatch)?.fileId, 100);
        expect(packets.map((p) => p.split(' ').first), [
          'AUTH',
          'FILE',
          'FILE',
          'LOGOUT',
          'AUTH',
          'FILE',
        ]);
        expect(ports.toSet(), {localPort});
        expect(packets.first, contains('日本語'));
      } finally {
        await client.close();
        await replacement.close();
        server.close();
        await subscription.cancel();
      }
    },
  );
}
