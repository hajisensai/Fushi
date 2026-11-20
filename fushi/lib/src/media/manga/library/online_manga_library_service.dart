import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart'
    show mangaImageContentType;
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException, writeCoverBytesAtomically;
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/storage/directory_move.dart';
import 'package:fushi/src/storage/download_layout.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_row.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_sidecar.dart';

/// 从一个已就绪的 [MihonManager] 直接建服务。
///
/// 源浏览页手上本来就有 manager，没必要为了「加入书架」再绕一次 AppModel；而
/// 跨运行时的分派（书架/作品页只有 bookKey，不知道该找谁）走
/// `AppModel.onlineMangaLibraryService`。
OnlineMangaLibraryService mihonOnlineLibraryService(MihonManager manager) =>
    OnlineMangaLibraryService(
      database: manager.database,
      rootDirectory: manager.rootDirectory,
      adapter: MihonLibraryAdapter(manager),
    );

/// 一次源刷新落库的结果：写回后的描述符 + 相对库里旧章表新出现的章。
typedef OnlineMangaRefreshOutcome = ({
  OnlineMangaLibraryEntry entry,
  List<OnlineMangaChapter> fresh,
});

/// 在线漫画书目录的唯一真相：库里那一行的 `extractDir`。
///
/// **不要**再按 bookKey 推导书目录：下载根可以改，用户改根时选「只用于新下载」的
/// 旧条目留在旧根，还没访问过的旧条目也可能仍在 `fushi_books`——按 bookKey 推导
/// 出来的路径对它们都是错的（BUG：改了下载目录，漫画仍下到默认目录的同一根因）。
/// 行不存在时抛 [StateError]：调用方拿着空路径去删章会删到相对路径上。
Future<String> onlineMangaBookDirectory(
  FushiDatabase database,
  String bookKey,
) async {
  final EpubBookRow? row = await database.getEpubBook(bookKey);
  if (row == null || row.extractDir.isEmpty) {
    throw StateError('The manga is not in the library: $bookKey');
  }
  return row.extractDir;
}

/// 在线漫画书架条目的读写口，**与运行时无关**。
///
/// v88 前这些逻辑住在 `MihonLibraryService` 里且签名上焊着 `MihonManager`，
/// 于是 Aidoku 只能瞬时浏览、进不了书架。现在唯一的运行时依赖是构造时传进来的
/// [OnlineMangaRuntimeAdapter]。
class OnlineMangaLibraryService {
  const OnlineMangaLibraryService({
    required this.database,
    required this.rootDirectory,
    required this.adapter,
    this.updateFeed,
    Future<DownloadLayout> Function()? downloadLayout,
  }) : _downloadLayout = downloadLayout;

  final FushiDatabase database;

  /// **旧**落盘根（`<runtimeRoot>/library/<bookKey>` 与 `reader-cache/`）。
  ///
  /// 2026-09-12 起在线条目统一住进 `<fushi_books>/<bookKey>`（设计稿 §2.1），这个根
  /// 只剩两个用途：[ensureBookDirectory] 识别还没迁走的旧目录，以及顺手清掉该书的
  /// 旧 `reader-cache/`。新条目不再往这里写任何东西。
  final Directory rootDirectory;

  final OnlineMangaRuntimeAdapter adapter;

  /// 更新提醒的投递口（v101）。可空是**刻意**的：源浏览页临时建的服务实例、
  /// 单测里的实例都不需要提醒，而「刷新出新章」这件事的判据不该因为少一个可选
  /// 依赖就走两条路径。null = 只落库不提醒。
  final UpdateFeedService? updateFeed;

  /// 下载根布局的取值口；null = 进程内的 [DownloadRoot.current]（AppModel 装的
  /// 解析器，没装时是默认根）。单测注入假根。
  final Future<DownloadLayout> Function()? _downloadLayout;

  Future<DownloadLayout> _layout() =>
      (_downloadLayout ?? DownloadRoot.current)();

  /// 书架身份（推导与稳定性约束见 [onlineMangaBookKeyFor]）。
  static String bookKeyFor({
    required OnlineMangaRuntimeKind runtime,
    required String extensionPackage,
    required String sourceId,
    required String seriesKey,
  }) => onlineMangaBookKeyFor(
    runtime: runtime,
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    seriesKey: seriesKey,
  );

  static String bookKeyOf(OnlineMangaLibraryEntry entry) =>
      onlineMangaBookKeyOf(entry);

