import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_row.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_sidecar.dart';
import 'package:fushi/src/storage/download_layout.dart';

/// 下载根里一部「有文件、没书架行」的在线漫画（删书时选了保留已下载章节）。
class RecoverableOnlineManga {
  const RecoverableOnlineManga({
    required this.sidecar,
    required this.directory,
    required this.downloadedChapterCount,
  });

  final OnlineMangaShelfSidecar sidecar;

  /// 书目录 `<某个下载根>/manga/<bookKey>`。
  final String directory;

  /// 章节目录下已有 `manga.json` 的章数（只用于展示）。
  final int downloadedChapterCount;

  String get bookKey => sidecar.bookKey;
  String get title => sidecar.title;
}

/// 下载根里能重建 / 不能重建的漫画目录。
class OnlineMangaReshelfScan {
  const OnlineMangaReshelfScan({
    required this.recoverable,
    required this.unrecognizedDirectories,
  });

  final List<RecoverableOnlineManga> recoverable;

  /// 没有书架行、也没有（有效）侧车的书目录：源身份无从还原，不能重新入库。
  /// 本功能之前删书会连目录一起删，所以正常情况下这里为空；不为空多半是旧版删书
  /// 时目录被占用没删掉的残留。
  final List<String> unrecognizedDirectories;
}

/// 「重新入库」：把下载根 manga 域里没有书架行的漫画目录重新建回书架。
///
/// **bookKey 与 uid 原样还原**（侧车里存着）：卡片背面的来源链接先按 uid、再按
/// bookKey 找书（`card_source_router.dart`），两者不变，旧卡片就重新连得上。
///
/// app 用的实例由 `AppModel.onlineMangaReshelf` 持有。本文件只依赖下层模块（描述符、
/// 侧车、建行口、下载布局），不进 AppModel 所在的 import 环。
class OnlineMangaReshelf {
  OnlineMangaReshelf({
    required this.database,
    Future<DownloadLayout> Function()? downloadLayout,
  }) : _downloadLayout = downloadLayout;

  final FushiDatabase database;
  final Future<DownloadLayout> Function()? _downloadLayout;

  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// 可重新入库的集合可能变了（删书保留文件 / 重新入库 / 删文件 / 改下载根）。
  static Stream<void> get changes => _changes.stream;

  /// 通知 [changes] 的订阅者重扫。
  static void notifyChanged() => _changes.add(null);

  Future<DownloadLayout> _layout() =>
      (_downloadLayout ?? DownloadRoot.current)();

  /// 扫描全部下载根（当前根 + 历史根）的 manga 域。
  Future<OnlineMangaReshelfScan> scan() async {
    final DownloadLayout layout = await _layout();
    final List<RecoverableOnlineManga> recoverable = <RecoverableOnlineManga>[];
    final List<String> unrecognized = <String>[];
    final Set<String> seen = <String>{};
    for (final String mangaRoot in layout.allMangaRoots) {
      final Directory root = Directory(mangaRoot);
      if (!await root.exists()) continue;
      await for (final FileSystemEntity entity in root.list(
        followLinks: false,
      )) {
        if (entity is! Directory) continue;
        final String bookKey = p.basename(entity.path);
        if (!seen.add(bookKey)) continue;
        if (await database.getEpubBook(bookKey) != null) continue;
        final OnlineMangaShelfSidecar? sidecar =
            await OnlineMangaShelfSidecar.read(entity.path);
        if (sidecar == null || !_identityMatches(sidecar, bookKey)) {
          unrecognized.add(entity.path);
          continue;
        }
        recoverable.add(
          RecoverableOnlineManga(
            sidecar: sidecar,
            directory: entity.path,
            downloadedChapterCount: await _downloadedChapters(entity.path),
          ),
        );
      }
    }
    recoverable.sort(
      (RecoverableOnlineManga a, RecoverableOnlineManga b) =>
          a.title.compareTo(b.title),
    );
    return OnlineMangaReshelfScan(
      recoverable: recoverable,
      unrecognizedDirectories: unrecognized,
    );
  }

  /// 侧车自报的 bookKey 必须同时等于目录名、等于按描述符重新推导的键——三者一致
  /// 才敢建行（侧车被手改 / 拷错目录时宁可不认，也不建一条键与内容对不上的行）。
  static bool _identityMatches(OnlineMangaShelfSidecar sidecar, String dir) {
    if (sidecar.bookKey != dir) return false;
    final OnlineMangaLibraryEntry entry = sidecar.entry;
    return onlineMangaBookKeyOf(entry) == sidecar.bookKey;
  }

  static Future<int> _downloadedChapters(String bookDir) async {
    final Directory chapters = Directory(p.join(bookDir, 'chapters'));
    if (!await chapters.exists()) return 0;
    int count = 0;
    await for (final FileSystemEntity entity in chapters.list(
      followLinks: false,
    )) {
      if (entity is! Directory) continue;
      if (await File(
        p.join(entity.path, MangaStorage.kMangaJsonFileName),
      ).exists()) {
        count++;
      }
    }
    return count;
  }

  /// 把 [item] 建回书架，返回新行。已在库（并发重复点）原样返回现有行。
  Future<EpubBookRow> reshelve(RecoverableOnlineManga item) async {
    final EpubBookRow? existing = await database.getEpubBook(item.bookKey);
    if (existing != null) return existing;
    final OnlineMangaShelfSidecar sidecar = item.sidecar;
    final File placeholder = File(
      p.join(item.directory, MangaStorage.kMangaJsonFileName),
    );
    if (!await placeholder.exists()) {
      await placeholder.writeAsString('{"pages":[]}', flush: true);
    }
    final String? cover = sidecar.coverPath;
    // 与「入库」同一个建行口：侧车、互联对端墓碑、远端合集认领都在里面。重新入库
    // 不另拼一份（漏清对端墓碑，下一轮同步就把刚要回来的书从 host 删掉）。
    final EpubBookRow row = await insertOnlineMangaShelfRow(
      database,
      entry: sidecar.entry,
      uid: sidecar.uid,
      title: sidecar.title,
      author: sidecar.author,
      coverPath:
          cover != null && await File(p.join(item.directory, cover)).exists()
          ? cover
          : null,
      epubPath: MangaStorage.kMangaJsonFileName,
      extractDir: item.directory,
      importedAt: sidecar.importedAt,
      sourceMetadata: sidecar.sourceMetadata,
    );
    notifyChanged();
    return row;
  }

  /// 不要了：删掉这部漫画留在下载根里的文件。
  Future<void> discard(RecoverableOnlineManga item) async {
    if (await database.getEpubBook(item.bookKey) != null) {
      throw StateError('The manga is back in the library: ${item.bookKey}');
    }
    await EpubStorage.deleteBookDir(item.directory);
    notifyChanged();
  }
}
