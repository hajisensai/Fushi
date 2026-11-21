// 全新 profile 经 SrsDbStore 端到端（规划 §6 合并条件，G7-5b）：空库首次打开、同一个库里新建第二个 profile，
// 各自走一遍「开库 → 建内置实体 → 加笔记 → 出卡 → 预览 → 作答 → 统计」；辅助进程（只读）在主进程还没建身份时给
// 等待状态、建好之后照常读；绑定变化（`bindingChanged`）让本对象的根上 ID 与缓存作废并通知订阅方；C 直出入口的页里
// 带 profile 行（按 profile 的集合读，不按卡认）。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;

const String kProfileA = '01928c3e-0000-7000-8000-00000000000a';
const String kProfileB = '01928c3e-0000-7000-8000-00000000000b';
const String kProfileC = '01928c3e-0000-7000-8000-00000000000c';

void main() {
  int now = DateTime.utc(2026, 11, 17, 3).millisecondsSinceEpoch;
  late Directory dir;
  final List<SrsStorage> opened = <SrsStorage>[];

  setUp(() {
    now = DateTime.utc(2026, 11, 17, 3).millisecondsSinceEpoch;
    dir = Directory.systemTemp.createTempSync('srs_fresh_e2e_');
  });

  tearDown(() async {
    for (final SrsStorage s in opened.reversed) {
      await s.close();
    }
    opened.clear();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：留给系统清理。
    }
  });

  Future<SrsStorage> storage(SrsOpenMode mode) async {
    final SrsStorage s = await SrsStorage.open(directory: dir.path, mode: mode);
    opened.add(s);
    return s;
  }

  Future<SrsDbStore> open(SrsStorage s, String profile) => SrsDbStore.open(
    core: s.core,
    profileUid: profile,
    deviceId: 'legacy-device-ignored',
    engine: const FakeFsrsEngine(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => now,
      bootClockMs: () => now,
      bootId: 'boot',
    ),
    fallbackRolloverHour: () => 4,
    localOffsetMin: () => 0,
  );

  /// 「加笔记 → 出卡 → 预览 → 作答 → 统计」：返回作答的那张卡。
  Future<String> studyOnce(SrsDbStore store, String expression) async {
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(store.profileUid, 'Expression'): expression,
      },
    );
    final String card = (await store.cardsOfNote(note)).single.id;
    final SrsStudyState state = (await store.studyState(store.defaultDeckId))!;
    expect(state.next, card, reason: 'the new card is queued');
    final SrsAnswerPreview preview = await store.preview(card);
    expect(preview.plan.byRating.keys, containsAll(<int>[1, 2, 3, 4]));
    final SrsAnswerOutcome out = await store.answerAndStudy(
      card,
      3,
      durationMs: 3000,
      studyDeckId: store.defaultDeckId,
    );
    expect(out.log.cardId, card);
    final SrsStatsReport report = await (await loadSrsStats(store)).report();
    expect(report.todayStats.count, 1);
    expect(report.cardCounts.total, 1);
    return card;
  }

  test('空库首次打开：身份在第一条按集合的命令之前建好，内置实体齐全，能加笔记、出卡、预览、作答、统计', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);

    // 设备号 / 集合 / 目录取自 identity 回包；全新 profile 的目录名 = uid（交接说明 G9-4 定案 2）。
    expect(a.sync2Device, isNotNull);
    expect(a.sync2Device, isNot('legacy-device-ignored'));
    expect(a.sync2Collection, isNotNull);
    expect(a.sync2Dir, kProfileA);
    // 第一次建身份时回包带 `bindingChanged`：接到了（打开途中，没有订阅方）。
    expect(a.debugBindingChanges, 1);

    final SrsDeckTree tree = await a.deckTree();
    expect(tree.decks.map((SrsDeckView d) => d.id), contains(a.defaultDeckId));
    expect(
      (await a.noteTypes()).map((SrsNoteTypeView t) => t.id),
      containsAll(<String>[a.lapisNoteTypeId, a.fushiCardNoteTypeId]),
    );

    await studyOnce(a, '食べる');

    // 重开（新的副本对象）：已有身份是一次读，不再报绑定变化，设备号不变。
    final SrsDbStore again = await open(primary, kProfileA);
    expect(again.debugBindingChanges, 0);
    expect(again.sync2Device, a.sync2Device);
    expect(again.sync2Collection, a.sync2Collection);
  });

  test('同一个库里新建第二个 profile：各自一个集合、各自的内置实体与复习，互不串', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final String cardA = await studyOnce(a, '飲む');

    final SrsDbStore b = await open(primary, kProfileB);
    expect(b.sync2Collection, isNot(a.sync2Collection));
    expect(b.sync2Dir, kProfileB);
    expect(b.debugBindingChanges, 1);
    final String cardB = await studyOnce(b, '見る');
    expect(cardB, isNot(cardA));
    // A 的统计没被 B 的作答带上。
    expect((await (await loadSrsStats(a)).report()).todayStats.count, 1);

    // C 直出入口的页里带 profile 行：B 问 A 的卡，按 B 的集合读 = 没有历史；只按卡认的话会读到 A 的那条评分。
    final SrsDayContext day = await b.dayContext();
    expect(
      (await b.optimizerTrainingSet(
        <String>[cardA],
        algorithm: SrsAlgorithm.fsrs6,
        day: day,
      )).reviewTotal,
      0,
      reason: 'B reads its own collection, not the one the card has history in',
    );
    expect(
      (await a.optimizerTrainingSet(
        <String>[cardA],
        algorithm: SrsAlgorithm.fsrs6,
        day: day,
      )).reviewTotal,
      greaterThan(0),
    );
  });

  test('辅助进程：主进程还没给这个 profile 建身份时是等待状态，建好之后照常只读打开', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    final String card = await studyOnce(a, '書く');

    final SrsStorage secondary = await storage(SrsOpenMode.secondary);
    await expectLater(
      open(secondary, kProfileC),
      throwsA(
        isA<SrsProfileIdentityPending>().having(
          (SrsProfileIdentityPending e) => e.profile,
          'profile',
          kProfileC,
        ),
      ),
    );

    final SrsDbStore readOnly = await open(secondary, kProfileA);
    expect(readOnly.sync2Device, a.sync2Device);
    expect(readOnly.sync2Collection, a.sync2Collection);
    expect((await readOnly.preview(card)).plan.byRating, hasLength(4));
    // 重新激活时重取身份：没变就不报绑定变化。
    await readOnly.refreshIdentity();
    expect(readOnly.debugBindingChanges, 0);

    // 主进程建好 C 之后，辅助进程再开就不是等待状态了。
    await open(primary, kProfileC);
    final SrsDbStore c = await open(secondary, kProfileC);
    expect(c.sync2Dir, kProfileC);
  });

  test('回包带 bindingChanged：根上 ID 与缓存作废重取、通知订阅方；没有变化的命令不报', () async {
    final SrsStorage primary = await storage(SrsOpenMode.primary);
    final SrsDbStore a = await open(primary, kProfileA);
    await a.deckTree();
    final SrsKernelIds idsBefore = a.kernelIds;
    final String deckBefore = a.defaultDeckId;
    int notified = 0;
    final StreamSubscription<void> sub = a.bindingChanges.listen(
      (_) => notified++,
    );
    addTearDown(sub.cancel);

    // 补盐（G9-4 `collection_salts_add`）是可能改绑定的命令：真有新盐时提交后回包带 `bindingChanged`。
    final Map<String, Object?> added = (await a.sync2Command(<String, Object?>{
      'op': 'collection_salts_add',
      'salts': <String>['01928c3e-0000-7000-8000-0000000000ff'],
      'now': now,
    })).map;
    expect(added['outcome'], 'saltsAdded');
    await Future<void>.delayed(Duration.zero);
    expect(a.debugBindingChanges, 2, reason: 'open + salts');
    expect(notified, 1);
    expect(identical(a.kernelIds, idsBefore), isFalse, reason: 're-read');
    // 盐只是加进集合：默认牌组的规范 ID 不变，重取的值相同。
    expect(a.defaultDeckId, deckBefore);
    expect(
      (await a.deckTree()).decks.map((SrsDeckView d) => d.id),
      contains(a.defaultDeckId),
    );

    // 同一批盐再补一次：`same`，不报。
    final Map<String, Object?> same = (await a.sync2Command(<String, Object?>{
      'op': 'collection_salts_add',
      'salts': <String>['01928c3e-0000-7000-8000-0000000000ff'],
      'now': now,
    })).map;
    expect(same['outcome'], 'same');
    await Future<void>.delayed(Duration.zero);
    expect(a.debugBindingChanges, 2);
    expect(notified, 1);
  });
}
