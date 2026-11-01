import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v135：作品图谱 L5 的三张表（docs/specs/2026-10-24-cross-media-links.md §5 / §6）——
/// `game_voice_casts`（设备本地缓存，无外键）、`person_identity_bridges`、
/// `adaptation_progress_anchors`。迁移只建表、重跑幂等；manual 桥两端按字典序规范化；
/// Wikidata 桥整组替换并写自环「查过」标记；对应点 CHECK 拒收非正整数。
void main() {
  const List<String> tables = <String>[
    'game_voice_casts',
    'person_identity_bridges',
    'adaptation_progress_anchors',
  ];
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test('v134 → v135 建三张表；重跑幂等、不清数据', () async {
    final Directory dir = Directory.systemTemp.createTempSync('people_v135');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags();
    await db.close();

    sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String t in tables) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 134');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 143);
    await migrated.upsertGameVoiceCast(
      GameVoiceCastsCompanion.insert(
        gameId: 'g',
        vndbId: 'v17',
        castJson: '[]',
        fetchedAt: 1,
      ),
    );
    await migrated.close();

    raw = sqlite.sqlite3.open(path);
    expect(raw.select('PRAGMA user_version').first.values.first, 143);
    for (final String t in tables) {
      expect(tableExists(raw, t), isTrue, reason: t);
    }
    expect(
      raw.select('PRAGMA foreign_key_list(game_voice_casts)'),
      isEmpty,
      reason: '设备本地缓存不挂外键',
    );
    raw.execute('PRAGMA user_version = 134');
    raw.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getGameVoiceCast('g'))!.vndbId, 'v17');
    await reopened.close();
  });

  test('桥与对应点的读写语义', () async {
    final Directory dir = Directory.systemTemp.createTempSync('people_rw');
    addTearDown(() => dir.deleteSync(recursive: true));
    final FushiDatabase db = FushiDatabase.atFile(
      '${dir.path}/t.db',
      isMainProcess: false,
    );
    addTearDown(db.close);

    await db.setManualPersonBridge('ref:z', 'ref:a', same: true, at: 1);
    await db.setManualPersonBridge('ref:a', 'ref:z', same: false, at: 2);
    final List<PersonIdentityBridgeRow> manual = await db
        .allPersonIdentityBridges();
    expect(manual.single.subject, 'ref:a');
    expect(manual.single.deletedAt, 2, reason: '(A,B) 与 (B,A) 落同一行，否决写墓碑');

    await db.replaceWikidataPersonBridges(<String, Set<String>>{
      'id:anidb:1': <String>{'id:mal:2'},
    }, at: 10);
    await db.replaceWikidataPersonBridges(<String, Set<String>>{
      'id:anidb:1': <String>{},
    }, at: 20);
    final List<PersonIdentityBridgeRow> wd = <PersonIdentityBridgeRow>[
      for (final PersonIdentityBridgeRow b
          in await db.allPersonIdentityBridges())
        if (b.source == PersonIdentityBridgeSource.wikidata) b,
    ];
    expect(wd.single.object, 'id:anidb:1', reason: '旧边整组替换，只剩自环标记');
    expect(wd.single.createdAt, 20);

    const AdaptationProgressPair pair = (
      sourceKind: 'book',
      sourceKey: 'b',
      adaptationKind: 'video_collection',
      adaptationKey: '3',
    );
    AdaptationProgressAnchorsCompanion anchor(int ep, int no) =>
        AdaptationProgressAnchorsCompanion.insert(
          sourceKind: pair.sourceKind,
          sourceKey: pair.sourceKey,
          adaptationKind: pair.adaptationKind,
          adaptationKey: pair.adaptationKey,
          episodeNumber: ep,
          sourceUnit: 'volume',
          sourceNumber: no,
          updatedAt: 1,
        );
    await db.upsertAdaptationProgressAnchor(anchor(13, 4));
    await db.upsertAdaptationProgressAnchor(anchor(1, 1));
    await db.upsertAdaptationProgressAnchor(anchor(13, 5));
    expect(
      (await db.adaptationProgressAnchorsFor(pair)).map(
        (AdaptationProgressAnchorRow r) => (r.episodeNumber, r.sourceNumber),
      ),
      <(int, int)>[(1, 1), (13, 5)],
    );
    await expectLater(
      db.upsertAdaptationProgressAnchor(anchor(0, 1)),
      throwsA(anything),
    );
    expect(await db.deleteAdaptationProgressAnchor(pair, 1), 1);
  });
}
