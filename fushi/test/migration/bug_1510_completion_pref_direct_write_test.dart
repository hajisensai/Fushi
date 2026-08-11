import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/migration/migration_importer.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, PrefCodec;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// BUG-1510 守卫：导入完成标志必须**直写落地库文件**，且写在删中转文件**之前**。
///
/// 用户真机（CPH2747）截图给的原话：
/// 「校验未通过，已保留待重传：Bad state: Tried to send Request (id = 867):
///   RunTransactionAction(NestedExecutorControl.beginTransaction, null) over
///   isolate channel, but the connection was closed!」
///
/// 两个错叠在一起才长成这个样子：
/// 1. 导入协议开头就 `closeDatabase()`，而写完成标志用的
///    `appModel.prefsRepo.setPref` → `_db.setPref` 走的正是那条已关闭的 drift
///    isolate 连接，必抛。所以合并明明成功、行数校验也过了，最后一步炸掉。
/// 2. 旧顺序是**先删中转文件再写标志**，于是这次异常掉进 catch 弹出「已保留待重传」
///    ——文件早没了。用户既没拿到「成功」，也没有能重传的东西（现场实测：中转目录
///    Documents/Hibiki 空、Fushi 里数据却在）。
void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bug1510');
    dbPath = p.join(tmp.path, 'fushi.db');
    final sqlite.Database db = sqlite.sqlite3.open(dbPath);
    db.execute(
        'CREATE TABLE preferences (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)');
    db.dispose();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, String> readPrefs() {
    final sqlite.Database db =
        sqlite.sqlite3.open(dbPath, mode: sqlite.OpenMode.readOnly);
    try {
      return <String, String>{
        for (final sqlite.Row r
            in db.select('SELECT key, value FROM preferences'))
          r['key'] as String: r['value'] as String,
      };
    } finally {
      db.dispose();
    }
  }

  group('BUG-1510 完成标志直写落地库', () {
    test('写入业务键并抬 prefs_version（不经 drift，库连接已关也能写）', () {
      MigrationImporter.writeCompletionPrefs(
        dbPath: dbPath,
        encodedValues: <String, String>{
          'migration_import_done_v1': PrefCodec.encode(true),
          'migration_readonly_v1': PrefCodec.encode(false),
        },
      );

      final Map<String, String> prefs = readPrefs();
      expect(prefs['migration_import_done_v1'], 'b:true');
      expect(prefs['migration_readonly_v1'], 'b:false');
      expect(prefs[FushiDatabase.prefsVersionKey], 'i:1',
          reason: '跨进程变更信号必须抬，否则别的进程读到新值配旧版本号');
    });

    test('重复写是 upsert 且版本单调递增', () {
      MigrationImporter.writeCompletionPrefs(
        dbPath: dbPath,
        encodedValues: <String, String>{'k': PrefCodec.encode(1)},
      );
      MigrationImporter.writeCompletionPrefs(
        dbPath: dbPath,
        encodedValues: <String, String>{'k': PrefCodec.encode(2)},
      );
      final Map<String, String> prefs = readPrefs();
      expect(prefs['k'], 'i:2');
      expect(prefs[FushiDatabase.prefsVersionKey], 'i:2');
    });

    test('空输入不建连接也不抬版本', () {
      MigrationImporter.writeCompletionPrefs(
          dbPath: dbPath, encodedValues: const <String, String>{});
      expect(readPrefs(), isEmpty);
    });
  });

  group('BUG-1510 导入页顺序契约', () {
    final String source =
        File('lib/src/pages/implementations/migration_import_page.dart')
            .readAsStringSync();

    test('不再用 prefsRepo.setPref 写完成标志（那条 drift 连接已关）', () {
      expect(source.contains('prefsRepo.setPref(kMigrationImportDonePrefKey'),
          isFalse,
          reason: '关库之后走 drift 必抛 connection was closed');
      expect(source.contains('prefsRepo.setPref(kMigrationReadonlyPrefKey'),
          isFalse);
      expect(source, contains('MigrationImporter.writeCompletionPrefs('));
    });

    test('标志落盘在删中转文件之前', () {
      final int write =
          source.indexOf('MigrationImporter.writeCompletionPrefs(');
      final int delete = source.indexOf('_importer.deleteBatchFiles(');
      expect(write, isNot(-1));
      expect(delete, isNot(-1));
      expect(write, lessThan(delete),
          reason: '反过来的话，写标志一炸就变成「文件已删 + 谎报已保留待重传」');
    });
  });
}
