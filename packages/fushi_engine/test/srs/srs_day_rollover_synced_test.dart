// 复习的「今天」：翻日时刻随 profile 同步、时区恒用本机（所有者 2026-11-10 拍板）。
//
// - 翻日时刻：用户改日界时写成 profile 的 `dayRolloverHour` 字段修改，随同步 v2 传到别的设备，多设备的「今天」一致；
//   从没写过时仍回落到宿主给的值（单设备用户升级后行为不变）。
// - 时区：只取本机偏移；旧版本声明过的 profile 键 `utcOffsetMin` 即使库里有值也不再影响结果。
// - 改了翻日时刻后，依赖「今天」的常驻状态（Dart 侧 profile 修改记录缓存、Rust 内核的复习会话与每日上限计数）跟着变。
//
// 走真实路径：真 store + Rust 内核 + 内存同步位置。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000d4011';

void main() {
  int t = DateTime.utc(2026, 11, 10, 5).millisecondsSinceEpoch;

  setUp(() => t = DateTime.utc(2026, 11, 10, 5).millisecondsSinceEpoch);

  Future<SrsDbStore> device(
    String id, {
    required int fallbackRollover,
    int localOffset = 0,
  }) async {
    final SrsStorage storage = await openTestSrsStorage();
    return SrsDbStore.open(
      core: storage.core,
      profileUid: _profile,
      deviceId: id,
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
      fallbackRolloverHour: () => fallbackRollover,
      localOffsetMin: () => localOffset,
    );
  }

  test('没写过翻日时刻：回落到宿主给的值，时区取本机', () async {
    final SrsDbStore s = await device(
      'a',
      fallbackRollover: 7,
      localOffset: 540,
    );
    expect((await s.syncedDayRollover())?.hour, isNull);
    final SrsDayContext day = await s.dayContext();
    expect(day.rolloverHour, 7);
    expect(day.utcOffsetMin, 540);
  });

  test('写入后本机 dayContext 立刻取到新值；同值再写不产生记录', () async {
    final SrsDbStore s = await device('a', fallbackRollover: 4);
    expect((await s.dayContext()).rolloverHour, 4, reason: '先把缓存填上');
    final SrsDayRollover? written = await s.setDayRolloverHour(6);
    expect(written?.hour, 6);
    expect((await s.syncedDayRollover())?.editId, written?.editId);
    expect((await s.dayContext()).rolloverHour, 6, reason: '写入推进修订号，缓存失效');
    final int ops = (await s.sync2Status())['ops']! as int;
    await s.setDayRolloverHour(6);
    expect((await s.sync2Status())['ops'], ops, reason: '与现值相同不写');
  });

  test('另一台设备经同步收到该字段后取到同一个值（各自的回落值不再起作用）', () async {
    final SrsDbStore a = await device('a', fallbackRollover: 4);
    final SrsDbStore b = await device(
      'b',
      fallbackRollover: 0,
      localOffset: -300,
    );
    await a.setDayRolloverHour(6);
    await srsSyncPeers(<SrsDbStore>[a, b], SrsMemoryLocationStore(), rounds: 3);
    expect((await b.syncedDayRollover())?.hour, 6);
    expect(
      (await b.syncedDayRollover())?.editId,
      (await a.syncedDayRollover())!.editId,
      reason: '两边生效的是同一条修改记录：宿主据此分辨「新来的修改」',
    );
    final SrsDayContext day = await b.dayContext();
    expect(day.rolloverHour, 6);
    expect(day.utcOffsetMin, -300, reason: '时区不随同步，仍是 b 的本机偏移');
  });

  test('库里存量的 profile utcOffsetMin 不再影响结果', () async {
    final SrsDbStore s = await device(
      'a',
      fallbackRollover: 4,
      localOffset: 480,
    );
    await s.editField(SrsEntityKind.profile, _profile, 'utcOffsetMin', -600);
    expect((await s.dayContext()).utcOffsetMin, 480);
  });

  test('改翻日时刻后内核的「今天」跟着变：每日新卡上限按新日界数今天已学', () async {
    final SrsDbStore s = await device('a', fallbackRollover: 4);
    final String deck = await s.ensureDeckPath('Root');
    await s.editField(
      SrsEntityKind.deck,
      deck,
      SrsFieldKeys.deckLimits,
      <String, Object?>{'new': 1, 'review': 100},
    );
    Future<String> newCard(String word) async {
      final String note = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(_profile, 'Expression'): word,
        },
        deckId: deck,
      );
      return (await s.cardsOfNote(note)).single.id;
    }

    final String first = await newCard('一');
    await newCard('二');
    // 03:00 UTC 学一张新卡：翻日 4 点时它算前一天。
    t = DateTime.utc(2026, 11, 10, 3).millisecondsSinceEpoch;
    await s.answer(first, 3, durationMs: 1000);
    t = DateTime.utc(2026, 11, 10, 5).millisecondsSinceEpoch;
    Future<int> newCount() async => (await s.deckSummaries())
        .singleWhere((SrsDeckSummary d) => d.deck.id == deck)
        .newCount;
    expect(await newCount(), 1, reason: '翻日 4 点：今天还没学新卡');

    await s.setDayRolloverHour(2);
    expect(await newCount(), 0, reason: '翻日 2 点：03:00 那张算今天，上限 1 已用完');

    await s.setDayRolloverHour(4);
    expect(await newCount(), 1, reason: '改回 4 点又是新的一天');
  });
}
