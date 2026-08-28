import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';

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
  });

  final FushiDatabase database;

  /// 在线漫画的本地落盘根（占位 manga.json、封面、章节页缓存）。
  final Directory rootDirectory;

  final OnlineMangaRuntimeAdapter adapter;

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
      return (await database.getEpubBook(bookKey))!;
    }

    final Directory directory = Directory(
      p.join(rootDirectory.path, 'library', bookKey),
    );
    await Directory(p.join(directory.path, 'chapters')).create(recursive: true);
    final File placeholder = File(p.join(directory.path, 'manga.json'));
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
    return (await database.getEpubBook(bookKey))!;
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
    int? nextIndex;
    final OnlineMangaChapter? selected = existing.currentChapter;
    if (selected != null) {
      final int found = chapters.indexWhere(
        (OnlineMangaChapter item) => item.key == selected.key,
      );
      if (found >= 0) nextIndex = found;
    }
    final OnlineMangaLibraryEntry updated = OnlineMangaLibraryEntry(
      runtime: existing.runtime,
      extensionPackage: existing.extensionPackage,
      sourceId: existing.sourceId,
      series: series,
      chapters: List<OnlineMangaChapter>.unmodifiable(chapters),
      currentChapterIndex: nextIndex,
    );
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: chapters.length,
      chaptersJson: _chaptersJson(chapters),
    );
    return updated;
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

  /// 某一章页图的落盘目录。
  Directory chapterDirectory(String bookKey, OnlineMangaChapter chapter) {
    final String digest = sha256
        .convert(utf8.encode(chapter.key))
        .toString()
        .substring(0, 24);
    return Directory(
      p.join(rootDirectory.path, 'reader-cache', 'chapters', bookKey, digest),
    );
  }

  /// 打开某一章，交给共享阅读器。
  Future<OnlineMangaReaderChapter> openChapter({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    bool persistProgress = true,
    int? initialPage,
  }) => adapter.openChapter(
    entry: entry,
    chapter: chapter,
    managedDirectory: chapterDirectory(bookKey, chapter),
    persistProgress: persistProgress,
    initialPage: initialPage,
  );

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
