import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/web_mine_queue_run.dart';
import 'package:fushi_core/fushi_core.dart';

/// 网页视频制卡队列一轮重放的编排规则（`web_mine_queue_run.dart`）：按视频归组、
/// 一行抛出不断整轮、让位的行留在待办、到不了的视频只等一次、整轮必收尾。
WebMineQueueRow _row(int id, String video) => WebMineQueueRow(
  id: id,
  bookUid: 'video/stream/book',
  videoKey: video,
  href: 'https://example.test/$video',
  cueStartMs: id * 1000,
  cueEndMs: id * 1000 + 800,
  sentence: 's$id',
  fieldsJson: '{}',
  status: WebMineQueueStatus.pending,
  createdAt: id,
);

/// 假页面：记下导航 / 重放 / 标失败的顺序，各步的结果可按行定制。
class _FakePage {
  _FakePage({this.current});

  String? current;
  bool stop = false;
  final List<String> log = <String>[];
  final List<Object> errors = <Object>[];
  final Map<int, String> failedRows = <int, String>{};
  final WebMineQueueTally tally = WebMineQueueTally();
  int progressCalls = 0;

  /// 到不了的视频（导航超时）。
  final Set<String> unreachable = <String>{};

  /// 导航到这个视频的途中被叫停。
  String? interruptAt;

  /// 重放时抛出的行 / 返回失败的行。
  final Set<int> throwingRows = <int>{};
  final Set<int> failingRows = <int>{};

  /// 重放这一行的途中页面被叫停（之后的调用抛出，模拟卸载后的 `ref.read`）。
  int? stopDuringRow;

  bool markFailedThrows = false;

  Future<void> run(List<WebMineQueueRow> rows) => runWebMineQueueRows(
    rows: rows,
    tally: tally,
    currentVideoKey: () => current,
    shouldStop: () => stop,
    navigate: (WebMineQueueRow row) async {
      log.add('nav:${row.videoKey}');
      if (interruptAt == row.videoKey) {
        stop = true;
        return WebMineNavigateOutcome.interrupted;
      }
      if (unreachable.contains(row.videoKey)) {
        return WebMineNavigateOutcome.timedOut;
      }
      current = row.videoKey;
      return WebMineNavigateOutcome.ready;
    },
    mineRow: (WebMineQueueRow row) async {
      log.add('mine:${row.id}');
      if (stopDuringRow == row.id) {
        stop = true;
        throw StateError('unmounted');
      }
      if (throwingRows.contains(row.id)) throw StateError('boom ${row.id}');
      return !failingRows.contains(row.id);
    },
    markFailed: (WebMineQueueRow row, String error) async {
      if (markFailedThrows) throw StateError('db closed');
      failedRows[row.id] = error;
    },
    onError: (Object error, StackTrace stack) => errors.add(error),
    onProgress: () => progressCalls++,
  );
}

