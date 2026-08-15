import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi/src/utils/misc/local_audio_db.dart';

/// BUG-1667：`LocalAudioDb.ensureIndexes` 旧实现无条件跑
/// `CREATE INDEX IF NOT EXISTS idx_entries_expr_read ...`，而它只按**索引名**判存在。
/// Yomitan「本地音频服务器」导出的 android.db 自带的等价索引叫 `idx_expr_reading` /
/// `idx_android`（本机 6.2 GB 真库实测两条都有），名字对不上就照建一遍完全重复的索引。
///
/// 更要命的是引用模式（BUG-483）：库是**用户的原始文件**，选了「不复制」的用户不该
/// 因为我们要建一条已经存在的索引而被写。故本组测试同时断言「已有等价索引时连
/// readWrite 句柄都不开」——用只读文件属性做硬证据。
void main() {
  late Directory dir;
  late String dbPath;

  /// 建一个空的音频库骨架（两张表，无任何索引）。
  void createSchema() {
    final Database db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE entries '
        '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.dispose();
  }

  void exec(String sql) {
    final Database db = sqlite3.open(dbPath);
    db.execute(sql);
    db.dispose();
  }

  Set<String> indexNames() {
    final Database db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      return <String>{
        for (final Row r
            in db.select("SELECT name FROM sqlite_master WHERE type='index'"))
          if (r['name'] is String) r['name'] as String,
      };
    } finally {
      db.dispose();
    }
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_local_audio_index');
    dbPath = '${dir.path}/android.db';
    createSchema();
  });

  tearDown(() async {
    await LocalAudioDb.waitForPendingIndexing();
    dir.deleteSync(recursive: true);
  });

  test('无任何索引的库：两条查询索引都补上', () async {
    await LocalAudioDb.ensureIndexes(dbPath);
    final Set<String> names = indexNames();
    expect(names, contains('idx_entries_expr_read'));
    expect(names, contains('idx_android_file_source'));
  });

  test('真库自带的同列异名索引：一条都不重复建', () async {
    // 与本机 6.2 GB 真 android.db 完全同名同列。
    exec('CREATE INDEX idx_expr_reading ON entries(expression, reading)');
    exec('CREATE INDEX idx_android ON android(file, source)');

    await LocalAudioDb.ensureIndexes(dbPath);

    final Set<String> names = indexNames();
    expect(names, contains('idx_expr_reading'));
    expect(names, contains('idx_android'));
    expect(names, isNot(contains('idx_entries_expr_read')),
        reason: 'idx_expr_reading 已覆盖 entries(expression, reading)，不该再建一条');
    expect(names, isNot(contains('idx_android_file_source')),
        reason: 'idx_android 已覆盖 android(file, source)，不该再建一条');
  });

  test('更宽索引的前缀已覆盖目标列：也不重复建', () async {
    // 真库里的 `idx_all ON entries(expression, reading, source)`：
    // SQLite 用它服务 `WHERE expression=? AND reading=?` 与专门的两列索引等效。
    exec('CREATE INDEX idx_all ON entries(expression, reading, source)');
    exec('CREATE INDEX idx_android ON android(file, source)');

    await LocalAudioDb.ensureIndexes(dbPath);

    expect(indexNames(), isNot(contains('idx_entries_expr_read')));
  });

  test('列序不同不算等价：仍要建', () async {
    // (reading, expression) 服务不了 `WHERE expression=?` 的等值前缀查找。
    exec('CREATE INDEX idx_wrong_order ON entries(reading, expression)');

    await LocalAudioDb.ensureIndexes(dbPath);

    expect(indexNames(), contains('idx_entries_expr_read'));
  });

  test('部分索引不算等价：只覆盖部分行，仍要建', () async {
    exec('CREATE INDEX idx_partial ON entries(expression, reading) '
        "WHERE source = 'nhk16'");

    await LocalAudioDb.ensureIndexes(dbPath);

    expect(indexNames(), contains('idx_entries_expr_read'),
        reason: '部分索引只覆盖 source=nhk16 的行，不能替代全量索引');
  });

  test('表达式索引不算等价：仍要建', () async {
    // 真库里的 `idx_entries_unique_audio` 用了 IFNULL(...)：
    // PRAGMA index_info 对表达式列回 name=null，不该被当成列名匹配上。
    exec('CREATE UNIQUE INDEX idx_expr_index ON entries('
        "expression, IFNULL(reading, ''), source, file)");

    await LocalAudioDb.ensureIndexes(dbPath);

    expect(indexNames(), contains('idx_entries_expr_read'));
  });

  test('索引齐备时不写库文件：只读库也能安然通过', () async {
    exec('CREATE INDEX idx_expr_reading ON entries(expression, reading)');
    exec('CREATE INDEX idx_android ON android(file, source)');

    // 用「文件最后修改时间不变」证明我们没开写句柄——引用模式下这就是
    // 「不碰用户原始文件」的可观测证据。
    final DateTime before = File(dbPath).lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    await LocalAudioDb.ensureIndexes(dbPath);
    await LocalAudioDb.waitForPendingIndexing(dbPath);

    expect(File(dbPath).lastModifiedSync(), before,
        reason: '等价索引齐备时不该打开 readWrite 句柄、不该写用户的库文件');
    // 同时确认没有留下写连接的旁文件。
    expect(File('$dbPath-wal').existsSync(), isFalse);
    expect(File('$dbPath-shm').existsSync(), isFalse);
  });

  test('缺表的库不致命：另一条仍能建', () async {
    // 只有 android 表的库（既有注释里点名的形状）。
    dbPath = '${dir.path}/android_only.db';
    final Database db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.dispose();

    await LocalAudioDb.ensureIndexes(dbPath);

    expect(indexNames(), contains('idx_android_file_source'));
  });
}
