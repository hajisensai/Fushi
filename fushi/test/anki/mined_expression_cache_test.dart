import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/mined_expression_cache.dart';

/// 反馈 JAEwvc6Lmr：Anki 连不上时查词也要对已在 Anki 里的词画 ✓。
///
/// 钉死的不变式：
/// * 真值是 Anki：问到了（probe 非 null）就用答案，并让缓存跟上（含「Anki 说没有」→ 划掉）；
/// * 没问到（probe == null）才退回缓存；缓存也没有时保持 `isDuplicate == false`；
/// * 每个作用域每次启动第一次问到时，后台整份刷新（去 HTML 后的第一字段），刷新期间
///   的实时答案叠回快照，作用域中途变了就丢弃快照，拉取失败缓存不动；
/// * 制卡确认进库（成功 / 判重复）就记进缓存；入队、切 app 的后端不记；
/// * 作用域隔离、跨实例（重启）持久。
void main() {
  late Directory tmp;
  late MinedExpressionCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mined_cache_test');
    cache = MinedExpressionCache(directory: () async => tmp);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  MinedExpressionCacheAnkiRepository wrap(_FakeBackend backend) =>
      MinedExpressionCacheAnkiRepository(inner: backend, cache: cache);

  test('问到 ✓ 记进缓存；之后 Anki 连不上照样画 ✓', () async {
    final _FakeBackend backend = _FakeBackend()..answers['食べる'] = true;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);

    expect(await repo.isDuplicate('食べる', 'たべる'), isTrue);
    await repo.lastRefresh;

    backend.reachable = false;
    expect(await repo.probeDuplicate('食べる', 'たべる'), isTrue);
    expect(await repo.isDuplicate('食べる', 'たべる'), isTrue);
  });

  test('没问到且缓存没有：probe 保持 null，isDuplicate 为 false', () async {
    final _FakeBackend backend = _FakeBackend()..reachable = false;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);
    expect(await repo.probeDuplicate('飲む', 'のむ'), isNull);
    expect(await repo.isDuplicate('飲む', 'のむ'), isFalse);
  });

  test('Anki 说没有（在 Anki 里删了）→ 从缓存划掉', () async {
    final _FakeBackend backend = _FakeBackend()..answers['食べる'] = true;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);
    expect(await repo.isDuplicate('食べる', ''), isTrue);
    await repo.lastRefresh;

    backend.answers['食べる'] = false;
    expect(await repo.isDuplicate('食べる', ''), isFalse);

    backend.reachable = false;
    expect(await repo.isDuplicate('食べる', ''), isFalse);
  });

  test('第一次问到触发整份刷新：去 HTML、替换旧词表，每次启动只刷一次', () async {
    final _FakeBackend backend = _FakeBackend()
      ..snapshot = <String>['<b>走る</b>', ' 読む&nbsp;', '']
      ..answers['見る'] = false;
    await cache.recordAnswer(backend.scope, '古い', true);
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);

    expect(await repo.isDuplicate('見る', ''), isFalse);
    await repo.lastRefresh;
    expect(backend.listCalls, 1);

    backend.reachable = false;
    expect(await repo.isDuplicate('走る', ''), isTrue);
    expect(await repo.isDuplicate('読む', ''), isTrue);
    expect(
      await repo.isDuplicate('古い', ''),
      isFalse,
      reason: '整份快照里没有的词（Anki 里已删）必须随刷新消失',
    );
    expect(await cache.count(backend.scope), 2);

    backend.reachable = true;
    await repo.isDuplicate('見る', '');
    await wrap(backend).isDuplicate('見る', '');
    expect(backend.listCalls, 1, reason: '同一作用域每次启动只整份刷新一次（跨仓库实例）');
  });

  test('刷新期间的实时答案叠回快照，不被开始那一刻的快照冲掉', () async {
    final Completer<List<String>?> pending = Completer<List<String>?>();
    final _FakeBackend backend = _FakeBackend()
      ..listResult = pending.future
      ..answers['見る'] = false;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);

    await repo.isDuplicate('見る', ''); // 触发刷新，快照尚未返回
    backend.answers['新しい'] = true;
    await repo.isDuplicate('新しい', ''); // 刷新期间问到的新词
    backend.answers['走る'] = false;
    await repo.isDuplicate('走る', ''); // 刷新期间 Anki 说没有
    pending.complete(<String>['走る', '読む']);
    await repo.lastRefresh;

    backend.reachable = false;
    expect(await repo.isDuplicate('新しい', ''), isTrue);
    expect(await repo.isDuplicate('読む', ''), isTrue);
    expect(await repo.isDuplicate('走る', ''), isFalse);
  });

  test('整份替换与实时答案交错到达：答案落在替换后的词表上，不丢', () async {
    const String scope = 'ankidroid|model:Fushi';
    await cache.count(scope); // 先载入，复现「词表已在内存」时的交错
    cache.beginRefresh(scope);
    final Future<int> refreshing = cache.completeRefresh(scope, <String>['走る']);
    final Future<void> answering = cache.recordAnswer(scope, '読む', true);
    await Future.wait(<Future<Object?>>[refreshing, answering]);

    expect(await cache.contains(scope, '走る'), isTrue);
    expect(await cache.contains(scope, '読む'), isTrue);
    final MinedExpressionCache reopened = MinedExpressionCache(
      directory: () async => tmp,
    );
    expect(
      await reopened.contains(scope, '読む'),
      isTrue,
      reason: '落盘的也得是合并后的词表',
    );
  });

  test('拉取期间作用域变了：快照丢弃，不写进新旧任何一份', () async {
    final Completer<List<String>?> pending = Completer<List<String>?>();
    final _FakeBackend backend = _FakeBackend()
      ..listResult = pending.future
      ..answers['見る'] = true;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);
    final String oldScope = backend.scope;

    await repo.isDuplicate('見る', '');
    backend.scope = 'ankidroid|model:Other';
    pending.complete(<String>['走る']);
    await repo.lastRefresh;

    expect(await cache.contains(oldScope, '走る'), isFalse);
    expect(await cache.contains(oldScope, '見る'), isTrue);
    expect(await cache.contains(backend.scope, '走る'), isFalse);
  });

  test('整份拉取失败：缓存原样保留', () async {
    final _FakeBackend backend = _FakeBackend()
      ..listError = StateError('provider died')
      ..answers['見る'] = true;
    await cache.recordAnswer(backend.scope, '走る', true);
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);

    await repo.isDuplicate('見る', '');
    await repo.lastRefresh;

    backend.reachable = false;
    expect(await repo.isDuplicate('走る', ''), isTrue);
    expect(await repo.isDuplicate('見る', ''), isTrue);
  });

  test('后端不做缓存（作用域 null）：原样透传', () async {
    final _FakeBackend backend = _FakeBackend()
      ..scopeEnabled = false
      ..answers['見る'] = true;
    final MinedExpressionCacheAnkiRepository repo = wrap(backend);
    expect(await repo.isDuplicate('見る', ''), isTrue);
    backend.reachable = false;
    expect(await repo.probeDuplicate('見る', ''), isNull);
    expect(backend.listCalls, 0);
  });

  group('制卡落账', () {
    Future<MineOutcome> mine(
      MinedExpressionCacheAnkiRepository repo,
      String expression,
    ) => repo.mineEntry(
      rawPayloadJson: '{"expression":"$expression","reading":"x"}',
      context: const AnkiMiningContext(sentence: 's'),
    );

    test('成功 / 判重复 → 记进缓存', () async {
      final _FakeBackend backend = _FakeBackend()..reachable = false;
      final MinedExpressionCacheAnkiRepository repo = wrap(backend);

      backend.mineOutcome = const MineOutcome.success();
      await mine(repo, '走る');
      backend.mineOutcome = const MineOutcome.duplicate();
      await mine(repo, '読む');

      expect(await repo.isDuplicate('走る', ''), isTrue);
      expect(await repo.isDuplicate('読む', ''), isTrue);
    });

    test('入队 / 失败 → 不记（卡还不在 Anki 里）', () async {
      final _FakeBackend backend = _FakeBackend()..reachable = false;
      final MinedExpressionCacheAnkiRepository repo = wrap(backend);

      backend.mineOutcome = const MineOutcome.queued();
      await mine(repo, '走る');
      backend.mineOutcome = MineOutcome.failure('boom');
      await mine(repo, '読む');

      expect(await repo.isDuplicate('走る', ''), isFalse);
      expect(await repo.isDuplicate('読む', ''), isFalse);
    });

    test('每张卡都切 app 的后端：「成功」只代表拉起了 app，不记', () async {
      final _FakeBackend backend = _FakeBackend()
        ..reachable = false
        ..switchesApp = true
        ..mineOutcome = const MineOutcome.success();
      final MinedExpressionCacheAnkiRepository repo = wrap(backend);
      await mine(repo, '走る');
      expect(await repo.isDuplicate('走る', ''), isFalse);
    });
  });

  test('跨实例持久（重启后离线仍可用），作用域互相隔离', () async {
    await cache.recordAnswer('scope-a', '走る', true);

    final MinedExpressionCache reopened = MinedExpressionCache(
      directory: () async => tmp,
    );
    expect(await reopened.contains('scope-a', '走る'), isTrue);
    expect(await reopened.contains('scope-b', '走る'), isFalse);
  });
}

