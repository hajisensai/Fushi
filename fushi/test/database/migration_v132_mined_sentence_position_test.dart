import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v132：mined_sentences 拆出显式定位列（docs/specs/2026-10-24-cross-media-links.md §4）。
///
/// v132 前视频来源把 norm_char_offset / norm_char_length 复用成 cue 起点 / 时长毫秒；
/// 迁移把 source='video' 的旧值搬进 position_ms / duration_ms 并清空旧列，书域行
/// 原样不动；重跑幂等。
void main() {
  bool columnExists(sqlite.Database raw, String column) => raw
      .select('PRAGMA table_info(mined_sentences)')
      .any((sqlite.Row r) => r['name'] == column);

  Future<String> legacyDbAtV131(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String column in <String>[
      'position_ms',
      'duration_ms',
      'page_index',
    ]) {
      raw.execute('ALTER TABLE mined_sentences DROP COLUMN $column');
    }
    expect(columnExists(raw, 'position_ms'), isFalse);
    // 旧口径的三条行：视频（偏移列装的是毫秒）/ 书（字符偏移）/ 无定位视频。
    raw.execute(
      'INSERT INTO mined_sentences (expression, reading, glossary, sentence, '
      'source, book_key, section_index, norm_char_offset, norm_char_length, '
      'date_key, created_at) VALUES '
      "('雨', 'あめ', '', '雨だ', 'video', 'video/ep1', 2, 61500, 2300, "
      "'2026-10-01', 1), "
      "('雪', 'ゆき', '', '雪国', 'book', 'snow', 3, 120, 4, '2026-10-01', 2), "
      "('風', 'かぜ', '', '', 'video', NULL, NULL, NULL, NULL, '2026-10-01', 3)",
    );
    raw.execute('PRAGMA user_version = 131');
    raw.dispose();
    return path;
  }

  Map<String, sqlite.Row> rowsByExpression(String path) {
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    final Map<String, sqlite.Row> rows = <String, sqlite.Row>{
      for (final sqlite.Row r in probe.select('SELECT * FROM mined_sentences'))
        r['expression'] as String: r,
    };
    probe.dispose();
    return rows;
  }

  test('v131 → v132：视频旧值搬进 position_ms / duration_ms 并清空旧列，书行不动', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mined_v132',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await legacyDbAtV131(directory);

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 137);
    final List<MinedSentenceRow> rows = await migrated.getAllMinedSentences();
    expect(rows, hasLength(3));
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 137);
    for (final String column in <String>[
      'position_ms',
      'duration_ms',
      'page_index',
    ]) {
      expect(columnExists(probe, column), isTrue, reason: column);
    }
    probe.dispose();

    final Map<String, sqlite.Row> byExpr = rowsByExpression(path);
    final sqlite.Row video = byExpr['雨']!;
    expect(video['position_ms'], 61500);
    expect(video['duration_ms'], 2300);
    expect(video['norm_char_offset'], isNull, reason: '旧列不再一列两义');
    expect(video['norm_char_length'], isNull);
    expect(video['section_index'], 2, reason: '集下标不动');

    final sqlite.Row book = byExpr['雪']!;
    expect(book['norm_char_offset'], 120);
    expect(book['norm_char_length'], 4);
    expect(book['position_ms'], isNull);
    expect(book['duration_ms'], isNull);

    final sqlite.Row bare = byExpr['風']!;
    expect(bare['position_ms'], isNull);
    expect(bare['norm_char_offset'], isNull);
  });

  test('重跑 v132 步幂等：已搬过的行不被二次改写', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mined_v132_rerun',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await legacyDbAtV131(directory);
    final FushiDatabase first = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await first.getAllMinedSentences();
    await first.close();

    // 回退版本号重跑：列已在、视频行 position_ms 已非空，都应跳过。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 131');
    raw.dispose();
    final FushiDatabase second = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await second.getAllMinedSentences();
    await second.close();

    final Map<String, sqlite.Row> byExpr = rowsByExpression(path);
    expect(byExpr['雨']!['position_ms'], 61500);
    expect(byExpr['雨']!['duration_ms'], 2300);
    expect(byExpr['雪']!['norm_char_offset'], 120);
  });

  test('addMinedSentence 新列各司其职（视频 / 音乐 / 漫画 / 游戏）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.addMinedSentence(
      source: 'video',
      dateKey: '2026-10-24',
      bookKey: 'video/ep',
      sectionIndex: 1,
      positionMs: 1000,
      durationMs: 500,
    );
    await db.addMinedSentence(
      source: 'music',
      dateKey: '2026-10-24',
      bookKey: 'track-uid',
      positionMs: 42000,
      durationMs: 3000,
    );
    await db.addMinedSentence(
      source: 'manga',
      dateKey: '2026-10-24',
      bookKey: 'manga-key',
      pageIndex: 7,
    );
    await db.addMinedSentence(
      source: 'game',
      dateKey: '2026-10-24',
      bookKey: '1700000000000000',
    );
    final Map<String, MinedSentenceRow> bySource = <String, MinedSentenceRow>{
      for (final MinedSentenceRow r in await db.getAllMinedSentences())
        r.source: r,
    };
    expect(bySource['video']!.positionMs, 1000);
    expect(bySource['video']!.durationMs, 500);
    expect(bySource['video']!.normCharOffset, isNull);
    expect(bySource['music']!.positionMs, 42000);
    expect(bySource['manga']!.pageIndex, 7);
    expect(bySource['game']!.bookKey, '1700000000000000');
  });

  test('时间轴来源误传字符偏移被断言拦下', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      () => db.addMinedSentence(
        source: 'video',
        dateKey: '2026-10-24',
        normCharOffset: 1000,
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
