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
  }) : outcomes = outcomes ?? <MineOutcome>[];

  final List<MineOutcome> outcomes;
  final bool batchMining;
  final bool switchesApp;
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
    expressions.add(fields['expression']! as String);
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

  test('每张卡都切 app 的后端：不自动补发；会话里一次一张，发完请求同步', () async {
    final PendingMiningAnkiRepository offlineRepo = repoOver(
      _FakeBackend(batchMining: true, switchesApp: true),
    );
    await mine(offlineRepo, 'm1');
    await mine(offlineRepo, 'm2');

    final _FakeBackend mobile = _FakeBackend(switchesApp: true);
    final PendingMiningAnkiRepository repo = repoOver(mobile);

    // 回前台的自动补发：没有会话就什么都不做。
    expect((await repo.flush()).skipped, isTrue);
    expect(mobile.expressions, isEmpty);

    // 用户点「全部发送」：只发一张。
    await repo.flush(interactive: true);
    expect(mobile.expressions, <String>['m1']);
    expect(opened, isEmpty);

    // AnkiMobile 跳回 → 回前台：会话里发下一张；队列空了请求同步。
    await repo.flush();
    expect(mobile.expressions, <String>['m1', 'm2']);
    expect(opened, <Uri>[ankiMobileSyncUri]);

    // 会话已结束：再回前台不再触发任何东西。
    await repo.flush();
    expect(opened, <Uri>[ankiMobileSyncUri]);
  });
}
