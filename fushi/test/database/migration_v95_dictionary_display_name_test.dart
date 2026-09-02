import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v95（词典改名）：`dictionary_metadata` 加 `display_name`——用户给词典起的
/// 显示名。真名 `name` 是主键 + 磁盘目录名 + C++ 引擎装载路径，还被每词典 CSS、
/// 样式规则、弹窗 `data-dictionary` 选择器、词典媒体 URL、Anki
/// `{single-glossary-<名>}` token、存储占用条目 id 和同步资产名当键，冻结不动。
///
/// 守三件事：从真实 v94 库出发列会补上；存量词典行无损（尤其 name 一个字节
/// 都不许动——动了就是全库换身份）；新列默认 NULL = 没改过名 = 显示真名 =
/// 逐字节保留 v95 前的渲染。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v95_display_name');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v94-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实的 v94 形状库：当前 schema 建满，摘掉 display_name，版本写回 94。
  Future<void> seedV94() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await fresh.customStatement(
      'INSERT INTO dictionary_metadata (name, format_key, "order", type, '
      'metadata_json, hidden_languages_json, collapsed_languages_json, '
      'language_override) '
      "VALUES ('JMdict [2026-05-17]', 'yomitan', 0, 'term', "
      '\'{"revision":"2026-05-17"}\', \'["en"]\', \'["ja"]\', \'ja\')',
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE dictionary_metadata DROP COLUMN display_name');
      raw.execute('PRAGMA user_version = 94');
    } finally {
      raw.dispose();
    }
  }

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  test('v94 库确实缺 display_name（前提自检）', () async {
    await seedV94();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 94);
      expect(
        hasColumn(probe, 'dictionary_metadata', 'display_name'),
        isFalse,
        reason: '前提不成立的话下面那条迁移断言测的是空气',
      );
    } finally {
      probe.dispose();
    }
  });

  test('v94 -> v95：补列、默认 NULL、存量词典行无损', () async {
    await seedV94();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    final List<DictionaryMetaRow> rows =
        await migrated.getAllDictionaryMetadata();
    expect(rows, hasLength(1), reason: '迁移丢一行就是丢一本词典');

    final DictionaryMetaRow row = rows.single;
    expect(
      row.name,
      'JMdict [2026-05-17]',
      reason: '真名是主键+磁盘目录名+引擎装载路径，迁移一个字节都不许动',
    );
    expect(
      row.displayName,
      isNull,
      reason: 'NULL = 没改过名 → 显示真名 → 逐字节保留 v95 前的渲染',
    );
    // 同属「用户设置」的邻居列不能被这一步碰掉。
    expect(row.languageOverride, 'ja');
    expect(row.hiddenLanguagesJson, '["en"]');
    expect(row.collapsedLanguagesJson, '["ja"]');
    expect(row.metadataJson, '{"revision":"2026-05-17"}');
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 95);
      expect(hasColumn(probe, 'dictionary_metadata', 'display_name'), isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('迁移后能真的写进改名，且真名仍是那把键', () async {
    await seedV94();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await migrated.upsertDictionaryMeta(
      DictionaryMetadataCompanion.insert(
        name: 'JMdict [2026-05-17]',
        formatKey: 'yomitan',
        order: 0,
        displayName: const Value<String?>('日汉大辞典'),
      ),
    );
    final List<DictionaryMetaRow> rows =
        await migrated.getAllDictionaryMetadata();
    expect(
      rows,
      hasLength(1),
      reason: '按主键 upsert：改名走同一行，不留孤儿',
    );
    expect(rows.single.displayName, '日汉大辞典');
    expect(rows.single.name, 'JMdict [2026-05-17]');
    await migrated.close();
  });

  test('重复打开幂等：第二次开库不因列已存在而报错', () async {
    await seedV94();

    final FushiDatabase first =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    expect(await second.getAllDictionaryMetadata(), hasLength(1));
    await second.close();
  });
}
