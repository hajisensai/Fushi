import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/anki/anki_auto_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';
import 'package:fushi/src/anki/auto_reposition_anki_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

// 「制卡后自动重排」调度器的行为守卫。用**真** runner + 假仓库跑，所以
// plan/apply/pruneSnapshots 三段真实代码都在测试路径上（只有 AnkiConnect 的
// HTTP 与词典 FFI 被替掉）。
//
// 钉四条不变式：
//   - 防抖：窗口内多次制卡只触发一次写回；
//   - 开关关着一次都不跑（默认关，老用户升级不会凭空多出自动写 Anki 的路径）；
//   - 后端不支持（AnkiDroid / AnkiMobile / 远端制卡）一次都不跑；
//   - 单飞：上一轮还在跑时进来的牌组不并发写，由那一轮收尾时捡走。

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({required this.supported, required AnkiSettings settings})
      : _settings = settings;

  final bool supported;
  AnkiSettings _settings;

  /// 牌组 → 新卡。默认给一组「位置与词频相反」的卡，保证 plan 必产生改动。
  final Map<String, List<AnkiCardInfo>> cards = <String, List<AnkiCardInfo>>{};

  /// 每次 setNewCardPositions 的入参，用来数「写了几轮」。
  final List<List<AnkiCardDueUpdate>> writes = <List<AnkiCardDueUpdate>>[];

  /// 写回时先等这个 completer，用来把一轮重排按住做单飞测试。
  Completer<void>? gate;

  @override
  bool get supportsDeckReposition => supported;

  @override
  Future<List<AnkiCardInfo>> listNewCards(String deckName) async =>
      cards[deckName] ?? const <AnkiCardInfo>[];

  @override
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) async {
    if (gate != null) await gate!.future;
    writes.add(updates);
    return AnkiCardDueWriteResult(
      written: updates.length,
      failures: const <int, String>{},
    );
  }

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  /// 下一次 mineEntry 返回什么（装饰器测试用）。
  MineOutcome mineResult = MineOutcome.failure('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      mineResult;

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

AnkiCardInfo _card(int id, int due, String expression) => AnkiCardInfo(
      cardId: id,
      noteId: id,
      ord: 0,
      due: due,
      type: 0,
      queue: 0,
      modelName: 'Basic',
      deckName: 'Mining',
      fields: <String, String>{'Expression': expression, 'Meaning': ''},
    );

/// 假词频表：`common` 排名 1、`rare` 排名 9999。
List<FushiTermResult> _lookup(String expression) {
  final int rank = expression == 'common' ? 1 : 9999;
  return <FushiTermResult>[
    FushiTermResult(
      expression: expression,
      reading: '',
      rules: '',
      glossaries: const <FushiGlossaryEntry>[],
      pitches: const <FushiPitchEntry>[],
      frequencies: <FushiFrequencyEntry>[
        FushiFrequencyEntry(
          dictName: 'JPDB',
          frequencies: <FushiFrequency>[
            FushiFrequency(value: rank, displayValue: ''),
          ],
        ),
      ],
    ),
  ];
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('auto_reposition_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ({_FakeRepo repo, AnkiAutoRepositionScheduler scheduler}) build({
    bool enabled = true,
    bool supported = true,
    bool alreadySorted = false,
    bool noFrequencies = false,
    AnkiRepositionSource source = AnkiRepositionSource.dictionaries,
    Duration debounce = const Duration(milliseconds: 20),
  }) {
    final AnkiSettings settings = AnkiSettings(
      selectedDeckId: 1,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      autoRepositionEnabled: enabled,
      repositionSource: source,
    );
    final _FakeRepo repo = _FakeRepo(supported: supported, settings: settings);
    // 位置与词频相反：rare 在前(due 1)、common 在后(due 2)，重排必然要动。
    repo.cards['Mining'] = alreadySorted
        ? <AnkiCardInfo>[_card(1, 1, 'common'), _card(2, 2, 'rare')]
        : <AnkiCardInfo>[_card(1, 1, 'rare'), _card(2, 2, 'common')];
    final AnkiAutoRepositionScheduler scheduler = AnkiAutoRepositionScheduler(
      runner: AnkiDeckRepositionRunner(
        repo,
        lookup:
            noFrequencies ? (String e) => const <FushiTermResult>[] : _lookup,
        snapshotDirectory: () async => tempDir,
      ),
      loadSettings: repo.loadSettings,
      debounce: debounce,
    );
    return (repo: repo, scheduler: scheduler);
  }

  test('防抖：窗口内多次制卡只触发一轮写回', () async {
    final r = build();
    for (int i = 0; i < 5; i++) {
      r.scheduler.notifyMined('Mining');
    }
    await r.scheduler.flushNow();

    expect(r.repo.writes, hasLength(1),
        reason: '五次制卡应合并成一次写回，而不是一张卡刷一次 AnkiConnect');
    expect(r.repo.writes.single, hasLength(2));
    // common(cardId 2) 应被排到第一个位置。
    final AnkiCardDueUpdate first = r.repo.writes.single.reduce(
        (AnkiCardDueUpdate a, AnkiCardDueUpdate b) => a.due <= b.due ? a : b);
    expect(first.cardId, 2, reason: '词频最高的卡应排到队首');
    r.scheduler.dispose();
  });

  test('开关关着一次都不跑', () async {
    final r = build(enabled: false);
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();
    expect(r.repo.writes, isEmpty);
    r.scheduler.dispose();
  });

  test('后端不支持卡片级读写时一次都不跑', () async {
    final r = build(supported: false);
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();
    expect(r.repo.writes, isEmpty);
    r.scheduler.dispose();
  });

  test('单飞：上一轮在跑时进来的制卡不并发写，收尾时补跑', () async {
    final r = build();
    final Completer<void> gate = Completer<void>();
    r.repo.gate = gate;

    r.scheduler.notifyMined('Mining');
    final Future<void> firstRun = r.scheduler.flushNow();
    await Future<void>.delayed(Duration.zero);

    // 第一轮卡在写回上，此时又制了一张卡并立刻催它跑。
    r.scheduler.notifyMined('Mining');
    final Future<void> secondCall = r.scheduler.flushNow();
    await Future<void>.delayed(Duration.zero);
    expect(r.repo.writes, isEmpty, reason: '第一轮还没写完，不该有任何写回落地');

    r.repo.gate = null;
    gate.complete();
    await Future.wait(<Future<void>>[firstRun, secondCall]);

    expect(r.repo.writes, hasLength(2), reason: '第二次制卡不能被丢掉，应由第一轮收尾时捡走再跑一轮');
    r.scheduler.dispose();
  });

  test('dispose 之后的制卡不再触发', () async {
    final r = build();
    r.scheduler.dispose();
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();
    expect(r.repo.writes, isEmpty);
  });

  group('装饰器只在真的制出新卡时才通知调度器', () {
    ({_FakeRepo repo, AutoRepositionAnkiRepository decorated}) wrap({
      bool supported = true,
    }) {
      final r = build(supported: supported);
      // 直接观测 notifyMined 的入参：把调度器换成一个只记账的探针不现实
      // （它是具体类），改用真调度器 + 记 pending 的间接观测反而更脆。
      // 这里用 onRunForTesting 之外的最短路径：跑完 flushNow 后看写回次数。
      final AutoRepositionAnkiRepository decorated =
          AutoRepositionAnkiRepository(
        inner: r.repo,
        scheduler: r.scheduler,
      );
      return (repo: r.repo, decorated: decorated);
    }

    Future<int> minesThenFlush(
      ({_FakeRepo repo, AutoRepositionAnkiRepository decorated}) w,
    ) async {
      await w.decorated.mineEntry(
        rawPayloadJson: '{}',
        context: const AnkiMiningContext(sentence: ''),
      );
      // 装饰器是否通知了调度器，只能由「有没有真的跑出一轮写回」体现。
      await Future<void>.delayed(const Duration(milliseconds: 40));
      return w.repo.writes.length;
    }

    test('制卡成功且带落卡牌组 → 触发', () async {
      final w = wrap();
      w.repo.mineResult = const MineOutcome.success(deckName: 'Mining');
      expect(await minesThenFlush(w), 1);
    });

    test('制卡失败 → 不触发', () async {
      final w = wrap();
      w.repo.mineResult = MineOutcome.failure('nope');
      expect(await minesThenFlush(w), 0);
    });

    test('成功但没有落卡牌组名 → 不触发', () async {
      final w = wrap();
      w.repo.mineResult = const MineOutcome.success();
      expect(await minesThenFlush(w), 0, reason: '牌组名是唯一的重排目标，猜一个比不做更危险');
    });

    test('后端不支持卡片级读写 → 不触发', () async {
      final w = wrap(supported: false);
      w.repo.mineResult = const MineOutcome.success(deckName: 'Mining');
      expect(await minesThenFlush(w), 0);
    });
  });

  test('位置本来就对时一张卡都不写、也不留快照', () async {
    final r = build(alreadySorted: true);
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();

    expect(r.repo.writes, isEmpty,
        reason: '判据必须是 plan.changed，不是 plan.updates.isEmpty——'
            'planCardPositions 给每张新卡都发一条 update，用 updates 判等于'
            '每批制卡都把整个牌组重写一遍');
    expect(tempDir.listSync(), isEmpty, reason: '没写回就不该留快照');
    r.scheduler.dispose();
  });

  test('词典来源下一张都没查到词频时不重排', () async {
    final r = build(noFrequencies: true);
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();

    expect(r.repo.writes, isEmpty,
        reason: '没有任何排序依据的「重排」只是一次无信息量的全牌组位置重写'
            '（选中的词频词典被删/被隐藏时就是这个状态）');
    r.scheduler.dispose();
  });

  test('自动重排的快照不会劫持手动重排的撤销点', () async {
    final r = build();
    final AnkiDeckRepositionRunner runner = AnkiDeckRepositionRunner(
      r.repo,
      lookup: _lookup,
      snapshotDirectory: () async => tempDir,
    );

    // 手动重排一次（auto 默认 false）。
    final AnkiRepositionPlan? manual = await runner.plan(
      deckName: 'Mining',
      settings: await r.repo.loadSettings(),
      options: const AnkiRepositionRankOptions(),
    );
    await runner.apply(manual!);
    final AnkiRepositionSnapshot? afterManual =
        await runner.latestSnapshot('Mining');
    expect(afterManual, isNotNull);

    // 再让自动路径跑一轮（卡的位置已被手动那次改过，这里重新造成待排状态）。
    r.repo.cards['Mining'] = <AnkiCardInfo>[
      _card(1, 1, 'rare'),
      _card(2, 2, 'common'),
    ];
    r.scheduler.notifyMined('Mining');
    await r.scheduler.flushNow();
    expect(r.repo.writes, isNotEmpty, reason: '自动那轮应该真的写了');

    final AnkiRepositionSnapshot? afterAuto =
        await runner.latestSnapshot('Mining');
    expect(afterAuto!.file.path, afterManual!.file.path,
        reason: '撤销按钮必须仍指向手动那次之前的状态；被自动快照顶掉的话，'
            '那次手动重排就永远撤不回去了，而按钮看起来一切正常');
    r.scheduler.dispose();
  });

  test('pruneSnapshots 只削自动快照，手动的一份不动', () async {
    final r = build();
    final AnkiDeckRepositionRunner runner = AnkiDeckRepositionRunner(
      r.repo,
      lookup: _lookup,
      snapshotDirectory: () async => tempDir,
    );
    File snap(String name) =>
        File('${tempDir.path}/$name')..writeAsStringSync('{}');

    snap(
        '${AnkiDeckRepositionRunner.kManualPrefix}2026-09-01T00-00-00.000Z.json');
    for (int i = 1; i <= 5; i++) {
      snap('${AnkiDeckRepositionRunner.kAutoPrefix}2026-09-0${i}T00-00-00.000Z'
          '.json');
    }

    final int deleted = await runner.pruneSnapshots(keep: 2);

    expect(deleted, 3, reason: '5 份自动快照只留 2 份');
    final List<String> left = tempDir
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .toList()
      ..sort();
    expect(
        left.where((String n) => !n.startsWith('reposition-auto-')).length, 1,
        reason: '手动快照是用户的撤销点，一份都不能被自动路径的产物挤掉');
    expect(left.length, 3);
    r.scheduler.dispose();
  });
}
