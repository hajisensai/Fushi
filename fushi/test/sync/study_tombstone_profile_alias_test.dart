import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// BUG-3644（群报 2026-10-21）：电脑下书 → 平板读完 → 统计同步到电脑 → 电脑删这本书
// 的统计 → 电脑没了、平板还在，再怎么同步都不收敛。两端 Profile 名字不同时触发：
// 平板的段在电脑上按名字回退进激活 Profile，电脑立的碑只带电脑的 Profile 名，到平板
// 名字对不上被丢弃；平板的段照常上行，又被电脑的碑挡在门外。
// 修法：落地回退时记「对端名字 → 本机 Profile」别名，导出时碑按别名再发一份。

Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<int> _profile(
  FushiDatabase db,
  String name, {
  bool activate = true,
}) async {
  final int id = await db.insertProfile(
    ProfilesCompanion.insert(name: name, createdAt: 1, updatedAt: 1),
  );
  if (activate) await db.setPref(kActiveProfileIdPrefKey, id.toString());
  return id;
}

StudySegmentsCompanion _seg(String uid, {String key = 'bk'}) =>
    StudySegmentsCompanion.insert(
      uid: uid,
      deviceId: 'tablet',
      mediaKind: kActivityMediaBook,
      mediaKey: key,
      title: '七魔剣',
      startAt: 1000,
      endAt: 2000,
      dateKey: '2026-10-20',
      hour: 12,
      durationMs: const Value<int>(600000),
      chars: const Value<int>(5000),
      updatedAt: 2000,
    );

Future<int> _chars(FushiDatabase db, {String key = 'bk'}) async {
  final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
  return facts.daily
      .where((StatFact f) => f.mediaKey == key)
      .fold<int>(0, (int s, StatFact f) => s + f.chars);
}

Future<void> _rounds(
  FushiDatabase pc,
  FushiDatabase tablet,
  FakeAssetStore store,
) async {
  for (int i = 0; i < 3; i++) {
    await AggregateSyncService(pc).sync(store: store, deviceId: 'pc');
    await AggregateSyncService(tablet).sync(store: store, deviceId: 'tablet');
  }
}

void main() {
  test('删书默认不删统计：同步来的统计在两端都留着', () async {
    final FushiDatabase pc = await _freshDb('alias_keep_pc_');
    final FushiDatabase tablet = await _freshDb('alias_keep_tab_');
    final FakeAssetStore store = FakeAssetStore();
    await _profile(pc, 'Default');
    await _profile(tablet, '默认');
    await pc.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'bk',
        title: '七魔剣',
        epubPath: '/x.epub',
        extractDir: '/x',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    await tablet.upsertStudySegment(_seg('seg1'));
    await _rounds(pc, tablet, store);
    expect(await _chars(pc), 5000);

    await pc.deleteEpubBook('bk', tombstone: true);
    await _rounds(pc, tablet, store);
    expect(await _chars(pc), 5000, reason: '删书不该动统计');
    expect(await _chars(tablet), 5000);
  });

  test('两端 Profile 名不同：电脑删该书统计后两端收敛（BUG-3644）', () async {
    final FushiDatabase pc = await _freshDb('alias_del_pc_');
    final FushiDatabase tablet = await _freshDb('alias_del_tab_');
    final FakeAssetStore store = FakeAssetStore();
    await _profile(pc, 'Default');
    await _profile(tablet, '默认');
    await tablet.upsertStudySegment(_seg('seg1'));
    await tablet.upsertStudySegment(_seg('other', key: 'bk2'));
    await _rounds(pc, tablet, store);
    expect(await _chars(pc), 5000, reason: '平板的段回退进电脑的激活 Profile');

    await pc.deleteReadingStatisticsForTitle('七魔剣', bookKey: 'bk');
    await _rounds(pc, tablet, store);
    expect(await _chars(pc), 0);
    expect(await _chars(tablet), 0, reason: '碑以平板的 Profile 名再发一份，平板才压得到这批段');
    expect(await _chars(pc, key: 'bk2'), 5000, reason: '别的书不受影响');
    expect(await _chars(tablet, key: 'bk2'), 5000);
  });

  test('修复前已分叉的存量（电脑有碑、平板有段、无别名）下一轮自愈', () async {
    final FushiDatabase pc = await _freshDb('alias_heal_pc_');
    final FushiDatabase tablet = await _freshDb('alias_heal_tab_');
    final FakeAssetStore store = FakeAssetStore();
    await _profile(pc, 'Default');
    await _profile(tablet, '默认');
    await tablet.upsertStudySegment(_seg('seg1'));
    await pc.upsertStudySegmentTombstone(
      mediaKind: kActivityMediaBook,
      mediaKey: 'bk',
      deletedAt: 5000,
    );
    expect(await pc.getStudyProfileNameAliases(), isEmpty);

    await _rounds(pc, tablet, store);
    expect(await _chars(pc), 0);
    expect(await _chars(tablet), 0);
  });

  test('别名只在名字对不上时记；碑不发给本机已有的同名 Profile', () async {
    final FushiDatabase pc = await _freshDb('alias_scope_pc_');
    final FushiDatabase tablet = await _freshDb('alias_scope_tab_');
    final FakeAssetStore store = FakeAssetStore();
    final int pcJp = await _profile(pc, 'JP');
    await _profile(pc, 'EN', activate: false);
    await _profile(tablet, 'JP');
    await tablet.upsertStudySegment(_seg('seg1'));
    await _rounds(pc, tablet, store);
    expect(
      await pc.getStudyProfileNameAliases(),
      isEmpty,
      reason: '同名 Profile 精确对上，不记别名',
    );

    // 电脑在 EN（平板没有、也从没往 EN 里落过平板的段）删这本书：碑仍按旧口径
    // 在平板被丢弃，平板 JP 的历史不受牵连。
    await pc.setPref(
      kActiveProfileIdPrefKey,
      (await pc.getAllProfiles())
          .firstWhere((p) => p.name == 'EN')
          .id
          .toString(),
    );
    await pc.deleteStudySegmentsForMedia(
      mediaKind: kActivityMediaBook,
      mediaKey: 'bk',
    );
    await pc.setPref(kActiveProfileIdPrefKey, pcJp.toString());
    await _rounds(pc, tablet, store);
    expect(await _chars(tablet), 5000);
    expect(await _chars(pc), 5000);
  });
}
