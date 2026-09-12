import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';

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
  });

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

  /// 身份串的分隔符：NUL。
  ///
  /// 写成 `String.fromCharCode(0)` 而不是源码里的裸字节，有两个理由：裸 NUL 会
  /// 让 git 把这个 .dart 判成 binary（diff/merge 直接丢改动）；而这个值一旦变
  /// 化，**全部存量书架条目的 bookKey 都会变** —— 主键失配 + 磁盘目录对不上 =
  /// 用户的在线漫画整片消失。让它显式、独立、难被顺手"清理"掉。
  static final String _identitySeparator = String.fromCharCode(0);

  /// 书架身份。
  ///
  /// 摘要而不是明文拼接：作品 URL 会进文件路径，长度和字符集都不可控。
  ///
  /// **v88 前的推导必须逐字节保持**：`packageName NUL sourceId NUL seriesKey`，
  /// 前缀 `mihon-`。这串既是 `epub_books` 主键**也是**磁盘目录名，改一个字符就
  /// 等于把所有已入库的在线漫画变成找不到的孤儿。所以 runtime 刻意**不进**
  /// 摘要，只做前缀——`OnlineMangaRuntimeKind.mihon.wireValue == 'mihon'`，
  /// 于是 Mihon 条目的键与 v88 完全一致，而 Aidoku 用 `aidoku-` 前缀天然不与
  /// 它撞键空间。
  static String bookKeyFor({
    required OnlineMangaRuntimeKind runtime,
    required String extensionPackage,
    required String sourceId,
    required String seriesKey,
  }) {
    final String identity = <String>[
      extensionPackage,
      sourceId,
      seriesKey,
    ].join(_identitySeparator);
    final String digest = sha256.convert(utf8.encode(identity)).toString();
    return '${runtime.wireValue}-${digest.substring(0, 32)}';
  }

  static String bookKeyOf(OnlineMangaLibraryEntry entry) => bookKeyFor(
    runtime: entry.runtime,
    extensionPackage: entry.extensionPackage,
    sourceId: entry.sourceId,
    seriesKey: entry.series.key,
  );

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
      await _adoptRemoteCollection(entry, row);
      return row;
    }

    final Directory directory = Directory(
      await MangaStorage.bookDirectory(bookKey),
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
        final String extension = _imageExtension(bytes);
        final File cover = File(p.join(directory.path, 'cover$extension'));
        await cover.writeAsBytes(bytes, flush: true);
        coverPath = p.basename(cover.path);
      } on Object {
        // 封面失败不能挡住「追这部作品」。作品页仍会经源的运行时按需取图。
      }
    }

    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        author: Value<String?>(entry.series.byline),
        coverPath: Value<String?>(coverPath),
        epubPath: p.basename(placeholder.path),
        extractDir: directory.path,
        chapterCount: entry.chapters.length,
        chaptersJson: _chaptersJson(entry.chapters),
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow row = (await database.getEpubBook(bookKey))!;
    await _adoptRemoteCollection(entry, row);
    return row;
  }

  Future<void> _adoptRemoteCollection(
    OnlineMangaLibraryEntry entry,
    EpubBookRow row,
  ) async {
    if (entry.runtime != OnlineMangaRuntimeKind.interconnect) return;
    await RemoteCollectionAdoptionService(database).adoptMembership(
      membership: RemoteCollectionMembership.fromJson(
        entry.series.raw['collection'],
      ),
      mediaType: MediaKind.epub,
      remoteEntryKey: entry.series.key,
      localEntryKey: row.uid,
    );
  }

  /// 用一次刷新的结果覆盖库里的描述符。
  ///
  /// 「当前章」按 [OnlineMangaChapter.key] 重新定位而不是沿用下标：源在两次
  /// 刷新之间插了新章，下标就会指到别的章上去。
  Future<OnlineMangaLibraryEntry?> refresh({
    required String bookKey,
    required OnlineMangaLibraryEntry? existing,
    required OnlineMangaSeries series,
    required List<OnlineMangaChapter> chapters,
  }) async {
    if (existing == null) return null;
    // 「刷出来一章都没有、而库里本来有」不是一次成功的刷新，是一次没抛异常的
    // 失败：Mihon 的 `chapterListParse` 撞上 Cloudflare 拦截页时通常**返回空
    // 列表而不抛**。照单全收就会把书架里那部漫画的章节整个清空、进度条归零，
    // 而且零提示。这里不落库、抛回给调用方走正常的失败展示（横幅 + 日志），
    // 库里的旧描述符原样保留。
    if (chapters.isEmpty && existing.chapters.isNotEmpty) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'Source returned no chapters; keeping the existing list.',
      );
    }
    int? nextIndex;
    final OnlineMangaChapter? selected = existing.currentChapter;
    if (selected != null) {
      final int found = chapters.indexWhere(
        (OnlineMangaChapter item) => item.key == selected.key,
      );
      if (found >= 0) nextIndex = found;
    }
    // copyWith 而不是重新构造：订阅两位（v3）必须跟着刷新活下来。
    final OnlineMangaLibraryEntry updated = existing.copyWith(
      series: series,
      chapters: List<OnlineMangaChapter>.unmodifiable(chapters),
      currentChapterIndex: nextIndex,
      clearCurrentChapter: nextIndex == null,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: chapters.length,
      chaptersJson: _chaptersJson(chapters),
    );
    await _publishNewChapters(
      bookKey: bookKey,
      title: series.title,
      previous: existing.chapters,
      current: chapters,
    );
    return updated;
  }

  /// 把这次刷新新出现的章投递成更新提醒。
  ///
  /// 挂在**落库之后**：先保证库里已经是新状态，再提醒——反过来的话，提醒发出去
  /// 而落库失败，用户点进来会看到一部没有那章的书。
  Future<void> _publishNewChapters({
    required String bookKey,
    required String title,
    required List<OnlineMangaChapter> previous,
    required List<OnlineMangaChapter> current,
  }) async {
    final UpdateFeedService? feed = updateFeed;
    if (feed == null) return;
    final List<OnlineMangaChapter> fresh = newlyAppearedChapters(
      previous: previous,
      current: current,
    );
    if (fresh.isEmpty) return;
    await feed.publishBatch(
      UpdateFeedKind.mangaChapter,
      <UpdateFeedDraft>[
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
      ],
    );
  }

  /// 联网刷新一条书架条目，成功则落库。
  Future<OnlineMangaLibraryEntry> refreshFromSource({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
  }) async {
    final OnlineMangaRefreshResult result = await adapter.refresh(entry);
    final OnlineMangaLibraryEntry? updated = await refresh(
      bookKey: bookKey,
      existing: entry,
      series: result.series,
      chapters: result.chapters,
    );
    return updated ?? entry;
  }

  /// 记下「用户选了这一章」。
  ///
  /// **与 v88 前的关键差异**：不再顺手把 `reader_positions` 清零。那一步是
  /// 「换章即丢上一章进度」的根因——位置表一本书恒一行，清零是当时唯一能让新章
  /// 从头开始的办法。现在每章进度住 `manga_chapter_states`，恢复由阅读器按
  /// chapterKey 查表决定，选章本身不再需要破坏任何进度。
  Future<OnlineMangaLibraryEntry> selectChapter({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required int chapterIndex,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= entry.chapters.length) {
      throw RangeError.index(chapterIndex, entry.chapters, 'chapterIndex');
    }
    final OnlineMangaLibraryEntry updated = entry.copyWith(
      currentChapterIndex: chapterIndex,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: _chaptersJson(updated.chapters),
    );
    return updated;
  }

  /// 写订阅位（设计稿 2026-09-12 §2.3）：只改 `sourceMetadata` 里的两个布尔，
  /// 章节列表 / 当前章原样。返回写回后的描述符。
  Future<OnlineMangaLibraryEntry> setSubscription({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required bool subscribed,
    required bool autoDownload,
  }) async {
    final OnlineMangaLibraryEntry updated = entry.copyWith(
      subscribed: subscribed,
      autoDownload: autoDownload,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: updated.chapters.length,
      chaptersJson: _chaptersJson(updated.chapters),
    );
    return updated;
  }

  /// 保证这条在线条目的书目录住在 `<fushi_books>/<bookKey>`，返回**当前**行。
  ///
  /// 2026-09-12 前在线条目落在 `<runtimeRoot>/library/<bookKey>`；章节页图只是
  /// `reader-cache/` 里的临时缓存。改成「先下载再读」后章目录成了正式内容，必须
  /// 和封面、占位 manga.json 一起住进标准书根，删书 / 备份 / 数据根迁移才能
  /// 按 `extractDir` 一并处理。首次访问时把旧目录整个搬过去（跨卷用复制 + 删除），
  /// 再改 `extractDir`；`bookKey` / `uid` 不变，进度零迁移。
  ///
  /// 已在标准位置的行原样返回（零 IO 之外的一次路径比较）。
  Future<EpubBookRow> ensureBookDirectory(EpubBookRow row) async {
    final String target = await MangaStorage.bookPath(row.bookKey);
    if (p.equals(row.extractDir, target)) return row;
    final Directory source = Directory(row.extractDir);
    final Directory destination = Directory(target);
    if (await source.exists()) {
      await _moveDirectory(source, destination);
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
    return (await database.getEpubBook(row.bookKey)) ??
        row.copyWith(extractDir: target);
  }

  /// 目录搬家：同卷直接 rename，跨卷（`rename` 抛 `FileSystemException`）退回
  /// 递归复制 + 删源。
  static Future<void> _moveDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      // 目标已有东西（半次迁移中断过）：合并进去而不是覆盖。
      await _copyTree(source, destination);
      await source.delete(recursive: true);
      return;
    }
    try {
      await source.rename(destination.path);
    } on FileSystemException {
      await _copyTree(source, destination);
      await source.delete(recursive: true);
    }
  }

  static Future<void> _copyTree(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final FileSystemEntity entity in source.list(followLinks: false)) {
      final String name = p.basename(entity.path);
      final String targetPath = p.join(destination.path, name);
      if (entity is Directory) {
        await _copyTree(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  /// 新读者从哪一章开始。
  ///
  /// 源按新→旧返回，所以「最旧的一章」= 列表末尾 = 第 1 话。
  static int initialChapterIndex(OnlineMangaLibraryEntry entry) {
    final int? selected = entry.currentChapterIndex;
    if (selected != null && selected >= 0 && selected < entry.chapters.length) {
      return selected;
    }
    return entry.chapters.isEmpty ? -1 : entry.chapters.length - 1;
  }

  /// 「继续阅读」落到哪一章。
  ///
  /// 优先取**最近读过且没读完**的那一章（`manga_chapter_states.updatedAt` 最大
  /// 且 `readAt == null`）；全读完了就落到它之后的下一话；一次没读过就走
  /// [initialChapterIndex]。这比直接用 `currentChapterIndex` 准：那个字段只记
  /// 「最后一次选了哪章」，用户在作品页点开一章看了两眼退出来，它也会被改写。
  static int resumeChapterIndex(
    OnlineMangaLibraryEntry entry,
    Map<String, MangaChapterStateRow> states,
  ) {
    if (entry.chapters.isEmpty) return -1;
    int bestIndex = -1;
    int bestUpdatedAt = -1;
    for (int index = 0; index < entry.chapters.length; index++) {
      final MangaChapterStateRow? state = states[entry.chapters[index].key];
      if (state == null) continue;
      if (state.updatedAt > bestUpdatedAt) {
        bestUpdatedAt = state.updatedAt;
        bestIndex = index;
      }
    }
    if (bestIndex < 0) return initialChapterIndex(entry);
    final MangaChapterStateRow best = states[entry.chapters[bestIndex].key]!;
    if (best.readAt == null) return bestIndex;
    // 最近那章已读完 → 往「更新」的方向走一话（列表是新→旧，所以是 -1）。
    // 已经是最新一话就停在原地，让用户看到自己读到头了。
    return bestIndex > 0 ? bestIndex - 1 : bestIndex;
  }

  static String _chaptersJson(List<OnlineMangaChapter> chapters) =>
      jsonEncode(<Map<String, Object?>>[
        for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
      ]);

  static Future<void> _writeAtomic(File target, String contents) async {
    await target.parent.create(recursive: true);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static String _imageExtension(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
      return '.webp';
    }
    if (bytes.length >= 6 && String.fromCharCodes(bytes.take(3)) == 'GIF') {
      return '.gif';
    }
    return '.jpg';
  }
}
