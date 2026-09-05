import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v96（BUG-2158 词典折叠三态）：`dictionary_metadata` 加 `expanded_languages_json`。
///
/// 守三件事：
///  1. 从真实 v95 库出发这一列会被加出来；
///  2. 存量词典行一行不丢、既有 `collapsed_languages_json` 原样保留；
///  3. **新列升级后是 `'[]'` 而不是 NULL**——这条是「Never break userspace」的落点：
///     空名单 = 全部「继承」= 逐字节保持 v96 前的折叠行为。若 default 没生效读成
///     NULL，`_rowToDictionary` 的 jsonDecode 会抛、被 catch 吞成 []，行为碰巧也对，
///     但每次加载都往错误日志里灌一条——所以这里直接钉住 `'[]'`。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v96_dict_expanded');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v95-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  /// 建一个真实的 v95 形状库：当前 schema 建满、塞一本存量词典（显式折叠了 ja），
  /// 再把新列 DROP 掉、版本写回 95。
  Future<void> seedV95() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await fresh.customStatement(
      'INSERT INTO dictionary_metadata '
      '(name, format_key, "order", type, metadata_json, '
      'hidden_languages_json, collapsed_languages_json, '
      'expanded_languages_json) '
      "VALUES ('明鏡国語辞典', 'yomichan', 3, 'term', '{}', "
      '\'[]\', \'["ja"]\', \'[]\')',
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute(
          'ALTER TABLE dictionary_metadata DROP COLUMN expanded_languages_json');
      raw.execute('PRAGMA user_version = 95');
    } finally {
      raw.dispose();
    }
  }

  test('v95 库确实没有 expanded_languages_json（前提自检）', () async {
    await seedV95();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 95);
      expect(hasColumn(probe, 'dictionary_metadata', 'expanded_languages_json'),
          isFalse);
      expect(
          hasColumn(probe, 'dictionary_metadata', 'collapsed_languages_json'),
          isTrue,
          reason: '存量列还在');
    } finally {
      probe.dispose();
    }
  });

  test('v95 -> v96：加列、存量词典无损、新列默认 [] = 全部继承', () async {
    await seedV95();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);

    final List<DictionaryMetaRow> dicts =
        await migrated.select(migrated.dictionaryMetadata).get();
    expect(dicts, hasLength(1), reason: '迁移丢一行就是丢一本词典的全部用户设置');
    expect(dicts.single.name, '明鏡国語辞典');
    expect(dicts.single.order, 3, reason: '排序是用户拖出来的，不能被迁移动到');
    expect(dicts.single.collapsedLanguagesJson, '["ja"]',
        reason: '既有的显式折叠必须原样保留');
    expect(dicts.single.expandedLanguagesJson, '[]',
        reason: '新列默认空名单 = 全部继承 = 与升级前的折叠行为逐字节一致');

    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 96);
      expect(hasColumn(probe, 'dictionary_metadata', 'expanded_languages_json'),
          isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('迁移后新列可正常读写', () async {
    await seedV95();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await migrated.customStatement(
      "UPDATE dictionary_metadata SET expanded_languages_json = '[\"ja\"]' "
      "WHERE name = '明鏡国語辞典'",
    );
    final List<DictionaryMetaRow> dicts =
        await migrated.select(migrated.dictionaryMetadata).get();
    expect(dicts.single.expandedLanguagesJson, '["ja"]');
    await migrated.close();
  });
}
