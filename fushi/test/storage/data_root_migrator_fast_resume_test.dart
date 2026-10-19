// BUG-3541：数据根迁移 / 沙箱重定位必须在同一流程里改写内置 torrent 引擎
// fast-resume 文件里的绝对 save_path。
//
// native `ht_load_resume_dir` 用 `lt::read_resume_data` 原样读回 resume 里的
// save_path；默认下载根 `<documents>/anime_downloads/content` 随数据根搬走后不
// 改写，种子就指向已搬空的旧目录。作用域判据与 DB 路径改写是同一个
// DocumentsPathRebaser：用户自选的外部下载根原样保留。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/sandbox_relocation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_fast_resume.dart';
import 'package:path/path.dart' as p;

/// 形状与 libtorrent `write_resume_data_buf` 一致的 bencode 字典（键按字典序，
/// 含二进制串、整数、嵌套列表/字典），`save_path` 夹在中间。
Uint8List resumeBytes(String savePath, {String? nestedSavePath}) {
  final BytesBuilder b = BytesBuilder();
  void str(List<int> bytes) {
    b.add(ascii.encode('${bytes.length}:'));
    b.add(bytes);
  }

  void s(String value) => str(utf8.encode(value));
  b.addByte(0x64); // d
  s('file-format');
  s('libtorrent resume file');
  s('info-hash');
  str(List<int>.generate(20, (int i) => (i * 37 + 0xfa) & 0xff));
  s('pieces');
  str(<int>[0x01, 0x00, 0x3a, 0x65, 0x64, 0x01]);
  s('save_path');
  s(savePath);
  s('total_uploaded');
  b.add(ascii.encode('i123456e'));
  s('trackers');
  b.add(ascii.encode('l'));
  b.add(ascii.encode('l'));
  s('udp://tracker.example:80/announce');
  b.add(ascii.encode('e'));
  b.add(ascii.encode('e'));
  s('zz-extra');
  b.add(ascii.encode('d'));
  s('nested_save_path');
  s(nestedSavePath ?? savePath);
  b.add(ascii.encode('e'));
  b.addByte(0x65); // e
  return b.toBytes();
}

String? savePathOf(File file) => readFastResumeSavePath(file.readAsBytesSync());

