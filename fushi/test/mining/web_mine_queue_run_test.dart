import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/web_mine_queue_run.dart';
import 'package:fushi_core/fushi_core.dart';

/// 网页视频制卡队列一轮重放的编排规则（`web_mine_queue_run.dart`）：按视频归组、
/// 一行抛出只损失这一行并结束本轮、让位的行留在待办、到不了的视频只等一次（跨轮也是）、
/// 整轮必收尾。
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

  /// 重放用的 WebView 表面换代（渲染 / 浏览器进程死亡）：导航到这个视频的途中死、重放这一行
  /// 的途中死（死后页面的调用抛出）、重放这一行时死但调用照常返回。
  bool surfaceGone = false;
  String? surfaceDiesDuringNavTo;
  int? surfaceDiesDuringRow;
  int? surfaceDiesAfterRow;

  /// 报给调用方的「到不了的视频」。
  final List<String> reportedUnreachable = <String>[];

  Future<WebMineQueueRowsEnd> run(List<WebMineQueueRow> rows) =>
      runWebMineQueueRows(
        rows: rows,
        tally: tally,
        currentVideoKey: () => current,
        shouldStop: () => stop,
        navigate: (WebMineQueueRow row) async {
          log.add('nav:${row.videoKey}');
          if (surfaceDiesDuringNavTo == row.videoKey) {
            // 死页面永远等不到画面：页面侧照常等满期限报超时。
            surfaceGone = true;
            return WebMineNavigateOutcome.timedOut;
          }
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
          if (surfaceDiesDuringRow == row.id) {
            surfaceGone = true;
            throw StateError('web_video_surface_lost');
          }
          if (surfaceDiesAfterRow == row.id) surfaceGone = true;
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
        surfaceLost: () => surfaceGone,
        onUnreachable: reportedUnreachable.add,
        onProgress: () => progressCalls++,
      );
}

/// 假的系统空闲时钟：[now] 往前走，[lastInput] 是最后一次用户输入的时刻。
class _FakeIdle {
  Duration now = const Duration(minutes: 10);
  Duration lastInput = Duration.zero;
  bool unsupported = false;

  void advance(Duration d) => now += d;
  void userInput() => lastInput = now;

  WebMineIdleGiveUps giveUps() => WebMineIdleGiveUps(
    inputIdle: () => unsupported ? null : now - lastInput,
    clock: () => now,
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

    test('BUG-4829：一行重放抛出只标这一行失败并结束本轮，其余行留在待办', () async {
      final _FakePage page = _FakePage(current: 'A')..throwingRows.add(2);
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
        _row(3, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.rowThrew);
      expect(page.log, <String>['mine:1', 'mine:2']);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 1);
      expect(page.failedRows.keys, <int>[2]);
      expect(page.failedRows[2], contains('boom 2'));
      expect(page.errors, hasLength(1));
      expect(page.progressCalls, 2);
    });

