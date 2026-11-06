import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 备份导出的「表归属」守卫：schema 里每张表都必须在 [backupTableRules] 登记去向。
///
/// 回归背景：以前只有被某段剥离逻辑点名的表才受类别勾选约束，32 张没人点名的表
/// （剪贴板历史、最近打开流、视频刮削缓存、AniDB 文件路径、注音揭示状态……）
/// 不管勾什么都整份随包出境——「只导出词典 + 本地音频」的推荐包实测带出了剪贴板、
/// 同步记录与媒体缓存。
/// 带 CHECK 约束的列：通用填值过不了约束，按 `表.列` 给合法值。
const Map<String, Object> _checkedColumnValues = <String, Object>{
  'anidb_file_identities.ed2k': '0123456789abcdef0123456789abcdef',
};

void main() {
  /// 无外键的表：可以直接塞一行带标记的数据，覆盖本次新登记的大部分表。
  const List<String> seededTables = <String>[
    'clipboard_history',
    'media_open_history',
    'anki_mappings',
    'anidb_file_identities',
    'video_metadata_people',
    'video_metadata_characters',
    'video_metadata_terms',
    'video_subtitle_glossaries',
    'video_subtitle_text_overrides',
    'series',
    'media_tracking_mappings',
    'revealed_images',
    'manga_chapter_states',
    'manga_reader_overrides',
    'book_custom_css',
    'collection_book_aliases',
  ];

  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('table_rules_');
  });
  tearDown(() async {
    if (work.existsSync()) await cleanupTempDir(work);
  });

  int seq = 0;

  Future<int> count(FushiDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
          .read<int>('c');

  /// 按 `PRAGMA table_info` 填满所有无默认值的 NOT NULL 列，文本列一律写入
  /// 含 [marker] 的值，方便定位泄漏来源。
  Future<void> insertMarkedRow(
    FushiDatabase db,
    String table,
    String marker,
  ) async {
    final columns = await db.customSelect('PRAGMA table_info($table)').get();
    final List<String> names = <String>[];
    final List<Object> values = <Object>[];
    for (final row in columns) {
      final String name = row.read<String>('name');
      final String type = row.read<String>('type').toUpperCase();
      final bool notNull = row.read<int>('notnull') == 1;
      final bool hasDefault = row.data['dflt_value'] != null;
      final bool intPk = row.read<int>('pk') > 0 && type.contains('INT');
      if (intPk && columns.where((c) => c.read<int>('pk') > 0).length == 1) {
        continue; // rowid 别名，自增
      }
      if (!notNull && !type.contains('TEXT')) continue;
      if (hasDefault && !type.contains('TEXT')) continue;
      names.add('"$name"');
      values.add(
        _checkedColumnValues['$table.$name'] ??
            (type.contains('TEXT') ? '${marker}_$name' : 1),
      );
    }
    await db.customStatement(
      'INSERT INTO $table (${names.join(', ')}) '
      'VALUES (${List<String>.filled(names.length, '?').join(', ')})',
      values,
    );
  }

  Future<({BackupService service, FushiDatabase db})> buildSource(
    String marker,
  ) async {
    final String dbDir = p.join(work.path, 'src${seq++}');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final String table in seededTables) {
      await insertMarkedRow(db, table, marker);
    }
    return (
      service: BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0'),
      db: db,
    );
  }

  Future<FushiDatabase> openExported(String zipPath) async {
    final Archive archive = ZipDecoder().decodeBytes(
      await File(zipPath).readAsBytes(),
    );
    final Directory dir = Directory(p.join(work.path, 'ex${seq++}'))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, 'fushi.db'),
    ).writeAsBytesSync(archive.findFile('fushi.db')!.content as List<int>);
    return FushiDatabase(dir.path);
  }

  test('every schema table has exactly one backup rule', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Set<String> schema = db.allTables
        .map((t) => t.actualTableName)
        .toSet();
    final Set<String> ruled = backupTableRules.keys.toSet();
    expect(
      schema.difference(ruled),
      isEmpty,
      reason:
          '新表必须在 backupTableRules 登记它随备份的去向，'
          '否则无论用户勾什么类别都会整份出境',
    );
    expect(
      ruled.difference(schema),
      isEmpty,
      reason: 'backupTableRules 里有 schema 已不存在的表',
    );
  });

  test('rules agree with the named strip lists', () {
    final Map<String, List<String>> lists = backupNamedTableListsForTesting;
    Set<String> withFate(BackupTableFate fate) => <String>{
      for (final e in backupTableRules.entries)
        if (e.value.fate == fate) e.key,
    };
    final Set<String> deviceLocal = withFate(BackupTableFate.deviceLocal);
    expect(lists['deviceLocal']!.toSet(), deviceLocal);
    expect(
      lists['deviceLocalParentFirst']!.toSet(),
      lists['deviceLocal']!.toSet(),
    );
    for (final String t in lists['statistics']!) {
      expect(backupTableRules[t]!.categories, <BackupCategory>{
        BackupCategory.statistics,
      }, reason: t);
    }
    // SRS 的表不在主库里（归 Rust 的 srs.db，随「复习」类别以 zip 条目 `srs.db` 快照走），
    // 不在这张表里登记。
    expect(
      backupTableRules.keys.where((String t) => t.startsWith('srs_')),
      isEmpty,
    );
    for (final e in backupTableRules.entries) {
      if (e.value.fate == BackupTableFate.followsCategories) {
        expect(e.value.categories, isNotEmpty, reason: e.key);
      }
    }
  });

  test('dictionary + local-audio export carries no row of any category-owned, '
      'device-local or private-trace table', () async {
    final built = await buildSource('PRIVATE');
    final String zip = p.join(work.path, 'pack.zip');
    await built.service.createBackup(
      zip,
      categories: <BackupCategory>{
        BackupCategory.dictionary,
        BackupCategory.localAudio,
      },
    );
    await built.db.close();

    final FushiDatabase ex = await openExported(zip);
    addTearDown(ex.close);
    for (final e in backupTableRules.entries) {
      if (e.value.fate == BackupTableFate.rowLevel) continue;
      expect(await count(ex, e.key), 0, reason: '${e.key} 不该随词典包出境');
    }
  });

  test(
    'full export keeps category-owned rows but never the clipboard',
    () async {
      final built = await buildSource('KEEP');
      final String zip = p.join(work.path, 'full.zip');
      await built.service.createBackup(zip);
      await built.db.close();

      final FushiDatabase ex = await openExported(zip);
      addTearDown(ex.close);
      for (final String table in seededTables) {
        final BackupTableRule rule = backupTableRules[table]!;
        expect(
          await count(ex, table),
          rule.fate == BackupTableFate.followsCategories ? 1 : 0,
          reason: table,
        );
      }
    },
  );

  test('overwrite import of a settings-excluded backup keeps this device '
      'anki mappings and clipboard history', () async {
    final built = await buildSource('SRC');
    final String zip = p.join(work.path, 'nosettings.zip');
    await built.service.createBackup(
      zip,
      categories: BackupCategory.values.toSet()
        ..remove(BackupCategory.settings),
    );
    await built.db.close();

    final String curDir = p.join(work.path, 'cur', 'support');
    Directory(curDir).createSync(recursive: true);
    final FushiDatabase cur0 = FushiDatabase(curDir);
    await insertMarkedRow(cur0, 'anki_mappings', 'MINE');
    await insertMarkedRow(cur0, 'clipboard_history', 'MINE');
    await cur0.close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir,
      zipPath: zip,
      importSettings: true,
      categories: BackupCategory.values.toSet(),
    );
    final FushiDatabase cur = FushiDatabase(curDir);
    addTearDown(cur.close);
    final mappings = await cur
        .customSelect('SELECT label FROM anki_mappings')
        .get();
    expect(mappings.map((r) => r.read<String>('label')), <String>[
      'MINE_label',
    ]);
    final clips = await cur
        .customSelect('SELECT content FROM clipboard_history')
        .get();
    expect(clips.map((r) => r.read<String>('content')), <String>[
      'MINE_content',
    ]);
  });
}
