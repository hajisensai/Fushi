// 远端任务观测链路的断连子状态（remote-job-client-lifecycle）：观测失败 ≠ 任务失败，
// 容忍窗从第一次失败起算，超窗才判 `disconnected` 并尽力清理。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/interconnect_remote_job_poll.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const String _host = 'http://host-a.invalid:8080';

void main() {
  group('RemoteJobLinkWatch', () {
    test('窗口从第一次失败起算，超窗返回 false', () {
      DateTime clock = DateTime(2026, 11, 10, 12);
      final RemoteJobLinkWatch watch = RemoteJobLinkWatch(
        tolerance: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(watch.isLost, isFalse);
      // 挂起很久之后才第一次失败：计时从这一刻开始，不从上次成功开始。
      clock = clock.add(const Duration(hours: 1));
      expect(watch.lost(), isTrue);
      expect(watch.lostSince, clock);
      clock = clock.add(const Duration(minutes: 10));
      expect(watch.lost(), isTrue);
      clock = clock.add(const Duration(seconds: 1));
      expect(watch.lost(), isFalse);
      expect(watch.isLost, isTrue);
    });

    test('一次成功即清零', () {
      DateTime clock = DateTime(2026, 11, 10, 12);
      final RemoteJobLinkWatch watch = RemoteJobLinkWatch(
        tolerance: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(watch.lost(), isTrue);
      clock = clock.add(const Duration(minutes: 9));
      watch.observed();
      expect(watch.isLost, isFalse);
      expect(watch.lostSince, isNull);
      clock = clock.add(const Duration(minutes: 9));
      expect(watch.lost(), isTrue);
      clock = clock.add(const Duration(minutes: 9));
      expect(watch.lost(), isTrue, reason: '新一轮断连从这次失败重新计时');
    });
  });

  group('InterconnectJobClient 断连判定', () {
    late Directory root;
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('remote_job_link_loss_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = SyncRepository(db);
      await repo.setFushiClientToken('tok');
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: _host, deviceName: 'Desk PC'),
      ]);
    });

    tearDown(() async {
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('观测一直看不到 host：超窗以 disconnected 收尾，期间只报一次重连中，之后才 DELETE', () async {
      DateTime clock = DateTime(2026, 11, 10, 12);
      final List<String> wire = <String>[];
      int statusFailures = 0;
      int failuresAtDelete = -1;
      final http.Client mock = MockClient((http.Request request) async {
        final String path = request.url.path;
        wire.add('${request.method} $path');
        if (request.method == 'POST' && path == '/api/jobs') {
          return http.Response(
            jsonEncode(<String, Object?>{'jobId': 'j1'}),
            200,
          );
        }
        if (request.method == 'PUT' || path.endsWith('/start')) {
          return http.Response('{}', 200);
        }
        if (request.method == 'GET' && path == '/api/jobs/j1') {
          statusFailures++;
          clock = clock.add(const Duration(minutes: 4));
          throw const SocketException('host unreachable');
        }
        if (request.method == 'DELETE') {
          failuresAtDelete = statusFailures;
          return http.Response('', 204);
        }
        return http.Response('unexpected', 500);
      });
      final File input = File(p.join(root.path, 'a.mp3'))
        ..writeAsStringSync('audio');
      final InterconnectJobClient client = InterconnectJobClient(
        repo: repo,
        httpClient: mock,
        pollDelay: (int _) => Duration.zero,
        linkLossTolerance: const Duration(minutes: 10),
        now: () => clock,
      );

      final List<HostJobEvent> events = <HostJobEvent>[];
      Object? error;
      try {
        await for (final HostJobEvent e in client.run(
          target: const HostJobTarget(
            baseUrl: _host,
            deviceName: 'Desk PC',
            kinds: <String>['asr'],
            capability: <String, Object?>{},
          ),
          kind: 'asr',
          params: const <String, Object?>{},
          inputs: <File>[input],
          outputDir: Directory(p.join(root.path, 'out')),
        )) {
          events.add(e);
        }
      } catch (e) {
        error = e;
      }

      expect(error, isA<HostJobRemoteException>());
      final HostJobRemoteException ex = error! as HostJobRemoteException;
      expect(ex.code, 'disconnected');
      expect(ex.detail, t.interconnect_remote_job_disconnected(minutes: '10'));
      // 第 1 次失败起算：第 2、3 次距起点 4、8 分钟仍在窗内，第 4 次（12 分钟）判断连。
      expect(statusFailures, 4);
      final List<HostJobRunning> reconnecting = events
          .whereType<HostJobRunning>()
          .where((HostJobRunning r) => r.reconnecting)
          .toList();
      expect(reconnecting, hasLength(1));
      for (int i = 0; i < 50 && failuresAtDelete < 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(wire.where((String r) => r.startsWith('DELETE ')), hasLength(1));
      expect(failuresAtDelete, 4, reason: '只在判定断连之后才清理');
    });
  });
}
