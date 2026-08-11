import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// BUG-1575：合并/覆盖导入必须把 `srt_books` 的四列路径 rebase 到本机根。
///
/// 真实故障：用户把互联下载来的 6 本 SRT 有声书经 hibiki → fushi 改名迁移
/// （`MigrationImporter` → `BackupService.mergeRestoreBackup`）带过来，合并引擎
/// 逐列原样 INSERT `srt_books`，而 `_rebaseContentPaths` 只遍历 `epub_books` /
/// `audiobooks` → srt 行带着**旧数据根**进了新库 = 有字幕没声音（cue 存在
/// `audio_cues`，不带路径）。
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('srtrb_src_');
    dst = await Directory.systemTemp.createTemp('srtrb_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<void> writeFile(String path, String content) async {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  /// 造一台「源设备」：audiobooks 根下一本 srt 有声书（音频 + 字幕 + 封面）。
  /// 返回导出好的 zip 路径。
  Future<String> buildSourceBackup({
    required String srcAudio,
    String? audioPathsJsonOverride,
  }) async {
    final String srcDbDir = p.join(src.path, 'db');
    final String srcBooks = p.join(src.path, 'fushi_books');
    Directory(srcDbDir).createSync(recursive: true);
    await writeFile(p.join(srcAudio, 'u1', '01.mp3'), 'MP3-1');
    await writeFile(p.join(srcAudio, 'u1', '02.mp3'), 'MP3-2');
    await writeFile(p.join(srcAudio, 'u1', 'sub.srt'), 'SRT');
    await writeFile(p.join(srcAudio, 'u1', 'cover.jpg'), 'COVER');

    final FushiDatabase srcDb = FushiDatabase(srcDbDir);
    await srcDb.upsertSrtBook(SrtBooksCompanion.insert(
      uid: 'srtbook_1',
      title: 'Audio Book',
      audioRoot: Value(p.join(srcAudio, 'u1')),
      audioPathsJson: Value(audioPathsJsonOverride ??
          jsonEncode(<String>[
            p.join(srcAudio, 'u1', '01.mp3'),
            p.join(srcAudio, 'u1', '02.mp3'),
          ])),
      srtPath: p.join(srcAudio, 'u1', 'sub.srt'),
      coverPath: Value(p.join(srcAudio, 'u1', 'cover.jpg')),
      importedAt: 0,
    ));
    final String zipPath = p.join(src.path, 'backup.zip');
    final BackupMeta meta = await BackupService(
      db: srcDb,
      dbDirectory: srcDbDir,
      appVersion: '2.0.0',
      booksRootDirectory: srcBooks,
      audiobooksRootDirectory: srcAudio,
    ).createBackup(zipPath);
    await srcDb.close();
    expect(meta.audiobooksRoot, srcAudio);
    return zipPath;
  }

  test('merge import rebases all four srt_books path columns onto this device',
      () async {
    final String srcAudio = p.join(src.path, 'audiobooks');
    final String zipPath = await buildSourceBackup(srcAudio: srcAudio);

    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'fushi_books');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);

    await BackupService.mergeRestoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: dstBooks,
      audiobooksRootDirectory: dstAudio,
    );

    final FushiDatabase dstDb = FushiDatabase(dstDbDir);
    try {
      final SrtBookRow? row = await dstDb.getSrtBookByUid('srtbook_1');
      expect(row, isNotNull);
      expect(row!.audioRoot, p.join(dstAudio, 'u1'));
      expect(row.srtPath, p.join(dstAudio, 'u1', 'sub.srt'));
      expect(row.coverPath, p.join(dstAudio, 'u1', 'cover.jpg'));
      expect(
        jsonDecode(row.audioPathsJson!),
        <String>[
          p.join(dstAudio, 'u1', '01.mp3'),
          p.join(dstAudio, 'u1', '02.mp3'),
        ],
      );
      // 文件也真的落在新根下：rebase 后的路径必须解析得开，否则书架照样断链。
      expect(File(row.srtPath).existsSync(), isTrue);
      expect(File(jsonDecode(row.audioPathsJson!)[0] as String).existsSync(),
          isTrue);
    } finally {
      await dstDb.close();
    }
  });

  test('overwrite restore rebases srt_books too', () async {
    final String srcAudio = p.join(src.path, 'audiobooks');
    final String zipPath = await buildSourceBackup(srcAudio: srcAudio);

    final String dstDbDir = p.join(dst.path, 'db');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);

    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: p.join(dst.path, 'fushi_books'),
      audiobooksRootDirectory: dstAudio,
    );

    final FushiDatabase dstDb = FushiDatabase(dstDbDir);
    try {
      final SrtBookRow? row = await dstDb.getSrtBookByUid('srtbook_1');
      expect(row!.srtPath, p.join(dstAudio, 'u1', 'sub.srt'));
      expect(row.audioRoot, p.join(dstAudio, 'u1'));
      expect(row.coverPath, p.join(dstAudio, 'u1', 'cover.jpg'));
      expect(jsonDecode(row.audioPathsJson!), <String>[
        p.join(dstAudio, 'u1', '01.mp3'),
        p.join(dstAudio, 'u1', '02.mp3'),
      ]);
    } finally {
      await dstDb.close();
    }
  });

  test(
      'malformed audio_paths_json is kept verbatim and does not abort the '
      'import (the other three columns still rebase)', () async {
    final String srcAudio = p.join(src.path, 'audiobooks');
    final String zipPath = await buildSourceBackup(
      srcAudio: srcAudio,
      audioPathsJsonOverride: '{not json at all',
    );

    final String dstDbDir = p.join(dst.path, 'db');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);

    await BackupService.mergeRestoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: p.join(dst.path, 'fushi_books'),
      audiobooksRootDirectory: dstAudio,
    );

    final FushiDatabase dstDb = FushiDatabase(dstDbDir);
    try {
      final SrtBookRow? row = await dstDb.getSrtBookByUid('srtbook_1');
      expect(row, isNotNull, reason: '坏 JSON 不得让整次导入失败');
      expect(row!.audioPathsJson, '{not json at all', reason: '坏值原样保留');
      expect(row.srtPath, p.join(dstAudio, 'u1', 'sub.srt'));
      expect(row.coverPath, p.join(dstAudio, 'u1', 'cover.jpg'));
    } finally {
      await dstDb.close();
    }
  });
}
