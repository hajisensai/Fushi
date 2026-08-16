import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v88（内容语言字体链·其余三类资源）：`video_books` / `srt_books` / `galgames`
/// 各加 `language` 覆盖列。
///
/// **这条测试守的是「加列不许并进已发布的版本号」**。这三列最初被写进了 v87 段，
/// 而 v87 早已随内容语言字体链那批改动落到 develop 上跑了一整天：凡是已经把
/// `user_version` 写成 87 的库（预发布/debug 通道、本机开发库）永远不会再进
/// `from < 87`，于是三列根本不会被创建。变异实测下的表现是两种都很坏：读路径
/// 不抛、`language` 一律读成 NULL（功能像「设了没反应」一样静默死掉），写路径
/// 则直接撞 no such column。
///
/// 因此这里**必须**从「真实的 v87 库」出发，而不是从更早的版本：只有 87 这个
/// 起点能区分「列在 v87 段」和「列在 v88 段」。用更早的起点两种写法都会通过。
///
/// 造 v87 库的办法是「建当前库 → DROP 掉这三列 → user_version 写回 87」，而不是
/// 手抄三张表的 v87 列集：这三张表列很多，手抄一旦写歪就是在测一条生产不存在的
/// 形状，而且以后每加一列都要跟着改。DROP 出来的形状按定义就是「v88 减去这三列」。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v88_content_language');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v87-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实的 v87 形状库：当前 schema 建满，再摘掉 v88 的三列并把版本写回 87。
  Future<void> seedV87() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 存量行：迁移必须无损带过去。
    await fresh.customStatement(
      'INSERT INTO video_books (book_uid, title, video_path) '
      "VALUES ('video/ep0', '第 1 集', '/abs/ep0.mkv')",
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE video_books DROP COLUMN language');
      raw.execute('ALTER TABLE srt_books DROP COLUMN language');
      raw.execute('ALTER TABLE galgames DROP COLUMN language');
      raw.execute('PRAGMA user_version = 87');
    } finally {
      raw.dispose();
    }
  }

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  test('v87 库确实缺这三列（前提自检——不然下面那条测了个寂寞）', () async {
    await seedV87();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 87);
      expect(hasColumn(probe, 'video_books', 'language'), isFalse);
      expect(hasColumn(probe, 'srt_books', 'language'), isFalse);
      expect(hasColumn(probe, 'galgames', 'language'), isFalse);
    } finally {
      probe.dispose();
    }
  });

  test('v87 -> v88：三列补齐且存量行无损', () async {
    await seedV87();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 走真实查询路径：列缺失时这一句就会 SqliteException，正是线上会炸的地方。
    final List<VideoBookRow> rows =
        await migrated.select(migrated.videoBooks).get();
    expect(rows, hasLength(1), reason: '迁移丢一行就是丢一部视频的记录');
    expect(rows.single.bookUid, 'video/ep0');
    expect(rows.single.language, isNull,
        reason: '存量行语言未知 = NULL，不许替用户猜（尤其不许因为「多半是日文」就填 ja）');
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 88);
      expect(hasColumn(probe, 'video_books', 'language'), isTrue);
      expect(hasColumn(probe, 'srt_books', 'language'), isTrue);
      expect(hasColumn(probe, 'galgames', 'language'), isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('升级后写入口照常：设置内容语言能真写穿（缺列时这里撞 no such column）', () async {
    await seedV87();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    addTearDown(migrated.close);
    // 读路径在缺列时**不抛**（一律读成 NULL），所以判别力靠这条写入：
    // `SET language = ?` 打在没有该列的表上必然报错。
    await migrated.updateVideoBookLanguage('video/ep0', 'ja');
    final List<VideoBookRow> rows =
        await migrated.select(migrated.videoBooks).get();
    expect(rows.single.language, 'ja');
  });

  test('重复打开幂等：第二次开库不因列已存在而报错', () async {
    await seedV87();

    final FushiDatabase first =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    final List<VideoBookRow> rows =
        await second.select(second.videoBooks).get();
    expect(rows, hasLength(1));
    await second.close();
  });
}
