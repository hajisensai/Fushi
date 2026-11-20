import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v163：`media_link_ai_verdicts`——作品图谱 AI 裁决的本机缓存。纯建表、幂等；设备
/// 本地缓存不挂外键；同一对端点只留最新一条；按裁决时刻过期清理。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_v163_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  bool tableExists(sqlite.Database db, String name) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[name],
  ).isNotEmpty;

  MediaLinkAiVerdictsCompanion row({
    required int judgedAt,
    String bKey = '1',
    bool related = false,
    String fingerprint = 'f1',
  }) => MediaLinkAiVerdictsCompanion.insert(
    aKind: 'game',
    aKey: 'g',
    bKind: 'video_collection',
    bKey: bKey,
    fingerprint: fingerprint,
    related: related,
    relation: Value<String?>(related ? 'adaptation' : null),
    aIsOriginal: Value<bool?>(related ? true : null),
    confidence: 0.8,
    judgedAt: judgedAt,
  );

  test('v162 → v163 建表；重跑不报错不清数据；无外键', () async {
    final String path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE media_link_ai_verdicts');
    raw.execute('PRAGMA user_version = 162');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 164);
    await migrated.upsertMediaLinkAiVerdicts(<MediaLinkAiVerdictsCompanion>[
      row(judgedAt: 100, related: true),
    ]);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 164);
    expect(tableExists(probe, 'media_link_ai_verdicts'), isTrue);
    expect(
      probe.select('PRAGMA foreign_key_list(media_link_ai_verdicts)'),
      isEmpty,
      reason: '设备本地缓存不挂外键',
    );
    // 重跑 v163 步：表已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 162');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final MediaLinkAiVerdictRow kept = (await reopened.mediaLinkAiVerdictsSince(
      0,
    )).single;
    expect(kept.related, isTrue);
    expect(kept.relation, 'adaptation');
    expect(kept.aIsOriginal, isTrue);
    expect(kept.reason, '');
    await reopened.close();
  });

  test('同一对端点覆盖成最新一条；按裁决时刻读取与清理', () async {
    final FushiDatabase db = FushiDatabase.atFile(
      p.join(tmp.path, 'fushi.db'),
      isMainProcess: false,
    );
    addTearDown(db.close);
    await db.upsertMediaLinkAiVerdicts(<MediaLinkAiVerdictsCompanion>[
      row(judgedAt: 100),
      row(judgedAt: 200, bKey: '2'),
    ]);
    await db.upsertMediaLinkAiVerdicts(<MediaLinkAiVerdictsCompanion>[
      row(judgedAt: 300, related: true, fingerprint: 'f2'),
    ]);
    final List<MediaLinkAiVerdictRow> all = await db.mediaLinkAiVerdictsSince(
      0,
    );
    expect(all, hasLength(2));
    final MediaLinkAiVerdictRow first = all.firstWhere(
      (MediaLinkAiVerdictRow r) => r.bKey == '1',
    );
    expect(first.fingerprint, 'f2');
    expect(first.related, isTrue);
    expect(await db.mediaLinkAiVerdictsSince(250), hasLength(1));
    expect(await db.pruneMediaLinkAiVerdicts(250), 1);
    expect((await db.mediaLinkAiVerdictsSince(0)).single.bKey, '1');
  });
}
