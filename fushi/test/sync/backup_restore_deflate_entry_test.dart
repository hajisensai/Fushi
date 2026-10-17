import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 备份导入解 DEFLATE 条目走原生 zlib 分块流式（deflate 版推荐包的前提）。
///
/// 旧实现用 archive 3.6.1 的 `Inflate.stream(raw, OutputFileStream)`：每个回溯
/// 引用都 flush + seek + 读文件，实测 1.13 MB/s，8 GB 的 deflate 推荐包要解两个
/// 多小时，进度条整条目只动一次。这里钉住三件事：字节逐字还原、压缩数据跨越
/// 多个 4 MB 读块也对、进度随解压持续推进而不是条目结束才跳一下。
void main() {
  late Directory tmp;
  late String dbDirectory;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_restore_deflate_');
    dbDirectory = p.join(tmp.path, 'support');
    Directory(dbDirectory).createSync();
  });

  tearDown(() => cleanupTempDir(tmp));

  late int schemaVersion;

  /// 当前 schema 的真实主库字节（覆盖恢复要求包里的库能被本版本打开）。
  Future<Uint8List> currentDbBytes() async {
    final String srcDir = p.join(tmp.path, 'src');
    Directory(srcDir).createSync();
    final FushiDatabase db = FushiDatabase(srcDir);
    schemaVersion = db.schemaVersion;
    await db.setPref('backup_sentinel', 'restored');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();
    return File(p.join(srcDir, fushiDatabaseFileName)).readAsBytesSync();
  }

  /// 前半段不可压的伪随机字节（让压缩后仍超过一个 4 MB 读块），后半段全零。
  Uint8List audioPayload() {
    final Random random = Random(20261016);
    final Uint8List bytes = Uint8List(9 * 1024 * 1024);
    for (int i = 0; i < 5 * 1024 * 1024; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  test('覆盖恢复：DEFLATE 的本地音频条目逐字还原，进度持续推进到 1', () async {
    final Uint8List dbBytes = await currentDbBytes();
    final Uint8List audio = audioPayload();
    final List<int> meta = utf8.encode(
      jsonEncode(
        BackupMeta(
          appVersion: '2.0.0',
          schemaVersion: schemaVersion,
          createdAt: DateTime(2026, 10, 16),
          bookCount: 0,
          statsCount: 0,
        ).toJson(),
      ),
    );
    final ArchiveFile audioEntry = ArchiveFile(
      'localAudio/local_audio_1.db',
      audio.length,
      audio,
    )..compress = true;
    final Archive archive = Archive()
      ..addFile(ArchiveFile('backup_meta.json', meta.length, meta))
      ..addFile(
        ArchiveFile(fushiDatabaseFileName, dbBytes.length, dbBytes)
          ..compress = false,
      )
      ..addFile(audioEntry);
    final String zipPath = p.join(tmp.path, 'deflate_audio.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

    // 前提自检：条目确实是 DEFLATE，且压缩后跨越不止一个 4 MB 读块。
    final Archive written = ZipDecoder().decodeBytes(
      File(zipPath).readAsBytesSync(),
    );
    final ArchiveFile packed = written.findFile('localAudio/local_audio_1.db')!;
    expect(packed.compressionType, ArchiveFile.DEFLATE);
    expect(packed.rawContent!.length, greaterThan(4 * 1024 * 1024));

    final List<double> progress = <double>[];
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDirectory,
      zipPath: zipPath,
      onProgress: progress.add,
    );

    final File restored = File(p.join(dbDirectory, 'local_audio_1.db'));
    expect(restored.existsSync(), isTrue);
    expect(restored.readAsBytesSync(), audio, reason: 'DEFLATE 条目必须逐字节还原');
    // 9 MB 音频远大于主库：原生 zlib 按块吐出，进度要在条目内部多次推进；
    // 旧实现整条目只报一次。
    final int midEntryTicks = progress
        .where((double v) => v > 0 && v < 1)
        .length;
    expect(midEntryTicks, greaterThan(2), reason: '进度应随解压逐块推进');
    expect(progress.last, closeTo(1.0, 1e-9));
  });
}
