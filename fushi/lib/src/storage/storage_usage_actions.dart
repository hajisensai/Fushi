import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart' show SrtBookRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_library_delete.dart'
    show VideoLibraryDeleteResult, deleteVideoBooksWithDecision;
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookRepository;
import 'package:fushi_engine/sync/deletion_propagation.dart'
    show DeleteDecision, DeleteScope;
import 'package:fushi/src/media/video/video_shader_downloader.dart'
    show anime4kInstalledBytes, deleteAnime4kShaderFiles;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show bookTagMapProvider, srtBookTagMapProvider;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储」页的取数与删除原语集合：页面（`StorageUsageView`）与控制通道
/// （`ctl_settings_body_storage.dart`）共用同一份接线，删除一律走各域既有路径
/// （书 `ReaderFushiSource.deleteBook`、纯字幕书 `SrtBookRepository.delete`、
/// 词典 `AppModel.deleteDictionary`、主库快照 `deleteDatabaseSnapshotFiles`、
/// Anime4K `deleteAnime4kShaderFiles`）。
class StorageUsageActions {
  const StorageUsageActions({
    required this.booksProvider,
    required this.dictionaryNamesProvider,
    required this.deleteBook,
    required this.deleteSrtBook,
    required this.deleteDictionary,
    required this.deleteDatabaseSnapshots,
    required this.deleteFiles,
    this.dictionaryDisplayNamesProvider,
    this.videosProvider,
    this.deleteVideo,
    this.anime4kBytesProvider = anime4kInstalledBytes,
    this.anime4kDelete = deleteAnime4kShaderFiles,
  });

  /// 真实接线（原 `settings_schema_storage.dart` 里的闭包）。
  factory StorageUsageActions.of(SettingsContext c) => StorageUsageActions(
    booksProvider: () => loadStorageBookRefs(c.appModel.database),
    dictionaryNamesProvider: () async => <String>[
      for (final Dictionary d in c.appModel.dictionaries) d.name,
    ],
    // 只翻译明细行的 label；真名列表照旧驱动目录扫描与删除路由。
    dictionaryDisplayNamesProvider: () async =>
        c.appModel.dictionaryDisplayNameOverrides,
    deleteBook: (String bookKey) async {
      final DeleteBookResult result = await ReaderFushiSource.instance
          .deleteBook(
            db: c.appModel.database,
            bookKey: bookKey,
            appModel: c.appModel,
          );
      if (result.deleted) {
        // 与书架删除路径同款缓存失效（books.part.dart）。invalidate 整个
        // family，不假设学习语言。
        c.ref.invalidate(fushiBooksProvider);
        c.ref.invalidate(bookTagMapProvider);
        c.ref.invalidate(srtBookTagMapProvider);
      }
      return result.deleted ? null : result.failureReason;
    },
    // BUG-1893：standalone 字幕书没有 EpubBooks 行，删除原语是
    // SrtBookRepository.delete（连带持久目录 + cue）。行本来就不在 = 目标状态
    // 已达成，按成功处理。
    deleteSrtBook: (String uid) async {
      await SrtBookRepository(c.appModel.database).delete(uid);
      c.ref.invalidate(fushiBooksProvider);
      c.ref.invalidate(srtBookTagMapProvider);
      return null;
    },
    // BUG-1870：主库快照残留的删除原语在 fushi_core（与扫描侧识别口径同源）。
    videosProvider: () => loadStorageVideoRefs(c.appModel.database),
    // 视频库自己的删除链（与视频页单删、下载中心「删除（连同文件）」同一条）：
    // 放播放器句柄 → 下载任务标 skip → 删行 + app 副本 → 删文件 → 对账下载任务。
    // 只删本机（不立跨端墓碑）、不动统计——这里是「腾空间」，不是「从库里抹掉」。
    deleteVideo: (String bookUid) async {
      final FushiDatabase db = c.appModel.database;
      final VideoLibraryDeleteResult result =
          await deleteVideoBooksWithDecision(
            repo: VideoBookRepository(db),
            database: db,
            pipeline: c.appModel.videoDownloadPipelineService,
            bookUids: <String>[bookUid],
            decision: const DeleteDecision(
              scope: DeleteScope.keepLocalOnly,
              deleteLocalFiles: true,
            ),
          );
      return storageVideoDeleteFailureReason(result);
    },
    deleteDatabaseSnapshots: () async =>
        deleteDatabaseSnapshotFiles(await AppPaths.supportRootDirectory()),
    deleteFiles: deleteStorageDerivedFiles,
    deleteDictionary: (String name) async {
      // AppModel.deleteDictionary 内部 catch-all 不上抛，「无异常」不等于成功——
      // 以「删除后该名是否仍在词典表」为准回报（审查 M1）。找不到该名 = 目标
      // 状态已达成，按成功处理。
      for (final Dictionary d in c.appModel.dictionaries) {
        if (d.name == name) {
          await c.appModel.deleteDictionary(d);
          final bool stillPresent = c.appModel.dictionaries.any(
            (Dictionary x) => x.name == name,
          );
          return stillPresent ? t.storage_dictionary_delete_incomplete : null;
        }
      }
      return null;
    },
  );