  Future<EpubBookRow?> find(OnlineMangaLibraryEntry entry) =>
      database.getEpubBook(bookKeyOf(entry));

  /// 入库（已在库则只刷新，不重复建行）。
  Future<EpubBookRow> add(OnlineMangaLibraryEntry entry) async {
    final String bookKey = bookKeyOf(entry);
    final EpubBookRow? existing = await database.getEpubBook(bookKey);
    if (existing != null) {
      await refresh(
        bookKey: bookKey,
        existing: OnlineMangaLibraryEntry.tryParse(existing.sourceMetadata),
        series: entry.series,
        chapters: entry.chapters,
      );
      final EpubBookRow row = (await database.getEpubBook(bookKey))!;
      await adoptOnlineMangaRemoteCollection(database, entry, row);
      return row;
    }

    // 新条目落 `<下载根>/manga/<bookKey>`（下载根是用户在「下载」设置里选的目录）。
    final Directory directory = Directory(
      (await _layout()).mangaBookPath(bookKey),
    );
    await Directory(p.join(directory.path, 'chapters')).create(recursive: true);
    final File placeholder = File(
      p.join(directory.path, MangaStorage.kMangaJsonFileName),
    );
    await _writeAtomic(placeholder, '{"pages":[]}');

    String? coverPath;
    final String? coverUrl = entry.series.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      try {
        final List<int> bytes = await adapter.fetchCover(entry, coverUrl);
        // BUG-2496：未知魔数（源返回的 Cloudflare 拦截页 / HTML 错误页）直接不落盘，
        // 不再回落成 `cover.jpg`——那种文件一到渲染层就是 `Invalid image data`。
        final String? extension = _imageExtension(bytes);
        if (extension == null) {
          throw const CoverImageInvalidException(
            'online manga cover is not PNG/WebP/GIF/JPEG',
          );
        }
        final String coverFile = p.join(directory.path, 'cover$extension');
        // 收口再查一次完整性（截断 JPEG/PNG）+ 原子写 + 驱逐解码缓存。
        await writeCoverBytesAtomically(bytes: bytes, destPath: coverFile);
        coverPath = p.basename(coverFile);
      } on CoverImageInvalidException catch (e) {
        ErrorLogService.instance.logDiagnostic(
          'OnlineMangaLibraryService.cover',
          e,
        );
      } on Object {
        // 封面失败不能挡住「追这部作品」。作品页仍会经源的运行时按需取图。
      }
    }

    // 建行与它的全部副作用（侧车、互联对端墓碑、远端合集认领）只走这一个口，
    // 「重新入库」同用（OnlineMangaReshelf.reshelve）。
    return insertOnlineMangaShelfRow(
      database,
      entry: entry,
      title: entry.series.title,
      author: entry.series.byline,
      coverPath: coverPath,
      epubPath: p.basename(placeholder.path),
      extractDir: directory.path,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 用一次刷新的结果覆盖库里描述符的**作品资料与章表**。
  ///
  /// 「当前章」按 [OnlineMangaChapter.key] 重新定位而不是沿用下标：源在两次
  /// 刷新之间插了新章，下标就会指到别的章上去。
  ///
  /// [existing] 只是调用方手上的快照：落库时在事务里重读当前描述符
  /// （gap-mangamisc-1），订阅位、当前章取**库里的**——刷新在飞的几秒里用户点了
  /// 订阅或换了章，不会被这次写回旧值。库里读不出描述符时才退回 [existing]。
  Future<OnlineMangaLibraryEntry?> refresh({
    required String bookKey,
    required OnlineMangaLibraryEntry? existing,
    required OnlineMangaSeries series,
    required List<OnlineMangaChapter> chapters,
  }) async => (await _refreshWithOutcome(
    bookKey: bookKey,
    existing: existing,
    series: series,
    chapters: chapters,
  ))?.entry;

  Future<OnlineMangaRefreshOutcome?> _refreshWithOutcome({
    required String bookKey,
    required OnlineMangaLibraryEntry? existing,
    required OnlineMangaSeries series,
    required List<OnlineMangaChapter> chapters,
  }) async {
    if (existing == null) return null;
    final List<OnlineMangaChapter> list = List<OnlineMangaChapter>.unmodifiable(
      chapters,
    );
    OnlineMangaLibraryEntry apply(OnlineMangaLibraryEntry current) {
      // 「刷出来一章都没有、而库里本来有」不是一次成功的刷新，是一次没抛异常的
      // 失败：Mihon 的 `chapterListParse` 撞上 Cloudflare 拦截页时通常**返回空
      // 列表而不抛**。照单全收就会把书架里那部漫画的章节整个清空、进度条归零，
      // 而且零提示。这里不落库、抛回给调用方走正常的失败展示（横幅 + 日志），
      // 库里的旧描述符原样保留。
      if (list.isEmpty && current.chapters.isNotEmpty) {
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'Source returned no chapters; keeping the existing list.',
        );
      }
      int? nextIndex;
      final OnlineMangaChapter? selected = current.currentChapter;
      if (selected != null) {
        final int found = list.indexWhere(
          (OnlineMangaChapter item) => item.key == selected.key,
        );
        if (found >= 0) nextIndex = found;
      }
      // copyWith 而不是重新构造：订阅两位（v3）必须跟着刷新活下来。
      return current.copyWith(
        series: series,
        chapters: list,
        currentChapterIndex: nextIndex,
        clearCurrentChapter: nextIndex == null,
      );
    }

    final OnlineMangaRefreshOutcome? written = await database
        .rewriteEpubBookMihonState<OnlineMangaRefreshOutcome>(bookKey, (
          String? metadata,
        ) {
          final OnlineMangaLibraryEntry current =
              OnlineMangaLibraryEntry.tryParse(metadata) ?? existing;
          final OnlineMangaLibraryEntry updated = apply(current);
          return (
            sourceMetadata: updated.encode(),
            chapterCount: list.length,
            chaptersJson: _chaptersJson(list),
            result: (
              entry: updated,
              fresh: newlyAppearedChapters(
                previous: current.chapters,
                current: list,
              ),
            ),
          );
        });
    if (written == null) {
      // 行已不在（刷新途中被移出书架）：不落库，按旧语义把结果交回调用方展示。
      return (
        entry: apply(existing),
        fresh: newlyAppearedChapters(
          previous: existing.chapters,
          current: list,
        ),
      );
    }
    await _refreshSidecar(bookKey);
    await _publishNewChapters(
      bookKey: bookKey,
      title: series.title,
      fresh: written.fresh,
    );
    return written;
  }