void main() {
  group('rebaseFastResumeSavePath — 字节级只换 save_path', () {
    test('只替换顶层 save_path，其余字节原样（含嵌套同名键）', () {
      final String oldPath = p.join('C:', 'old', 'anime_downloads', 'content');
      final String newPath = p.join('D:', '新しい', 'anime_downloads', 'content');
      final Uint8List original = resumeBytes(oldPath);
      final Uint8List? rebased = rebaseFastResumeSavePath(
        original,
        (String v) => v == oldPath ? newPath : v,
      );
      expect(rebased, isNotNull);
      expect(readFastResumeSavePath(rebased!), newPath);
      // 与「只把顶层换成新路径」构造的字节逐字节相同：嵌套字典里的同名键、
      // 二进制串、整数、列表一个字节都不动。
      expect(rebased, resumeBytes(newPath, nestedSavePath: oldPath));
    });

    test('作用域外（rebase 返回原值）→ null，不写盘', () {
      expect(
        rebaseFastResumeSavePath(resumeBytes('/ext/dl'), (String v) => v),
        isNull,
      );
    });

    test('不是 bencode 字典 / 截断 / 没有 save_path → null', () {
      expect(rebaseFastResumeSavePath(Uint8List(0), (String v) => 'x'), isNull);
      expect(
        rebaseFastResumeSavePath(
          Uint8List.fromList(ascii.encode('li1ee')),
          (String v) => 'x',
        ),
        isNull,
      );
      final Uint8List full = resumeBytes('/a');
      expect(
        rebaseFastResumeSavePath(
          Uint8List.sublistView(full, 0, full.length ~/ 2),
          (String v) => 'x',
        ),
        isNull,
      );
      expect(
        rebaseFastResumeSavePath(
          Uint8List.fromList(<int>[...full, 0x78]),
          (String v) => 'x',
        ),
        isNull,
        reason: '尾部带垃圾的文件 libtorrent 加载不了，不改',
      );
      expect(
        rebaseFastResumeSavePath(
          Uint8List.fromList(ascii.encode('d3:fooi1ee')),
          (String v) => 'x',
        ),
        isNull,
      );
    });
  });

  group('DataRootMigrator.migrate 改写 fast-resume', () {
    late Directory tmp;
    late Directory oldDocs;
    late Directory oldSupport;
    late String newDataRoot;
    late String externalRoot;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('fushi_fastresume_');
      oldDocs = Directory(p.join(tmp.path, 'old', 'documents'))
        ..createSync(recursive: true);
      oldSupport = Directory(p.join(tmp.path, 'old', 'support'))
        ..createSync(recursive: true);
      newDataRoot = p.join(tmp.path, 'new');
      externalRoot = p.join(tmp.path, 'external_downloads');
      final Directory resume = Directory(
        DataRootMigrator.embeddedTorrentFastResumeDirectory(oldDocs.path),
      )..createSync(recursive: true);
      File(p.join(oldDocs.path, 'anime_downloads', 'content', 'ep01.mkv'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
      File(p.join(resume.path, 'aaaa.resume')).writeAsBytesSync(
        resumeBytes(p.join(oldDocs.path, 'anime_downloads', 'content')),
      );
      File(
        p.join(resume.path, 'bbbb.resume'),
      ).writeAsBytesSync(resumeBytes(externalRoot));
      File(p.join(resume.path, 'user_paused.json')).writeAsStringSync('[]');
      final FushiDatabase db = FushiDatabase(oldSupport.path);
      await db.setPref('seed', '1');
      await db.close();
    });
    tearDown(() {
      DataRootMigrator.debugFailMidRebase = false;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    DataRootMigrationRequest request({
      Future<void> Function(DataRootMigrationTarget target)? commit,
    }) => DataRootMigrationRequest(
      oldDocumentsRoot: oldDocs,
      oldSupportRoot: oldSupport,
      target: DataRootMigrationTarget.customRoot(newDataRoot),
      documentsTopLevelIncludeNames: null,
      closeResources: () async {},
      commitLocation: commit ?? (DataRootMigrationTarget _) async {},
    );

    test('数据根内的 save_path 改到新根，外部下载根原样', () async {
      final (Directory newDocs, Directory _) = await const DataRootMigrator()
          .migrate(request());
      final String resumeDir =
          DataRootMigrator.embeddedTorrentFastResumeDirectory(newDocs.path);
      expect(
        savePathOf(File(p.join(resumeDir, 'aaaa.resume'))),
        p.join(newDocs.path, 'anime_downloads', 'content'),
      );
      expect(
        savePathOf(File(p.join(resumeDir, 'bbbb.resume'))),
        externalRoot,
        reason: '用户自选的外部下载根不在搬移作用域内',
      );
      expect(
        File(p.join(resumeDir, 'user_paused.json')).readAsStringSync(),
        '[]',
      );
      expect(
        Directory(resumeDir).listSync().where(
          (FileSystemEntity e) => e.path.endsWith('.rebase-tmp'),
        ),
        isEmpty,
      );
    });

    test('DB 改写失败 → resume 写回原字节、随旧根回滚', () async {
      DataRootMigrator.debugFailMidRebase = true;
      await expectLater(
        const DataRootMigrator().migrate(request()),
        throwsA(isA<DataRootMigrationException>()),
      );
      final String resumeDir =
          DataRootMigrator.embeddedTorrentFastResumeDirectory(oldDocs.path);
      expect(
        savePathOf(File(p.join(resumeDir, 'aaaa.resume'))),
        p.join(oldDocs.path, 'anime_downloads', 'content'),
      );
    });

    test('提交位置失败 → resume 反向改写回旧根', () async {
      await expectLater(
        const DataRootMigrator().migrate(
          request(
            commit: (DataRootMigrationTarget _) async =>
                throw StateError('pref write failed'),
          ),
        ),
        throwsA(isA<DataRootMigrationException>()),
      );
      final String resumeDir =
          DataRootMigrator.embeddedTorrentFastResumeDirectory(oldDocs.path);
      expect(
        savePathOf(File(p.join(resumeDir, 'aaaa.resume'))),
        p.join(oldDocs.path, 'anime_downloads', 'content'),
      );
      expect(savePathOf(File(p.join(resumeDir, 'bbbb.resume'))), externalRoot);
    });
  });

  test('沙箱重定位同样改写 fast-resume（台账记着旧根）', () async {
    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_fastresume_sbx_',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));
    final String oldRoot = p.join(tmp.path, 'AAAA-1111', 'Documents');
    final String newRoot = p.join(tmp.path, 'BBBB-2222', 'Documents');
    final Directory resume = Directory(
      DataRootMigrator.embeddedTorrentFastResumeDirectory(newRoot),
    )..createSync(recursive: true);
    final File file = File(p.join(resume.path, 'cccc.resume'))
      ..writeAsBytesSync(
        resumeBytes(p.join(oldRoot, 'anime_downloads', 'content')),
      );
    final Directory support = Directory(p.join(tmp.path, 'support'))
      ..createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(support.path);
    addTearDown(db.close);
    await db.setPref(SandboxRelocation.lastDocumentsRootPrefKey, oldRoot);

    final SandboxRelocationOutcome outcome = await SandboxRelocation.reconcile(
      db: db,
      documentsRoot: newRoot,
      supportRoot: support.path,
    );

    expect(outcome.rebased, isTrue);
    expect(savePathOf(file), p.join(newRoot, 'anime_downloads', 'content'));
  });
}
