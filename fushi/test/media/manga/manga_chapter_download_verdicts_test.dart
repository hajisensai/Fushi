import 'dart:async';

import 'package:fushi/src/media/manga/library/manga_chapter_download_verdicts.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// manga-4：作品页在任务表每个信号上都对全书每章重判磁盘。这里钉住「只重判状态
/// 变了的章」与「刷新串行合并」。
MangaDownloadJobRow _job(
  String chapterKey, {
  required String status,
  String? jobId,
  int pagesDone = 0,
}) => MangaDownloadJobRow(
  jobId: jobId ?? 'job-$chapterKey',
  kind: MangaDownloadJobKind.chapter,
  bookKey: 'book',
  chapterKey: chapterKey,
  runtime: 'mihon',
  title: 'T',
  chapterTitle: chapterKey,
  status: status,
  pagesDone: pagesDone,
  pagesTotal: 20,
  attemptCount: 0,
  autoOcr: false,
  createdAt: 0,
  updatedAt: pagesDone,
);

void main() {
  final List<String> chapters = <String>[for (int i = 0; i < 100; i++) 'c$i'];

  late Set<String> onDisk;
  late List<String> checked;
  late MangaChapterDownloadVerdicts verdicts;

  setUp(() {
    onDisk = <String>{for (int i = 0; i < 100; i += 2) 'c$i'};
    checked = <String>[];
    verdicts = MangaChapterDownloadVerdicts(
      check: (String bookDir, String key) async {
        checked.add(key);
        return onDisk.contains(key);
      },
    );
  });

  test('首次全量判；之后纯进度信号一章都不重判', () async {
    final Set<String> first = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: <String, MangaDownloadJobRow>{
        'c1': _job('c1', status: MangaDownloadJobStatus.running),
      },
    );
    expect(checked, hasLength(100));
    expect(first, onDisk);

    // 下载中那章每下完一页写一次进度：状态不变 → 不碰磁盘。
    for (int page = 1; page <= 20; page++) {
      checked.clear();
      final Set<String> again = await verdicts.resolve(
        bookDir: '/b',
        chapterKeys: chapters,
        jobs: <String, MangaDownloadJobRow>{
          'c1': _job(
            'c1',
            status: MangaDownloadJobStatus.running,
            pagesDone: page,
          ),
        },
      );
      expect(checked, isEmpty, reason: 'page $page');
      expect(again, onDisk);
    }
  });

  test('任务状态变了只重判那一章；完成后结论跟着变', () async {
    await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: <String, MangaDownloadJobRow>{
        'c1': _job('c1', status: MangaDownloadJobStatus.running),
      },
    );
    checked.clear();
    onDisk.add('c1');
    final Set<String> done = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: <String, MangaDownloadJobRow>{
        'c1': _job('c1', status: MangaDownloadJobStatus.done),
      },
    );
    expect(checked, <String>['c1']);
    expect(done, contains('c1'));

    // 任务行被删（下载中心删任务连文件）→ 也重判那一章。
    checked.clear();
    onDisk.remove('c1');
    final Set<String> removed = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(checked, <String>['c1']);
    expect(removed, isNot(contains('c1')));

    // 同章换了一条新任务（取消后重排）：jobId 变了也算变。
    await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: <String, MangaDownloadJobRow>{
        'c3': _job('c3', status: MangaDownloadJobStatus.queued, jobId: 'a'),
      },
    );
    checked.clear();
    await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: <String, MangaDownloadJobRow>{
        'c3': _job('c3', status: MangaDownloadJobStatus.queued, jobId: 'b'),
      },
    );
    expect(checked, <String>['c3']);
  });

  test('显式作废、新出现的章、书目录变了、invalidateAll 才重判', () async {
    await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );

    checked.clear();
    onDisk.remove('c0');
    verdicts.invalidate(<String>['c0']);
    final Set<String> afterDelete = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(checked, <String>['c0']);
    expect(afterDelete, isNot(contains('c0')));

    checked.clear();
    await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: <String>['new', ...chapters],
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(checked, <String>['new']);

    checked.clear();
    await verdicts.resolve(
      bookDir: '/moved',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(checked, hasLength(100));

    checked.clear();
    verdicts.invalidateAll();
    await verdicts.resolve(
      bookDir: '/moved',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(checked, hasLength(100));
  });

  test('下架的章从结论里消失', () async {
    final Set<String> first = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: chapters,
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(first, contains('c2'));
    final Set<String> second = await verdicts.resolve(
      bookDir: '/b',
      chapterKeys: <String>[
        for (final String c in chapters)
          if (c != 'c2') c,
      ],
      jobs: const <String, MangaDownloadJobRow>{},
    );
    expect(second, isNot(contains('c2')));
  });

  test('判据中途抛错：没判完的章下一轮必重判，不因任务行没再变而挂着旧结论', () async {
    String? throwFor;
    final List<String> seen = <String>[];
    final MangaChapterDownloadVerdicts flaky = MangaChapterDownloadVerdicts(
      check: (String bookDir, String key) async {
        seen.add(key);
        if (key == throwFor) throw StateError('stat failed');
        return onDisk.contains(key);
      },
    );
    const List<String> keys = <String>['c1', 'c2', 'c3'];
    Map<String, MangaDownloadJobRow> jobsWith(String status) =>
        <String, MangaDownloadJobRow>{
          for (final String key in <String>['c1', 'c3'])
            key: _job(key, status: status),
        };

    expect(
      await flaky.resolve(
        bookDir: '/b',
        chapterKeys: keys,
        jobs: jobsWith(MangaDownloadJobStatus.running),
      ),
      <String>{'c2'},
    );

    // c1 / c3 下完了；判 c1 时读盘抛错，c3 这一轮没轮到。
    onDisk.addAll(<String>['c1', 'c3']);
    seen.clear();
    throwFor = 'c1';
    await expectLater(
      flaky.resolve(
        bookDir: '/b',
        chapterKeys: keys,
        jobs: jobsWith(MangaDownloadJobStatus.done),
      ),
      throwsA(isA<StateError>()),
    );
    expect(seen, <String>['c1']);

    // 下一轮任务行与上一轮相同（纯进度信号）：c1 / c3 也必须重判。
    seen.clear();
    throwFor = null;
    final Set<String> next = await flaky.resolve(
      bookDir: '/b',
      chapterKeys: keys,
      jobs: jobsWith(MangaDownloadJobStatus.done),
    );
    expect(seen, <String>['c1', 'c3']);
    expect(next, <String>{'c1', 'c2', 'c3'});
  });

  group('CoalescedRefresh', () {
    test('在跑时再请求只补一轮；等待方都等到最后一轮', () async {
      int runs = 0;
      final List<Completer<void>> gates = <Completer<void>>[];
      final CoalescedRefresh refresh = CoalescedRefresh(() {
        runs++;
        final Completer<void> gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      });
      final Future<void> a = refresh.request();
      final Future<void> b = refresh.request();
      final Future<void> c = refresh.request();
      expect(runs, 1, reason: '同时只跑一轮');
      bool bDone = false;
      unawaited(b.then((_) => bDone = true));
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(runs, 2, reason: '跑的过程中来的两次请求合成一轮');
      expect(bDone, isFalse, reason: '补的那一轮没跑完，等待方不能先放行');
      gates[1].complete();
      await Future.wait(<Future<void>>[a, b, c]);
      expect(runs, 2);
      expect(refresh.isRunning, isFalse);

      // 空闲后再请求是新的一轮。
      final Future<void> d = refresh.request();
      expect(runs, 3);
      gates[2].complete();
      await d;
    });

    test('一轮抛错时期间来的请求照样补跑，等待方收到那个错误', () async {
      int runs = 0;
      final Completer<void> gate = Completer<void>();
      final CoalescedRefresh refresh = CoalescedRefresh(() async {
        runs++;
        if (runs == 1) {
          await gate.future;
          throw StateError('boom');
        }
      });
      final Future<void> a = refresh.request();
      final Future<void> b = refresh.request();
      gate.complete();
      await expectLater(a, throwsA(isA<StateError>()));
      await expectLater(b, throwsA(isA<StateError>()));
      expect(runs, 2, reason: '第一轮期间来的请求不能随它的错误一起丢掉');
      expect(refresh.isRunning, isFalse);
    });

    test('一轮抛错：等待方收到错误，之后还能再跑', () async {
      int runs = 0;
      final CoalescedRefresh refresh = CoalescedRefresh(() async {
        runs++;
        if (runs == 1) throw StateError('boom');
      });
      await expectLater(refresh.request(), throwsA(isA<StateError>()));
      await refresh.request();
      expect(runs, 2);
    });
  });
}
