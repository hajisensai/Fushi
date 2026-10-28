import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_progress_sync.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const int _min = 60 * 1000;

KavitaSyncDecision _decide({
  int? serverPage,
  int? serverAt,
  int? localPage,
  int? localAt,
  int? lastSync,
  int? syncedPage,
}) => resolveKavitaProgress(
  serverPage: serverPage,
  serverModifiedAt: serverAt,
  localPage: localPage,
  localUpdatedAt: localAt,
  lastSyncAt: lastSync,
  lastSyncedPage: syncedPage,
);

void main() {
  group('resolveKavitaProgress', () {
    test('nothing on either side', () {
      expect(_decide().action, KavitaSyncAction.none);
    });

    test('server only: adopt unless it is just page 0', () {
      expect(
        _decide(serverPage: 9, serverAt: 1000).action,
        KavitaSyncAction.adoptServer,
      );
      expect(
        _decide(serverPage: 0, serverAt: 1000).action,
        KavitaSyncAction.none,
      );
    });

    test('local only: push unless it is just page 0', () {
      expect(
        _decide(localPage: 4, localAt: 1000).action,
        KavitaSyncAction.pushLocal,
      );
      expect(
        _decide(localPage: 0, localAt: 1000).action,
        KavitaSyncAction.none,
      );
    });

    test('same page is always a no-op', () {
      expect(
        _decide(
          serverPage: 5,
          serverAt: 10 * _min,
          localPage: 5,
          localAt: 99 * _min,
          lastSync: 1 * _min,
        ).action,
        KavitaSyncAction.none,
      );
    });

    test('synced before: only server moved -> adopt server', () {
      expect(
        _decide(
          serverPage: 12,
          serverAt: 100 * _min,
          localPage: 5,
          localAt: 10 * _min,
          lastSync: 10 * _min,
        ).action,
        KavitaSyncAction.adoptServer,
      );
    });

    test('synced before: only local moved -> push local', () {
      expect(
        _decide(
          serverPage: 5,
          serverAt: 10 * _min,
          localPage: 8,
          localAt: 100 * _min,
          lastSync: 10 * _min,
        ).action,
        KavitaSyncAction.pushLocal,
      );
    });

    test('synced before: both moved -> conflict, prefers newer side', () {
      final KavitaSyncDecision serverNewer = _decide(
        serverPage: 12,
        serverAt: 200 * _min,
        localPage: 8,
        localAt: 100 * _min,
        lastSync: 10 * _min,
      );
      expect(serverNewer.action, KavitaSyncAction.conflict);
      expect(serverNewer.preferred, KavitaSyncAction.adoptServer);
      final KavitaSyncDecision localNewer = _decide(
        serverPage: 12,
        serverAt: 100 * _min,
        localPage: 8,
        localAt: 200 * _min,
        lastSync: 10 * _min,
      );
      expect(localNewer.action, KavitaSyncAction.conflict);
      expect(localNewer.preferred, KavitaSyncAction.pushLocal);
    });

    test(
      'local still on the last agreed page is not movement, however late its '
      'updatedAt (in-section scroll / mark-read)',
      () {
        // 本机推完第 5 章后在章内又读了很久（updatedAt 远晚于基线），另一台设备
        // 推进到第 8 章：本地没离开一致的那章，应采用服务器而不是弹冲突。
        expect(
          _decide(
            serverPage: 8,
            serverAt: 200 * _min,
            localPage: 5,
            localAt: 150 * _min,
            lastSync: 10 * _min,
            syncedPage: 5,
          ).action,
          KavitaSyncAction.adoptServer,
        );
        // 真离开了一致的页：仍是冲突。
        expect(
          _decide(
            serverPage: 8,
            serverAt: 200 * _min,
            localPage: 6,
            localAt: 150 * _min,
            lastSync: 10 * _min,
            syncedPage: 5,
          ).action,
          KavitaSyncAction.conflict,
        );
      },
    );

    test('clock skew within tolerance is not evidence of movement', () {
      expect(
        _decide(
          serverPage: 7,
          serverAt: 10 * _min + 60 * 1000, // 1 min after last sync
          localPage: 5,
          localAt: 10 * _min,
          lastSync: 10 * _min,
        ).action,
        KavitaSyncAction.none,
      );
    });

    test('never synced: clear winner by timestamp', () {
      expect(
        _decide(
          serverPage: 9,
          serverAt: 100 * _min,
          localPage: 3,
          localAt: 10 * _min,
        ).action,
        KavitaSyncAction.adoptServer,
      );
      expect(
        _decide(
          serverPage: 9,
          serverAt: 10 * _min,
          localPage: 3,
          localAt: 100 * _min,
        ).action,
        KavitaSyncAction.pushLocal,
      );
    });

    test('never synced: timestamps within tolerance -> conflict', () {
      expect(
        _decide(
          serverPage: 9,
          serverAt: 10 * _min,
          localPage: 3,
          localAt: 10 * _min + 30 * 1000,
        ).action,
        KavitaSyncAction.conflict,
      );
    });

    test(
      'server edit right after our last sync still pulls (page baseline)',
      () {
        // 上次一致在第 3 页（本机 10 分钟时推的）；Kavita 网页 30 秒后改到第 8 页。
        // 时间基线 + 2 分钟容差会判成没动；页号基线必须判 adoptServer。
        expect(
          _decide(
            serverPage: 8,
            serverAt: 10 * _min + 30 * 1000,
            localPage: 3,
            localAt: 10 * _min,
            lastSync: 10 * _min,
            syncedPage: 3,
          ).action,
          KavitaSyncAction.adoptServer,
        );
      },
    );

    test('page baseline: both left the agreed page -> conflict', () {
      expect(
        _decide(
          serverPage: 8,
          serverAt: 20 * _min,
          localPage: 5,
          localAt: 15 * _min,
          lastSync: 10 * _min,
          syncedPage: 3,
        ).action,
        KavitaSyncAction.conflict,
      );
    });

    test('page baseline: only local left the agreed page -> push', () {
      expect(
        _decide(
          serverPage: 3,
          serverAt: 10 * _min,
          localPage: 5,
          localAt: 11 * _min,
          lastSync: 10 * _min,
          syncedPage: 3,
        ).action,
        KavitaSyncAction.pushLocal,
      );
    });

    test('finished chapter is the last zero-based page', () {
      expect(isKavitaChapterFinished(page: 11, totalPages: 12), isTrue);
      expect(isKavitaChapterFinished(page: 10, totalPages: 12), isFalse);
      expect(isKavitaChapterFinished(page: 0, totalPages: 0), isFalse);
    });
  });

  group('KavitaProgressSync', () {
    const KavitaProgressTarget target = KavitaProgressTarget(
      seriesId: 477,
      volumeId: 4146,
      chapterId: 43011,
      libraryId: 5,
      totalPages: 12,
    );

    /// 记录所有请求；[failFirst] 个写请求返回 503；[serverGet] 控制 get-progress。
    ({KavitaApi api, List<http.Request> log}) harness({
      int failFirst = 0,
      Map<String, Object?>? serverGet,
    }) {
      final List<http.Request> log = <http.Request>[];
      int failed = 0;
      final KavitaApi api = KavitaApi(
        serverUrl: 'http://kavita.test',
        apiKey: 'K',
        client: MockClient((http.Request r) async {
          if (r.url.path == '/api/Plugin/authenticate') {
            return http.Response('{"token":"jwt"}', 200);
          }
          log.add(r);
          if (r.url.path == '/api/Reader/get-progress') {
            return http.Response(
              jsonEncode(serverGet ?? <String, Object?>{'pageNum': 0}),
              200,
            );
          }
          if (r.method == 'POST' && failed < failFirst) {
            failed++;
            return http.Response('', 503);
          }
          return http.Response('', 200);
        }),
      );
      return (api: api, log: log);
    }

    List<int> pushedPages(List<http.Request> log) => <int>[
      for (final http.Request r in log)
        if (r.url.path == '/api/Reader/progress')
          (jsonDecode(r.body) as Map<String, Object?>)['pageNum']! as int,
    ];

    test('debounces to the last page only', () {
      fakeAsync((FakeAsync async) {
        final h = harness();
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          serverVerified: true,
        );
        sync.reportPage(1);
        async.elapse(const Duration(seconds: 3));
        sync.reportPage(2);
        async.elapse(const Duration(seconds: 3));
        sync.reportPage(3);
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(pushedPages(h.log), isEmpty, reason: 'still inside debounce');
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(pushedPages(h.log), <int>[3]);
        expect(sync.hasPending, isFalse);
        sync.dispose();
      });
    });

    test('skips pages equal to the last pushed one', () {
      fakeAsync((FakeAsync async) {
        final h = harness();
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          serverVerified: true,
          lastPushedPage: 4,
        );
        sync.reportPage(4);
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(pushedPages(h.log), isEmpty);
        sync.dispose();
      });
    });

    test('retries with backoff after a failure and then succeeds', () {
      fakeAsync((FakeAsync async) {
        final h = harness(failFirst: 2);
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          serverVerified: true,
        );
        sync.reportPage(5);
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(pushedPages(h.log).length, 1);
        expect(sync.hasPending, isTrue);
        expect(sync.failureCount, 1);
        async.elapse(const Duration(seconds: 16)); // 15 s backoff
        async.flushMicrotasks();
        expect(pushedPages(h.log).length, 2);
        expect(sync.failureCount, 2);
        async.elapse(const Duration(seconds: 31)); // 30 s backoff
        async.flushMicrotasks();
        expect(pushedPages(h.log).length, 3);
        expect(sync.hasPending, isFalse);
        expect(sync.failureCount, 0);
        sync.dispose();
      });
    });

    test('finishing the last page also marks the chapter read', () {
      fakeAsync((FakeAsync async) {
        final h = harness();
        int? pushedAt;
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          serverVerified: true,
          nowMs: () => 777,
          onPushed: (int page, String? scroll, int at) => pushedAt = at,
        );
        sync.reportPage(11);
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(pushedPages(h.log), <int>[11]);
        final Iterable<http.Request> reads = h.log.where(
          (http.Request r) => r.url.path == '/api/Reader/mark-multiple-read',
        );
        expect(reads.length, 1);
        expect(
          (jsonDecode(reads.single.body) as Map<String, Object?>)['chapterIds'],
          <int>[43011],
        );
        expect(pushedAt, 777);
        sync.dispose();
      });
    });

    test('flush pushes immediately (reader close)', () {
      fakeAsync((FakeAsync async) {
        final h = harness();
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          serverVerified: true,
        );
        sync.reportPage(6, bookScrollId: 'p/a');
        bool? ok;
        sync.flush().then((bool v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isTrue);
        final http.Request req = h.log.single;
        expect(
          (jsonDecode(req.body) as Map<String, Object?>)['bookScrollId'],
          'p/a',
        );
        sync.dispose();
      });
    });

    test('refuses to overwrite a newer server position until verified', () {
      fakeAsync((FakeAsync async) {
        final h = harness(
          serverGet: <String, Object?>{
            'pageNum': 9,
            'lastModifiedUtc': DateTime.utc(2026, 10, 26, 12).toIso8601String(),
          },
        );
        KavitaProgress? seen;
        final KavitaProgressSync sync = KavitaProgressSync(
          api: h.api,
          target: target,
          lastSyncAt: DateTime.utc(2026, 10, 26, 8).millisecondsSinceEpoch,
          onServerNewer: (KavitaProgress s) => seen = s,
        );
        sync.reportPage(3);
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(seen?.pageNum, 9);
        expect(pushedPages(h.log), isEmpty);
        expect(sync.hasPending, isFalse);

        // 没裁决就继续翻页：仍要先核对、仍被拒，不能在下一页悄悄覆盖服务器。
        seen = null;
        sync.reportPage(4);
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(seen?.pageNum, 9);
        expect(pushedPages(h.log), isEmpty);

        // 用户选择保留本地 -> 标记已裁决 -> 再翻页即推。
        sync.markServerVerified();
        sync.reportPage(3);
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(pushedPages(h.log), <int>[3]);
        sync.dispose();
      });
    });

    test(
      'a quiet server (page 0, no history) does not block the first push',
      () {
        fakeAsync((FakeAsync async) {
          final h = harness(serverGet: <String, Object?>{'pageNum': 0});
          final KavitaProgressSync sync = KavitaProgressSync(
            api: h.api,
            target: target,
          );
          sync.reportPage(2);
          async.elapse(const Duration(seconds: 11));
          async.flushMicrotasks();
          expect(pushedPages(h.log), <int>[2]);
          sync.dispose();
        });
      },
    );
  });
}
