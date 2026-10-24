import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/platform/file_hard_link.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000d4';

/// 备份媒体池改用硬链接（同卷时不占第二份空间）。「是不是硬链接」用原地追加来判：
/// 硬链接两个名字是同一份内容，一边原地写另一边跟着变；复制的不会。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_media_link_test_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  bool sameContentObject(File a, File b) {
    final String before = b.readAsStringSync();
    a.writeAsStringSync('+probe', mode: FileMode.append);
    return b.readAsStringSync() != before;
  }

  group('tryCreateHardLink', () {
    test('建出的是同一份内容；目标已存在 / 源不存在返回 false 不抛', () {
      final File src = File(p.join(tmp.path, 'a.bin'))
        ..writeAsStringSync('hello');
      final String linkPath = p.join(tmp.path, 'b.bin');
      expect(tryCreateHardLink(src.path, linkPath), isTrue);
      expect(File(linkPath).readAsStringSync(), 'hello');
      expect(sameContentObject(src, File(linkPath)), isTrue);
      expect(tryCreateHardLink(src.path, linkPath), isFalse, reason: '已存在');
      expect(
        tryCreateHardLink(p.join(tmp.path, 'missing'), p.join(tmp.path, 'c')),
        isFalse,
      );
    });

    test('先写临时文件再改名替换一边：另一边保留旧内容', () {
      final File src = File(p.join(tmp.path, 'a.bin'))
        ..writeAsStringSync('old');
      final File link = File(p.join(tmp.path, 'b.bin'));
      expect(tryCreateHardLink(src.path, link.path), isTrue);
      File(p.join(tmp.path, 'a.bin.tmp'))
        ..writeAsStringSync('new')
        ..renameSync(src.path);
      expect(src.readAsStringSync(), 'new');
      expect(link.readAsStringSync(), 'old');
    });
  });

  group('备份媒体池', () {
    late SrsStorage srs;
    late SrsDbStore store;
    late SrsBackupStore backups;
    late Directory mediaDir;

    setUp(() async {
      srs = await SrsStorage.open(
        path: p.join(tmp.path, kSrsDatabaseFileName),
        inline: true,
      );
      int t = DateTime.utc(2026, 10, 23, 9).millisecondsSinceEpoch;
      store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: kProfile,
        deviceId: 'link',
        engine: const SrsFakeEngine(),
        trustedClock: SrsTrustedClock(
          wallClockMs: () => t++,
          monotonicMs: () => t,
          bootId: 'boot-link',
        ),
      );
      mediaDir = Directory(p.join(tmp.path, 'srs_media', kProfile))
        ..createSync(recursive: true);
      backups = SrsBackupStore(
        root: Directory(p.join(tmp.path, 'srs_backups')),
        profileUid: kProfile,
        mediaDir: mediaDir,
      );
    });
    tearDown(() async {
      await srs.close();
    });

    Future<SrsBackupInfo> backup() =>
        backups.create(store, kind: SrsBackupKind.manual, profileName: '日语');

    File pooledOf(SrsBackupInfo info, String name) => File(
      p.join(
        backups.mediaPool.path,
        info.manifest.media
            .firstWhere((SrsBackupMediaEntry m) => m.name == name)
            .sha256,
      ),
    );

    test('入池是媒体文件的硬链接；旧版本复制进池的文件下一次备份换成链接', () async {
      File(p.join(mediaDir.path, 'a.png')).writeAsStringSync('image-a');
      final SrsBackupInfo first = await backup();
      final File pooledA = pooledOf(first, 'a.png');
      expect(pooledA.readAsStringSync(), 'image-a');

      // 模拟旧版本：b.png 以复制的形式在池里，索引里没有 `linked` 记号。
      final File b = File(p.join(mediaDir.path, 'b.png'))
        ..writeAsStringSync('image-b');
      final SrsBackupInfo second = await backup();
      final File pooledB = pooledOf(second, 'b.png');
      pooledB.deleteSync();
      b.copySync(pooledB.path);
      final File index = File(p.join(backups.mediaPool.path, 'index.json'));
      final Map<String, Object?> j =
          (jsonDecode(index.readAsStringSync()) as Map).cast<String, Object?>();
      for (final Object? e in j.values) {
        (e! as Map).remove('linked');
      }
      index.writeAsStringSync(jsonEncode(j));
      final SrsBackupInfo third = await backup();
      expect(pooledOf(third, 'b.png').readAsStringSync(), 'image-b');

      expect(sameContentObject(b, pooledB), isTrue, reason: '复制件换成了链接');
      expect(
        sameContentObject(File(p.join(mediaDir.path, 'a.png')), pooledA),
        isTrue,
        reason: '第一次入池就是链接',
      );
    });

    test('恢复媒体：从池里硬链接回媒体目录', () async {
      File(p.join(mediaDir.path, 'a.png')).writeAsStringSync('image-a');
      final SrsBackupInfo info = await backup();
      File(p.join(mediaDir.path, 'a.png')).deleteSync();
      final SrsBackupArchive arch = await SrsBackupStore.read(info.file);
      try {
        expect(await backups.restoreMedia(arch), 0);
      } finally {
        arch.close();
      }
      final File restored = File(p.join(mediaDir.path, 'a.png'));
      expect(restored.readAsStringSync(), 'image-a');
      expect(sameContentObject(restored, pooledOf(info, 'a.png')), isTrue);
    });
  });
}
