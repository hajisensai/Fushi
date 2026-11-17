// 牌组页「每日上限单位改缺省」提醒的计数（srsLimitUnitLegacyCountProvider）按库的指纹复用上次结果：评分只落今天的日志，
// 不必重扫；但它取决于改缺省之前的复习，一批只含旧复习日志的同步并进来时必须重算（内容指纹在这种合并下不变）。
//
// 两份内存库模拟两台设备（同一 profile、不同设备号，所以是同一个集合），经同一个同步位置跑真的同步一轮合并
// （新代生产路径：收段落进来的操作）。W3 合流时改成了 `.fushisrs` 导入（不是生产上「只同步进来旧日志」的那条路），
// 这里改回同步一轮（G9-5 续 ⑥）。协议 3 的前提「只并入复习日志不推进内容指纹」在新代反过来了：收段只要落了东西，
// 内核就把刷新键整份作废（`gen4/cmd/sync.rs` `Tally::all()`），内容指纹本身推进，develop 那次修复拼上的 RWKV 键
// （合并信号）成了冗余的保险。所以这里断言新代的前提「只并进旧复习日志也推进内容指纹」——撤掉合并信号仍然绿是
// 预期的，那一半由这条前提顶替；内核哪天不再因收段推进内容指纹，这条前提先红。回归本身由结果钉住：合并前算过一次 0
// 并缓存，合并后必须是 1。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';

import 'srs_test_support.dart';

/// 经同一个位置 [location] 先 [from] 后 [to] 各跑一轮同步（[to] 收到 [from] 的新操作）。
Future<void> _ship(
  SrsMemoryLocationStore location,
  SrsDbStore from,
  SrsDbStore to,
) async {
  for (final SrsDbStore s in <SrsDbStore>[from, to]) {
    final SrsSync2Report r = await srsSync2Round(
      host: s,
      location: location,
      locationId: 'test',
      nowMs: () => s.now().$1,
    );
    expect(r.error, isNull);
  }
}

Future<int> _count(ProviderContainer container) async {
  container.read(srsRevisionProvider.notifier).state++;
  return container.read(srsLimitUnitLegacyCountProvider.future);
}

void main() {
  test('只同步进来改缺省之前的复习日志：提醒计数重算，不沿用合并前的结果；本机评分不重扫', () async {
    // 测试时钟（2026-10-01）在改缺省（kSrsLimitUnitDefaultChangedAtMs）之前。
    final SrsTestClock clock = SrsTestClock();
    final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
      deviceId: 'dev-a',
      clock: clock,
    );
    addTearDown(dbA.close);
    final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
      deviceId: 'dev-b',
      clock: clock,
    );
    addTearDown(dbB.close);
    final SrsMemoryLocationStore location = SrsMemoryLocationStore();

    final String note = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(a.profileUid, 'Expression'): '聞く',
      },
    );
    final String card = (await a.cardsOfNote(note)).single.id;
    // 先把笔记 / 卡片同步过去：B 有这张卡，但还没有任何复习。
    await _ship(location, a, b);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        srsStoreProvider.overrideWith((Ref ref) async => b),
      ],
    );
    addTearDown(container.dispose);
    expect(await _count(container), 0);

    // A 在改缺省之前评了分；这一批只多出这条复习日志。
    clock.advance(const Duration(minutes: 1));
    await a.answer(card, 3);
    final String beforeMerge = b.contentFingerprint;
    await _ship(location, a, b);
    expect(
      b.contentFingerprint,
      isNot(beforeMerge),
      reason: '新代前提：只并进复习日志的一轮收段也推进内容指纹（合并信号因此冗余）',
    );
    expect(await b.limitUnitLegacyDecks(), <String>{b.defaultDeckId});
    expect(await _count(container), 1);

    // 本机评分只落日志：结果不变。
    final Future<int> first = container.read(
      srsLimitUnitLegacyCountProvider.future,
    );
    clock.advance(const Duration(minutes: 1));
    await b.answer(card, 3);
    container.read(srsRevisionProvider.notifier).state++;
    final Future<int> second = container.read(
      srsLimitUnitLegacyCountProvider.future,
    );
    expect(await second, 1);
    expect(await first, 1);
  });
}
