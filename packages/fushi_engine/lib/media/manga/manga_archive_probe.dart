/// 「这个 `.zip` / `.epub` 是不是页图包」的**后台**定性入口。
///
/// [MangaArchiveImporter.looksLikeImageArchive] 是同步的：`.zip` 只读中央目录，
/// 但 `.epub` 要先整本解析一次（`EpubParser.parseSyncFromPath` 解压进临时目录）
/// 才能判「纯图」还是「有正文」。在来源库扫描 / 无头服务端的事件循环上同步跑它，
/// 一本几百 MB 的文字 EPUB 就能让 UI 卡死、服务端停止响应。
///
/// 判据只有那一份（[MangaArchiveImporter.looksLikeImageArchive]），这里只换执行
/// 位置：整个判定丢进一次性 isolate（[Isolate.run]），调用方 `await` 结果。判定
/// 本身不碰任何全局装配点（只读文件、写系统临时目录），所以能安全跨 isolate。
library;

import 'dart:isolate';

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
Future<bool> looksLikeImageArchiveInBackground(String archivePath) =>
    Isolate.run<bool>(
      () => MangaArchiveImporter.looksLikeImageArchive(archivePath),
      debugName: 'manga-archive-probe',
    );
