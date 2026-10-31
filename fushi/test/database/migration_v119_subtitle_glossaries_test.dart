import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v119（视频字幕 AI 校对，spec 2026-10-19-video-asr-llm-subtitle-pipeline 第 3 节 S0）：
/// ① `video_metadata_characters.original_name`（角色日文原名，存量行 NULL）；
/// ② 新表 `video_subtitle_glossaries`（作品级专名表）。
///
/// 存量角色行原样保留、新列为 NULL；重跑本步幂等（列 / 表已在不重复建、不清数据）。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  /// 建当前 schema 的库写入一条存量角色行，再退回 v118 形态（去列、删表）。
  Future<String> createV118Db(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
      VideoMetadataCharactersCompanion.insert(
        characterKey: 'character:mal:7',
        name: 'Hirasawa, Yui',
        description: const Value<String?>('Guitar'),
        updatedAt: 1000,
      ),
    ]);
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'ALTER TABLE video_metadata_characters DROP COLUMN original_name',
    );
    raw.execute('DROP TABLE video_subtitle_glossaries');
    expect(
      columnsOf(raw, 'video_metadata_characters'),
      isNot(contains('original_name')),
    );
    expect(tableExists(raw, 'video_subtitle_glossaries'), isFalse);
    raw.execute('PRAGMA user_version = 118');
    raw.dispose();
    return path;
  }

  test('v118 → v119 加 original_name 列（存量行 NULL）并建专名表；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'subtitle_glossaries_v119',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createV118Db(directory);

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 142);
    final VideoMetadataCharacterRow? character = await migrated
        .getVideoMetadataCharacter('character:mal:7');
    expect(character?.name, 'Hirasawa, Yui');
    expect(character?.description, 'Guitar');
    expect(character?.originalName, isNull, reason: '存量行不编造日文名');

    // 新列走 upsert 只补空：给了值就写上，下一轮没给（null）不冲掉。
    await migrated
        .upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
          VideoMetadataCharactersCompanion.insert(
            characterKey: 'character:mal:7',
            name: 'Hirasawa, Yui',
            originalName: const Value<String?>('平沢 唯'),
            updatedAt: 2000,
          ),
        ]);
    await migrated
        .upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
          VideoMetadataCharactersCompanion.insert(
            characterKey: 'character:mal:7',
            name: 'Hirasawa, Yui',
            updatedAt: 3000,
          ),
        ]);
    expect(
      (await migrated.getVideoMetadataCharacter(
        'character:mal:7',
      ))?.originalName,
      '平沢 唯',
    );

    await migrated.upsertVideoSubtitleGlossary(
      VideoSubtitleGlossariesCompanion.insert(
        workKey: 'collection:1',
        glossaryJson: '{"entries":[]}',
        userEditedAt: const Value<int?>(5),
        updatedAt: 6,
      ),
    );
    final VideoSubtitleGlossaryRow? glossary = await migrated
        .getVideoSubtitleGlossary('collection:1');
    expect(glossary?.glossaryJson, '{"entries":[]}');
    expect(glossary?.sourceFingerprint, '', reason: '默认空串');
    expect(glossary?.userEditedAt, 5);
    expect(glossary?.updatedAt, 6);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 142);
    expect(
      columnsOf(probe, 'video_metadata_characters'),
      contains('original_name'),
    );
    expect(columnsOf(probe, 'video_subtitle_glossaries'), <String>{
      'work_key',
      'glossary_json',
      'source_fingerprint',
      'user_edited_at',
      'updated_at',
    });
    final List<sqlite.Row> pk = probe
        .select("PRAGMA table_info('video_subtitle_glossaries')")
        .where((sqlite.Row r) => (r['pk'] as int) > 0)
        .toList();
    expect(pk.map((sqlite.Row r) => r['name']), <String>['work_key']);

    // 重跑 v119 步：列与表都已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 118');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await reopened.getVideoSubtitleGlossary('collection:1'))?.updatedAt,
      6,
    );
    expect(
      (await reopened.getVideoMetadataCharacter(
        'character:mal:7',
      ))?.originalName,
      '平沢 唯',
    );
    await reopened.close();

    final sqlite.Database probe2 = sqlite.sqlite3.open(path);
    addTearDown(probe2.dispose);
    expect(probe2.select('PRAGMA user_version').first.values.first, 142);
  });
}