  /// 书籍清单取数（真实现读 `epub_books` + `srt_books` + `audiobooks`）。
  final Future<List<StorageBookRef>> Function() booksProvider;

  /// 词典名清单取数（真实现读 `AppModel.dictionaries`）。
  final Future<List<String>> Function() dictionaryNamesProvider;

  /// 词典真名 -> 显示名（只含改过名的）；null = 按真名显示。
  final Future<Map<String, String>> Function()? dictionaryDisplayNamesProvider;

  /// 视频库行取数（真实现读 `video_books` + 合集成员表）。null = 不列视频明细
  /// （测试 seam / 旧调用点）。
  final Future<List<StorageVideoRef>> Function()? videosProvider;

  /// 删一条视频（行 + 文件）。null = 视频明细不可删。
  final Future<String?> Function(String bookUid)? deleteVideo;

  /// 返回 null = 成功，非 null = 失败原因（下同）。
  final Future<String?> Function(String bookKey) deleteBook;
  final Future<String?> Function(String uid) deleteSrtBook;
  final Future<String?> Function(String name) deleteDictionary;
  final Future<DatabaseSnapshotDeletionResult> Function()
  deleteDatabaseSnapshots;

  /// 删除 [StorageEntryKind.derivedFile] / [StorageEntryKind.backupArchives]
  /// 明细指向的路径（文件或目录）。
  final Future<String?> Function(List<String> paths) deleteFiles;

  final Future<int> Function() anime4kBytesProvider;
  final Future<List<String>> Function() anime4kDelete;
}

/// 派生 / 缓存类明细（封面缩略图、浏览器数据、OCR 模型、着色器、临时文件、
/// 备份包）的删除原语。这些路径没有任何 DB 行引用，裸删不绕过墓碑/引用护栏。
/// 已经不在磁盘上 = 目标状态已达成，按成功处理。返回 null = 成功。
Future<String?> deleteStorageDerivedFiles(List<String> paths) async {
  for (final String path in paths) {
    try {
      final FileSystemEntityType type = await FileSystemEntity.type(path);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.notFound:
          break;
        default:
          await File(path).delete();
      }
    } on FileSystemException catch (e) {
      return '${p.basename(path)}: $e';
    }
  }
  return null;
}

/// 一次删除的结果：[failure] 为 null = 全部成功；[changed] = 磁盘确实变了
/// （快照删除逐文件容错，部分成功也要重扫）。
class StorageEntryDeleteOutcome {
  const StorageEntryDeleteOutcome({
    required this.failure,
    required this.changed,
  });

  final String? failure;
  final bool changed;
}

/// 一次视频删除的失败摘要：行没删掉 / 文件没删掉都算失败（文件留在盘上，用户
/// 以为腾了空间其实没有）；全成功 → null。
String? storageVideoDeleteFailureReason(VideoLibraryDeleteResult result) {
  if (result.failed.isNotEmpty) {
    return '${result.failed.first.error}';
  }
  if (result.localFiles.failures.isNotEmpty) {
    final LocalFileDeleteFailure first = result.localFiles.failures.first;
    return '${p.basename(first.path)}: ${first.error}';
  }
  return null;
}

/// 明细能不能删（只读子项删它就是绕过护栏的裸删）。
bool isStorageEntryDeletable(
  StorageEntryUsage entry, {
  bool canDeleteVideos = true,
}) => switch (entry.kind) {
  StorageEntryKind.readOnly => false,
  StorageEntryKind.videoBook => canDeleteVideos,
  _ => true,
};