    test('环境级故障（每一行都会抛）一轮只损失一行，不把整条队列标成失败', () async {
      final _FakePage page = _FakePage(current: 'A')
        ..throwingRows.addAll(<int>[1, 2, 3, 4]);
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
        _row(3, 'B'),
        _row(4, 'B'),
      ]);
      expect(end, WebMineQueueRowsEnd.rowThrew);
      expect(page.log, <String>['mine:1']);
      expect(page.failedRows.keys, <int>[1]);
      expect(page.tally.failed, 1);
    });

    test('BUG-4829：导航本身抛出同样只算这一行失败并结束本轮', () async {
      final _FakePage page = _FakePage(current: 'A');
      final WebMineQueueTally tally = WebMineQueueTally();
      final List<int> mined = <int>[];
      final Map<int, String> failed = <int, String>{};
      final WebMineQueueRowsEnd end = await runWebMineQueueRows(
        rows: <WebMineQueueRow>[_row(1, 'B'), _row(2, 'B'), _row(3, 'A')],
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
      expect(end, WebMineQueueRowsEnd.rowThrew);
      expect(mined, isEmpty);
      expect(failed.keys, <int>[1]);
      expect(tally.ok, 0);
      expect(tally.failed, 1);
    });

    test('标失败自己抛出（库写不进去）不向外抛，本轮照样结束', () async {
      final _FakePage page = _FakePage(current: 'A')
        ..throwingRows.add(1)
        ..markFailedThrows = true;
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.rowThrew);
      expect(page.log, <String>['mine:1']);
      expect(page.tally.ok, 0);
      expect(page.tally.failed, 1);
      expect(page.errors, hasLength(2));
    });

    test('重放返回失败（原因已由它写进行里）不再重复标失败', () async {
      final _FakePage page = _FakePage(current: 'A')..failingRows.add(1);
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.drained);
      expect(page.log, <String>['mine:1', 'mine:2']);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 1);
      expect(page.failedRows, isEmpty);
      expect(page.errors, isEmpty);
    });

    test('BUG-4832：导航途中让位，这一行与之后的行都留在待办，不标 navigate_timeout', () async {
      final _FakePage page = _FakePage(current: 'A')..interruptAt = 'B';
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'B'),
      ]);
      expect(end, WebMineQueueRowsEnd.stopped);
      expect(page.reportedUnreachable, isEmpty);
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
      // 到不了的视频报给调用方（跨轮由 WebMineIdleGiveUps 记住）。
      expect(page.reportedUnreachable, <String>['B']);
    });

    test('已经叫停：一行都不碰', () async {
      final _FakePage page = _FakePage(current: 'A')..stop = true;
      expect(
        await page.run(<WebMineQueueRow>[_row(1, 'A')]),
        WebMineQueueRowsEnd.stopped,
      );
      expect(page.log, isEmpty);
      expect(page.tally.done, 0);
    });

    test('重放途中页面被叫停后抛出：这一行不标失败、留在待办，整轮停下', () async {
      final _FakePage page = _FakePage(current: 'A')..stopDuringRow = 1;
      expect(
        await page.run(<WebMineQueueRow>[_row(1, 'A'), _row(2, 'A')]),
        WebMineQueueRowsEnd.stopped,
      );
      expect(page.log, <String>['mine:1']);
      expect(page.failedRows, isEmpty);
      expect(page.tally.done, 0);
      expect(page.errors, hasLength(1));
    });
  });

  group('runWebMineQueueRows：重放表面进程死亡（BUG-4983）', () {
    test('重放途中渲染进程死了：在途这一行不标失败、留在待办，其余行不碰，结束本轮', () async {
      final _FakePage page = _FakePage(current: 'A')..surfaceDiesDuringRow = 2;
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
        _row(3, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.surfaceLost);
      expect(page.log, <String>['mine:1', 'mine:2']);
      expect(page.failedRows, isEmpty);
      expect(page.tally.ok, 1);
      expect(page.tally.failed, 0);
    });

    test('导航途中进程死了：不标 navigate_timeout、不把视频记成到不了', () async {
      final _FakePage page = _FakePage(current: 'A')
        ..surfaceDiesDuringNavTo = 'B';
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'B'),
        _row(2, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.surfaceLost);
      expect(page.failedRows, isEmpty);
      expect(page.reportedUnreachable, isEmpty);
      expect(page.log, <String>['nav:B']);
      expect(page.tally.done, 0);
    });

    test('一行落定之后表面换了：这一行照常计数，下一行不再碰', () async {
      final _FakePage page = _FakePage(current: 'A')..surfaceDiesAfterRow = 1;
      final WebMineQueueRowsEnd end = await page.run(<WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'A'),
      ]);
      expect(end, WebMineQueueRowsEnd.surfaceLost);
      expect(page.log, <String>['mine:1']);
      expect(page.tally.ok, 1);
    });

    test('开跑时表面已经报废（重建预算用尽）：一行都不碰', () async {
      final _FakePage page = _FakePage(current: 'A')..surfaceGone = true;
      expect(
        await page.run(<WebMineQueueRow>[_row(1, 'A')]),
        WebMineQueueRowsEnd.surfaceLost,
      );
      expect(page.log, isEmpty);
      expect(page.failedRows, isEmpty);
    });
  });

  group('WebMineIdleGiveUps（本次空闲已放弃的视频 / 书）', () {
    test('记下之后没有输入就一直有效，来过一次输入就作废', () {
      final _FakeIdle idle = _FakeIdle();
      final WebMineIdleGiveUps giveUps = idle.giveUps();
      giveUps.giveUpVideo('book', 'B');
      giveUps.giveUpBook('other');
      idle.advance(const Duration(hours: 3));
      expect(giveUps.unreachableVideos('book'), <String>{'B'});
      expect(giveUps.isBookGivenUp('other'), isTrue);
      expect(giveUps.isBookGivenUp('book'), isFalse);
      expect(giveUps.unreachableVideos('other'), isEmpty);

      idle.userInput();
      idle.advance(const Duration(minutes: 5));
      expect(giveUps.unreachableVideos('book'), isEmpty);
      expect(giveUps.isBookGivenUp('other'), isFalse);
    });

    test('输入只作废它之前记下的；之后记下的仍有效', () {
      final _FakeIdle idle = _FakeIdle();
      final WebMineIdleGiveUps giveUps = idle.giveUps();
      giveUps.giveUpVideo('book', 'B');
      idle.advance(const Duration(seconds: 10));
      idle.userInput();
      idle.advance(const Duration(minutes: 3));
      giveUps.giveUpVideo('book', 'C');
      idle.advance(const Duration(minutes: 1));
      expect(giveUps.unreachableVideos('book'), <String>{'C'});
    });

    test('判不了系统空闲（非 Windows）：一律作废', () {
      final _FakeIdle idle = _FakeIdle()..unsupported = true;
      final WebMineIdleGiveUps giveUps = idle.giveUps();
      giveUps.giveUpVideo('book', 'B');
      giveUps.giveUpBook('book');
      expect(giveUps.unreachableVideos('book'), isEmpty);
      expect(giveUps.isBookGivenUp('book'), isFalse);
    });

    test('startable 去掉到不了的视频的行；全在到不了的视频上时整本放弃', () {
      final _FakeIdle idle = _FakeIdle();
      final WebMineIdleGiveUps giveUps = idle.giveUps();
      final List<WebMineQueueRow> rows = <WebMineQueueRow>[
        _row(1, 'A'),
        _row(2, 'B'),
        _row(3, 'B'),
      ];
      expect(giveUps.startable('video/stream/book', rows), same(rows));
      giveUps.giveUpVideo('video/stream/book', 'B');
      expect(
        giveUps
            .startable('video/stream/book', rows)
            .map((WebMineQueueRow r) => r.id),
        <int>[1],
      );
      giveUps.settleAfterRound('video/stream/book', rows);
      expect(giveUps.isBookGivenUp('video/stream/book'), isFalse);
      giveUps.settleAfterRound('video/stream/book', rows.sublist(1));
      expect(giveUps.isBookGivenUp('video/stream/book'), isTrue);
      // 队列空了不算放弃。
      giveUps.settleAfterRound('empty', const <WebMineQueueRow>[]);
      expect(giveUps.isBookGivenUp('empty'), isFalse);
    });

    test('BUG-4832：空闲自动制卡跨轮——到不了的视频整次空闲只等一次、只标一行失败；用户回来后重新给机会', () async {
      const String book = 'video/stream/book';
      final _FakeIdle idle = _FakeIdle();
      final WebMineIdleGiveUps giveUps = idle.giveUps();
      final List<WebMineQueueRow> pending = <WebMineQueueRow>[
        _row(1, 'B'),
        _row(2, 'B'),
        _row(3, 'B'),
        _row(4, 'A'),
      ];
      final List<String> navigations = <String>[];
      final Map<int, String> failed = <int, String>{};

      // 与页面同一套流程：调度器每 5 秒问一次能不能开跑，能就跑一轮。
      Future<int> idleRounds() async {
        int rounds = 0;
        for (int tick = 0; tick < 20; tick++) {
          idle.advance(const Duration(seconds: 5));
          if (pending.isEmpty || giveUps.isBookGivenUp(book)) continue;
          final List<WebMineQueueRow> rows = giveUps.startable(book, pending);
          if (rows.isEmpty) {
            giveUps.settleAfterRound(book, pending);
            continue;
          }
          rounds++;
          final WebMineQueueTally tally = WebMineQueueTally();
          await runWebMineQueueRows(
            rows: groupWebMineRowsByVideo(rows, currentVideoKey: 'A'),
            tally: tally,
            currentVideoKey: () => 'A',
            shouldStop: () => false,
            navigate: (WebMineQueueRow row) async {
              navigations.add(row.videoKey);
              idle.advance(const Duration(seconds: 30));
              return WebMineNavigateOutcome.timedOut;
            },
            mineRow: (WebMineQueueRow row) async {
              pending.remove(row);
              return true;
            },
            markFailed: (WebMineQueueRow row, String error) async {
              failed[row.id] = error;
              pending.remove(row);
            },
            onError: (Object error, StackTrace stack) => fail('$error'),
            onUnreachable: (String videoKey) =>
                giveUps.giveUpVideo(book, videoKey),
          );
          giveUps.settleAfterRound(book, List<WebMineQueueRow>.of(pending));
        }
        return rounds;
      }

      expect(await idleRounds(), 1);
      expect(navigations, <String>['B']);
      expect(failed, <int, String>{1: 'navigate_timeout'});
      expect(pending.map((WebMineQueueRow r) => r.id), <int>[2, 3]);
      expect(giveUps.isBookGivenUp(book), isTrue);

      // 用户回来过一次再离开：再给这个视频一次机会（仍然一次空闲只等一次）。
      idle.userInput();
      expect(giveUps.isBookGivenUp(book), isFalse);
      expect(await idleRounds(), 1);
      expect(navigations, <String>['B', 'B']);
      expect(pending.map((WebMineQueueRow r) => r.id), <int>[3]);
    });
  });

  group('runWebMineQueueRound（BUG-4829：整轮必收尾）', () {
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

  test('webMineRoundEndedOnError：准备步骤抛出 / 一行抛出 / 表面死亡算出错，跑完与让位不算', () {
    // null = runWebMineQueueRows 没跑完（准备步骤抛出），计数是 0 / 0。
    expect(webMineRoundEndedOnError(null), isTrue);
    expect(webMineRoundEndedOnError(WebMineQueueRowsEnd.rowThrew), isTrue);
    expect(webMineRoundEndedOnError(WebMineQueueRowsEnd.surfaceLost), isTrue);
    expect(webMineRoundEndedOnError(WebMineQueueRowsEnd.drained), isFalse);
    expect(webMineRoundEndedOnError(WebMineQueueRowsEnd.stopped), isFalse);
  });
}
