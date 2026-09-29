import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

/// 可编排结果的假后端：按调用顺序吐 [outcomes]，记下每次收到的词与封面字节。
class _FakeBackend implements BaseAnkiRepository {
  _FakeBackend({
    List<MineOutcome>? outcomes,
    this.batchMining = false,
    this.switchesApp = false,
    this.throwFor = const <String>{},
  }) : outcomes = outcomes ?? <MineOutcome>[];

  final List<MineOutcome> outcomes;
  final bool batchMining;
  final bool switchesApp;

  /// 收到这些词时违约抛异常（MineOutcome 契约本是永不抛）。
  final Set<String> throwFor;

  /// 后端「认得」的词（AnkiMobile 上就是本机账本）。
  final Set<String> inAnki = <String>{};

  @override
  Future<bool> isDuplicate(String expression, String reading) async =>
      inAnki.contains(expression);
  final List<String> expressions = <String>[];
  final List<String?> coverContents = <String?>[];

  @override
  Future<AnkiSettings> loadSettings() async =>
      AnkiSettings(batchMiningEnabled: batchMining);

  @override
  bool get switchesAppPerNote => switchesApp;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final Map<String, Object?> fields =
        jsonDecode(rawPayloadJson) as Map<String, Object?>;
    final String expression = fields['expression']! as String;
    expressions.add(expression);
    if (throwFor.contains(expression)) throw StateError('backend bug');
    final String? cover = context.coverPath;
    coverContents.add(
      cover != null && File(cover).existsSync()
          ? File(cover).readAsStringSync()
          : null,
    );
    return outcomes.isEmpty
        ? const MineOutcome.success(deckName: 'd')
        : outcomes.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

MineOutcome _refused() =>
    MineOutcome.failure('refused', errorCode: AnkiErrorCode.connectionRefused);

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late PendingMineStore store;
  late List<Uri> opened;

