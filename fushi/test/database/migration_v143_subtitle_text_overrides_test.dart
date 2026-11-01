import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v143：新表 `video_subtitle_text_overrides`（用户在字幕列表里手改的单条字幕文本，
/// 反馈 gleDreKAvo / dpAsMkUjKT）。纯新增：升级建表、不碰存量数据；建过的库幂等跳过。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  bool hasTable(sqlite.Database raw) => raw
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='video_subtitle_text_overrides'",
      )
      .isNotEmpty;

  VideoSubtitleTextOverridesCompanion row(
    String edited, {
    int startMs = 1000,
  }) => VideoSubtitleTextOverridesCompanion.insert(
    videoKey: 'vid-uid',
    sourceKey: 'file:ep01.srt',
    startMs: startMs,
    originalText: '元の字幕',
    editedText: edited,
    updatedAt: 1,
  );

  test('v142 → v143：建出覆盖表，存量视频书原样，读写删可用', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'subeditv143',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v142 形态：没有这张表；存一本视频书作为「升级不碰存量」的见证。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE video_subtitle_text_overrides');
    raw.execute(
      'INSERT INTO video_books (book_uid, title, video_path) '
      "VALUES ('vid-uid', 'Video', '/v/ep01.mkv')",
    );
    raw.execute('PRAGMA user_version = 142');
    expect(hasTable(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 143);
    await migrated.upsertVideoSubtitleTextOverride(row('直した字幕'));
    // 同一句再改一次是覆盖，不是第二行。
    await migrated.upsertVideoSubtitleTextOverride(row('もう一度直した'));
    final List<VideoSubtitleTextOverrideRow> rows = await migrated
        .getVideoSubtitleTextOverrides(
          videoKey: 'vid-uid',
          sourceKey: 'file:ep01.srt',
        );
    expect(rows, hasLength(1));
    expect(rows.single.editedText, 'もう一度直した');
    expect(
      await migrated.getVideoSubtitleTextOverrides(
        videoKey: 'vid-uid',
        sourceKey: 'embedded:2',
      ),
      isEmpty,
      reason: '换了字幕源就是另一层覆盖',
    );
    expect(
      await migrated.deleteVideoSubtitleTextOverride(
        videoKey: 'vid-uid',
        sourceKey: 'file:ep01.srt',
        startMs: 1000,
        originalText: '元の字幕',
      ),
      1,
    );
    expect(
      await migrated.getVideoSubtitleTextOverrides(
        videoKey: 'vid-uid',
        sourceKey: 'file:ep01.srt',
      ),
      isEmpty,
    );
    expect(
      (await migrated
              .customSelect(
                "SELECT COUNT(*) AS c FROM video_books WHERE book_uid = 'vid-uid'",
              )
              .getSingle())
          .read<int>('c'),
      1,
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
    expect(hasTable(probe), isTrue);
  });

  test('v143 步幂等：表已在（按当前定义建的库）时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'subeditv143idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.upsertVideoSubtitleTextOverride(
      row('直した字幕').copyWith(updatedAt: const Value<int>(7)),
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 142');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final List<VideoSubtitleTextOverrideRow> rows = await migrated
        .getVideoSubtitleTextOverrides(
          videoKey: 'vid-uid',
          sourceKey: 'file:ep01.srt',
        );
    expect(rows.single.editedText, '直した字幕');
    expect(rows.single.updatedAt, 7);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
  });
}
