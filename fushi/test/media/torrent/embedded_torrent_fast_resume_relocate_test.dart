// BUG-3541 真引擎往返：libtorrent 写出的 fast-resume 经数据根迁移改写后，新
// session 从新根恢复、直接认出已完成的数据（不按旧路径找文件、不从零重下）。
//
// 缺原生库（FUSHI_TORRENT_LIB 未指向 fushi_torrent_ffi）整条 skip；纯 Dart 的
// 改写与迁移流程由 test/storage/data_root_migrator_fast_resume_test.dart 覆盖。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/media/torrent/torrent_fast_resume.dart';
import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:path/path.dart' as p;

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

Future<FtTorrentStatus> _waitForComplete(
  EmbeddedTorrentSession session, {
  required String what,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < const Duration(seconds: 30)) {
    final List<FtTorrentStatus> listed = session.listTorrents();
    if (listed.isNotEmpty &&
        (listed.single.isSeeding || listed.single.isFinished) &&
        listed.single.progress >= 1) {
      return listed.single;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('timed out waiting for $what: ${session.listTorrents()}');
}

void main() {
  final String? libPath = _resolveLibPath();

  test(
    '迁移改写后的 fast-resume 让新 session 在新根直接认出已完成数据',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync(
        'fushi_fastresume_rt_',
      );
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows 偶发句柄未释放；留给系统清理。
        }
      });
      final String oldDocs = p.join(tmp.path, 'old', 'documents');
      final String newDocs = p.join(tmp.path, 'new', 'documents');
      final String oldContent = p.join(oldDocs, 'anime_downloads', 'content');
      final File payload = File(p.join(oldContent, 'ep01.mkv'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          Uint8List.fromList(List<int>.generate(256 * 1024, (int i) => i * 7)),
        );

      final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.open(
        libraryPath: libPath!,
      );
      final String torrentPath = p.join(tmp.path, 'ep01.torrent');
      final FtAddResult made = engine.makeTorrent(
        contentPath: payload.path,
        outTorrentPath: torrentPath,
      );
      expect(made.ok, isTrue, reason: '${made.error}');

      // ① 旧根：加种 → 校验完成 → 强制落 resume → 关 session（迁移前的停机序列）。
      final String oldResume =
          DataRootMigrator.embeddedTorrentFastResumeDirectory(oldDocs);
      final EmbeddedTorrentSession first = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      )!;
      expect(
        first.addTorrentFile(torrentPath, savePath: oldContent).ok,
        isTrue,
      );
      await _waitForComplete(first, what: 'initial check');
      expect(first.saveResumeData(oldResume).saved, 1);
      first.close();
      final File oldResumeFile = File(
        p.join(oldResume, '${made.id}$kEmbeddedTorrentFastResumeExtension'),
      );
      expect(
        readFastResumeSavePath(oldResumeFile.readAsBytesSync()),
        oldContent,
      );

      // ② 搬目录 + 改写（迁移器的同一入口与作用域判据）。
      Directory(p.dirname(newDocs)).createSync(recursive: true);
      Directory(oldDocs).renameSync(newDocs);
      final FastResumeRebase rebase =
          await DataRootMigrator.rebaseEmbeddedTorrentFastResume(
            documentsRoot: newDocs,
            docs: DocumentsPathRebaser(
              oldRoot: oldDocs,
              newRoot: newDocs,
              scopeTopLevelNames: AppPaths.fushiOwnedDocumentsEntries,
            ),
          );
      expect(rebase.rewrittenCount, 1);

      // ③ 新 session 从新根恢复：save_path 是新根，数据直接认成已完成。
      final EmbeddedTorrentSession second = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      )!;
      addTearDown(second.close);
      final List<String> restored = second.loadResumeDir(
        DataRootMigrator.embeddedTorrentFastResumeDirectory(newDocs),
      );
      expect(
        restored.map((String id) => id.toLowerCase()),
        contains(made.id!.toLowerCase()),
      );
      final FtTorrentStatus status = await _waitForComplete(
        second,
        what: 'restore at new root',
      );
      expect(
        p.normalize(status.savePath),
        p.normalize(p.join(newDocs, 'anime_downloads', 'content')),
      );
    },
    skip: libPath == null ? 'fushi_torrent_ffi native lib not built' : null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
