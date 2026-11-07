// BUG-1569③ / 反馈 kM-Gb_Xnu-：全局同步互斥拆成按资源加锁（整轮 / 通道后端 / 单本书）。
// 前半段测锁表本身（并发、互斥、先来先得、嵌套不成环、zone 继承 owner、代数）；
// 后半段测同步入口真的按资源排队：全量 sweep 进行中退出书，互联那份不等整轮，
// 云那份只等云通道；对比弹窗 / 复习同步仍与整轮串行。
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_resource_locks.dart';
import 'package:fushi/src/sync/sync_task_board.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _waitFor(bool Function() cond, {String what = 'condition'}) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 让出若干轮事件循环（锁的授予经 Completer，要过一轮微任务才轮到等待者）。
Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 只记录 restoreAuth 调用的后端：认证恒为否，退出书同步因此在 restoreAuth 之后
/// 立刻收场（notAuthenticated），测的只是「它什么时候被放行」。
class _RecordingBackend implements SyncBackend {
  _RecordingBackend(this.name, this.log);

  final String name;
  final List<String> log;
  int restoreCalls = 0;

  /// 每次同步时读一下「此刻的本地进度」，记进 [seenProgress]（测「上传的是哪份」）。
  String Function()? probe;
  final List<String> seenProgress = <String>[];

  /// 非空时，restoreAuth 记账后挂在它上面（模拟这一遍同步正在跑、还没结束）。
  Completer<void>? hold;

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    restoreCalls++;
    log.add(name);
    final String Function()? read = probe;
    if (read != null) seenProgress.add(read());
    final Completer<void>? gate = hold;
    if (gate != null) await gate.future;
    return false;
  }

  @override
  Future<bool> get isAuthenticated async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

