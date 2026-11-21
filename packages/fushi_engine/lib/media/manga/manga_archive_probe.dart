/// 「这个 `.zip` / `.epub` 是不是页图包」的**后台**定性入口。
///
/// [MangaArchiveImporter.looksLikeImageArchive] 是同步的：`.zip` 只读中央目录，
/// 但 `.epub` 要先把 container / OPF / spine 文档解出来、整本解析一次
/// （`EpubParser.parseSyncFromPath`）才能判「纯图」还是「有正文」。在来源库扫描 /
/// 无头服务端 / 漫画导入框的事件循环上同步跑它，一本几百 MB 的文字 EPUB 就能让
/// UI 卡死、服务端停止响应。
///
/// 判据只有那一份（[MangaArchiveImporter.looksLikeImageArchive] /
/// [MangaArchiveImporter.imageEpubRejection]），这里只换执行位置：判定丢进一次性
/// isolate（[Isolate.run]），调用方 `await` 结果。判定本身不碰任何全局装配点（只读
/// 文件、写调用方给的目录），所以能安全跨 isolate。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:path/path.dart' as p;

/// 扩展名本身二义、必须开包才能定性的载体（带点、小写）。其余漫画载体扩展名
/// （`.cbz` / `.rar` / `.cbr` / `.cb7`）光看扩展名就是漫画包。
const Set<String> kAmbiguousMangaArchiveExtensions = <String>{'.zip', '.epub'};

/// [archivePath] 是否需要开包定性（见 [kAmbiguousMangaArchiveExtensions]）。
bool mangaArchiveNeedsContentProbe(String archivePath) =>
    kAmbiguousMangaArchiveExtensions.contains(
      p.extension(archivePath).toLowerCase(),
    );

/// 在后台 isolate 里跑 [MangaArchiveImporter.looksLikeImageArchive]。
///
/// [db]：给了就把 `.epub` 探测的解压落点建在书库根下的 `.tmp-*`
/// （[EpubImporter.createStagingDir]），用完在这里删；进程死在探测中途时残留归
/// 导入残留清扫管。不给才退回系统临时目录（探测自己建、自己删，崩溃残留 app 内
/// 看不见也清不掉）。
///
/// `.epub` 的否决理由在主 isolate 上记日志：后台 isolate 里 `engineLog` 没装配，
/// 在那边记的诊断落不进反馈日志。
Future<bool> looksLikeImageArchiveInBackground(
  String archivePath, {
  FushiDatabase? db,
}) async {
  if (p.extension(archivePath).toLowerCase() != '.epub') {
    return _looksLikeImageArchiveInIsolate(archivePath);
  }
  final String? probeDir = db == null
      ? null
      : await EpubImporter.createStagingDir(db);
  try {
    final String? rejection = await _imageEpubRejectionInIsolate(
      archivePath,
      probeDir,
    );
    if (rejection != null) {
      MangaArchiveImporter.logEpubRejection(archivePath, rejection);
    }
    return rejection == null;
  } finally {
    if (probeDir != null) {
      final Directory dir = Directory(probeDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// 只收字符串参数的独立函数：[Isolate.run] 的闭包不会连带捕获调用方作用域里的
/// 不可发送对象（数据库句柄）。
Future<bool> _looksLikeImageArchiveInIsolate(String archivePath) =>
    Isolate.run<bool>(
      () => MangaArchiveImporter.looksLikeImageArchive(archivePath),
      debugName: 'manga-archive-probe',
    );

Future<String?> _imageEpubRejectionInIsolate(
  String archivePath,
  String? probeDir,
) => Isolate.run<String?>(
  () =>
      MangaArchiveImporter.imageEpubRejection(archivePath, probeDir: probeDir),
  debugName: 'manga-epub-probe',
);
