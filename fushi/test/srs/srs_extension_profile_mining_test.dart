// 反馈 biLEesNqWb + 用户拍板「进到对应的复习才对吧」：浏览器扩展选了非激活配置 B、B 的挖词目标是
// Fushi 复习时，卡进 **B 的复习**（App 激活配置 A 的复习里没有），查重按 B 判，同步 v2 的操作记在 B 名下；
// 用户之后切到 B，卡照常在复习里。全程真实 srs.db + Rust 内核，同一个句柄上按 uid 开副本
// （SrsProfileStores），不 mock 复习。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_profile_stores.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

const String _uidA = 'profile-a-uid';
const String _uidB = 'profile-b-uid';

/// 内层 Anki 仓库：复习目标下不该有任何制卡 / 查重落到这里。
class _InnerAnki extends BaseAnkiRepository {
  int calls = 0;

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    calls++;
    return const MineOutcome.success(deckName: 'Anki deck');
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    calls++;
    return false;
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

String _payload(String expression, String reading) =>
    jsonEncode(<String, Object?>{
      'expression': expression,
      'reading': reading,
      'glossary': '<ol><li>cat</li></ol>',
      'glossaryFirst': '<ol><li>cat</li></ol>',
    });

void main() {
  late SrsStorage storage;
  late Directory support;
  late SrsProfileStores stores;
  late SrsDbStore storeA;

  Future<SrsDbStore> openActive(String uid) => stores.activate(
    uid,
    () => SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: uid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    ),
  );

  /// 扩展按配置 [uid] 的视图制卡用的仓库（与 AppModel.hostMiningRepositoryForView 同形）。
  SrsMiningAnkiRepository repoFor(String uid, _InnerAnki inner) =>
      SrsMiningAnkiRepository(
        inner: inner,
        miner: () => stores.minerFor(
          profileUid: uid,
          destination: const SrsMiningDestination(),
          fallbackRolloverHour: () => 4,
        ),
      );

  Future<bool> hasTerm(
    SrsDbStore store,
    String expression,
    String reading,
  ) async => (await store.lookupTermStatus(<SrsTermQuery>[
    SrsTermQuery(expression, reading),
  ])).isNotEmpty;

