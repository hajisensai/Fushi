import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-2193：`dictionary_metadata` 里的一条**幽灵行**（元数据在、磁盘目录不在）
/// 曾经让**整批**词典都不进备份包，并且顺手把 DB 副本里的词典行整表清空——导出还
/// 照样报成功。用户勾了「词典」，拿到的 zip 里只有 `backup_meta.json` 和 `fushi.db`。
///
/// 既有的 `backup_categories_test` / `backup_service_test` 全部把测试数据造成
/// 「元数据与磁盘完全一致」的理想世界（前者的 harness 注释里就明说是为了让
/// `_hasCompleteDictionaryResources` 放行），所以这个形态一条覆盖都没有。
void main() {
  late Directory src;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_ghost_src_');
  });
  tearDown(() async {
    try {
      if (src.existsSync()) await cleanupTempDir(src);
    } on PathNotFoundException {
      // Windows 上递归清理会和已被移除的临时路径抢。
    }
  });

  Future<void> writeFile(String path, String content) async {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  /// 造一台「装了三本词典，其中一本的目录不见了」的设备。
  Future<({BackupService service, FushiDatabase db})> buildDevice({
    required List<String> onDisk,
    required List<String> inDb,
  }) async {
    final String dbDir = p.join(src.path, 'db');
    final String dict = p.join(src.path, 'dictionaryResources');
    Directory(dbDir).createSync(recursive: true);
    for (final String name in onDisk) {
      await writeFile(p.join(dict, name, 'index.bin'), 'IDX-$name');
    }
    // 运行期临时目录：它们**不该**进备份包。
    await writeFile(p.join(dict, 'import_temp', 'half.zip'), 'JUNK');
    await writeFile(p.join(dict, '.pending_delete', 'old.bin'), 'JUNK');

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (int i = 0; i < inDb.length; i++) {
      await db.upsertDictionaryMeta(
        DictionaryMetadataCompanion.insert(
          name: inDb[i],
          formatKey: 'yomitan',
          order: i,
        ),
      );
    }
    return (
      service: BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        dictionaryResourceDirectory: dict,
      ),
      db: db,
    );
  }

  Future<Archive> readZip(String zipPath) async {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      return ZipDecoder().decodeBuffer(input);
    } finally {
      await input.close();
    }
  }

  test('一条幽灵行不再连累其余词典：好的照打，坏的只删自己那一行', () async {
    final built = await buildDevice(
      onDisk: <String>['JMdict', 'Daijirin'],
      inDb: <String>['JMdict', 'Daijirin', 'GoneDict'],
    );
    final String zip = p.join(src.path, 'out.zip');
    List<String> skipped = const <String>[];
    await built.service.createBackup(
      zip,
      onDictionariesSkipped: (List<String> names) => skipped = names,
    );
    await built.db.close();

    final Archive archive = await readZip(zip);
    expect(archive.findFile('dictionaryResources/JMdict/index.bin'), isNotNull,
        reason: '有文件的词典必须照常进包');
    expect(
      archive.findFile('dictionaryResources/Daijirin/index.bin'),
      isNotNull,
      reason: '第二本同样不该被那条幽灵行连累',
    );
    expect(skipped, <String>['GoneDict'], reason: '跳过了谁必须报出来，不能静默');
  });

  test('运行期临时目录不进包（按词典名枚举的副产品）', () async {
    final built = await buildDevice(
      onDisk: <String>['JMdict'],
      inDb: <String>['JMdict'],
    );
    final String zip = p.join(src.path, 'out.zip');
    await built.service.createBackup(zip);
    await built.db.close();

    final Archive archive = await readZip(zip);
    expect(archive.findFile('dictionaryResources/JMdict/index.bin'), isNotNull);
    expect(
      archive.files.any((ArchiveFile f) =>
          f.name.contains('import_temp') || f.name.contains('.pending_delete')),
      isFalse,
      reason: '整棵树无差别打包会把半个下载包和待删目录一起塞进备份',
    );
  });

  test('全都是幽灵行时如实报出全部跳过，且不产出空的词典前缀', () async {
    final built = await buildDevice(
      onDisk: <String>[],
      inDb: <String>['GoneA', 'GoneB'],
    );
    final String zip = p.join(src.path, 'out.zip');
    List<String> skipped = const <String>[];
    await built.service.createBackup(
      zip,
      onDictionariesSkipped: (List<String> names) => skipped = names,
    );
    await built.db.close();

    expect(skipped, <String>['GoneA', 'GoneB']);
    final Archive archive = await readZip(zip);
    expect(
      archive.files.any(
        (ArchiveFile f) => f.name.startsWith('dictionaryResources/'),
      ),
      isFalse,
    );
  });

  test('没有幽灵行时一条都不报——不制造假警报', () async {
    final built = await buildDevice(
      onDisk: <String>['JMdict'],
      inDb: <String>['JMdict'],
    );
    final String zip = p.join(src.path, 'out.zip');
    bool called = false;
    await built.service.createBackup(
      zip,
      onDictionariesSkipped: (List<String> _) => called = true,
    );
    await built.db.close();
    expect(called, isFalse);
  });

  test('用户没勾词典时不算「被跳过」——那是他自己的选择', () async {
    final built = await buildDevice(
      onDisk: <String>['JMdict'],
      inDb: <String>['JMdict', 'GoneDict'],
    );
    final String zip = p.join(src.path, 'out.zip');
    bool called = false;
    await built.service.createBackup(
      zip,
      categories: BackupCategory.values.toSet()
        ..remove(BackupCategory.dictionary),
      onDictionariesSkipped: (List<String> _) => called = true,
    );
    await built.db.close();
    expect(called, isFalse);
    final Archive archive = await readZip(zip);
    expect(
      archive.files.any(
        (ArchiveFile f) => f.name.startsWith('dictionaryResources/'),
      ),
      isFalse,
    );
  });

  test('预览计数只数打得出来的，与实际打包内容一致', () async {
    final built = await buildDevice(
      onDisk: <String>['JMdict', 'Daijirin'],
      inDb: <String>['JMdict', 'Daijirin', 'GoneDict'],
    );
    final BackupContentSummary summary =
        await built.service.summarizeLiveContent();
    await built.db.close();
    expect(
      summary.counts[BackupCategory.dictionary],
      2,
      reason: '旧实现数 dictionary_metadata 行数（3），与打包判据不同源，'
          '于是勾选框写着 3、导出后 0 本，用户完全无从察觉',
    );
  });
}
