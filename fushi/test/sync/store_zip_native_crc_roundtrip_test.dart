import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_source_pref.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 备份 zip 与音频同步包的 STORE 条目改由 `native_zip.addFileStored` 写（CRC 走
/// Rust `ffcCrc32`，不再是 archive 的纯 Dart `getCrc32`）。钉住：
/// - 条目头 CRC 与 archive `getCrc32`（第三方实现，当真值）逐条一致，且 archive
///   `verify: true` 能解开整包——别的 zip 读端（含旧版 app）校验 CRC 不会拒收；
/// - 现有恢复路径（`BackupRestoreService.restoreBackup` /
///   `SyncAssetPackageService.importLocalAudioPackage`）原样读回，字节一致；
/// - 文件跨多个 4 MiB 读块（9 MiB + 尾块），覆盖增量 CRC 的链式与尾块。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi-store-crc-');
  });
  tearDown(() async {
    if (temp.existsSync()) await cleanupTempDir(temp);
  });

  Uint8List pseudoRandom(int length, int seed) {
    final Uint8List out = Uint8List(length);
    int state = seed;
    for (int i = 0; i < length; i++) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      out[i] = state >> 16 & 0xff;
    }
    return out;
  }

  /// 包内 [name] 的条目头 CRC 必须等于 archive getCrc32([bytes])。
  void expectHeaderCrc(String zipPath, String name, List<int> bytes) {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      final ArchiveFile? entry = ZipDecoder()
          .decodeBuffer(input)
          .findFile(name);
      expect(entry, isNotNull, reason: name);
      expect(entry!.crc32, getCrc32(bytes), reason: name);
    } finally {
      input.closeSync();
    }
  }

  test('备份：STORE 条目 CRC 与 archive 一致，verify 解开，restoreBackup 原样读回', () async {
    final String srcDbDir = p.join(temp.path, 'src', 'db');
    final String srcAudio = p.join(temp.path, 'src', 'audiobooks');
    Directory(srcDbDir).createSync(recursive: true);
    final Uint8List big = pseudoRandom(9 * 1024 * 1024 + 4321, 0x2468ace);
    final Uint8List srt = Uint8List.fromList(
      '1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n'.codeUnits,
    );
    File(p.join(srcAudio, 'h', 'a.m4b'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(big);
    File(p.join(srcAudio, 'h', 'align.srt')).writeAsBytesSync(srt);

    final FushiDatabase srcDb = FushiDatabase(srcDbDir);
    final String zipPath = p.join(temp.path, 'backup.zip');
    try {
      await BackupService(
        db: srcDb,
        dbDirectory: srcDbDir,
        appVersion: '1.0.0',
        audiobooksRootDirectory: srcAudio,
      ).createBackup(zipPath);
    } finally {
      await srcDb.close();
    }

    expectHeaderCrc(zipPath, 'audiobooks/h/a.m4b', big);
    expectHeaderCrc(zipPath, 'audiobooks/h/align.srt', srt);
    // 整包（含 meta 与 db 条目）经 archive 的纯 Dart CRC 校验。
    final Archive verified = ZipDecoder().decodeBytes(
      File(zipPath).readAsBytesSync(),
      verify: true,
    );
    expect(verified.findFile('audiobooks/h/a.m4b')!.content, big);

    final String dstDbDir = p.join(temp.path, 'dst', 'db');
    final String dstAudio = p.join(temp.path, 'dst', 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);
    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      audiobooksRootDirectory: dstAudio,
    );
    expect(File(p.join(dstAudio, 'h', 'a.m4b')).readAsBytesSync(), big);
    expect(File(p.join(dstAudio, 'h', 'align.srt')).readAsBytesSync(), srt);
  });

  test(
    '音频同步包：STORE 资源 CRC 与 archive 一致，verify 解开，importLocalAudioPackage 原样读回',
    () async {
      final FushiDatabase sourceDb = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final FushiDatabase targetDb = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Uint8List big = pseudoRandom(9 * 1024 * 1024 + 777, 0x1357bdf);
      final File dbFile = File(p.join(temp.path, 'local_audio_7.db'))
        ..writeAsBytesSync(big);
      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportLocalAudioPackage(
            displayName: 'NHK',
            enabled: true,
            sources: const <LocalAudioSourcePref>[
              LocalAudioSourcePref(name: 'nhk16', enabled: true),
            ],
            dbFile: dbFile,
            outputFile: File(p.join(temp.path, 'nhk.fushiaudiolib')),
          );

      expectHeaderCrc(package.path, 'resources/local_audio_7.db', big);
      final Archive verified = ZipDecoder().decodeBytes(
        package.readAsBytesSync(),
        verify: true,
      );
      final ArchiveFile resource = verified.findFile(
        'resources/local_audio_7.db',
      )!;
      expect(resource.content, big);

      final Directory staging = Directory(p.join(temp.path, 'staging'))
        ..createSync();
      final LocalAudioPackageContents contents = await SyncAssetPackageService(
        db: targetDb,
      ).importLocalAudioPackage(packageFile: package, stagingDir: staging);
      expect(contents.dbFile.readAsBytesSync(), big);
    },
  );
}
