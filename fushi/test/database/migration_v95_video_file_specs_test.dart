import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v95（库页/详情页技术规格标注）：新表 `video_file_specs`，缓存 ffprobe 探到的
/// 分辨率 / HDR 色彩标签 / 编码 / 色深 / 帧率 / 音轨 / 字幕轨。
///
/// 守三件事：从真实 v94 库出发表会建出来；存量视频书一行不丢；新表初始为空
/// （= 旧库升级后不显示任何规格角标，与升级前行为一致，由探测队列按需回填）。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v95_file_specs');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v94-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实的 v94 形状库：当前 schema 建满、塞一行存量视频书，
  /// 再把新表整个 DROP 掉、版本写回 94。
  Future<void> seedV94() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await fresh.customStatement(
      'INSERT INTO video_books (book_uid, title, video_path, imported_at) '
      "VALUES ('vid-1', '某电影', 'D:\\media\\movie.mkv', 1700000000)",
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('DROP TABLE video_file_specs');
      raw.execute('PRAGMA user_version = 94');
    } finally {
      raw.dispose();
    }
  }

  bool hasTable(sqlite3.Database db, String table) {
    final sqlite3.ResultSet rows = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.isNotEmpty;
  }

  test('v94 库确实没有 video_file_specs（前提自检）', () async {
    await seedV94();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 94);
      expect(hasTable(probe, 'video_file_specs'), isFalse);
      expect(hasTable(probe, 'video_books'), isTrue, reason: '存量表还在');
    } finally {
      probe.dispose();
    }
  });

  test('v94 -> v95：建表、初始为空、存量视频书无损', () async {
    await seedV94();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);

    final List<VideoBookRow> books =
        await migrated.select(migrated.videoBooks).get();
    expect(books, hasLength(1), reason: '迁移丢一行就是丢一部片子');
    expect(books.single.title, '某电影');
    expect(books.single.videoPath, r'D:\media\movie.mkv');

    final List<VideoFileSpecRow> specs =
        await migrated.select(migrated.videoFileSpecs).get();
    expect(specs, isEmpty,
        reason: '新表初始为空 = 旧库升级后不显示规格角标，与升级前逐像素一致');

    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 97);
      expect(hasTable(probe, 'video_file_specs'), isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('迁移后新表可正常读写，主键是文件路径', () async {
    await seedV94();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await migrated.customStatement(
      'INSERT INTO video_file_specs (file_path, file_size_bytes, '
      'file_modified_at, probed_at, probe_version, width, height, '
      'video_codec, color_transfer) '
      r"VALUES ('D:\media\movie.mkv', 123456, 1700000000, 1700000001, 2, "
      "3840, 2160, 'hevc', 'smpte2084')",
    );

    final VideoFileSpecRow row =
        (await migrated.select(migrated.videoFileSpecs).get()).single;
    expect(row.filePath, r'D:\media\movie.mkv');
    expect(row.width, 3840);
    expect(row.height, 2160);
    expect(row.colorTransfer, 'smpte2084');
    expect(row.audioTracksJson, '[]', reason: '轨道 JSON 默认空数组，不是 NULL');
    expect(row.subtitleTracksJson, '[]');
    expect(row.durationMs, isNull, reason: '没探到的列保持 NULL');

    // 同一路径再写一次 = 覆盖，不是新增（主键是 file_path）。
    await migrated.customStatement(
      'INSERT OR REPLACE INTO video_file_specs (file_path, file_size_bytes, '
      'file_modified_at, probed_at, probe_version, width, height) '
      r"VALUES ('D:\media\movie.mkv', 999, 1700000000, 1700000002, 2, "
      '1920, 1080)',
    );
    final List<VideoFileSpecRow> after =
        await migrated.select(migrated.videoFileSpecs).get();
    expect(after, hasLength(1), reason: '同一文件只该有一行');
    expect(after.single.width, 1920);

    await migrated.close();
  });

  test('重复打开幂等：第二次开库不因表已存在而报错', () async {
    await seedV94();

    final FushiDatabase first =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    expect(await second.select(second.videoBooks).get(), hasLength(1));
    expect(await second.select(second.videoFileSpecs).get(), isEmpty);
    await second.close();
  });
}
