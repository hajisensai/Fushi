import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';

const String _hash = '0123456789abcdef0123456789abcdef';
const AnidbUdpConfig _config = AnidbUdpConfig(
  username: 'test_user',
  password: 'a&b+=日本語',
  clientName: 'testclient',
  clientVersion: 1,
);
// fid|aid|eid|other eps|deprecated|state|romaji|kanji|english|epno|ep|ep romaji|ep kanji
const String _file =
    '100|200|300|||0|TV Series|Romaji|日本語|English|S01|Special|Tokubetsu|特別';

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
          'FILE size=123&ed2k=$_hash&fmask=6700000000&amask=10e0f000&s=Ab12',
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

  // BUG-2586：客户端与协调器同寿命，AniDB 虚拟连接 35 分钟无数据即失效——下一批
  // 第一条 FILE 落在死会话上会回 506，之前直接报「会话失败」把整个文件判成识别
  // 失败。要求：清会话、重新 AUTH、同一条 FILE 重发一次；第二次仍拒才抛。
  // 505 ILLEGAL INPUT OR ACCESS DENIED 按 Shoko 当会话无效处理（重登重发一次）。
  for (final int expired in [501, 505, 506]) {
    test('$expired on FILE re-authenticates once and resends the same FILE',
        () async {
      int auths = 0;
      int files = 0;
      final _Fake fake = _Fake((packet, tag) {
        if (packet.startsWith('AUTH ')) {
          auths++;
          return '$tag 200 Sess$auths LOGIN ACCEPTED';
        }
        if (packet.startsWith('FILE ')) {
          files++;
          return files == 1
              ? '$tag $expired LOGIN FIRST'
              : _normal(packet, tag);
        }
        return _normal(packet, tag);
      });
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      final AnidbFileIdentity? match =
          await client.lookup(size: 123, ed2k: _hash);
      expect(match?.fileId, 100);
      expect(auths, 2);
      expect(files, 2);
      expect(fake.packets[1], contains('&s=Sess1'));
      expect(fake.packets[3], contains('&s=Sess2'), reason: '重发要带新会话');
      await client.close();
      expect(fake.packets.last, startsWith('LOGOUT s=Sess2'));
    });
  }

  test('a second session rejection on FILE is a session failure, not a loop',
      () async {
    int auths = 0;
    final _Fake fake = _Fake((packet, tag) {
      if (packet.startsWith('AUTH ')) {
        auths++;
        return '$tag 200 Sess$auths LOGIN ACCEPTED';
      }
      if (packet.startsWith('FILE ')) return '$tag 506 INVALID SESSION';
      return _normal(packet, tag);
    });
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
          AnidbUdpFailure.session,
        ),
      ),
    );
    expect(auths, 2);
    expect(fake.packets.where((p) => p.startsWith('FILE ')).length, 2);
    await client.close();
  });

  // BUG-2586（对齐 Shoko）：一个丢包不再让整个进程的 AniDB 请求停 30 分钟——
  // 同一 tag 的报文原样重发一次，第二次仍无应答才算超时。
  test('a lost reply is resent once with the same tag before timing out',
      () async {
    int files = 0;
    final _Fake fake = _Fake((packet, tag) {
      if (packet.startsWith('FILE ')) {
        files++;
        if (files == 1) throw TimeoutException('lost');
      }
      return _normal(packet, tag);
    });
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: _config,
      transportFactory: (_) async => fake,
    );
    expect((await client.lookup(size: 123, ed2k: _hash))?.fileId, 100);
    expect(files, 2);
    expect(fake.packets[1], fake.packets[2], reason: '重发必须是同一报文同一 tag');
    await client.close();
  });

  test('two lost replies surface as timeout without a third send', () async {
    int files = 0;
    final _Fake fake = _Fake((packet, tag) {
      if (packet.startsWith('FILE ')) {
        files++;
        throw TimeoutException('lost');
      }
      return _normal(packet, tag);
    });
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
          AnidbUdpFailure.timeout,
        ),
      ),
    );
    expect(files, 2);
    await client.close();
  });

  for (final MapEntry<int, AnidbUdpFailure> error in {
    500: AnidbUdpFailure.authentication,
    503: AnidbUdpFailure.clientOutdated,
    504: AnidbUdpFailure.clientBanned,
    506: AnidbUdpFailure.session,
    598: AnidbUdpFailure.session,
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

  test(
      'idle session is logged out after [idleLogout] and re-authenticated '
      'on the next request (Shoko 5 min idle logout)', () async {
    int auths = 0;
    final _Fake fake = _Fake((packet, tag) {
      if (packet.startsWith('AUTH ')) auths++;
      return _normal(packet, tag);
    });
    final AnidbUdpFileClient client = AnidbUdpFileClient(
      config: _config,
      transportFactory: (_) async => fake,
      idleLogout: const Duration(milliseconds: 40),
    );
    expect((await client.lookup(size: 1, ed2k: _hash))?.fileId, 100);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.packets.last, startsWith('LOGOUT s=Ab12'));
    expect((await client.lookup(size: 2, ed2k: _hash))?.fileId, 100);
    expect(auths, 2, reason: '空闲登出后下一条请求重新 AUTH');
    await client.close();
    expect(fake.packets.where((p) => p.startsWith('LOGOUT ')).length, 2);
  });

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
          ? '$tag 220 FILE\n100|200|300|||0|Romaji|Japanese|English|invalid|x|y|z'
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

  group('shared rate gate: timeout is not a ban (BUG-2592, Shoko parity)', () {
    int nowMs = 0;
    final List<Duration> slept = <Duration>[];
    setUp(() {
      nowMs = 0;
      slept.clear();
      AnidbUdpFileClient.resetSharedState(
        clockMs: () => nowMs,
        sleep: (Duration d) async {
          slept.add(d);
          nowMs += d.inMilliseconds;
        },
      );
    });
    tearDown(AnidbUdpFileClient.resetSharedState);

    /// [silentFiles] 为 true 时 FILE 全部丢包（AUTH 正常应答）。
    AnidbUdpFileClient gated(_Fake fake) => AnidbUdpFileClient(
          config: _config,
          transportFactory: (_) async => fake,
          sharedRateGate: true,
        );

    /// FILE 丢包（[silent] 为真时）；[allSilent] 时 AUTH 也丢——模拟整条链路
    /// 静默，而不是「AUTH 通、FILE 不通」这种半通状态。
    _Fake silentFiles(List<int> files,
            {bool Function()? silent, bool allSilent = false}) =>
        _Fake((packet, tag) {
          if (packet.startsWith('FILE ')) files.add(nowMs);
          if (allSilent || packet.startsWith('FILE ')) {
            if (silent?.call() ?? true) throw TimeoutException('lost');
          }
          return _normal(packet, tag);
        });

    test(
        'two silent datagrams fail one file, then back off 30 s instead of '
        'banning for 90 min', () async {
      final List<int> files = <int>[];
      bool silent = true;
      final AnidbUdpFileClient client =
          gated(silentFiles(files, silent: () => silent));
      await expectLater(
        client.lookup(size: 1, ed2k: _hash),
        throwsA(isA<AnidbUdpException>()
            .having((e) => e.reason, 'reason', AnidbUdpFailure.timeout)),
      );
      expect(files.length, 2);
      expect(
          AnidbUdpFileClient.sharedBlockRemaining, const Duration(seconds: 30));
      // 退避窗口内：不发包，报 backoff 而不是「限流或维护」。
      await expectLater(
        client.lookup(size: 2, ed2k: _hash),
        throwsA(isA<AnidbUdpException>()
            .having((e) => e.reason, 'reason', AnidbUdpFailure.backoff)),
      );
      expect(files.length, 2);
      // 30 s 后恢复发送；一旦收到应答，退避计数归零。
      nowMs += 30000;
      silent = false;
      expect((await client.lookup(size: 3, ed2k: _hash))?.fileId, 100);
      expect(AnidbUdpFileClient.sharedBlockRemaining, Duration.zero);
      silent = true;
      await expectLater(
        client.lookup(size: 4, ed2k: _hash),
        throwsA(isA<AnidbUdpException>()
            .having((e) => e.reason, 'reason', AnidbUdpFailure.timeout)),
      );
      expect(
          AnidbUdpFileClient.sharedBlockRemaining, const Duration(seconds: 30),
          reason: '中间有过应答，退避从 30 s 重新起算');
      await client.close();
    });

    test('consecutive silent rounds double the backoff up to 10 min', () async {
      final List<int> files = <int>[];
      final AnidbUdpFileClient client =
          gated(silentFiles(files, allSilent: true));
      final List<int> expectedSeconds = <int>[30, 60, 120, 240, 480, 600, 600];
      for (final int seconds in expectedSeconds) {
        await expectLater(
          client.lookup(size: seconds, ed2k: _hash),
          throwsA(isA<AnidbUdpException>()
              .having((e) => e.reason, 'reason', AnidbUdpFailure.timeout)),
        );
        expect(AnidbUdpFileClient.sharedBlockRemaining,
            Duration(seconds: seconds));
        nowMs += seconds * 1000;
      }
      await client.close();
    });

    test(
        'AUTH that times out twice rebuilds the socket and logs in once more '
        'before backing off (Shoko LoginWithFallbacks/ForceReconnection)',
        () async {
      int connects = 0;
      int auths = 0;
      final List<_Fake> transports = <_Fake>[];
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        sharedRateGate: true,
        transportFactory: (_) async {
          connects++;
          final _Fake fake = _Fake((packet, tag) {
            if (packet.startsWith('AUTH ')) {
              auths++;
              // 第一条 socket 上的 AUTH 全部丢包；重建后正常。
              if (connects == 1) throw TimeoutException('lost');
            }
            return _normal(packet, tag);
          });
          transports.add(fake);
          return fake;
        },
      );
      expect((await client.lookup(size: 1, ed2k: _hash))?.fileId, 100);
      expect(connects, 2, reason: '双超时后重建 socket');
      expect(transports.first.closed, isTrue);
      expect(auths, 3, reason: '旧 socket 两次 + 新 socket 一次');
      expect(AnidbUdpFileClient.sharedBlockRemaining, Duration.zero,
          reason: '登录第一轮超时不进退避');
      await client.close();
    });

    test(
        'rate limiter: 2 s per packet, 6 s once active for over 10 s, reset '
        'after 120 s idle (Shoko UDPRateLimiter)', () async {
      final AnidbUdpFileClient client = gated(_Fake(_normal));
      // AUTH + 7 FILE：前 6 次等待 2 s（活跃 0→12 s），之后 6 s。
      for (int i = 1; i <= 7; i++) {
        await client.lookup(size: i, ed2k: _hash);
      }
      expect(slept.map((Duration d) => d.inMilliseconds).toList(),
          <int>[2000, 2000, 2000, 2000, 2000, 2000, 6000]);
      // 空闲 130 s 后回到短间隔：本包不等，下一包等 2 s。
      slept.clear();
      nowMs += 130000;
      await client.lookup(size: 8, ed2k: _hash);
      await client.lookup(size: 9, ed2k: _hash);
      expect(slept.map((Duration d) => d.inMilliseconds).toList(), <int>[2000]);
      await client.close();
    });

    test('555 bans every client for 90 min; 602 backs off 5 min', () async {
      for (final (int code, AnidbUdpFailure reason, Duration block) in [
        (555, AnidbUdpFailure.banned, const Duration(minutes: 90)),
        (602, AnidbUdpFailure.maintenance, const Duration(minutes: 5)),
      ]) {
        AnidbUdpFileClient.resetSharedState(
            clockMs: () => nowMs, sleep: (Duration d) async {});
        final _Fake fake = _Fake((packet, tag) => packet.startsWith('FILE ')
            ? '$tag $code SERVER SAYS'
            : _normal(packet, tag));
        final AnidbUdpFileClient client = gated(fake);
        await expectLater(
          client.lookup(size: 1, ed2k: _hash),
          throwsA(isA<AnidbUdpException>()
              .having((e) => e.reason, 'reason', reason)),
        );
        expect(AnidbUdpFileClient.sharedBlockRemaining, block);
        // 另一个客户端（另一个协调器）在窗口内同样不发包。
        final _Fake other = _Fake(_normal);
        final AnidbUdpFileClient replacement = gated(other);
        await expectLater(
          replacement.lookup(size: 2, ed2k: _hash),
          throwsA(isA<AnidbUdpException>()
              .having((e) => e.reason, 'reason', reason)),
        );
        expect(other.packets, isEmpty);
        nowMs += block.inMilliseconds;
        expect((await replacement.lookup(size: 2, ed2k: _hash))?.fileId, 100);
        await client.close();
        await replacement.close();
      }
    });
  });

  group('verifyLogin (settings test button, BUG-2581)', () {
    test('sends exactly AUTH then LOGOUT on close, never FILE', () async {
      final _Fake fake = _Fake(_normal);
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      await client.verifyLogin();
      expect(client.clientUpdateAvailable, isFalse);
      await client.close();
      expect(fake.packets.map((p) => p.split(' ').first), ['AUTH', 'LOGOUT']);
      expect(fake.packets.first, contains('user=test_user'));
      expect(fake.packets.first, contains('client=testclient'));
      expect(fake.packets.last, contains('s=Ab12'));
      expect(fake.closed, isTrue);
    });

    test('201 reports a newer client version but still logs in', () async {
      final _Fake fake = _Fake(
        (String packet, String tag) =>
            '$tag 201 Cd34 LOGIN ACCEPTED - NEW VERSION AVAILABLE',
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      await client.verifyLogin();
      expect(client.clientUpdateAvailable, isTrue);
      await client.close();
    });

    test('500 surfaces as authentication and no LOGOUT is sent', () async {
      final _Fake fake = _Fake(
        (String packet, String tag) => '$tag 500 LOGIN FAILED',
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      await expectLater(
        client.verifyLogin(),
        throwsA(
          isA<AnidbUdpException>()
              .having((e) => e.reason, 'reason', AnidbUdpFailure.authentication)
              .having((e) => e.code, 'code', 500),
        ),
      );
      await client.close();
      expect(fake.packets.map((p) => p.split(' ').first), ['AUTH']);
    });

    test('incomplete configuration is rejected before any socket', () async {
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: const AnidbUdpConfig(
          username: 'test_user',
          password: '',
          clientName: 'testclient',
          clientVersion: 1,
        ),
        transportFactory: (_) async => throw StateError('must not connect'),
      );
      await expectLater(
        client.verifyLogin(),
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
  });

  group('FILE xref columns (Shoko fmask 0x67: other episodes / deprecated / state)',
      () {
    test('a single-episode file has no other episodes and state flags decode',
        () {
      final AnidbFileIdentity identity = AnidbUdpFileClient.parseFileReply(
          '100|200|300|||5|TV Series|Romaji|日本語|English|01|Ep|Ep r|Ep k');
      expect(identity.episodeId, 300);
      expect(identity.otherEpisodes, isEmpty);
      expect(identity.isDeprecated, isFalse);
      expect(identity.crcMatches, isTrue, reason: 'bit 1 = CRCMatch');
      expect(identity.fileVersion, 2, reason: 'bit 4 = IsV2');
      expect(identity.animeType, 'TV Series');
      expect(identity.isMovieType, isFalse);
    });

    test('eid list with percentages → primary + other episodes', () {
      final AnidbFileIdentity identity = AnidbUdpFileClient.parseFileReply(
          "100|200|300,50'301,50|||0|Movie|R|K|E|01|Ep|Ep r|Ep k");
      expect(identity.episodeId, 300);
      expect(identity.otherEpisodes,
          <AnidbEpisodeShare>[const AnidbEpisodeShare(episodeId: 301, percentage: 50)]);
      expect(identity.isMovieType, isTrue, reason: 'amask byte1 bit4 = anime type');
    });

    test('other episodes column in both Shoko formats, deduplicated', () {
      final AnidbFileIdentity format1 = AnidbUdpFileClient.parseFileReply(
          "100|200|300|301'50'302'50||0|OVA|R|K|E|01|Ep|Ep r|Ep k");
      expect(format1.otherEpisodes, <AnidbEpisodeShare>[
        const AnidbEpisodeShare(episodeId: 301, percentage: 50),
        const AnidbEpisodeShare(episodeId: 302, percentage: 50),
      ]);
      final AnidbFileIdentity format2 = AnidbUdpFileClient.parseFileReply(
          "100|200|300'301|301,50'303,100||0|OVA|R|K|E|01|Ep|Ep r|Ep k");
      expect(format2.otherEpisodes, <AnidbEpisodeShare>[
        const AnidbEpisodeShare(episodeId: 301, percentage: 50),
        const AnidbEpisodeShare(episodeId: 303, percentage: 100),
      ], reason: 'eid 列表里的 301 均分 50%，other eps 里同一 eid 不重复');
    });

    test('deprecated flag and CRC error surface, unknown state → null CRC', () {
      final AnidbFileIdentity deprecated = AnidbUdpFileClient.parseFileReply(
          '100|200|300||1|2|Web|R|K|E|01|Ep|Ep r|Ep k');
      expect(deprecated.isDeprecated, isTrue);
      expect(deprecated.crcMatches, isFalse);
      final AnidbFileIdentity unknown = AnidbUdpFileClient.parseFileReply(
          '100|200|300||0|0||R|K|E|01|Ep|Ep r|Ep k');
      expect(unknown.crcMatches, isNull);
      expect(unknown.fileVersion, 1);
    });

    test('an unparseable other-episodes column does not void the identity',
        () {
      final AnidbFileIdentity identity = AnidbUdpFileClient.parseFileReply(
          '100|200|300|garbage||0|Other|R|K|E|01|Ep|Ep r|Ep k');
      expect(identity.episodeId, 300);
      expect(identity.otherEpisodes, isEmpty);
    });
  });

  group('EPISODE (Shoko `RequestGetEpisode`: air date for episode linking)', () {
    // wiki: eid|aid|length|rating|votes|epno|eng|romaji|kanji|aired|type
    const String episode =
        '313835|19079|24|850|12|04|The Calamity|Kajin|禍進|1777075200|1';

    test('240 parses eid/aid/epno and aired as a UTC day', () async {
      final _Fake fake = _Fake(
        (packet, tag) => packet.startsWith('EPISODE ')
            ? '$tag 240 EPISODE\n$episode'
            : _normal(packet, tag),
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      final AnidbEpisodeInfo? info = await client.episode(episodeId: 313835);
      expect(info, isNotNull);
      expect(info!.episodeId, 313835);
      expect(info.animeId, 19079);
      expect(info.episodeNumber, '04');
      expect(info.airedAt, DateTime.utc(2026, 4, 25));
      // 三语集名也留下（一文件多集里「其余集」的标题只有 EPISODE 能给）。
      expect(info.englishTitle, 'The Calamity');
      expect(info.romajiTitle, 'Kajin');
      expect(info.kanjiTitle, '禍進');
      final String request =
          fake.packets.firstWhere((p) => p.startsWith('EPISODE '));
      expect(request, contains('eid=313835'));
      expect(request, contains('s=Ab12'));
      // 同一 eid 第二次不再上网。
      await client.episode(episodeId: 313835);
      expect(fake.packets.where((p) => p.startsWith('EPISODE ')).length, 1);
      await client.close();
    });

    test('340 NO SUCH EPISODE is null, not an error', () async {
      final _Fake fake = _Fake(
        (packet, tag) => packet.startsWith('EPISODE ')
            ? '$tag 340 NO SUCH EPISODE'
            : _normal(packet, tag),
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      expect(await client.episode(episodeId: 1), isNull);
      await client.close();
    });

    test('aired = 0 (unknown) yields a null air date', () async {
      final _Fake fake = _Fake(
        (packet, tag) => packet.startsWith('EPISODE ')
            ? '$tag 240 EPISODE\n313835|19079|24|0|0|04||||0|1'
            : _normal(packet, tag),
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      final AnidbEpisodeInfo? info = await client.episode(episodeId: 313835);
      expect(info?.airedAt, isNull);
      expect(info?.episodeNumber, '04');
      await client.close();
    });

    test('rejects truncated or non-numeric fields', () async {
      final _Fake fake = _Fake(
        (packet, tag) => packet.startsWith('EPISODE ')
            ? '$tag 240 EPISODE\n313835|19079|24|850|12|04|x|y'
            : _normal(packet, tag),
      );
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      await expectLater(
        client.episode(episodeId: 313835),
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

    test('an expired session re-authenticates once and resends EPISODE',
        () async {
      int episodeCalls = 0;
      final _Fake fake = _Fake((packet, tag) {
        if (packet.startsWith('EPISODE ')) {
          episodeCalls++;
          return episodeCalls == 1
              ? '$tag 506 INVALID SESSION'
              : '$tag 240 EPISODE\n$episode';
        }
        return _normal(packet, tag);
      });
      final AnidbUdpFileClient client = AnidbUdpFileClient(
        config: _config,
        transportFactory: (_) async => fake,
      );
      final AnidbEpisodeInfo? info = await client.episode(episodeId: 313835);
      expect(info?.airedAt, DateTime.utc(2026, 4, 25));
      expect(fake.packets.where((p) => p.startsWith('AUTH ')).length, 2);
      expect(episodeCalls, 2);
      await client.close();
    });
  });
}