  setUp(() async {
    PendingMiningAnkiRepository.debugReset();
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    tmp = await Directory.systemTemp.createTemp('pending_mine_queue');
    store = PendingMineStore(
      db: () => db,
      root: () async => Directory('${tmp.path}/${PendingMineStore.dirName}'),
    );
    opened = <Uri>[];
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  PendingMiningAnkiRepository repoOver(_FakeBackend backend) =>
      PendingMiningAnkiRepository(
        inner: backend,
        store: store,
        payloadBuilder: ForwardedMinePayloadBuilder(
          dictMediaLoader: (String d, String p) => null,
        ),
        openUrl: (Uri uri) async {
          opened.add(uri);
          return true;
        },
      );

  /// 模拟调用方：临时封面在 mineEntry 返回后立刻被删。
  Future<MineOutcome> mine(
    PendingMiningAnkiRepository repo,
    String word,
  ) async {
    final File cover = File('${tmp.path}/cover_$word.jpg')
      ..writeAsStringSync('cover-$word');
    try {
      return await repo.mineEntry(
        rawPayloadJson: jsonEncode(<String, String>{
          'expression': word,
          'reading': 'r-$word',
        }),
        context: AnkiMiningContext(sentence: 's-$word', coverPath: cover.path),
      );
    } finally {
      cover.deleteSync();
    }
  }

  test('后端拒绝连接：卡冻结进队列（含媒体），返回 queued', () async {
    final _FakeBackend backend = _FakeBackend(
      outcomes: <MineOutcome>[_refused()],
    );
    final MineOutcome outcome = await mine(repoOver(backend), 'a');

    expect(outcome.result, MineResult.queued);
    final List<PendingMineRow> rows = await store.all();
    expect(rows.map((PendingMineRow r) => r.expression), <String>['a']);
    expect(rows.single.reading, 'r-a');
    expect(rows.single.status, PendingMineStatus.pending);
    final payload = await store.readPayload(rows.single.id);
    expect(utf8.decode(payload!.coverBytes!), 'cover-a');
  });

  test('请求可能已送达的失败（超时 / 未知）不入队，原样报失败', () async {
    for (final String code in <String>[
      AnkiErrorCode.connectionTimeout,
      AnkiErrorCode.connectionUnknown,
    ]) {
      final _FakeBackend backend = _FakeBackend(
        outcomes: <MineOutcome>[MineOutcome.failure('x', errorCode: code)],
      );
      final MineOutcome outcome = await mine(repoOver(backend), code);
      expect(outcome.result, MineResult.error, reason: code);
    }
    expect(await store.count(), 0);
  });

  test('批量模式：不碰后端，直接入队', () async {
    final _FakeBackend backend = _FakeBackend(batchMining: true);
    final MineOutcome outcome = await mine(repoOver(backend), 'b');

    expect(outcome.result, MineResult.queued);
    expect(backend.expressions, isEmpty);
    expect(await store.count(), 1);
  });

  test('补发：按入队顺序重放、媒体还原；送达出队，不可达就停下', () async {
    final _FakeBackend offline = _FakeBackend(
      outcomes: <MineOutcome>[_refused(), _refused(), _refused()],
    );
    final PendingMiningAnkiRepository offlineRepo = repoOver(offline);
    for (final String w in <String>['x', 'y', 'z']) {
      await mine(offlineRepo, w);
    }
    expect(await store.count(), 3);

    // 第一张送达，第二张又连不上：第三张不该被尝试。
    final _FakeBackend flaky = _FakeBackend(
      outcomes: <MineOutcome>[const MineOutcome.success(), _refused()],
    );
    final PendingFlushReport first = await repoOver(flaky).flush();
    expect(flaky.expressions, <String>['x', 'y']);
    expect(flaky.coverContents, <String?>['cover-x', 'cover-y']);
    expect(first.delivered, 1);
    expect(first.unreachable, isTrue);
    expect(first.remaining, 2);

    final _FakeBackend online = _FakeBackend();
    final PendingFlushReport second = await repoOver(online).flush();
    expect(online.expressions, <String>['y', 'z']);
    expect(second.delivered, 2);
    expect(await store.count(), 0);
    expect(
      Directory('${tmp.path}/${PendingMineStore.dirName}').listSync(),
      isEmpty,
      reason: '送达后载荷文件要一起删掉',
    );
  });

  test('补发：Anki 拒收的标 failed 并继续，重复视为已送达', () async {
    final PendingMiningAnkiRepository offlineRepo = repoOver(
      _FakeBackend(outcomes: <MineOutcome>[_refused(), _refused(), _refused()]),
    );
    for (final String w in <String>['p', 'q', 'r']) {
      await mine(offlineRepo, w);
    }
    final _FakeBackend backend = _FakeBackend(
      outcomes: <MineOutcome>[
        MineOutcome.failure('bad field'),
        const MineOutcome.duplicate(),
        const MineOutcome.success(),
      ],
    );
    final PendingFlushReport report = await repoOver(backend).flush();

    expect(backend.expressions, <String>['p', 'q', 'r']);
    expect(report.failed, 1);
    expect(report.delivered, 2);
    final List<PendingMineRow> left = await store.all();
    expect(left.single.expression, 'p');
    expect(left.single.status, PendingMineStatus.failed);
    expect(left.single.lastError, 'bad field');

    // failed 不自动补发，重试后才会。
    expect((await repoOver(_FakeBackend()).flush()).delivered, 0);
    await store.retry(left.single.id);
    expect((await repoOver(_FakeBackend()).flush()).delivered, 1);
  });

  test('直接制卡成功 = 后端可达：顺带补发队列', () async {
    final PendingMiningAnkiRepository offlineRepo = repoOver(
      _FakeBackend(outcomes: <MineOutcome>[_refused()]),
    );
    await mine(offlineRepo, 'old');

    final _FakeBackend backend = _FakeBackend();
    final PendingMiningAnkiRepository repo = repoOver(backend);
    expect((await mine(repo, 'new')).result, MineResult.success);
    // 自动补发走同一把串行锁：再排一轮空补发即可等到它结束。
    await repo.flush();
    expect(backend.expressions, <String>['new', 'old']);
    expect(await store.count(), 0);
  });

  test('AnkiMobile：回前台不自动补发；x-success 回跳才出队，发完才请求同步', () async {
    final PendingMiningAnkiRepository offlineRepo = repoOver(
      _FakeBackend(batchMining: true, switchesApp: true),
    );
    await mine(offlineRepo, 'm1');
    await mine(offlineRepo, 'm2');

    final _FakeBackend mobile = _FakeBackend(switchesApp: true);
    final PendingMiningAnkiRepository repo = repoOver(mobile);

    // 回前台的自动补发：什么都不做。
    expect((await repo.flush()).skipped, isTrue);
    expect(mobile.expressions, isEmpty);

    // 用户点「全部发送」：拉起第一张，行仍在队列里（等回跳确认）。
    await repo.flush(interactive: true);
    expect(mobile.expressions, <String>['m1']);
    expect(await store.count(), 2);
    expect(opened, isEmpty);

    // 词条对不上的回跳（来自别的直接制卡）不算数。
    await repo.confirmAnkiMobileDelivery('别的词');
    expect(mobile.expressions, <String>['m1']);
    expect(await store.count(), 2);

    // m1 回跳：出队并拉起 m2；此时还不能同步——m2 还没存进 AnkiMobile。
    await repo.confirmAnkiMobileDelivery('m1');
    expect(mobile.expressions, <String>['m1', 'm2']);
    expect(await store.count(), 1);
    expect(opened, isEmpty);

    // m2 回跳：队列清空，这时才请求 AnkiMobile 同步。
    await repo.confirmAnkiMobileDelivery('m2');
    expect(await store.count(), 0);
    expect(opened, <Uri>[ankiMobileSyncUri]);

    // 之后的回前台 / 回跳都不再触发任何东西。
    await repo.flush();
    await repo.confirmAnkiMobileDelivery('m2');
    expect(opened, <Uri>[ankiMobileSyncUri]);
  });

  test('AnkiMobile：用户取消（没有回跳）时卡不丢，下次「全部发送」重发它', () async {
    await mine(
      repoOver(_FakeBackend(batchMining: true, switchesApp: true)),
      'c1',
    );

    final _FakeBackend mobile = _FakeBackend(switchesApp: true);
    final PendingMiningAnkiRepository repo = repoOver(mobile);
    await repo.flush(interactive: true);
    // 用户在 AnkiMobile 里取消、手动切回：没有 x-success。
    expect((await repo.flush()).skipped, isTrue);
    expect(await store.count(), 1, reason: '没确认送达就不能出队');

    await repo.flush(interactive: true);
    expect(mobile.expressions, <String>['c1', 'c1']);
    await repo.confirmAnkiMobileDelivery('c1');
    expect(await store.count(), 0);
  });

  test('补发中的意外（载荷丢失 / 后端违约抛异常）标 failed，不挡住后面的卡', () async {
    final PendingMiningAnkiRepository offlineRepo = repoOver(
      _FakeBackend(batchMining: true),
    );
    for (final String w in <String>['lost', 'boom', 'ok']) {
      await mine(offlineRepo, w);
    }
    final PendingMineRow lost = (await store.all()).first;
    File(
      '${tmp.path}/${PendingMineStore.dirName}/${lost.id}.json',
    ).deleteSync();

    final _FakeBackend backend = _FakeBackend(throwFor: <String>{'boom'});
    final PendingFlushReport report = await repoOver(backend).flush();

    expect(backend.expressions, <String>['boom', 'ok']);
    expect(report.delivered, 1);
    expect(report.failed, 2);
    expect(report.unreachable, isFalse);
    final List<PendingMineRow> left = await store.all();
    expect(left.map((PendingMineRow r) => r.expression), <String>[
      'lost',
      'boom',
    ]);
    expect(
      left.every((PendingMineRow r) => r.status == PendingMineStatus.failed),
      isTrue,
    );
  });

  test('BUG-2773：本机制、已上传到中转的卡不在本机补发，留给落地设备', () async {
    await mine(repoOver(_FakeBackend(batchMining: true)), 'up');
    final PendingMineRow row = (await store.all()).single;
    await (db.update(db.pendingMineQueue)
          ..where(($PendingMineQueueTable t) => t.id.equals(row.id)))
        .write(const PendingMineQueueCompanion(uploaded: Value<bool>(true)));

    final _FakeBackend backend = _FakeBackend();
    await repoOver(backend).flush();

    expect(backend.expressions, isEmpty, reason: '否则两台设备各落一张');
    expect(await store.sendable(), isEmpty);
    final PendingMineRow kept = (await store.rows()).single;
    expect(kept.status, PendingMineStatus.pending);
    expect(await store.markSending(row.id), isFalse);
  });

  test('上传过的卡被标送达（用户删 / 快照过期）：标 landed，行留给中转清理远端', () async {
    await mine(repoOver(_FakeBackend(batchMining: true)), 'up');
    final PendingMineRow row = (await store.all()).single;
    await (db.update(db.pendingMineQueue)
          ..where(($PendingMineQueueTable t) => t.id.equals(row.id)))
        .write(const PendingMineQueueCompanion(uploaded: Value<bool>(true)));

    await store.markDelivered(row);

    expect(await store.all(), isEmpty);
    final PendingMineRow landed = (await store.rows()).single;
    expect(landed.status, PendingMineStatus.landed);
    expect(await store.sendable(), isEmpty, reason: 'landed 不能被再次补发');
  });

  test('孤儿载荷与半截 .tmp 在补发前被清掉，有行的载荷保留', () async {
    await mine(repoOver(_FakeBackend(batchMining: true)), 'keep');
    final Directory dir = Directory('${tmp.path}/${PendingMineStore.dirName}');
    File('${dir.path}/orphan.json').writeAsStringSync('{}');
    File('${dir.path}/half.json.tmp').writeAsStringSync('{');

    // 补发一个不可达的后端：卡留在队列里，只看清理效果。
    await repoOver(_FakeBackend(outcomes: <MineOutcome>[_refused()])).flush();

    final List<String> names = dir
        .listSync()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    final String keepId = (await store.all()).single.id;
    expect(names, <String>['$keepId.json']);
  });

  test('AnkiMobile：切过去期间 Fushi 被杀、回跳冷启动，照样确认出队', () async {
    await mine(
      repoOver(_FakeBackend(batchMining: true, switchesApp: true)),
      'k1',
    );
    await repoOver(_FakeBackend(switchesApp: true)).flush(interactive: true);

    // 进程重启：内存里什么都没了，只剩库里那张 sending。
    PendingMiningAnkiRepository.debugReset();
    final PendingMiningAnkiRepository fresh = repoOver(
      _FakeBackend(switchesApp: true),
    );
    await fresh.confirmAnkiMobileDelivery('k1');

    expect(await store.count(), 0);
    expect(opened, <Uri>[ankiMobileSyncUri]);
  });

  test('AnkiMobile：残留的 sending 卡即使本机账本记过这个词，也退回重发（不静默丢卡）', () async {
    await mine(
      repoOver(_FakeBackend(batchMining: true, switchesApp: true)),
      'seen',
    );
    await repoOver(_FakeBackend(switchesApp: true)).flush(interactive: true);

    // 账本里有这个词（例如以前制过卡），但这次被取消了。
    final _FakeBackend mobile = _FakeBackend(switchesApp: true)
      ..inAnki.add('seen');
    await repoOver(mobile).flush(interactive: true);

    expect(mobile.expressions, <String>[
      'seen',
    ], reason: '重新拉起，由 AnkiMobile 查重');
    expect(await store.count(), 1, reason: '没有回跳确认就不出队');
  });

  test('AnkiMobile：连发链中途断了（下一张失败），已确认的那张照样请求同步', () async {
    final PendingMiningAnkiRepository offline = repoOver(
      _FakeBackend(batchMining: true, switchesApp: true),
    );
    await mine(offline, 'a1');
    await mine(offline, 'a2');

    final _FakeBackend mobile = _FakeBackend(
      switchesApp: true,
      outcomes: <MineOutcome>[
        const MineOutcome.success(),
        MineOutcome.failure('AnkiMobile is not installed'),
      ],
    );
    final PendingMiningAnkiRepository repo = repoOver(mobile);
    await repo.flush(interactive: true);
    await repo.confirmAnkiMobileDelivery('a1');

    expect(mobile.expressions, <String>['a1', 'a2']);
    expect(opened, <Uri>[ankiMobileSyncUri]);
    final PendingMineRow left = (await store.all()).single;
    expect(left.expression, 'a2');
    expect(left.status, PendingMineStatus.failed);
  });
}