  Future<int> opsOf(String uid) async {
    final QueryRow r = await storage.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
        )
        .getSingle();
    return r.read<int>('c');
  }

  Future<SrsDbStore> foreignStoreOf(String uid) async => (await stores.minerFor(
    profileUid: uid,
    destination: const SrsMiningDestination(),
    fallbackRolloverHour: () => 4,
  ))!.store;

  setUp(() async {
    storage = await openSrsTestStorage();
    support = Directory.systemTemp.createTempSync('fushi_srs_ext_profile_');
    addTearDown(() {
      try {
        support.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄滞后：临时目录留给系统清理。
      }
    });
    stores = SrsProfileStores(
      SrsProfileStoresDeps(
        storage: () async => storage,
        deviceId: () async => 'dev',
        supportRoot: () async => support,
        engine: () => const SrsTestEngine(),
      ),
    );
    storeA = await openActive(_uidA);
  });

  test('A 激活、扩展选 B（复习目标）：卡落进 B 的复习，A 里没有；不碰 Anki；同步 v2 操作记在 B 名下', () async {
    final int opsA = await opsOf(_uidA);
    final int opsB = await opsOf(_uidB);
    final _InnerAnki inner = _InnerAnki();

    final MineOutcome out = await repoFor(_uidB, inner).mineEntry(
      rawPayloadJson: _payload('猫', 'ねこ'),
      context: const AnkiMiningContext(sentence: '猫がいる。'),
    );

    expect(out.result, MineResult.success, reason: out.errorDetail);
    expect(inner.calls, 0, reason: '复习目标下不发往 Anki');
    final SrsDbStore storeB = await foreignStoreOf(_uidB);
    expect(storeB.profileUid, _uidB);
    expect(identical(storeB, storeA), isFalse);
    expect(await hasTerm(storeB, '猫', 'ねこ'), isTrue, reason: '卡在 B 的复习里');
    expect(await hasTerm(storeA, '猫', 'ねこ'), isFalse, reason: 'A 的复习里没有');
    expect(await opsOf(_uidB), greaterThan(opsB), reason: '操作日志记在 B 名下');
    expect(await opsOf(_uidA), opsA, reason: 'A 名下没有新操作');
  });

  test('B 已有同词：按 B 查重命中、再制卡判重；A 没有这个词，按 A 查重不命中', () async {
    final _InnerAnki inner = _InnerAnki();
    expect(
      (await repoFor(_uidB, inner).mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: const AnkiMiningContext(sentence: '上手だ。'),
      )).result,
      MineResult.success,
    );

    // 新的一次扩展请求（新仓库实例），同一份 B 副本。
    final SrsMiningAnkiRepository again = repoFor(_uidB, inner);
    expect(await again.isDuplicate('上手', 'じょうず'), isTrue);
    expect(await again.isDuplicate('上手', 'うわて'), isFalse, reason: '同形异读不算');
    expect(
      (await again.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: const AnkiMiningContext(sentence: '上手だ。'),
      )).result,
      MineResult.duplicate,
    );
    expect(await repoFor(_uidA, inner).isDuplicate('上手', 'じょうず'), isFalse);
    expect(inner.calls, 0);
  });

  test('用户切到 B：扩展副本先作废，激活副本看得到扩展制的卡，之后的扩展请求直接用激活副本', () async {
    final _InnerAnki inner = _InnerAnki();
    expect(
      (await repoFor(_uidB, inner).mineEntry(
        rawPayloadJson: _payload('犬', 'いぬ'),
        context: const AnkiMiningContext(sentence: '犬だ。'),
      )).result,
      MineResult.success,
    );
    final SrsDbStore foreignB = await foreignStoreOf(_uidB);

    final SrsDbStore activeB = await openActive(_uidB);

    expect(foreignB.isUsable, isFalse, reason: '同一个 uid 不留两份活副本');
    expect(activeB.isUsable, isTrue);
    expect(await hasTerm(activeB, '犬', 'いぬ'), isTrue, reason: '切过去后卡在复习里');
    expect(identical(await foreignStoreOf(_uidB), activeB), isTrue);
    // 作废的扩展副本不能再写（不会在过期的序号 / 时钟上继续写）。
    await expectLater(
      foreignB.runExclusive(() async {}),
      throwsA(isA<StateError>()),
    );
    // A 变成非激活后，扩展选 A 就开 A 的副本（不是旧的激活副本）。
    final SrsDbStore foreignA = await foreignStoreOf(_uidA);
    expect(identical(foreignA, storeA), isFalse);
    expect(foreignA.profileUid, _uidA);
  });

  test('A 与 B 的写入同时发起：都落地、各进各的复习（扩展副本的独占区套在激活副本外层锁里）', () async {
    final _InnerAnki inner = _InnerAnki();
    final SrsMiningAnkiRepository forA = repoFor(_uidA, inner);
    final SrsMiningAnkiRepository forB = repoFor(_uidB, inner);
    final List<(String, String)> wordsA = <(String, String)>[
      ('雨', 'あめ'),
      ('風', 'かぜ'),
      ('空', 'そら'),
    ];
    final List<(String, String)> wordsB = <(String, String)>[
      ('山', 'やま'),
      ('川', 'かわ'),
      ('海', 'うみ'),
    ];
    final List<MineOutcome> outs = await Future.wait(<Future<MineOutcome>>[
      for (int i = 0; i < 3; i++) ...<Future<MineOutcome>>[
        forA.mineEntry(
          rawPayloadJson: _payload(wordsA[i].$1, wordsA[i].$2),
          context: const AnkiMiningContext(sentence: 'A'),
        ),
        forB.mineEntry(
          rawPayloadJson: _payload(wordsB[i].$1, wordsB[i].$2),
          context: const AnkiMiningContext(sentence: 'B'),
        ),
      ],
    ]);
    expect(
      outs.map((MineOutcome o) => o.result),
      everyElement(MineResult.success),
    );
    final SrsDbStore storeB = await foreignStoreOf(_uidB);
    for (final (String e, String r) in wordsA) {
      expect(await hasTerm(storeA, e, r), isTrue, reason: 'A: $e');
      expect(await hasTerm(storeB, e, r), isFalse, reason: 'B 不该有 $e');
    }
    for (final (String e, String r) in wordsB) {
      expect(await hasTerm(storeB, e, r), isTrue, reason: 'B: $e');
      expect(await hasTerm(storeA, e, r), isFalse, reason: 'A 不该有 $e');
    }
  });
}