/// 按明细 kind 分流到对应删除原语（页面与控制通道共用，确认由调用方负责）。
/// 只读明细抛 [StateError]。
Future<StorageEntryDeleteOutcome> deleteStorageEntry(
  StorageUsageActions actions,
  StorageEntryUsage entry,
) async {
  switch (entry.kind) {
    case StorageEntryKind.book:
      final String? failure = await actions.deleteBook(entry.id);
      return StorageEntryDeleteOutcome(
        failure: failure,
        changed: failure == null,
      );
    case StorageEntryKind.srtBook:
      final String? failure = await actions.deleteSrtBook(entry.id);
      return StorageEntryDeleteOutcome(
        failure: failure,
        changed: failure == null,
      );
    case StorageEntryKind.dictionary:
      final String? failure = await actions.deleteDictionary(entry.id);
      return StorageEntryDeleteOutcome(
        failure: failure,
        changed: failure == null,
      );
    case StorageEntryKind.databaseSnapshots:
      final DatabaseSnapshotDeletionResult result = await actions
          .deleteDatabaseSnapshots();
      return StorageEntryDeleteOutcome(
        failure: storageSnapshotDeleteFailureReason(result),
        changed: result.deleted.isNotEmpty,
      );
    case StorageEntryKind.videoBook:
      final Future<String?> Function(String bookUid)? deleteVideo =
          actions.deleteVideo;
      if (deleteVideo == null) throw StateError('video delete not wired');
      final String? failure = await deleteVideo(entry.id);
      return StorageEntryDeleteOutcome(
        failure: failure,
        changed: failure == null,
      );
    case StorageEntryKind.backupArchives:
    case StorageEntryKind.derivedFile:
      final String? failure = await actions.deleteFiles(entry.paths);
      return StorageEntryDeleteOutcome(
        failure: failure,
        changed: failure == null,
      );
    case StorageEntryKind.readOnly:
      throw StateError('read-only entry');
  }
}

/// 快照批量删除的失败摘要：全成功 → null；否则「第一个失败的文件名: 原因
/// (+还有几个)」。
String? storageSnapshotDeleteFailureReason(
  DatabaseSnapshotDeletionResult result,
) {
  if (!result.hasFailures) return null;
  final MapEntry<String, String> first = result.failures.entries.first;
  final int rest = result.failures.length - 1;
  final String head = '${p.basename(first.key)}: ${first.value}';
  return rest > 0 ? '$head (+$rest)' : head;
}

/// 一次性扫完全部类目（控制通道用；页面走渐进的
/// [StorageUsageService.scanCategories] 流）。按体积降序。
Future<List<StorageCategoryUsage>> scanAllStorageCategories(
  StorageUsageService service,
  StorageUsageActions actions,
) async {
  final List<StorageBookRef> books = await actions.booksProvider();
  final List<String> dictNames = await actions.dictionaryNamesProvider();
  final Map<String, String> displayNames =
      await actions.dictionaryDisplayNamesProvider?.call() ??
      const <String, String>{};
  final List<StorageVideoRef> videos =
      await actions.videosProvider?.call() ?? const <StorageVideoRef>[];
  final List<StorageCategoryUsage> usage = await service
      .scanCategories(
        books: books,
        dictionaryNames: dictNames,
        dictionaryDisplayNames: displayNames,
        videos: videos,
      )
      .toList();
  usage.sort((StorageCategoryUsage a, StorageCategoryUsage b) {
    final int byBytes = b.bytes.compareTo(a.bytes);
    return byBytes != 0 ? byBytes : a.id.index.compareTo(b.id.index);
  });
  return usage;
}

/// 存储页书籍条目的扫描输入：`epub_books` + `srt_books` + `audiobooks` 三张表。
///
/// 有声书 persist 目录的真实键口径与删除侧一致（审查 H1）：EPUB 配音频用
/// bookKey，字幕书音频用关联 SrtBooks.uid。音频的真相源是 DB 里记的路径
/// （BUG-1893，`audioRoot` / `audioPathsJson`）。standalone 字幕书（bookKey 恒空）
/// 没有 EpubBooks 行，单独成条（[StorageEntryKind.srtBook]）。
Future<List<StorageBookRef>> loadStorageBookRefs(FushiDatabase db) async {
  final List<EpubBookRow> rows = await db.getAllEpubBooks();
  final List<SrtBookRow> srtRows = await db.getAllSrtBooks();
  final List<AudiobookRow> audiobookRows = await db.getAllAudiobooks();
  final Map<String, List<String>> audioPathsByBookKey =
      <String, List<String>>{};
  for (final AudiobookRow ab in audiobookRows) {
    if (ab.bookKey.isEmpty) continue;
    (audioPathsByBookKey[ab.bookKey] ??= <String>[]).addAll(
      storageAudioPathsOf(ab.audioRoot, ab.audioPathsJson),
    );
  }
  final Map<String, List<String>> srtUidsByBookKey = <String, List<String>>{};
  final List<SrtBookRow> standaloneSrtRows = <SrtBookRow>[];
  for (final SrtBookRow srt in srtRows) {
    if (srt.bookKey.isEmpty) {
      standaloneSrtRows.add(srt);
      continue;
    }
    (srtUidsByBookKey[srt.bookKey] ??= <String>[]).add(srt.uid);
    (audioPathsByBookKey[srt.bookKey] ??= <String>[]).addAll(
      storageAudioPathsOf(srt.audioRoot, srt.audioPathsJson),
    );
  }
  return <StorageBookRef>[
    for (final EpubBookRow row in rows)
      StorageBookRef(
        id: row.bookKey,
        title: row.title,
        extractDir: row.extractDir,
        persistKeys: <String>[
          row.bookKey,
          ...srtUidsByBookKey[row.bookKey] ?? const <String>[],
        ],
        audioPaths: audioPathsByBookKey[row.bookKey] ?? const <String>[],
      ),
    for (final SrtBookRow srt in standaloneSrtRows)
      StorageBookRef(
        id: srt.uid,
        title: srt.title,
        // 无 EPUB 正文载体：磁盘占用全在 persist 目录 / audioRoot 里。
        extractDir: '',
        persistKeys: <String>[srt.uid],
        audioPaths: storageAudioPathsOf(srt.audioRoot, srt.audioPathsJson),
        kind: StorageEntryKind.srtBook,
      ),
  ];
}