class _FakeBackend implements BaseAnkiRepository {
  /// Anki 此刻能不能问到。
  bool reachable = true;

  /// 问到时的答案（没登记的词 = Anki 里没有）。
  final Map<String, bool> answers = <String, bool>{};

  String scope = 'ankidroid|model:Fushi';
  bool scopeEnabled = true;

  /// 整份列出的结果；不设时 = [answers] 里答「有」的词（与实时查重一致的一份 Anki）。
  List<String>? snapshot;
  Future<List<String>?>? listResult;
  Object? listError;
  int listCalls = 0;

  bool switchesApp = false;
  MineOutcome mineOutcome = const MineOutcome.success();

  @override
  Future<bool?> probeDuplicate(String expression, String reading) async =>
      reachable ? (answers[expression] ?? false) : null;

  @override
  Future<bool> isDuplicate(String expression, String reading) async =>
      (await probeDuplicate(expression, reading)) ?? false;

  @override
  Future<String?> minedCacheScope() async => scopeEnabled ? scope : null;

  @override
  Future<List<String>?> listMinedFirstFields() async {
    listCalls++;
    final Object? error = listError;
    if (error != null) throw error;
    final Future<List<String>?>? pending = listResult;
    if (pending != null) return await pending;
    return snapshot ??
        <String>[
          for (final MapEntry<String, bool> e in answers.entries)
            if (e.value) e.key,
        ];
  }

  @override
  bool get switchesAppPerNote => switchesApp;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => mineOutcome;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