void main() {
  group('groupWebMineRowsByVideo', () {
    test('同一视频的行排在一起，组内保持入队顺序，组按首行入队顺序', () {
      final List<WebMineQueueRow> rows = <WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'A'),
        _row(4, 'C'),
        _row(5, 'B'),
      ];
      expect(
        groupWebMineRowsByVideo(rows).map((WebMineQueueRow r) => r.id).toList(),
        <int>[1, 3, 2, 5, 4],
      );
    });

    test('页面当前所在的视频那一组排最前（不用导航）', () {
      final List<WebMineQueueRow> rows = <WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'A'),
      ];
      expect(
        groupWebMineRowsByVideo(
          rows,
          currentVideoKey: 'B',
        ).map((WebMineQueueRow r) => r.id).toList(),
        <int>[2, 1, 3],
      );
      // 当前视频不在队列里 / 还不知道当前视频：按首行入队顺序。
      expect(
        groupWebMineRowsByVideo(
          rows,
          currentVideoKey: 'Z',
        ).map((WebMineQueueRow r) => r.id).toList(),
        <int>[1, 3, 2],
      );
      expect(groupWebMineRowsByVideo(const <WebMineQueueRow>[]), isEmpty);
    });
  });

  group('runWebMineQueueRows', () {
    test('A、B、A 归组后只导航两次；当前就在 B 时只导航一次', () async {
      final List<WebMineQueueRow> rows = <WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'A'),
      ];
      final _FakePage page = _FakePage();
      await page.run(groupWebMineRowsByVideo(rows, currentVideoKey: null));
      expect(page.log, <String>[
        'nav:A',
        'mine:1',
        'mine:3',
        'nav:B',
        'mine:2',
      ]);
      expect(page.tally.ok, 3);
      expect(page.tally.failed, 0);
      expect(page.progressCalls, 3);

      final _FakePage onB = _FakePage(current: 'B');
      await onB.run(groupWebMineRowsByVideo(rows, currentVideoKey: 'B'));
      expect(onB.log, <String>['mine:2', 'nav:A', 'mine:1', 'mine:3']);
    });

    test('BUG-4792：一行重放抛出只标这一行失败，后面的行照跑', () async {
      final _FakePage page = _FakePage(current: 'A')..throwingRows.add(2);
      await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
        _row(3, 'A'),
      ]);
      expect(page.log, <String>['mine:1', 'mine:2', 'mine:3']);
      expect(page.tally.ok, 2);
      expect(page.tally.failed, 1);
      expect(page.failedRows.keys, <int>[2]);
      expect(page.failedRows[2], contains('boom 2'));
      expect(page.errors, hasLength(1));
    });

    test('BUG-4792：导航本身抛出同样只算这一行失败', () async {
      final _FakePage page = _FakePage(current: 'A');
      final WebMineQueueTally tally = WebMineQueueTally();
      final List<int> mined = <int>[];
      final Map<int, String> failed = <int, String>{};
      await runWebMineQueueRows(
        rows: <WebMineQueueRow>[_row(1, 'B'), _row(2, 'A')],
        tally: tally,
        currentVideoKey: () => 'A',
        shouldStop: () => false,
        navigate: (WebMineQueueRow row) async => throw StateError('loadUrl'),
        mineRow: (WebMineQueueRow row) async {
          mined.add(row.id);
          return true;
        },
        markFailed: (WebMineQueueRow row, String error) async =>
            failed[row.id] = error,
        onError: (Object error, StackTrace stack) => page.errors.add(error),
      );
      expect(mined, <int>[2]);
      expect(failed.keys, <int>[1]);
      expect(tally.ok, 1);
      expect(tally.failed, 1);
    });

    test('标失败自己抛出（库写不进去）也不中断整轮', () async {
      final _FakePage page = _FakePage(current: 'A')
        ..throwingRows.add(1)
        ..markFailedThrows = true;
      await page.run(<WebMineQueueRow>[_row(1, 'A'), _row(2, 'A')]);
      expect(page.log, <String>['mine:1', 'mine:2']);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 1);
      expect(page.errors, hasLength(2));
    });

    test('重放返回失败（原因已由它写进行里）不再重复标失败', () async {
      final _FakePage page = _FakePage(current: 'A')..failingRows.add(1);
      await page.run(<WebMineQueueRow>[_row(1, 'A'), _row(2, 'A')]);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 1);
      expect(page.failedRows, isEmpty);
      expect(page.errors, isEmpty);
    });

    test('BUG-4793：导航途中让位，这一行与之后的行都留在待办，不标 navigate_timeout', () async {
      final _FakePage page = _FakePage(current: 'A')..interruptAt = 'B';
      await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'B'),
      ]);
      expect(page.log, <String>['mine:1', 'nav:B']);
      expect(page.failedRows, isEmpty);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 0);
      expect(page.progressCalls, 1);
    });

    test('导航超时：只标这一行，同一视频的其余行本轮跳过留待办，别的视频照跑', () async {
      final _FakePage page = _FakePage(current: 'A')..unreachable.add('B');
      await page.run(<WebMineQueueRow>[
        _row(1, 'B'),
        _row(2, 'B'),
        _row(3, 'B'),
        _row(4, 'A'),
      ]);
      // 到不了的视频只等一次，不是每行各等一个期限。
      expect(page.log, <String>['nav:B', 'mine:4']);
      expect(page.failedRows, <int, String>{1: 'navigate_timeout'});
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 1);
    });

    test('已经叫停：一行都不碰', () async {
      final _FakePage page = _FakePage(current: 'A')..stop = true;
      await page.run(<WebMineQueueRow>[_row(1, 'A')]);
      expect(page.log, isEmpty);
      expect(page.tally.done, 0);
    });

    test('重放途中页面被叫停后抛出：这一行不标失败、留在待办，整轮停下', () async {
      final _FakePage page = _FakePage(current: 'A')..stopDuringRow = 1;
      await page.run(<WebMineQueueRow>[_row(1, 'A'), _row(2, 'A')]);
      expect(page.log, <String>['mine:1']);
      expect(page.failedRows, isEmpty);
      expect(page.tally.done, 0);
      expect(page.errors, hasLength(1));
    });
  });

  group('runWebMineQueueRound（BUG-4792：整轮必收尾）', () {
    test('正常跑完：收尾步骤按序执行，返回 true', () async {
      final List<String> log = <String>[];
      final bool completed = await runWebMineQueueRound(
        body: () async => log.add('body'),
        cleanup: <Future<void> Function()>[
          () async => log.add('c1'),
          () async => log.add('c2'),
        ],
        onError: (Object error, StackTrace stack) => log.add('error'),
      );
      expect(completed, isTrue);
      expect(log, <String>['body', 'c1', 'c2']);
    });

    test('准备步骤抛出：不向外抛，收尾步骤照常执行，返回 false', () async {
      final List<String> log = <String>[];
      final bool completed = await runWebMineQueueRound(
        body: () async => throw StateError('getTemporaryDirectory'),
        cleanup: <Future<void> Function()>[
          () async => log.add('c1'),
          () async => log.add('c2'),
        ],
        onError: (Object error, StackTrace stack) => log.add('error:$error'),
      );
      expect(completed, isFalse);
      expect(log, hasLength(3));
      expect(log.first, contains('getTemporaryDirectory'));
      expect(log.sublist(1), <String>['c1', 'c2']);
    });

    test('某一步收尾抛出（停采集失败）：后面的收尾照常执行', () async {
      final List<String> log = <String>[];
      final bool completed = await runWebMineQueueRound(
        body: () async {},
        cleanup: <Future<void> Function()>[
          () async => throw StateError('loopback.stop'),
          () async => log.add('reset running'),
        ],
        onError: (Object error, StackTrace stack) => log.add('error'),
      );
      expect(completed, isTrue);
      expect(log, <String>['error', 'reset running']);
    });

    test('同步抛出的步骤同样被接住', () async {
      final List<String> log = <String>[];
      final bool completed = await runWebMineQueueRound(
        body: () => throw StateError('setState after dispose'),
        cleanup: <Future<void> Function()>[
          () => throw StateError('sync cleanup'),
          () async => log.add('last'),
        ],
        onError: (Object error, StackTrace stack) => log.add('error'),
      );
      expect(completed, isFalse);
      expect(log, <String>['error', 'error', 'last']);
    });
  });
}