void main() {
  group('SyncResourceLocks', () {
    test('不同资源并发，同一资源串行', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final Completer<void> gateA = Completer<void>();
      final List<String> ran = <String>[];
      final Future<void> a = locks.withResources(<String>{'x'}, () async {
        ran.add('a');
        await gateA.future;
      });
      final Future<void> b = locks.withResources(<String>{'y'}, () async {
        ran.add('b');
      });
      final Future<void> c = locks.withResources(<String>{'x'}, () async {
        ran.add('c');
      });
      await b;
      await _settle();
      expect(ran, <String>['a', 'b'], reason: 'y 与 x 不冲突，b 不等 a；c 要 x，必须等');
      gateA.complete();
      await Future.wait(<Future<void>>[a, c]);
      expect(ran, <String>['a', 'b', 'c']);
      expect(locks.isHeld('x'), isFalse);
    });

    test('抛错也释放', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      await expectLater(
        locks.withResources<void>(<String>{
          'x',
        }, () async => throw StateError('boom')),
        throwsStateError,
      );
      expect(locks.isHeld('x'), isFalse);
      await locks.withResources(<String>{'x'}, () async {});
    });

    test('先来先得：大请求排着时，后来的小请求不插队（不饿死整轮）', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final Completer<void> gate = Completer<void>();
      final List<String> order = <String>[];
      final Future<void> holder = locks.withResources(<String>{
        'channel:a',
      }, () => gate.future);
      final Future<void> big = locks.withResources(<String>{
        'round',
        'channel:a',
        'channel:b',
      }, () async => order.add('big'));
      // channel:b 此刻是空的，但排在前面的 big 也要它：不得抢先。
      final Future<void> small = locks.withResources(<String>{
        'channel:b',
      }, () async => order.add('small'));
      await _settle();
      expect(order, isEmpty);
      expect(locks.waiterCount, 2);
      gate.complete();
      await Future.wait(<Future<void>>[holder, big, small]);
      expect(order, <String>['big', 'small']);
    });

    test('持锁方的嵌套请求不让位给前面的等待者（否则成环）', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final Object sweep = Object();
      final Completer<void> bookStepReached = Completer<void>();
      final List<String> order = <String>[];
      // sweep 持有通道，跑到一半要书锁。
      final Future<void> sweepRun = locks.withResources(
        <String>{'round', 'channel:a'},
        () async {
          await bookStepReached.future;
          await locks.withResources(<String>{'book:k'}, () async {
            order.add('sweep-book');
          });
          order.add('sweep-done');
        },
        owner: sweep,
      );
      // 对比弹窗这类「独占全部」的请求先排上（它要 sweep 手里的通道）。
      final Future<void> exclusive = locks.withResources(<String>{
        'round',
        'channel:a',
        'book:k',
      }, () async => order.add('exclusive'));
      await _settle();
      bookStepReached.complete();
      await Future.wait(<Future<void>>[
        sweepRun,
        exclusive,
      ]).timeout(const Duration(seconds: 2));
      expect(order, <String>['sweep-book', 'sweep-done', 'exclusive']);
    });

    test('嵌套请求省略 owner 时沿用外层锁的 owner（zone 继承），不会排到等它的人后面', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final Completer<void> reachedNested = Completer<void>();
      final Completer<void> goNested = Completer<void>();
      final List<String> order = <String>[];
      // 对比弹窗的应用：独占整轮后，逐本再拿书锁——调用方不传 owner。
      final Future<void> apply = locks.withResources(
        <String>{'round'},
        () async {
          reachedNested.complete();
          await goNested.future;
          await locks.withResources(<String>{'book:k'}, () async {
            order.add('apply-book');
          });
        },
      );
      await reachedNested.future;
      // 在它拿书锁之前，有人排上了「整轮 + 这本书」（要等 apply 放掉整轮）。
      final Future<void> waiter = locks.withResources(<String>{
        'round',
        'book:k',
      }, () async => order.add('waiter'));
      await _settle();
      goNested.complete();
      // 若嵌套请求没继承 owner，它会按先来先得排到 waiter 后面，而 waiter 在等它
      // 放掉整轮——成环，这里超时。
      await Future.wait(<Future<void>>[
        apply,
        waiter,
      ]).timeout(const Duration(seconds: 2));
      expect(order, <String>['apply-book', 'waiter']);
    });

    test('onWait 报出挡路的持有者', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final Object holderOwner = Object();
      final Completer<void> gate = Completer<void>();
      final Future<void> holder = locks.withResources(
        <String>{'channel:a'},
        () => gate.future,
        owner: holderOwner,
      );
      final List<Object?> seen = <Object?>[];
      final Future<void> waiter = locks.withResources(
        <String>{'channel:a', 'book:k'},
        () async {},
        onWait: seen.addAll,
      );
      expect(seen, hasLength(1));
      expect(identical(seen.single, holderOwner), isTrue);
      gate.complete();
      await Future.wait(<Future<void>>[holder, waiter]);
    });

    test('generationOf：每释放一次加一（sweep 据此判断快照是否过期）', () async {
      final SyncResourceLocks locks = SyncResourceLocks();
      final String key = syncBookResource('BookA');
      expect(locks.generationOf(key), 0);
      await locks.withResources(<String>{key}, () async {});
      await locks.withResources(<String>{key, 'other'}, () async {});
      expect(locks.generationOf(key), 2);
      expect(locks.generationOf(syncBookResource('BookB')), 0);
    });
  });

  group('同步入口按资源排队', () {
    late FushiDatabase db;
    late List<String> log;
    late _RecordingBackend cloud;
    late _RecordingBackend interconnect;

    setUp(() async {
      resetSyncTasksForTest();
      db = _memDb();
      log = <String>[];
      cloud = _RecordingBackend('cloud', log);
      interconnect = _RecordingBackend('interconnect', log);
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(cloud, type: SyncBackendType.webDav, isInterconnect: false),
        SyncChannel(
          interconnect,
          type: SyncBackendType.fushiServer,
          isInterconnect: true,
        ),
      ];
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(true);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'BookA',
          title: 'BookA',
          epubPath: '/fake/BookA.epub',
          extractDir: '/fake/BookA',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: 0,
        ),
      );
    });

    tearDown(() async {
      debugSyncChannelsOverride = null;
      resetSyncTasksForTest();
      await db.close();
    });

    test('sweep 正占着整轮 + 云通道：退出书的互联那份立刻跑，云那份只等云通道', () async {
      // 测试 fake 都没有声明通道身份，云通道的锁键是 unscoped 那格。
      final String cloudChannel = syncChannelResource(
        SyncChannelScope.unscoped,
      );
      final Completer<void> sweepOnCloud = Completer<void>();
      final Future<void> sweep = syncResourceLocks.withResources(<String>{
        kSyncRoundResource,
        cloudChannel,
      }, () => sweepOnCloud.future);

      lastSyncOutcome.value = null;
      final Future<void> exit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      await _waitFor(
        () => interconnect.restoreCalls == 1,
        what: 'interconnect part to run while the sweep holds the round',
      );
      expect(cloud.restoreCalls, 0, reason: '云后端是无锁单例：sweep 还在用它，必须等');
      expect(syncResourceLocks.isHeld(kSyncRoundResource), isTrue);
      final SyncTask task = syncTasks.value.singleWhere(
        (SyncTask t) => t.kind == SyncActivityKind.singleBook,
      );
      expect(task.title, 'BookA');
      expect(task.isWaiting, isTrue, reason: '任务面板要能说出它在排队');

      // sweep 跑完云通道、放掉它（整轮仍持有，转去跑互联）：云那份立刻轮到。
      sweepOnCloud.complete();
      await sweep;
      await exit;
      expect(log, <String>['interconnect', 'cloud']);
      expect(lastSyncOutcome.value?.kind, SyncActivityKind.singleBook);
      expect(lastSyncOutcome.value?.reason, SyncOutcomeReason.noChannels);
      expect(syncTasks.value, isEmpty, reason: '没有失败的任务结束即移出任务表');
    });

    test('sweep 只占整轮（正在跑互联通道）时，退出书的两份都不等', () async {
      final Completer<void> gate = Completer<void>();
      final Future<void> sweep = syncResourceLocks.withResources(<String>{
        kSyncRoundResource,
        syncChannelResource(
          SyncChannelScope.forBackendType(SyncBackendType.fushiServer),
        ),
      }, () => gate.future);
      await runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      expect(log.toSet(), <String>{'interconnect', 'cloud'});
      expect(syncResourceLocks.isHeld(kSyncRoundResource), isTrue);
      gate.complete();
      await sweep;
    });

    test('同一本书正被别的路径同步时，退出书等那本书的锁', () async {
      final Completer<void> gate = Completer<void>();
      final Future<void> other = syncResourceLocks.withResources(<String>{
        syncBookResource('BookA'),
      }, () => gate.future);
      final Future<void> exit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      await _settle();
      expect(log, isEmpty);
      gate.complete();
      await other;
      await exit;
      expect(log.toSet(), <String>{'interconnect', 'cloud'});
    });

    test('对比弹窗 / 复习同步（runExclusiveWithSync）仍与整轮串行', () async {
      final Completer<void> gate = Completer<void>();
      final Future<void> sweep = syncResourceLocks.withResources(<String>{
        kSyncRoundResource,
      }, () => gate.future);
      bool ran = false;
      final Future<void> exclusive = runExclusiveWithSync<void>(() async {
        ran = true;
      });
      await _settle();
      expect(ran, isFalse, reason: 'SRS 单 ingest session 等串行约束靠整轮兜住');
      gate.complete();
      await sweep;
      await exclusive;
      expect(ran, isTrue);
    });

    test('sweep 占着云通道时同一本书退出两次：host 拿到第二次的进度，云那份只跑一次', () async {
      String progress = 'P1';
      interconnect.probe = () => progress;
      cloud.probe = () => progress;
      final Completer<void> sweepOnCloud = Completer<void>();
      final Future<void> sweep = syncResourceLocks.withResources(<String>{
        kSyncRoundResource,
        syncChannelResource(SyncChannelScope.unscoped),
      }, () => sweepOnCloud.future);

      final Future<void> firstExit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      await _waitFor(
        () => interconnect.restoreCalls == 1,
        what: 'first exit interconnect part',
      );
      await _settle();

      // 用户重开这本书、读到 P2 后再退出：云那份还排在 sweep 后面（这本书的云去重位
      // 仍被占着），互联那份必须照跑，不能因为同一本书还有请求在飞就丢掉。
      progress = 'P2';
      await runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      expect(interconnect.seenProgress, <String>['P1', 'P2']);
      expect(cloud.restoreCalls, 0, reason: 'sweep 还占着云通道');

      sweepOnCloud.complete();
      await sweep;
      await firstExit;
      // 云那份开跑时才读本地进度，两次退出合并成一遍，读到的是 P2。
      expect(cloud.seenProgress, <String>['P2']);
      expect(syncTasks.value, isEmpty);
    });

    test('某条通道的同步正在跑时又退出：跑完在同一处再跑一遍，读最新进度', () async {
      String progress = 'P1';
      interconnect.probe = () => progress;
      cloud.probe = () => progress;
      final Completer<void> interconnectBusy = Completer<void>();
      interconnect.hold = interconnectBusy;

      final Future<void> firstExit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      await _waitFor(
        () => interconnect.restoreCalls == 1,
        what: 'first interconnect pass to start',
      );
      progress = 'P2';
      // 互联那一遍正在跑：这次退出的互联那份只记一笔重跑，不另起一遍并发去跑。
      final Future<void> secondExit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      // 第二次退出的云那份拿到云通道、排在这本书的锁后面，说明它已过了逐通道认领。
      await _waitFor(
        () => syncTasks.value.any((SyncTask t) => t.isWaiting),
        what: 'second exit to claim its channels',
      );
      expect(interconnect.restoreCalls, 1);

      interconnect.hold = null;
      interconnectBusy.complete();
      await firstExit;
      await secondExit;
      expect(interconnect.seenProgress, <String>[
        'P1',
        'P2',
      ], reason: '开跑之后到的请求要在同一处再跑一遍，读最新进度');
      expect(cloud.seenProgress.last, 'P2');
      expect(syncTasks.value, isEmpty);

      // 去重位已让出：之后的退出照常跑。
      progress = 'P3';
      await runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      expect(interconnect.seenProgress.last, 'P3');
      expect(cloud.seenProgress.last, 'P3');
    });

    test('排队期间通道的自动同步被关：拿到锁后复核，不跑', () async {
      final String cloudChannel = syncChannelResource(
        SyncChannelScope.unscoped,
      );
      final Completer<void> gate = Completer<void>();
      final Future<void> sweep = syncResourceLocks.withResources(<String>{
        cloudChannel,
      }, () => gate.future);
      final Future<void> exit = runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/BookA',
      );
      await _waitFor(
        () => interconnect.restoreCalls == 1,
        what: 'interconnect',
      );
      await SyncRepository(db).setAutoSyncEnabled(false);
      gate.complete();
      await sweep;
      await exit;
      expect(cloud.restoreCalls, 0, reason: '云通道排队期间被关，拿到锁后必须不跑');
    });
  });
}