  /// 把这次刷新新出现的章投递成更新提醒。
  ///
  /// 挂在**落库之后**：先保证库里已经是新状态，再提醒——反过来的话，提醒发出去
  /// 而落库失败，用户点进来会看到一部没有那章的书。
  Future<void> _publishNewChapters({
    required String bookKey,
    required String title,
    required List<OnlineMangaChapter> fresh,
  }) async {
    final UpdateFeedService? feed = updateFeed;
    if (feed == null || fresh.isEmpty) return;
    await feed.publishBatch(UpdateFeedKind.mangaChapter, <UpdateFeedDraft>[
      for (final OnlineMangaChapter chapter in fresh)
        UpdateFeedDraft(
          kind: UpdateFeedKind.mangaChapter,
          targetKey: mangaChapterTargetKey(
            bookKey: bookKey,
            chapterKey: chapter.key,
          ),
          title: title,
          subtitle: mangaChapterDisplayName(chapter),
          detailJson: jsonEncode(<String, Object?>{
            'bookKey': bookKey,
            'chapterKey': chapter.key,
          }),
        ),
    ]);
  }

  /// 联网刷新一条书架条目，成功则落库。
  Future<OnlineMangaLibraryEntry> refreshFromSource({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async => (await refreshFromSourceWithOutcome(
    bookKey: bookKey,
    entry: entry,
  )).entry;

  /// [refreshFromSource]，另外交回「相对**库里**旧章表新出现的章」（后台更新探针
  /// 据此自动下载；按调用方快照算会把作品页刚刷进来的章再当新章排一遍）。
  Future<OnlineMangaRefreshOutcome> refreshFromSourceWithOutcome({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async {
    final OnlineMangaRefreshResult result = await adapter.refresh(entry);
    return await _refreshWithOutcome(
          bookKey: bookKey,
          existing: entry,
          series: result.series,
          chapters: result.chapters,
        ) ??
        (entry: entry, fresh: const <OnlineMangaChapter>[]);
  }

  /// 记下「用户选了这一章」，返回写回后的描述符（以它的 `currentChapterIndex`
  /// 为准开章）。
  ///
  /// 按 [chapterKey] 而不是下标（gap-mangamisc-1）：调用方的下标是按它手上那份章表
  /// 算的，库里的章表可能已被一次刷新改过（源插了新章），同一个下标指的是另一章。
  /// 事务内重读当前描述符，只改当前章；章已不在库里的章表上时抛 [StateError]。
  ///
  /// **与 v88 前的关键差异**：不再顺手把 `reader_positions` 清零。那一步是
  /// 「换章即丢上一章进度」的根因——位置表一本书恒一行，清零是当时唯一能让新章
  /// 从头开始的办法。现在每章进度住 `manga_chapter_states`，恢复由阅读器按
  /// chapterKey 查表决定，选章本身不再需要破坏任何进度。
  Future<OnlineMangaLibraryEntry> selectChapter({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required String chapterKey,
  }) => _rewriteEntry(bookKey, entry, (OnlineMangaLibraryEntry current) {
    final int index = current.indexOfChapterKey(chapterKey);
    if (index < 0) {
      throw StateError('The chapter is no longer listed: $chapterKey');
    }
    return current.copyWith(currentChapterIndex: index);
  });

  /// 写订阅位（设计稿 2026-09-12 §2.3）：只改 `sourceMetadata` 里的两个布尔，
  /// 章节列表 / 当前章取库里当前值（事务内重读，gap-mangamisc-1）。返回写回后的
  /// 描述符。
  Future<OnlineMangaLibraryEntry> setSubscription({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required bool subscribed,
    required bool autoDownload,
  }) => _rewriteEntry(
    bookKey,
    entry,
    (OnlineMangaLibraryEntry current) =>
        current.copyWith(subscribed: subscribed, autoDownload: autoDownload),
  );

  /// 事务内重读描述符 → [change] → 写回 + 刷侧车。库里读不出描述符时以调用方的
  /// [fallback] 为底；行已不在时不写，返回 `change(fallback)`（与改造前「写一个
  /// 不存在的行 = 无操作」同义）。
  Future<OnlineMangaLibraryEntry> _rewriteEntry(
    String bookKey,
    OnlineMangaLibraryEntry fallback,
    OnlineMangaLibraryEntry Function(OnlineMangaLibraryEntry current) change,
  ) async {
    final OnlineMangaLibraryEntry? written = await database
        .rewriteEpubBookMihonState<OnlineMangaLibraryEntry>(bookKey, (
          String? metadata,
        ) {
          final OnlineMangaLibraryEntry updated = change(
            OnlineMangaLibraryEntry.tryParse(metadata) ?? fallback,
          );
          return (
            sourceMetadata: updated.encode(),
            chapterCount: updated.chapters.length,
            chaptersJson: _chaptersJson(updated.chapters),
            result: updated,
          );
        });
    if (written == null) return change(fallback);
    await _refreshSidecar(bookKey);
    return written;
  }

  /// 保证这条在线条目的书目录住在**某个下载根**的 `manga/<bookKey>` 下，返回
  /// **当前**行。
  ///
  /// 在线漫画的章节是下载内容，跟随用户在「下载」设置里选的下载根（BUG：改了下载
  /// 目录，漫画仍然下到默认目录）。三种存量位置首次访问时整个搬进当前下载根
  /// `<下载根>/manga/<bookKey>`（跨卷复制 + 删源，中断后再来一次是合并），再改
  /// `extractDir`；`bookKey` / `uid` 不变，进度零迁移：
  ///  - 2026-09-12 前的 `<runtimeRoot>/library/<bookKey>`；
  ///  - 2026-11 前的 `<fushi_books>/<bookKey>`；
  ///  - 任何不在下载根布局里的旧路径。
  ///
  /// 已在下载布局（`<某个下载根>/manga/<bookKey>`，见
  /// [DownloadLayout.isMangaBookDirectory]）里的行原样返回：用户改下载根时选
  /// 「只用于新下载」，旧根里的漫画就该留在旧根，不能在打开时被偷偷搬走。
  Future<EpubBookRow> ensureBookDirectory(EpubBookRow row) async {
    final bool alreadyInLayout = DownloadLayout.isMangaBookDirectory(
      row.extractDir,
      row.bookKey,
    );
    final EpubBookRow current = await relocateBookDirectory(
      database,
      row,
      layout: await _layout(),
    );
    if (alreadyInLayout) return current;
    // 旧的阅读期页缓存对新布局毫无价值，顺手清掉——失败只记日志，不挡打开。
    final Directory staleCache = Directory(
      p.join(rootDirectory.path, 'reader-cache', 'chapters', row.bookKey),
    );
    try {
      if (await staleCache.exists()) await staleCache.delete(recursive: true);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'OnlineMangaLibraryService.cleanReaderCache',
        error,
        stack,
      );
    }
    return current;
  }

  /// [ensureBookDirectory] 的核心（不依赖运行时适配器）：删书「保留已下载章节」
  /// 也要先把书目录归位到下载根，重新入库才扫得到它（`ReaderFushiSource.deleteBook`）。
  static Future<EpubBookRow> relocateBookDirectory(
    FushiDatabase database,
    EpubBookRow row, {
    required DownloadLayout layout,
  }) async {
    final String target = layout.mangaBookPath(row.bookKey);
    if (DownloadLayout.isMangaBookDirectory(row.extractDir, row.bookKey)) {
      if (await Directory(row.extractDir).exists() ||
          !await Directory(target).exists()) {
        await _ensureSidecar(row);
        return row;
      }
      // 行指着一个已经不存在的下载根位置、而当前根里有这本书：下载根迁移在
      // 「目录已改名、库还没改写」之间被打断过。按目录事实把行指回来。
      await database.updateEpubBookContentPaths(
        row.bookKey,
        extractDir: target,
      );
      return (await database.getEpubBook(row.bookKey)) ??
          row.copyWith(extractDir: target);
    }
    final Directory source = Directory(row.extractDir);
    final Directory destination = Directory(target);
    if (row.extractDir.isNotEmpty && await source.exists()) {
      await moveDirectoryMerging(source, destination);
    } else {
      await destination.create(recursive: true);
    }
    await Directory(p.join(target, 'chapters')).create(recursive: true);
    final File placeholder = File(
      p.join(target, MangaStorage.kMangaJsonFileName),
    );
    if (!await placeholder.exists()) {
      await _writeAtomic(placeholder, '{"pages":[]}');
    }
    await database.updateEpubBookContentPaths(row.bookKey, extractDir: target);
    final EpubBookRow current =
        (await database.getEpubBook(row.bookKey)) ??
        row.copyWith(extractDir: target);
    await _writeSidecarLogged(current);
    return current;
  }

  /// 侧车缺失时补写（下载根里每部在线漫画都要能被「重新入库」认出来）。
  static Future<void> _ensureSidecar(EpubBookRow row) async {
    if (await onlineMangaShelfSidecarFile(row.extractDir).exists()) return;
    await _writeSidecarLogged(row);
  }

  static Future<void> _writeSidecarLogged(EpubBookRow row) async {
    try {
      await writeOnlineMangaShelfSidecar(row);
    } on FileSystemException catch (error, stack) {
      ErrorLogService.instance.log(
        'OnlineMangaLibraryService.writeSidecar',
        error,
        stack,
      );
    }
  }

  /// 描述符改动后把书架侧车同步成库里的最新行。
  ///
  /// 侧车只是「删书后还能重新入库」的冗余副本，刷新章节列表不该因为它写不进去
  /// 而失败：写失败记日志（删书保留文件时会再强制写一次并报错）。
  Future<void> _refreshSidecar(String bookKey) async {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) return;
    await _writeSidecarLogged(row);
  }

  /// 新读者从哪一章开始（[mangaInitialChapterIndex]）。
  static int initialChapterIndex(OnlineMangaLibraryEntry entry) =>
      mangaInitialChapterIndex(entry);

  /// 「继续阅读」落到哪一章（[continueMangaChapterIndex]）。这比直接用
  /// `currentChapterIndex` 准：那个字段只记「最后一次选了哪章」，用户在作品页点开
  /// 一章看了两眼退出来，它也会被改写。[target] 见 [MangaResumeTarget]。
  static int resumeChapterIndex(
    OnlineMangaLibraryEntry entry,
    Map<String, MangaChapterStateRow> states, {
    MangaResumeTarget target = MangaResumeTarget.furthestProgress,
  }) => continueMangaChapterIndex(entry, states, target: target);

  static String _chaptersJson(List<OnlineMangaChapter> chapters) =>
      onlineMangaChaptersJson(chapters);

  static Future<void> _writeAtomic(File target, String contents) async {
    await target.parent.create(recursive: true);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  /// 按魔数定封面扩展名（与页图同一判据 [mangaImageContentType]）；不是 PNG / WebP /
  /// GIF / JPEG / AVIF 返回 null（调用方不落盘）。
  static String? _imageExtension(List<int> bytes) =>
      switch (mangaImageContentType(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      )) {
        'image/png' => '.png',
        'image/webp' => '.webp',
        'image/gif' => '.gif',
        'image/jpeg' => '.jpg',
        'image/avif' => '.avif',
        _ => null,
      };
}