/// 存储页视频条目的扫描输入：`video_books` 全部行 + 所属作品（视频合集）名。
///
/// 一条视频可属于多个合集：取 id 最小的那个（最早建立的，一般就是下载 / 导入时
/// 自动建的作品合集），保证每条视频只出现在一个组里。
Future<List<StorageVideoRef>> loadStorageVideoRefs(FushiDatabase db) async {
  final List<VideoBookRow> rows = await db.allVideoBooks();
  final Map<int, String> collectionNames = <int, String>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      c.id: c.name,
  };
  final Map<String, int> collectionOf = <String, int>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    if (!collectionNames.containsKey(item.collectionId)) continue;
    final int? existing = collectionOf[item.entryKey];
    if (existing == null || item.collectionId < existing) {
      collectionOf[item.entryKey] = item.collectionId;
    }
  }
  return <StorageVideoRef>[
    for (final VideoBookRow row in rows)
      StorageVideoRef(
        id: row.bookUid,
        title: row.title,
        videoPath: row.videoPath,
        group: switch (collectionOf[row.bookUid]) {
          final int id => collectionNames[id],
          null => null,
        },
      ),
  ];
}

/// DB 里一行有声书/字幕书的音频真实路径：legacy 的 `audioRoot`（目录模式）加
/// `audioPathsJson`（文件列表模式），两列全取、重叠交给
/// `resolveBookStoragePaths` 去嵌套。坏 JSON 降级成空列表，不能炸整页扫描。
List<String> storageAudioPathsOf(
  final String? audioRoot,
  final String? audioPathsJson,
) {
  final List<String> out = <String>[
    if (audioRoot != null && audioRoot.isNotEmpty) audioRoot,
  ];
  if (audioPathsJson == null || audioPathsJson.isEmpty) return out;
  try {
    final Object? decoded = jsonDecode(audioPathsJson);
    if (decoded is List) {
      for (final Object? item in decoded) {
        if (item is String && item.isNotEmpty) out.add(item);
      }
    }
  } on FormatException {
    // 旧行/手改坏值：当作没有文件列表，仍保留 audioRoot。
  }
  return out;
}

/// 类目显示名（页面与控制通道共用）。
String storageCategoryTitle(StorageCategoryId id) => switch (id) {
  StorageCategoryId.books => t.storage_category_books,
  StorageCategoryId.dictionaries => t.storage_category_dictionaries,
  StorageCategoryId.videoDownloads => t.storage_category_video_downloads,
  StorageCategoryId.covers => t.storage_category_covers,
  StorageCategoryId.subtitles => t.storage_category_subtitles,
  StorageCategoryId.shaders => t.storage_category_shaders,
  StorageCategoryId.customFonts => t.storage_category_custom_fonts,
  StorageCategoryId.web => t.storage_category_web,
  StorageCategoryId.exports => t.storage_category_exports,
  StorageCategoryId.backups => t.storage_category_backups,
  StorageCategoryId.database => t.storage_category_database,
  StorageCategoryId.ocrModels => t.storage_category_ocr_models,
  StorageCategoryId.cache => t.storage_category_cache,
  StorageCategoryId.other => t.storage_category_other,
};

/// 条目显示名：快照 / 备份聚合条目按文件数翻译，其余用服务层给的 label。
String storageEntryTitle(StorageEntryUsage entry) => switch (entry.kind) {
  StorageEntryKind.databaseSnapshots =>
    t.storage_entry_database_snapshots_label(n: entry.paths.length),
  StorageEntryKind.backupArchives => t.storage_entry_backups_label(
    n: entry.paths.length,
  ),
  _ => entry.label,
};
