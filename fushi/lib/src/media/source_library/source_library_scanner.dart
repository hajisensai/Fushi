// TODO-817 M1b source-library scanner: scans one source library (local folder
// root, row = SourceLibraryRow) into many books/videos, backfilling sourceId on
// insert, then writes the media-count / scan-time / scan-error back onto the
// MediaSources table.
//
// [planScanFromFileList] is a pure function (no IO): it takes a SourceFileEntry
// list and classifies into epub / video / subtitle, associating each video with
// its same-stem sidecar subtitle via the existing sidecar pure function.
// [SourceLibraryScanner.scan] is the thin IO orchestration: list via
// SourceFileSystem (M1b wires only LocalSourceFileSystem) -> planScanFromFileList
// -> reuse existing importers (EpubImporter.importFromPath /
// VideoBookRepository.saveVideoBook) with sourceId -> updateMediaSourceScanResult.
//
// TODO-1274: network transport (SFTP/FTP/WebDAV) is now wired for BOOK sources —
// the transport is resolved from the row (local vs SFTP/FTP/WebDAV built from
// configJson + SourceLibraryCredentialStore), and remote EPUBs are downloaded via
// copyToLocal before import. Routing is transport-agnostic here: any non-'local'
// transport builds a NetworkSourceFileSystem which dispatches SFTP/FTP/WebDAV
// internally, so [buildNetworkFileSystem] needs no per-transport branch.
// Existing manual import paths (dialogs) are untouched; sourceId defaults to null.
//
// 网络来源三域现状：
// - book：三 transport 全通（远端 EPUB copyToLocal 下载后导入；同名字幕 + 音频
//   sidecar 同样先下到临时盘再升级成有声书，与本地同一个对齐落库 service）。
// - manga：三 transport 全通，`.mokuro` / 压缩包 / 纯页图目录三种卷都收
//   （[_importMangaRemote]：先按标题做去重预检，未命中才整卷镜像到临时目录，
//   交给既有 MangaImporter——落库产物与本地导入逐字节同构）。纯页图目录的归卷
//   规则与本地同一份 [planMangaFolders]，只是按 URL 路径语义计算。
// - video：SFTP / WebDAV / AList（按流媒体书原地入库，播放走既有 stream 通道 +
//   打开时按 sourceId 现解析：WebDAV 的 Basic 认证、AList 的签名直链、SFTP 的
//   回环中继地址，见 source_stream_headers.dart / sftp_stream_source.dart）；
//   FTP 读不了区间、拖不了进度条，仍拒绝。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi_music/fushi_music.dart' show MusicScanRootError;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:fushi_engine/media/torrent/download_save_root.dart'
    show isSourceIncomingPath;
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi/src/media/collections/library_organize_runner.dart'
    show scheduleAutomaticLibraryOrganize;
import 'package:fushi/src/media/collections/collection_ai_order.dart'
    show scheduleAutomaticCollectionAiOrder;
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDragPlaylistExtensions;
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart'
    show PortraitCoverImage;
import 'package:fushi/i18n/strings.g.dart' show LocaleSettings;
import 'package:fushi/src/media/import/sidecar_finder.dart';
import 'package:fushi/src/media/manga/import/manga_pdf_importer.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc_thumbnail.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException;
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/dvd/dvd_library_title.dart';
import 'package:fushi_engine/media/video/dvd/dvd_ifo.dart'
    show DvdIfoFormatException;
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_archive_probe.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart'
    show MangaImportException;
import 'package:fushi_engine/media/manga/mokuro_legacy_html.dart'
    show isMokuroLegacyHtmlPath, kMokuroLegacyOcrDirName, legacyMokuroRoot;
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show
        MokuroImage,
        MokuroPayload,
        joinMokuroPageRoot,
        mokuroPageRootCandidates,
        parseMokuro,
        resolveMokuroPageRoot;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrOutDirName;
import 'package:fushi/src/media/source_library/sftp_stream_source.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath, sourceEntryBasename;
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/strm_file.dart' show kStrmExtension;
import 'package:fushi/src/media/video/url_stream_video.dart'
    show StreamVideoSpec;
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';

/// 书文件扩展名（小写、不带点）。
///
/// `pdf` 在列：PDF 是 `EpubBooks.format` 的三种书身份之一，单本导入对话框一直认
/// 它（`ImportCarrier.pdf` → `PdfImporter`）。此前这份扫描白名单只有 `epub`，于是
/// 「导入文件夹」把目录里每一份 PDF 静默跳过——不报错、不计数，看起来像扫描漏掉了
/// 文件（用户实报）。导入分流见 [SourceLibraryScanner._importBooks]。
const Set<String> kScanBookExtensions = <String>{'epub', 'pdf'};

/// Subtitle whitelist shared with the video import dialog (no lrc).
const Set<String> kScanVideoSubtitleExts = <String>{'srt', 'vtt', 'ass', 'ssa'};

/// 视频域允许的网络传输：条目可原地流播（WebDAV / AList 条目就是 http(s) URL；
/// SFTP 条目入库为 `sftp://` 稳定地址、起播时经回环中继按偏移读，见
/// sftp_stream_source.dart）。FTP 不在其中：读不了区间，拖不了进度条。
const Set<String> kStreamableVideoSourceTransports = <String>{
  'sftp',
  'webdav',
  'alist',
};

/// 漫画 manifest 扩展名白名单（小写、不带点）。页图目录不靠扩展名代表整卷，
/// 由 [planScanFromFileList] 按目录结构另行归组。
const Set<String> kScanMangaExtensions = <String>{'mokuro'};

/// 漫画来源里「单文件即一卷」的载体扩展名（小写、不带点）：`.cbz` / `.zip` /
/// `.rar` / `.cbr` / `.cb7` / `.epub` / `.pdf`。
///
/// 从 [kMangaCarrierFileExtensions]（压缩包段取自引擎 [kMangaArchiveFileExtensions]）
/// 派生，不再手抄：此前这里只抄了 7-Zip 那一路的 `rar` / `cbr` / `cb7`，漫画来源
/// 里最常见的 `.cbz` / `.zip` 卷被静默跳过，显示「0 卷」，而手动导入同一批文件
/// 完全正常。`.mokuro` 不在这里，它有自己的 [kScanMangaExtensions] 分支。
///
/// 只在漫画来源里生效（[planScanFromFileList] 的 `mangaRootPath` 非空）：`.epub` /
/// `.pdf` 在书籍来源里是书，不能被漫画分支抢走。`.zip` / `.epub` 光看扩展名分不清
/// 是不是页图包，导入时再用与手动导入同一份 [classifyImportCarrier] 开包定性。
final Set<String> kScanMangaCarrierExtensions = <String>{
  for (final String extension in kMangaCarrierFileExtensions)
    if (extension != '.mokuro') extension.substring(1),
};

/// One pending book item: EPUB path + optional same-stem sidecar subtitle/audio.
///
/// TODO-946：当 EPUB 旁有同名字幕**且**有同名音频时，[subtitlePath] / [audioPaths]
/// 非空，扫描器据此把这本书导成有声书（字幕做对齐源 + 音频）；二者缺一则按纯
/// EPUB 导入（音频必配字幕，沿用 sidecar_finder 既有语义）。
@immutable
class ScanBookItem {
  const ScanBookItem({
    required this.bookPath,
    this.subtitlePath,
    this.audioPaths = const <String>[],
  });

  /// 书文件完整路径（来源命名空间）。扩展名决定用哪个导入器——`.pdf` 走
  /// [PdfImporter]，其余走 [EpubImporter]。字段名不再叫 `epubPath`：它装的
  /// 是「一本书的文件」，装进 PDF 后那个名字就是句谎话。
  final String bookPath;

  /// 这份书文件是不是 PDF（决定导入器与能否挂有声书）。
  bool get isPdf => p.extension(bookPath).toLowerCase() == '.pdf';

  /// 同名字幕完整路径；无同名字幕为 null。
  final String? subtitlePath;

  /// 同名（含同前缀多段）音频完整路径列表；无为空。
  final List<String> audioPaths;

  /// 是否应导成有声书：同名字幕与音频齐备（音频必配字幕）。
  ///
  /// PDF 恒 false：对齐拿 EPUB 的章节正文与字幕逐句配，PDF 行的 `chaptersJson`
  /// 是 `'[]'`、根本没有可配的正文，喂进去只会产出一本空对齐的假有声书。
  bool get isAudiobook =>
      !isPdf && subtitlePath != null && audioPaths.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ScanBookItem &&
      other.bookPath == bookPath &&
      other.subtitlePath == subtitlePath &&
      _listEquals(other.audioPaths, audioPaths);

  @override
  int get hashCode =>
      Object.hash(bookPath, subtitlePath, Object.hashAll(audioPaths));
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One pending video item: video path + associated same-stem subtitle (or null).
@immutable
class ScanVideoItem {
  const ScanVideoItem({required this.videoPath, this.subtitlePath});

  /// Full video file path (source namespace).
  final String videoPath;

  /// Associated subtitle full path; null when no same-name subtitle.
  final String? subtitlePath;

  @override
  bool operator ==(Object other) =>
      other is ScanVideoItem &&
      other.videoPath == videoPath &&
      other.subtitlePath == subtitlePath;

  @override
  int get hashCode => Object.hash(videoPath, subtitlePath);
}

/// One pending playlist item: an m3u8/m3u manifest scanned in a video source.
///
/// TODO-1237: folder scan treats `.m3u8`/`.m3u` as multi-episode playlist
/// manifests, same semantics as the drag-drop path (kDragPlaylistExtensions /
/// DropIntent.importNewPlaylist): not a single video file but a parseM3u8'd
/// episode list persisted as one playlist VideoBook.
@immutable
class ScanPlaylistItem {
  const ScanPlaylistItem({required this.playlistPath});

  /// Full m3u8/m3u file path (source namespace).
  final String playlistPath;

  @override
  bool operator ==(Object other) =>
      other is ScanPlaylistItem && other.playlistPath == playlistPath;

  @override
  int get hashCode => playlistPath.hashCode;
}

/// One pending manga item: a `.mokuro` volume manifest scanned in a manga
/// source. 页图目录不在此关联——[MangaImporter.importFromMokuroPath] 自己按
/// mokuro 惯例在 `.mokuro` 同级探测图片来源（平铺或子目录）。
@immutable
class ScanMangaItem {
  const ScanMangaItem({required this.mokuroPath});

  /// Full `.mokuro` file path (source namespace).
  final String mokuroPath;

  @override
  bool operator ==(Object other) =>
      other is ScanMangaItem && other.mokuroPath == mokuroPath;

  @override
  int get hashCode => mokuroPath.hashCode;
}

/// One pending single-file manga volume (archive / EPUB / PDF, see
/// [kScanMangaCarrierExtensions]) scanned from a manga source.
@immutable
class ScanMangaArchiveItem {
  const ScanMangaArchiveItem({
    required this.archivePath,
    this.mokuroSidecarPath,
  });

  /// Full carrier file path (source namespace).
  final String archivePath;

  /// 同目录的 `<stem>.mokuro` / `<文件名>.mokuro` OCR sidecar（源命名空间），由
  /// [MangaArchiveImporter.importArchive] 按文件名在包旁边找到并当作文字层。这里
  /// 记下它，一是它不再被当成独立一卷重复导入，二是网络来源要把它和包一起镜像到
  /// 临时目录，否则 OCR 在下载那一步就丢了。
  final String? mokuroSidecarPath;

  @override
  bool operator ==(Object other) =>
      other is ScanMangaArchiveItem &&
      other.archivePath == archivePath &&
      other.mokuroSidecarPath == mokuroSidecarPath;

  @override
  int get hashCode => Object.hash(archivePath, mokuroSidecarPath);
}

/// 一次漫画来源导入的逐卷结局：入库数 + 失败卷与第一个失败原因。
///
/// 一卷失败不中断其余卷（与视频分支 BUG-2570 同语义），由
/// [SourceLibraryScanner.scan] 汇总成一条能照着查的 lastScanError。
class _MangaVolumeTally {
  int imported = 0;
  final List<String> failedPaths = <String>[];
  Object? firstError;

  /// 跑一卷：[body] 返回 true 计一卷入库，false 是「已在库 / 不是漫画」的正常
  /// 跳过；[DuplicateImportCancelledException] 同样是正常跳过；其它异常记为该卷
  /// 失败。
  Future<void> attempt(String path, Future<bool> Function() body) async {
    try {
      if (await body()) imported++;
    } on DuplicateImportCancelledException catch (e) {
      debugPrint(
        'SourceLibraryScanner skip duplicate manga ${e.title} ($path)',
      );
    } catch (e, stack) {
      failedPaths.add(path);
      firstError ??= e;
      debugPrint(
        'SourceLibraryScanner manga import failed for $path: $e\n'
        '$stack',
      );
    }
  }
}

/// 一次漫画来源扫描的**卷身份**上下文：来源扫描索引（源相对路径 → 书 uid，外加
/// 「不是漫画」的负向表）+ 本轮在场的源 + 远端条目元数据。
///
/// 与无头服务端同一张索引、同一个偏好键（`media_source_scan_index_<sourceId>`，引擎
/// [BookSourceIndex]），同一个重复判据（[isDuplicateSourceBook]）。
class _MangaSourceIdentity {
  _MangaSourceIdentity._({
    required this.db,
    required this.sourceId,
    required this.rootPath,
    required this.isLocal,
    required this.index,
    required Map<String, SourceFileEntry> entryByPath,
  }) : _entryByPath = entryByPath;

  /// 读索引、丢掉指向已不在库的书的条目，并按本轮计划算出在场的源。
  static Future<_MangaSourceIdentity> load({
    required FushiDatabase db,
    required SourceLibraryRow source,
    required bool isLocal,
    required ScanPlan plan,
    required List<SourceFileEntry> entries,
  }) async {
    final BookSourceIndex index = await BookSourceIndex.load(db, source.id);
    index.retainUids(<String>{
      for (final BookSourceRow row in await loadBookSourceRows(db))
        if (row.uid.isNotEmpty) row.uid,
    });
    final _MangaSourceIdentity identity = _MangaSourceIdentity._(
      db: db,
      sourceId: source.id,
      rootPath: source.rootPath,
      isLocal: isLocal,
      index: index,
      entryByPath: <String, SourceFileEntry>{
        for (final SourceFileEntry entry in entries)
          if (!entry.isDirectory) entry.path: entry,
      },
    );
    identity.present.addAll(<String>[
      for (final ScanMangaItem item in plan.mangas)
        identity.relOf(item.mokuroPath),
      for (final ScanMangaArchiveItem item in plan.mangaArchives)
        identity.relOf(item.archivePath),
      for (final ScanMangaFolderItem item in plan.mangaFolders)
        identity.relOf(item.folderPath),
    ]);
    // 文件删了 / 改名了，旧的「不是漫画」结论随之作废。
    index.retainRejected(identity.present);
    return identity;
  }

  final FushiDatabase db;
  final int sourceId;
  final String rootPath;
  final bool isLocal;
  final BookSourceIndex index;
  final Map<String, SourceFileEntry> _entryByPath;

  /// 本轮计划里的全部卷（索引键形态）。
  final Set<String> present = <String>{};

  /// 卷路径的索引键：本地按宿主路径语义，远端（正斜杠路径 / `https://` href）按
  /// [p.url]——与 [planScanFromFileList] 归卷时用的路径语义一致。
  String relOf(String path) => isLocal
      ? bookSourceRelPath(rootPath, path)
      : p.url.relative(p.url.normalize(path), from: p.url.normalize(rootPath));

  /// 卷 [path] 的内容指纹：本地现场 stat（字节数 + 修改时刻），远端取列目录给的
  /// 元数据（ETag / 大小 / 修改时刻）。拿不到时为 null，负向表就不缓存它。
  String? fingerprintOf(String path) => isLocal
      ? localSourceContentFingerprint(path)
      : _entryByPath[path]?.contentFingerprint;

  bool isIndexed(String path) => index.uidOf(relOf(path)) != null;

  bool isRejected(String path) =>
      index.isRejected(relOf(path), fingerprintOf(path));

  void reject(String path) => index.reject(relOf(path), fingerprintOf(path));

  /// 卷 [path]（拟用标题 [title]）该用的重复处理策略；null = 不导入。
  ///
  /// 标题没被占 → [DuplicatePolicy.skip]（与导入器的判定是同一件事，万一并发撞上
  /// 仍按重复跳过）；被本来源另一个在场的文件占着 → [DuplicatePolicy.suffix]；是本
  /// 来源自己的旧行 → 认领后返回 null；被手动导入 / 别的来源的书占着 → null。
  Future<DuplicatePolicy?> policyFor(String path, String title) async {
    final String rel = relOf(path);
    final SourceDuplicateVerdict verdict = await isDuplicateSourceBook(
      db: db,
      index: index,
      sourceId: sourceId,
      rel: rel,
      proposedTitle: title,
      format: BookFormat.manga,
      presentRels: present,
      // app 的来源扫描从来都写 sourceId：无来源的同名行是手动导入的书。
      claimUnsourcedRows: false,
    );
    switch (verdict.kind) {
      case SourceDuplicateKind.none:
        return const DuplicatePolicy.skip();
      case SourceDuplicateKind.otherSourceFile:
        return const DuplicatePolicy.suffix();
      case SourceDuplicateKind.sameSource:
        final String? uid = await adoptExistingBookForSource(
          db: db,
          sourceId: sourceId,
          proposedTitle: title,
          format: BookFormat.manga,
        );
        if (uid != null) index.put(rel, uid);
        debugPrint(
          'SourceLibraryScanner manga already imported: $title ($path)',
        );
        return null;
      case SourceDuplicateKind.foreign:
        debugPrint('SourceLibraryScanner skip duplicate manga $title ($path)');
        return null;
    }
  }

  /// 卷 [path] 导入成了书 [bookKey]：登记进索引。
  Future<void> record(String path, String bookKey) async {
    final String? uid = await bookUidForKey(db, bookKey);
    if (uid != null) index.put(relOf(path), uid);
  }
}

/// `.mokuro` 顶层对象（不是对象时为空表），供 [MangaImporter.deriveMokuroTitle]。
Map<String, Object?> _decodeMokuroRoot(String json) {
  final Object? raw = jsonDecode(json);
  return raw is Map ? raw.cast<String, Object?>() : <String, Object?>{};
}

/// One pending pure-image manga folder scanned from a local manga source.
@immutable
class ScanMangaFolderItem {
  const ScanMangaFolderItem({required this.folderPath, this.series});

  /// 页图所在的一卷目录；标题稳定，供后台重扫按标题身份静默去重。
  final String folderPath;

  /// 「系列目录/卷目录」下探出的卷的系列归属（引擎 [planMangaFolders]）；普通卷为
  /// null。有它时入库标题取 [MangaSeriesVolume.title]（「系列名 卷目录名」），
  /// 否则取卷目录名。
  final MangaSeriesVolume? series;

  @override
  bool operator ==(Object other) =>
      other is ScanMangaFolderItem &&
      other.folderPath == folderPath &&
      other.series == series;

  @override
  int get hashCode => Object.hash(folderPath, series);
}

/// One pending Blu-ray disc (`BDMV` tree) scanned from a local video source.
@immutable
class ScanBlurayDiscItem {
  const ScanBlurayDiscItem({required this.discRootPath});

  /// 含 `BDMV` 的那一层目录。盘内各条播放列表在导入时才解析——规划层只认路径形状，
  /// 不读盘（一次扫描会走过上万个路径）。
  final String discRootPath;

  @override
  bool operator ==(Object other) =>
      other is ScanBlurayDiscItem && other.discRootPath == discRootPath;

  @override
  int get hashCode => discRootPath.hashCode;
}

/// One pending DVD (`VIDEO_TS` tree) scanned from a local video source.
@immutable
class ScanDvdDiscItem {
  const ScanDvdDiscItem({required this.discRootPath});

  /// 盘根：含 `VIDEO_TS` 的那一层目录，或 `.iso` 镜像文件。IFO 在导入时才解析——
  /// 规划层只认路径形状。
  final String discRootPath;

  @override
  bool operator ==(Object other) =>
      other is ScanDvdDiscItem && other.discRootPath == discRootPath;

  @override
  int get hashCode => discRootPath.hashCode;
}

/// Classification result of one scan (pure data).
@immutable
class ScanPlan {
  const ScanPlan({
    this.books = const <ScanBookItem>[],
    this.videos = const <ScanVideoItem>[],
    this.playlists = const <ScanPlaylistItem>[],
    this.mangas = const <ScanMangaItem>[],
    this.mangaArchives = const <ScanMangaArchiveItem>[],
    this.mangaFolders = const <ScanMangaFolderItem>[],
    this.blurayDiscs = const <ScanBlurayDiscItem>[],
    this.dvdDiscs = const <ScanDvdDiscItem>[],
  });

  /// Pending book items (EPUB + optional same-stem subtitle/audio sidecar).
  final List<ScanBookItem> books;

  /// Pending video items (with associated subtitles).
  final List<ScanVideoItem> videos;

  /// Pending playlist items (m3u8/m3u multi-episode manifests, TODO-1237).
  final List<ScanPlaylistItem> playlists;

  /// Pending manga items (`.mokuro` volume manifests).
  final List<ScanMangaItem> mangas;

  /// Pending single-file manga volumes (manga sources only).
  final List<ScanMangaArchiveItem> mangaArchives;

  /// Pending local pure-image manga folders.
  final List<ScanMangaFolderItem> mangaFolders;

  /// Pending Blu-ray discs (local video sources only).
  final List<ScanBlurayDiscItem> blurayDiscs;

  /// Pending DVDs (local video sources only).
  final List<ScanDvdDiscItem> dvdDiscs;
}

/// 一次来源扫描的可核对摘要。
///
/// 扫描器仍负责把成功/失败状态写回 `MediaSources`；调用方通过本值决定是否启动
/// 可选的来源刮削，而不必重新枚举磁盘或猜测本轮创建了哪些作品容器。
@immutable
class SourceScanSummary {
  const SourceScanSummary({
    required this.sourceId,
    required this.mediaKind,
    required this.discoveredPaths,
    required this.importedMediaCount,
    this.createdVideoUids = const <String>[],
    this.reusedVideoUids = const <String>[],
    this.createdCollectionIds = const <int>[],
    this.updatedCollectionIds = const <int>[],
    this.error,
  });

  final int sourceId;
  final String mediaKind;
  final List<String> discoveredPaths;
  final int importedMediaCount;
  final List<String> createdVideoUids;
  final List<String> reusedVideoUids;
  final List<int> createdCollectionIds;
  final List<int> updatedCollectionIds;
  final String? error;

  bool get succeeded => error == null;
}

/// Extension of an entry name (lowercase, no leading dot).
String _extOf(String name) =>
    p.extension(name).toLowerCase().replaceFirst('.', '');

/// Drops entries inside the source's video download staging directory
/// (`.fushi-incoming`, BUG-2755). Managed video downloads land there
/// while they are still downloading; importing them would register half-written
/// files that the organize stage then renames away. Only local sources can be
/// download targets, so network listings pass through unchanged.
List<SourceFileEntry> excludeSourceIncomingEntries(
  List<SourceFileEntry> entries, {
  required String sourceRoot,
  required bool isLocal,
}) {
  if (!isLocal) return entries;
  return entries
      .where(
        (SourceFileEntry entry) =>
            !isSourceIncomingPath(sourceRoot, entry.path),
      )
      .toList(growable: false);
}

/// Pure function: classifies a listed [files] set into a scan plan. No IO.
///
/// - Skips directory entries (recursive listing yields only files anyway).
/// - EPUB (ext in [kScanBookExtensions]) -> [ScanPlan.epubPaths].
/// - Video (ext in [kVideoExtensions]) -> [ScanPlan.videos], associating the
///   same-stem subtitle found by [selectSidecarNames] within the same directory.
/// - Audio (ext in [kAudioExtensions]) -> [ScanPlan.videos] too, but only when
///   [includeAudioAsVideo] (video sources): an album track is a video without a
///   picture. Book sources keep audio as EPUB sidecars only.
/// - Subtitles are not inserted on their own; they only attach to a video.
///
/// Sidecar association is scoped to the same directory: [files] are bucketed by
/// parent dir, and each video is matched against its own directory file-name set,
/// matching the import dialog's sidecar semantics.
ScanPlan planScanFromFileList(
  List<SourceFileEntry> files, {
  String? mangaRootPath,
  p.Context? mangaPathContext,
  bool detectBlurayDiscs = false,
  bool detectDvdDiscs = false,
  bool includeAudioAsVideo = false,
}) {
  // 蓝光盘先认：认出来之后，盘的 `BDMV` 树整个从散装视频里摘掉。不摘的话用户会同时
  // 拿到「正片」和一屏叫 `00001`~`00042` 的 m2ts 碎片（正片常被切成好几段，另有菜
  // 单/预告/警告片）。与 `.mokuro` 让位规则同一取舍：manifest 认领了的文件不再被更
  // 低层的分类器重复消费。
  //
  // 只在本地来源开：盘内播放列表要随机读 `PLAYLIST`/`CLIPINF`，播放要拿到 `STREAM`
  // 下的本地路径，网络来源两样都给不了。
  final List<String> blurayRoots = detectBlurayDiscs
      ? planBlurayDiscRoots(<String>[
          for (final SourceFileEntry entry in files)
            if (!entry.isDirectory) entry.path,
        ])
      : const <String>[];
  final Set<String> blurayRootSet = blurayRoots.toSet();
  // DVD 同理：认出 `VIDEO_TS/VIDEO_TS.IFO` 后整棵 `VIDEO_TS` 归盘管，里面的 VOB
  // （按 1 GB 切开、混着菜单 VOB）不再各自成为散装视频。`VIDEO_TS` 之外的 `.vob`
  // 照旧按普通视频。同样只在本地来源开：IFO 要随机读，播放要本地盘根。
  final List<String> dvdRoots = detectDvdDiscs
      ? planDvdDiscRoots(<String>[
          for (final SourceFileEntry entry in files)
            if (!entry.isDirectory) entry.path,
        ])
      : const <String>[];
  final Set<String> dvdRootSet = dvdRoots.toSet();
  // 镜像形态的 DVD（`.iso`）：规划层只收路径，导入时打开探测——不靠扩展名猜里面是
  // DVD 还是 BD（BD 镜像暂不入库，见 [_importDvdDiscs]）。`.iso` 不在任何媒体白名单
  // 里，不会与散装视频重复。
  final List<String> discImages = <String>[];

  // parent dir -> all file basenames under it (for sidecar matching).
  final Map<String, List<String>> namesByDir = <String, List<String>>{};
  // parent dir -> {basename: original full path} (for sidecar path lookup).
  // TODO-1274: sidecar full paths are looked up here, NOT rebuilt via
  // p.join(dir, name), so a remote source's forward-slash paths survive on a
  // Windows host (p.join would inject backslashes).
  final Map<String, Map<String, String>> pathByDir =
      <String, Map<String, String>>{};
  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    final String dir = p.dirname(e.path);
    (namesByDir[dir] ??= <String>[]).add(e.name);
    (pathByDir[dir] ??= <String, String>{})[e.name] = e.path;
  }

  final List<ScanBookItem> books = <ScanBookItem>[];
  final List<ScanVideoItem> videos = <ScanVideoItem>[];
  final List<ScanPlaylistItem> playlists = <ScanPlaylistItem>[];
  final List<ScanMangaItem> mangas = <ScanMangaItem>[];

  for (final SourceFileEntry e in files) {
    if (e.isDirectory) continue;
    if (isInsideBlurayDisc(e.path, blurayRootSet)) continue;
    if (isInsideDvdDisc(e.path, dvdRootSet)) continue;
    final String ext = _extOf(e.name);
    if (detectDvdDiscs && ext == 'iso') {
      discImages.add(e.path);
      continue;
    }
    // TODO-1237: m3u8/m3u playlist manifest, reusing the drag-drop path's own
    // [kDragPlaylistExtensions] whitelist. Checked before the video branch
    // (m3u8 is not in kVideoExtensions, the two are disjoint; ordering is only
    // for clarity).
    if (kDragPlaylistExtensions.contains(ext)) {
      playlists.add(ScanPlaylistItem(playlistPath: e.path));
      continue;
    }
    // `.mokuro` 漫画卷（与其余白名单两两不相交，book/video 分类零影响）。
    if (kScanMangaExtensions.contains(ext)) {
      mangas.add(ScanMangaItem(mokuroPath: e.path));
      continue;
    }
    // 漫画来源（mangaRootPath 非空）里的单文件卷由下面的 [_planMangaVolumes]
    // 统一归组；这里只拦住它们，`.epub` / `.pdf` 不能落进书籍清单。
    if (mangaRootPath != null && kScanMangaCarrierExtensions.contains(ext)) {
      continue;
    }
    if (kScanBookExtensions.contains(ext)) {
      // TODO-946：EPUB 同目录扫同名字幕 + 音频（wantAudio:true，字幕扩展含 lrc）。
      // 命中音频 -> 导成有声书（字幕作对齐源）；否则纯 EPUB。同目录作用域，与
      // 视频 sidecar 关联一致。
      final String dir = p.dirname(e.path);
      final List<String> siblings = namesByDir[dir] ?? const <String>[];
      final ({String? subtitle, List<String> audio}) sel = selectSidecarNames(
        mainFileName: e.name,
        siblingNames: siblings,
        wantAudio: true,
      );
      final Map<String, String> dirPaths =
          pathByDir[dir] ?? const <String, String>{};
      books.add(
        ScanBookItem(
          bookPath: e.path,
          subtitlePath: sel.subtitle == null ? null : dirPaths[sel.subtitle!],
          audioPaths: sel.audio.map((String n) => dirPaths[n] ?? n).toList(),
        ),
      );
      continue;
    }
    // `.strm` 流指针按普通视频入库（videoPath = `.strm` 自身）：标题取文件名、
    // 照常参与分组 / 刮削 / 同名字幕关联；指向的流地址在起播时现读
    // （stream_video_launch.dart 的 resolveStrmStreamTarget）。
    // 纯音频（专辑曲目等）只在视频来源里按「无画面的视频」收录；书籍来源里同目录
    // 音频是 EPUB 的有声书 sidecar（上面的 book 分支），绝不能再单独入库。
    if (kVideoExtensions.contains('.$ext') ||
        ext == kStrmExtension ||
        (includeAudioAsVideo && kAudioExtensions.contains('.$ext'))) {
      final String dir = p.dirname(e.path);
      final List<String> siblings = namesByDir[dir] ?? const <String>[];
      final ({String? subtitle, List<String> audio}) sel = selectSidecarNames(
        mainFileName: e.name,
        siblingNames: siblings,
        wantAudio: false,
        subtitleExts: kScanVideoSubtitleExts,
      );
      final Map<String, String> dirPaths =
          pathByDir[dir] ?? const <String, String>{};
      videos.add(
        ScanVideoItem(
          videoPath: e.path,
          subtitlePath: sel.subtitle == null ? null : dirPaths[sel.subtitle!],
        ),
      );
    }
  }

  // 漫画来源：哪些是卷整个交给引擎归组（与无头服务端同一份口径），包括单文件卷
  // 与包旁 `.mokuro` sidecar 的认领——sidecar 是那个包的文字层，不是另一卷。
  final MangaFolderPlan? mangaPlan = mangaRootPath == null
      ? null
      : _planMangaVolumes(
          files: files,
          rootPath: mangaRootPath,
          context: mangaPathContext,
        );

  return ScanPlan(
    books: books,
    videos: videos,
    playlists: playlists,
    mangas: mangaPlan == null
        ? mangas
        : <ScanMangaItem>[
            for (final String path in mangaPlan.mokuroPaths)
              ScanMangaItem(mokuroPath: path),
          ],
    mangaArchives: mangaPlan == null
        ? const <ScanMangaArchiveItem>[]
        : <ScanMangaArchiveItem>[
            for (final String path in mangaPlan.carrierPaths)
              ScanMangaArchiveItem(
                archivePath: path,
                mokuroSidecarPath: mangaPlan.mokuroSidecars[path],
              ),
          ],
    mangaFolders: mangaPlan == null
        ? const <ScanMangaFolderItem>[]
        : <ScanMangaFolderItem>[
            for (final String folder in mangaPlan.imageFolders)
              ScanMangaFolderItem(
                folderPath: folder,
                series: mangaPlan.seriesVolumes[folder],
              ),
          ],
    blurayDiscs: <ScanBlurayDiscItem>[
      for (final String root in blurayRoots)
        ScanBlurayDiscItem(discRootPath: root),
    ],
    dvdDiscs: <ScanDvdDiscItem>[
      for (final String root in dvdRoots) ScanDvdDiscItem(discRootPath: root),
      for (final String image in discImages..sort())
        ScanDvdDiscItem(discRootPath: image),
    ],
  );
}

/// 把扫描根里的纯页图归成可独立导入的卷目录。
///
/// 归组规则（单文件卷各一卷、包旁 sidecar 归包；根有页图 → 根一卷；否则每个含
/// 页图的直接子目录一卷；与 `.mokuro` / 单文件卷有包含关系的候选目录让位）下沉在
/// 引擎 [planMangaFolders]，与无头服务端的库扫描共用同一份实现；这里只做
/// [SourceFileEntry] → 路径列表的适配。
///
/// 本地与网络来源同一套归组规则；网络来源传 [context] = [p.url]（远端路径是正斜杠
/// / `https://` href），归出的卷目录仍是远端路径，由 [SourceLibraryScanner] 的
/// 远端分支先镜像到本地再导入。
MangaFolderPlan _planMangaVolumes({
  required List<SourceFileEntry> files,
  required String rootPath,
  p.Context? context,
}) {
  return planMangaFolders(
    rootPath: rootPath,
    context: context,
    // app 能把 PDF 栅格化成漫画，所以载体表比引擎缺省多一个 `.pdf`。
    carrierExtensions: <String>{
      for (final String ext in kScanMangaCarrierExtensions) '.$ext',
    },
    filePaths: <String>[
      for (final SourceFileEntry entry in files)
        if (!entry.isDirectory) entry.path,
    ],
  );
}

/// Source-library scanner: scans one [SourceLibraryRow] root, inserts the media
/// owned by this source, and writes back the scan result.
class SourceLibraryScanner {
  SourceLibraryScanner(
    this._db, {
    MangaSevenZipExtractor? mangaSevenZipExtractor,
    SourceFolderAccess? folderAccess,
  }) : _videoRepo = VideoBookRepository(_db),
       _mangaSevenZipExtractor = mangaSevenZipExtractor,
       _folderAccess = folderAccess ?? SourceFolderAccess.instance;

  final FushiDatabase _db;

  /// iOS 本地来源的安全作用域访问（BUG-3697）；测试注入 fake。
  final SourceFolderAccess _folderAccess;
  final VideoBookRepository _videoRepo;
  final MangaSevenZipExtractor? _mangaSevenZipExtractor;

  /// 从来源行解析文件系统：local → LocalSourceFileSystem；网络 → 解出连接参数
  /// （configJson）+ 凭据（SourceLibraryCredentialStore）构造 NetworkSourceFileSystem。
  Future<SourceFileSystem> _resolveFileSystem(SourceLibraryRow source) async {
    if (source.transport == 'local') {
      return const LocalSourceFileSystem();
    }
    final SourceLibrarySecret secret = await SourceLibraryCredentialStore(
      _db,
    ).readSecret(source.id);
    return buildNetworkFileSystem(
      transport: source.transport,
      config: decodeSourceConfig(source.configJson),
      password: secret.password,
      privateKey: secret.privateKey,
    );
  }

  /// 纯构造：把 transport + 连接参数 + 凭据组装成 [SourceFileSystem]（无 I/O）。
  /// 扫描与 SFTP 视频的播放期解析器（source_stream_headers.dart）共用这一处，测试也
  /// 借它断言路由正确。WebDAV 的 host/port/useTls 不参与传输（URL 即 rootPath，
  /// 自带 scheme/host/端口），此处仍原样填入仅为字段对齐，NetworkSourceFileSystem 忽略。
  static SourceFileSystem buildNetworkFileSystem({
    required String transport,
    required Map<String, Object?> config,
    String? password,
    String? privateKey,
  }) {
    if (transport == 'local') {
      return const LocalSourceFileSystem();
    }
    final int port =
        (config['port'] as num?)?.toInt() ?? (transport == 'sftp' ? 22 : 21);
    return NetworkSourceFileSystem(
      NetworkSourceConfig(
        transport: transport,
        host: (config['host'] as String?) ?? '',
        port: port,
        username: (config['username'] as String?) ?? '',
        password: (password != null && password.isNotEmpty) ? password : null,
        privateKey: (privateKey != null && privateKey.isNotEmpty)
            ? privateKey
            : null,
        useTls: (config['useTls'] as bool?) ?? false,
        baseUrl: (config['baseUrl'] as String?),
      ),
    );
  }

  /// Scans one source library.
  ///
  /// [fs] defaults to [LocalSourceFileSystem] (M1b connects only locally); tests
  /// inject a local impl over a real temp dir. Routes by [SourceLibraryRow.mediaKind]
  /// ('book' | 'video' | 'manga'):
  /// - 'book': each EPUB -> [EpubImporter.importFromPath] (with sourceId).
  /// - 'video': each video -> [VideoBookRepository.saveVideoBook] (with sourceId)
  ///   plus parsed cues when a same-name subtitle exists.
  /// - 'manga': each `.mokuro` -> [MangaImporter.importFromMokuroPath] (with
  ///   sourceId)；网络 transport 先整卷镜像下载（见 [_importMangaRemote]）。
  ///
  /// After insert, calls [FushiDatabase.updateMediaSourceScanResult] to write the
  /// media count / timestamp; any throw records its text in lastScanError
  /// (mediaCount reflects the count successfully inserted before the failure).
  ///
  /// [restoreDissolvedGroups]：用户显式「恢复自动分组」时为 true——本轮扫描不再
  /// 尊重解散合集留下的墓碑（BUG-1739 的防复活门），把散开的视频按规则重新归组。
  /// 普通重扫 / 定时扫描一律 false，用户的解散照常保持。
  Future<SourceScanSummary> scan(
    SourceLibraryRow source, {
    SourceFileSystem? fs,
    bool restoreDissolvedGroups = false,
  }) {
    if (source.mediaKind != SourceLibraryKind.video.dbValue) {
      return _scanUnlocked(source, fs: fs);
    }
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) {
      return Future<SourceScanSummary>.value(
        SourceScanSummary(
          sourceId: source.id,
          mediaKind: source.mediaKind,
          discoveredPaths: const <String>[],
          importedMediaCount: 0,
          error: '视频刮削资料正在清理',
        ),
      );
    }
    return _scanUnlocked(
      source,
      fs: fs,
      restoreDissolvedGroups: restoreDissolvedGroups,
    ).whenComplete(lease.release);
  }

  /// 音乐来源：不走通用文件清单 + ScanPlan——目录遍历与标签 / CUE 解析都在 Rust 胖核心
  /// （native/fushi_music）里，由 [MusicLibraryScanner] 接管。只支持本地目录（Rust 直接
  /// 读文件系统）；网络来源如实报错。原生库缺失是部署缺陷，照常抛出不吞。
  Future<SourceScanSummary> _scanMusicSource(SourceLibraryRow source) async {
    int mediaCount = 0;
    String? scanError;
    if (source.transport != 'local') {
      scanError = 'Music sources support local folders only';
    } else {
      try {
        final MusicScanSummary summary = await MusicLibraryScanner(_db)
            .scanSource(
              sourceId: source.id,
              rootPath: source.rootPath,
              recursive: source.recursive,
            );
        mediaCount = summary.trackCount;
        scanError = summary.errorSummary;
        // 缺 ReplayGain 标签的新曲目交给后台响度扫描（不阻塞来源扫描收尾）。
        onMusicSourceScanned?.call();
      } on MusicScanRootError catch (e) {
        scanError = e.toString();
      }
    }
    await _db.updateMediaSourceScanResult(
      id: source.id,
      mediaCount: mediaCount,
      lastScannedAt: DateTime.now(),
      lastScanError: scanError,
    );
    return SourceScanSummary(
      sourceId: source.id,
      mediaKind: source.mediaKind,
      discoveredPaths: const <String>[],
      importedMediaCount: mediaCount,
      error: scanError,
    );
  }

  Future<SourceScanSummary> _scanUnlocked(
    SourceLibraryRow source, {
    SourceFileSystem? fs,
    bool restoreDissolvedGroups = false,
  }) async {
    // iOS：本地来源在沙盒外，不先激活书签 `dart:io` 一个文件都列不出（BUG-3697）。
    // 激活失败（没存书签 / 解析失败 / 文件夹被挪走）是**整次扫描**读不了，写明原因
    // 后直接收尾，不把「读不到」伪装成「0 个媒体」。其它平台恒返回 null。
    final String? accessError = await _folderAccess.ensureSourceAccess(
      _db,
      source,
    );
    if (accessError != null) {
      await _db.updateMediaSourceScanResult(
        id: source.id,
        mediaCount: 0,
        lastScannedAt: DateTime.now(),
        lastScanError: accessError,
      );
      return SourceScanSummary(
        sourceId: source.id,
        mediaKind: source.mediaKind,
        discoveredPaths: const <String>[],
        importedMediaCount: 0,
        error: accessError,
      );
    }
    if (source.mediaKind == SourceLibraryKind.music.dbValue) {
      return _scanMusicSource(source);
    }
    final SourceFileSystem transportFs = fs ?? await _resolveFileSystem(source);
    int mediaCount = 0;
    String? scanError;

    /// 逐文件失败的汇总（BUG-2570）。扫描本身跑完了，只是其中几个文件没进得去——
    /// 比「整次扫描中断」轻一级，所以只有在 [scanError] 为空时才顶上去。
    String? partialError;
    List<String> discoveredPaths = const <String>[];
    VideoFolderGroupSummary grouping = (
      createdVideoUids: const <String>[],
      reusedVideoUids: const <String>[],
      createdCollectionIds: const <int>[],
      updatedCollectionIds: const <int>[],
    );
    try {
      // 值域显式化（命名统一 Phase 3.4）：落库串经 SourceLibraryKind 严格解析，
      // 未知串在这里立刻失败（与旧 else 分支同语义），下方分派改穷尽 switch。
      final SourceLibraryKind? kind = SourceLibraryKind.tryParse(
        source.mediaKind,
      );
      if (kind == null) {
        throw ArgumentError.value(
          source.mediaKind,
          'mediaKind',
          'Unsupported media kind for scan (expected book | video | manga)',
        );
      }
      // 网络视频来源支持 SFTP、WebDAV 与 AList/OpenList，按流媒体书原地入库
      // 播放（[_importVideos] streamInPlace）：WebDAV / AList 条目本身就是 http(s)
      // URL（AList 播放前再经 fs/get 换签名直链）；SFTP 条目换进 `sftp://` 命名
      // 空间入库，起播时经回环中继按偏移读（见 sftp_stream_source.dart 与
      // source_stream_headers.dart）。FTP 读不了区间、拖不了进度条，仍拒绝。
      if (!transportFs.isLocal &&
          kind == SourceLibraryKind.video &&
          !kStreamableVideoSourceTransports.contains(source.transport)) {
        throw StateError(
          'Network video sources support SFTP/WebDAV/AList only',
        );
      }
      final String? sftpUrlRoot =
          !transportFs.isLocal &&
              kind == SourceLibraryKind.video &&
              source.transport == 'sftp'
          ? sftpSourceUrlRootForConfig(decodeSourceConfig(source.configJson))
          : null;
      final SourceFileSystem files = sftpUrlRoot == null
          ? transportFs
          : SftpUrlNamespaceFileSystem(transportFs, urlRoot: sftpUrlRoot);
      // 扫描根与条目同一命名空间：作品归组按「相对扫描根」算目录。
      final String scanRoot = sftpUrlRoot == null
          ? source.rootPath
          : sftpSourceUrlOf(source.rootPath, sftpUrlRoot);
      final List<SourceFileEntry> entries = excludeSourceIncomingEntries(
        await files.listFiles(source.rootPath, recursive: source.recursive),
        sourceRoot: source.rootPath,
        isLocal: files.isLocal,
      );
      final ScanPlan plan = planScanFromFileList(
        entries,
        mangaRootPath: kind == SourceLibraryKind.manga ? source.rootPath : null,
        mangaPathContext: files.isLocal ? null : p.url,
        detectBlurayDiscs: files.isLocal && kind == SourceLibraryKind.video,
        detectDvdDiscs: files.isLocal && kind == SourceLibraryKind.video,
        includeAudioAsVideo: kind == SourceLibraryKind.video,
      );
      discoveredPaths = <String>[
        for (final ScanBookItem item in plan.books) item.bookPath,
        for (final ScanVideoItem item in plan.videos) item.videoPath,
        for (final ScanPlaylistItem item in plan.playlists) item.playlistPath,
        for (final ScanMangaItem item in plan.mangas) item.mokuroPath,
        for (final ScanMangaArchiveItem item in plan.mangaArchives)
          item.archivePath,
        for (final ScanMangaFolderItem item in plan.mangaFolders)
          item.folderPath,
        for (final ScanBlurayDiscItem item in plan.blurayDiscs)
          item.discRootPath,
        for (final ScanDvdDiscItem item in plan.dvdDiscs) item.discRootPath,
      ];

      switch (kind) {
        case SourceLibraryKind.book:
          mediaCount = await _importBooks(plan, source.id, files);
          // 与视频分支对称：入库后把分卷按系列持久归组（BUG-3441）。不留到书架页
          // 打开才归——本机作为互联 host / 合集云同步源时，对端拿到的归属来自这里。
          await BookSeriesGrouper(_db).groupAll();
        case SourceLibraryKind.video:
          // Video source imports both single videos and m3u8/m3u playlists
          // (TODO-1237).
          final ({
            List<String> createdPaths,
            List<String> failedPaths,
            Object? firstError,
          })
          imported = await _importVideos(plan, source.id, files);
          final List<String> createdVideoPaths = imported.createdPaths;
          mediaCount = createdVideoPaths.length;
          // BUG-2570：部分文件失败不再作废整批。把「几个失败 / 第一个是谁 / 为什么」
          // 汇总成一条能照着查的错误，成功的条目照常计数入库。真正中断扫描的异常
          // 仍走下面的总 catch 覆盖它（那是整次扫描没跑完，比部分失败更严重）。
          if (imported.failedPaths.isNotEmpty) {
            partialError =
                'Imported ${createdVideoPaths.length} video(s); '
                '${imported.failedPaths.length} failed. First failure: '
                '${p.basename(imported.failedPaths.first)} — '
                '${imported.firstError}';
          }
          // 来源扫描与旧「导入视频文件夹」共用同一套作品/季/集解析规则：散片
          // 保持独立，多集整理为 playlist 合集。先完成逐文件入库，字幕 cue / 封面
          // 的既有增强不变；再只做归组，重扫复用已有成员且不删除缺失文件。
          // 网络（WebDAV）来源同样归组：文件名解析统一走解码 basename
          // （sourceEntryBasename）。来源库条目路径进到这里已是解码态（见该函数
          // 文档），所以取末段即可，不能再解一次。
          grouping =
              await VideoFolderGroupCoordinator(
                database: _db,
                repository: _videoRepo,
              ).groupPaths(
                videoPaths: <String>[
                  for (final ScanVideoItem item in plan.videos)
                    if (source.videoGroupingMode == 'folder' ||
                        classifyLocalVideoExtra(item.videoPath) == null)
                      item.videoPath,
                ],
                createdVideoPaths: createdVideoPaths,
                sourceId: source.id,
                groupingMode: source.videoGroupingMode,
                sourceRoot: scanRoot,
                restoreDissolvedGroups: restoreDissolvedGroups,
              );
          // 归组按季 → 集排完后，没有集号的 SP / OVA / 特别篇交 AI 定位（只在
          // 指派了提供商、用户没手动排过时才发请求）；后台跑，不阻塞扫描。
          scheduleAutomaticCollectionAiOrder(
            db: _db,
            collectionIds: <int>[
              ...grouping.createdCollectionIds,
              ...grouping.updatedCollectionIds,
            ],
          );
          // 规则归不了组的新视频：开了「导入后自动 AI 整理」时去抖后交 AI（spec
          // 2026-10-20 §10.2，门在 runner 里），不阻塞扫描。
          scheduleAutomaticLibraryOrganize(CollectionShelfDomain.video);
          mediaCount += await _importPlaylists(
            plan,
            source.id,
            files,
            restoreDissolvedGroups: restoreDissolvedGroups,
          );
          mediaCount += await _importBlurayDiscs(
            plan,
            source.id,
            restoreDissolvedGroups: restoreDissolvedGroups,
          );
          final ({int imported, List<String> failed}) dvd =
              await _importDvdDiscs(
                plan,
                source.id,
                restoreDissolvedGroups: restoreDissolvedGroups,
              );
          mediaCount += dvd.imported;
          // IFO 损坏的盘明确报出来（与 BUG-2570 部分失败同语义：其余盘照常入库）。
          if (dvd.failed.isNotEmpty) {
            final String note =
                '${dvd.failed.length} DVD(s) unreadable. '
                'First: ${dvd.failed.first}';
            partialError = partialError == null ? note : '$partialError; $note';
          }
          if (source.videoGroupingMode != 'folder') {
            await VideoSourceMetadataIndexer(_db).index(source);
          }
        case SourceLibraryKind.manga:
          final _MangaVolumeTally manga = await _importManga(
            plan,
            source,
            files,
            entries,
          );
          mediaCount = manga.imported;
          // 与视频分支同语义（BUG-2570）：部分卷失败不作废整批。
          if (manga.failedPaths.isNotEmpty) {
            partialError =
                'Imported ${manga.imported} manga volume(s); '
                '${manga.failedPaths.length} failed. First failure: '
                '${p.basename(manga.failedPaths.first)} — '
                '${manga.firstError}';
          }
          await BookSeriesGrouper(_db).groupAll();
        case SourceLibraryKind.music:
          // 音乐来源在进 try 之前就分流给 [_scanMusicSource]，走不到这里。
          throw StateError('music sources are routed to _scanMusicSource');
      }
    } catch (e, stack) {
      scanError = e.toString();
      debugPrint(
        'SourceLibraryScanner.scan failed for '
        'source ${source.id} (${source.rootPath}): $e\n$stack',
      );
    } finally {
      // 关闭网络连接（本地/注入的 fake 无需关闭）。
      if (transportFs is NetworkSourceFileSystem) {
        await transportFs.close();
      }
    }

    // 整次扫描中断的异常优先；没有它时，逐文件失败的汇总才是本次要报的错。
    scanError ??= partialError;
    await _db.updateMediaSourceScanResult(
      id: source.id,
      mediaCount: mediaCount,
      lastScannedAt: DateTime.now(),
      lastScanError: scanError,
    );
    return SourceScanSummary(
      sourceId: source.id,
      mediaKind: source.mediaKind,
      discoveredPaths: List<String>.unmodifiable(discoveredPaths),
      importedMediaCount: mediaCount,
      createdVideoUids: grouping.createdVideoUids,
      reusedVideoUids: grouping.reusedVideoUids,
      createdCollectionIds: grouping.createdCollectionIds,
      updatedCollectionIds: grouping.updatedCollectionIds,
      error: scanError,
    );
  }

  /// Imports every EPUB in the plan; returns the count successfully inserted.
  ///
  /// BUG-443: silent same-title dedup, mirroring [_importVideos]. Manual single-
  /// file import asks the user (or auto-suffixes to `X (2)`), but a batch folder
  /// scan must NOT re-import already-imported books as `X (2)`. We pass
  /// `DuplicatePolicy.skip()` so [EpubImporter.importFromPath] reuses the existing
  /// `sanitizeTtuFilename` identity key: on a collision it throws
  /// [DuplicateImportCancelledException], which we catch per book and skip
  /// (not counted, not an error). The within-isolate parse + DB read picks up
  /// books inserted earlier in the same scan, so a same-batch duplicate is also
  /// skipped.
  Future<int> _importBooks(
    ScanPlan plan,
    int sourceId,
    SourceFileSystem fs,
  ) async {
    int count = 0;
    Directory? epubTmp;
    for (final ScanBookItem item in plan.books) {
      try {
        // 网络来源：先把远端书文件下载到临时盘（导入器只吃本地路径）；本地原样。
        String localBook = item.bookPath;
        if (!fs.isLocal) {
          epubTmp ??= Directory.systemTemp.createTempSync('m1c_scan_books_');
          localBook = await fs.copyToLocal(item.bookPath, epubTmp.path);
        }
        // DuplicatePolicy.skip() reuses the sanitizeTtuFilename identity key so a
        // re-scan / same-batch duplicate throws DuplicateImportCancelledException
        // (caught below) instead of a silent "X (2)" (BUG-443). The returned
        // bookKey is the audiobook anchor when a sidecar audio attaches.
        //
        // PDF 分流到 [PdfImporter]：同一套 bookKey 身份、同一条 skip 语义、同一张
        // `EpubBooks` 表，差别只在产物（拷 document.pdf + 栅格化首页当封面）。标题
        // 取文件名去扩展名——PDF 元数据里的标题不可靠，与单本导入对话框同口径。
        final String bookKey = item.isPdf
            ? await PdfImporter.importFromPath(
                db: _db,
                filePath: localBook,
                fileName: p.basename(item.bookPath),
                title: p.basenameWithoutExtension(item.bookPath),
                sourceId: sourceId,
                policy: const DuplicatePolicy.skip(),
              )
            : await EpubImporter.importFromPath(
                db: _db,
                filePath: localBook,
                fileName: p.basename(item.bookPath),
                sourceId: sourceId,
                policy: const DuplicatePolicy.skip(),
              );
        count++;
        // TODO-946：同目录有同名字幕 + 音频 -> 复用对话框抽出的非 UI 落库 service
        // 把这本 EPUB 升级成有声书（字幕做对齐源 + 音频）。网络来源先把 sidecar
        // 下到临时盘（[_withLocalSidecars]）：service 会把字幕与音频复制进书自己的
        // 持久目录，临时文件用完即删，落库产物与本地导入同构。
        if (item.isAudiobook) {
          await _withLocalSidecars(
            item,
            fs,
            (String subtitlePath, List<String> audioPaths) =>
                alignAndPersistAudiobook(
                  db: _db,
                  repo: SrtBookRepository(_db),
                  audiobookRepo: AudiobookRepository(_db),
                  bookKey: bookKey,
                  title: p.basenameWithoutExtension(item.bookPath),
                  subtitlePath: subtitlePath,
                  audioPaths: audioPaths,
                ),
          );
        }
      } on DuplicateImportCancelledException catch (e) {
        // TODO-1284：书已导入过。纯重扫时静默跳过是对的（对齐 _importVideos），但若
        // 首次导入后才把同名字幕+音频放到书旁边（书当初是按纯 EPUB 导入的），重扫必须
        // 把它补挂成有声书——否则新增的 .srt/.mp3 被静默忽略。仅当该书尚未挂任何有声书
        // 时才对齐，保证重复重扫幂等、不重跑 matcher、不覆盖用户手动重匹配。
        await _attachSidecarAudiobookToExisting(item, e.title, fs);
        debugPrint(
          'SourceLibraryScanner skip duplicate book '
          '${e.title} (${item.bookPath})',
        );
      }
    }
    if (epubTmp != null) {
      try {
        epubTmp.deleteSync(recursive: true);
      } catch (_) {}
    }
    return count;
  }

  /// TODO-1284：重扫时把「首次导入后才新增到书旁的同名字幕+音频」补挂成有声书。
  ///
  /// [title] 是 [DuplicateImportCancelledException] 携带的冲突标题，其身份 key
  /// （[sanitizeTtuFilename]）即已存在书的 bookKey。仅当本次扫描项确有 sidecar
  /// 字幕+音频（[ScanBookItem.isAudiobook]）、该 bookKey 的书确实在库、且尚未挂任何
  /// 有声书时才对齐落库；已挂则跳过，保证重扫幂等、不重跑 matcher、不覆盖用户手动
  /// 重匹配。三项判据都在下载 sidecar 之前，网络来源重扫已挂好的书零音频流量。
  Future<void> _attachSidecarAudiobookToExisting(
    ScanBookItem item,
    String title,
    SourceFileSystem fs,
  ) async {
    if (!item.isAudiobook) return;
    final String bookKey = sanitizeTtuFilename(title);
    final EpubBookRow? existingBook = await _db.getEpubBook(bookKey);
    if (existingBook == null) return;
    final AudiobookRepository audiobookRepo = AudiobookRepository(_db);
    final Audiobook? alreadyAttached = await audiobookRepo.findByBookKey(
      bookKey,
    );
    if (alreadyAttached != null) return;
    await _withLocalSidecars(
      item,
      fs,
      (String subtitlePath, List<String> audioPaths) =>
          alignAndPersistAudiobook(
            db: _db,
            repo: SrtBookRepository(_db),
            audiobookRepo: audiobookRepo,
            bookKey: bookKey,
            title: p.basenameWithoutExtension(item.bookPath),
            subtitlePath: subtitlePath,
            audioPaths: audioPaths,
          ),
    );
  }

  /// 让 [body] 拿到 [item] 的字幕 / 音频 sidecar 的**本地**路径。
  ///
  /// 本地来源原样透传；网络来源先 [SourceFileSystem.copyToLocal] 到一个临时目录，
  /// [body] 结束后（无论成败）删掉。同目录 sidecar 文件名天然不重名，平铺即可。
  static Future<T> _withLocalSidecars<T>(
    ScanBookItem item,
    SourceFileSystem fs,
    Future<T> Function(String subtitlePath, List<String> audioPaths) body,
  ) async {
    if (fs.isLocal) return body(item.subtitlePath!, item.audioPaths);
    final Directory tmp = Directory.systemTemp.createTempSync(
      'm1c_scan_book_sidecars_',
    );
    try {
      final String subtitle = await fs.copyToLocal(
        item.subtitlePath!,
        tmp.path,
      );
      final List<String> audio = <String>[
        for (final String remote in item.audioPaths)
          await fs.copyToLocal(remote, tmp.path),
      ];
      return await body(subtitle, audio);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 漫画来源扫描：逐卷导入 `.mokuro` 卷、单文件卷与纯页图卷，返回逐卷结局。
  ///
  /// **重复判据 = 标题 + 来源路径**（引擎 [isDuplicateSourceBook]，与无头服务端同一
  /// 份）。每个源在来源扫描索引（[BookSourceIndex]）里记下「源相对路径 → 书 uid」：
  /// - 索引里已有 → 已导入，跳过（不开包、不下载）；
  /// - 标题被本来源另一个仍在场的文件占着 → 是另一卷，按 [DuplicatePolicy.suffix]
  ///   换名另导。此前只看标题，`系列A/Vol 1.cbz` 之后的 `系列B/Vol 1.cbz`、同目录的
  ///   `Vol 1.pdf` 都被静默跳过；
  /// - 标题被本来源一本没人认领的旧行占着（升级前扫进来的）→ 认领它，不再导入；
  /// - 被手动导入 / 别的来源的书占着 → 按重复跳过（BUG-443 的「重扫不生成 `X (2)`」
  ///   语义不变）。
  ///
  /// 单文件卷里扩展名二义的 `.zip` / `.epub` 在后台 isolate 开包定性
  /// （[looksLikeImageArchiveInBackground]）；判「不是漫画」的连同内容指纹记进索引的
  /// 负向表，指纹不变就不再开包 / 下载重判。
  ///
  /// 其它导入异常（坏 JSON / 缺图 / 坏包）**逐卷**收进 [_MangaVolumeTally]，其余卷
  /// 照常入库，由 [scan] 汇总成一条 lastScanError（与视频分支 BUG-2570 同语义）。
  ///
  /// 网络 transport 走 [_importMangaRemote]（整卷镜像下载后仍复用本地导入器）。
  Future<_MangaVolumeTally> _importManga(
    ScanPlan plan,
    SourceLibraryRow source,
    SourceFileSystem fs,
    List<SourceFileEntry> entries,
  ) async {
    final _MangaVolumeTally tally = _MangaVolumeTally();
    if (plan.mangas.isEmpty &&
        plan.mangaArchives.isEmpty &&
        plan.mangaFolders.isEmpty) {
      return tally;
    }
    final _MangaSourceIdentity identity = await _MangaSourceIdentity.load(
      db: _db,
      source: source,
      isLocal: fs.isLocal,
      plan: plan,
      entries: entries,
    );
    try {
      if (fs.isLocal) {
        await _importMangaLocal(plan, identity, tally);
      } else {
        await _importMangaRemote(plan, identity, fs, tally);
      }
      await _retireFlattenedSeries(plan, identity, tally);
    } finally {
      await identity.index.save(_db);
    }
    return tally;
  }

  /// 旧版把 `系列/卷N/页图` 的整个系列目录导成一本；本轮按新规则拆出的分卷全部在库
  /// 后，回收那本合订本（引擎 [retireFlattenedMangaSeries]，与无头服务端同一份）。
  /// 回收失败只记进本轮的部分失败汇总，不中断扫描。
  Future<void> _retireFlattenedSeries(
    ScanPlan plan,
    _MangaSourceIdentity id,
    _MangaVolumeTally tally,
  ) async {
    final Map<String, MangaSeriesVolume> seriesByDir =
        <String, MangaSeriesVolume>{};
    final Map<String, List<String>> volumeRels = <String, List<String>>{};
    for (final ScanMangaFolderItem item in plan.mangaFolders) {
      final MangaSeriesVolume? series = item.series;
      if (series == null) continue;
      seriesByDir[series.seriesDir] = series;
      (volumeRels[series.seriesDir] ??= <String>[]).add(
        id.relOf(item.folderPath),
      );
    }
    if (seriesByDir.isEmpty) return;
    final ({List<String> retiredUids, List<String> errors}) result =
        await retireFlattenedMangaSeries(
          db: _db,
          index: id.index,
          sourceId: id.sourceId,
          series: <FlattenedMangaSeries>[
            for (final MapEntry<String, MangaSeriesVolume> e
                in seriesByDir.entries)
              (
                seriesRel: id.relOf(e.key),
                seriesTitle: e.value.seriesTitle,
                volumeRels: volumeRels[e.key]!,
              ),
          ],
        );
    if (result.retiredUids.isNotEmpty) {
      debugPrint(
        'SourceLibraryScanner retired ${result.retiredUids.length} '
        'flattened manga series book(s) superseded by split volumes',
      );
    }
    for (final String error in result.errors) {
      tally.failedPaths.add(error);
      tally.firstError ??= error;
    }
  }

  /// 本地漫画来源逐卷导入（判据见 [_importManga]）。
  Future<void> _importMangaLocal(
    ScanPlan plan,
    _MangaSourceIdentity id,
    _MangaVolumeTally tally,
  ) async {
    for (final ScanMangaItem item in plan.mangas) {
      final String path = item.mokuroPath;
      await tally.attempt(path, () async {
        if (id.isIndexed(path)) return false;
        // 标题与导入器同一派生（mokuro 顶层 title/volume，再退化文件名），显式传给
        // 导入器，判据与落库用的是同一个标题。
        // mokuro 旧版 `.html` manifest 没有 JSON 顶层，元数据按路径派生（与导入器
        // 拼回的 `.mokuro` 顶层同一个函数）。
        final String title = MangaImporter.deriveMokuroTitle(
          isMokuroLegacyHtmlPath(path)
              ? legacyMokuroRoot(path)
              : _decodeMokuroRoot(await File(path).readAsString()),
          p.basename(path),
        );
        final DuplicatePolicy? policy = await id.policyFor(path, title);
        if (policy == null) return false;
        final String bookKey = await MangaImporter.importFromMokuroPath(
          db: _db,
          mokuroPath: path,
          title: title,
          sourceId: id.sourceId,
          policy: policy,
        );
        await id.record(path, bookKey);
        return true;
      });
    }
    for (final ScanMangaArchiveItem item in plan.mangaArchives) {
      final String path = item.archivePath;
      await tally.attempt(path, () async {
        // 先查索引 / 负向表 / 重复判据（都只读库），全部放行才开包：已在库的卷每次
        // 重扫都整包解压一遍、文字 EPUB 每次整本解析一遍，正是这几步要挡掉的。
        if (id.isIndexed(path) || id.isRejected(path)) return false;
        final String title = p.basenameWithoutExtension(path);
        final DuplicatePolicy? policy = await id.policyFor(path, title);
        if (policy == null) return false;
        final String? bookKey = await _importMangaCarrierFile(
          localPath: path,
          title: title,
          sourceId: id.sourceId,
          policy: policy,
        );
        if (bookKey == null) {
          id.reject(path);
          return false;
        }
        await id.record(path, bookKey);
        return true;
      });
    }
    for (final ScanMangaFolderItem item in plan.mangaFolders) {
      final String path = item.folderPath;
      await tally.attempt(path, () async {
        if (id.isIndexed(path)) return false;
        final String title = item.series?.title ?? p.basename(path);
        final DuplicatePolicy? policy = await id.policyFor(path, title);
        if (policy == null) return false;
        final String bookKey = await MangaImporter.importFromImageFolder(
          db: _db,
          imageDirPath: path,
          title: title,
          sourceId: id.sourceId,
          policy: policy,
        );
        await id.record(path, bookKey);
        return true;
      });
    }
  }

  /// 把一个本地单文件漫画卷（[kScanMangaCarrierExtensions]）导入漫画库，返回书 key。
  ///
  /// 载体身份交给与手动导入同一份 [classifyImportCarrier] 判定，不在扫描器里另立
  /// 规则：`.cbz` / `.rar` / `.cbr` / `.cb7` 直接是压缩包卷；`.zip` / `.epub` 开包
  /// 确认装的是页图（[MangaArchiveImporter.looksLikeImageArchive]，词典包一票否决、
  /// 文字 EPUB 不算）——这一步在后台 isolate 里跑（[looksLikeImageArchiveInBackground]），
  /// 文字 EPUB 的定性要整本解析一次，不能压在 UI isolate 上；`.pdf` 逐页栅格化成漫画
  /// （[importMangaFromPdf]）。
  ///
  /// 返回 null 表示「扩展名对得上但内容不是漫画」（词典 `.zip`、文字 `.epub`）：
  /// 漫画来源里混进这种文件不算导入失败，跳过即可，与其它非漫画文件同样处理。
  Future<String?> _importMangaCarrierFile({
    required String localPath,
    required String title,
    required int sourceId,
    required DuplicatePolicy policy,
  }) async {
    final bool isImageArchive =
        mangaArchiveNeedsContentProbe(localPath) &&
        await looksLikeImageArchiveInBackground(localPath);
    final ImportCarrier carrier = classifyImportCarrier(
      localPath,
      // 扫描规划阶段已经只收文件，目录分支不可达。
      isDirectory: (String _) => false,
      // 只对二义扩展名问它，答案已在后台 isolate 里算好。
      isImageArchive: (String _) => isImageArchive,
      directoryHasPageImages: (String _) => false,
      directoryCarrierFileCount: (String _) => 0,
      directoryMokuroFileCount: (String _) => 0,
    );
    switch (carrier) {
      case ImportCarrier.mangaArchive:
        return MangaArchiveImporter.importArchive(
          db: _db,
          archivePath: localPath,
          title: title,
          sourceId: sourceId,
          policy: policy,
          sevenZipExtractor: _mangaSevenZipExtractor,
        );
      case ImportCarrier.pdf:
        return importMangaFromPdf(
          db: _db,
          pdfPath: localPath,
          fileName: p.basename(localPath),
          title: title,
          sourceId: sourceId,
          policy: policy,
        );
      case ImportCarrier.mangaFolder:
      case ImportCarrier.mangaBatchFolder:
      case ImportCarrier.mangaMokuro:
      case ImportCarrier.epub:
      case ImportCarrier.text:
        debugPrint(
          'SourceLibraryScanner skip non-manga file in manga source '
          '($carrier): $localPath',
        );
        return null;
    }
  }

  /// 网络漫画来源整卷下载导入。
  ///
  /// 一卷漫画体量远超一次「顺手下载」，所以下载前先过与本地同一套判据
  /// （[_MangaSourceIdentity]：来源索引、负向表、标题 + 来源路径的重复判据）——重扫
  /// 已入库的卷、判过不是漫画且没变过的包都零下载。`.mokuro` 卷先读远端小文本派生
  /// 标题（[MangaImporter.deriveMokuroTitle]）再判。放行才把该卷镜像到本地临时目录，
  /// 交给本地导入器：导入器只吃本地路径，落库时仍是恒复制进书目录，产物与本地导入
  /// 逐字节同构。
  ///
  /// 缺页 / 坏 JSON 与本地语义一致：抛 [MangaImportException] 记为该卷失败。WebDAV
  /// 的 href 分段是百分号编码的，查表键与镜像文件名统一用解码后的相对路径（来源库
  /// 条目路径本就是解码态，取末段用 [sourceEntryBasename]）。
  Future<void> _importMangaRemote(
    ScanPlan plan,
    _MangaSourceIdentity id,
    SourceFileSystem fs,
    _MangaVolumeTally tally,
  ) async {
    for (final ScanMangaItem item in plan.mangas) {
      await tally.attempt(
        item.mokuroPath,
        () => _importRemoteMokuroVolume(item: item, id: id, fs: fs),
      );
    }
    for (final ScanMangaArchiveItem item in plan.mangaArchives) {
      await tally.attempt(
        item.archivePath,
        () => _importRemoteMangaCarrier(item: item, id: id, fs: fs),
      );
    }
    for (final ScanMangaFolderItem item in plan.mangaFolders) {
      await tally.attempt(
        item.folderPath,
        () => _importRemoteMangaFolder(item: item, id: id, fs: fs),
      );
    }
  }

  /// 远端一卷 `.mokuro`：先过判据，放行才镜像页图并交本地导入器。
  /// 返回 false = 已在库 / 按重复跳过，未下载页图。
  Future<bool> _importRemoteMokuroVolume({
    required ScanMangaItem item,
    required _MangaSourceIdentity id,
    required SourceFileSystem fs,
  }) async {
    if (id.isIndexed(item.mokuroPath)) return false;
    if (isMokuroLegacyHtmlPath(item.mokuroPath, context: p.url)) {
      return _importRemoteLegacyMokuroVolume(item: item, id: id, fs: fs);
    }
    final String mokuroName = sourceEntryBasename(item.mokuroPath);
    final String jsonStr = await fs.readText(item.mokuroPath);
    final String title = MangaImporter.deriveMokuroTitle(
      _decodeMokuroRoot(jsonStr),
      mokuroName,
    );
    final DuplicatePolicy? policy = await id.policyFor(item.mokuroPath, title);
    if (policy == null) return false;
    final MokuroPayload payload = parseMokuro(jsonStr);
    if (payload.images.isEmpty) {
      throw const MangaImportException('Mokuro file has no pages');
    }

    // 远端相对路径（解码、正斜杠）→ 远端全路径查找表，作用域 = `.mokuro` 父目录。
    final String parentDir = _remoteParentDir(item.mokuroPath);
    final List<SourceFileEntry> remoteFiles = await fs.listFiles(
      parentDir,
      recursive: true,
    );
    final String prefix = parentDir.endsWith('/') ? parentDir : '$parentDir/';
    final Map<String, String> remoteByRel = <String, String>{};
    for (final SourceFileEntry e in remoteFiles) {
      if (e.isDirectory || !e.path.startsWith(prefix)) continue;
      // 段不再解码：[SourceFileEntry.path] 进到这里时**已经是解码态**——WebDAV
      // 的 PROPFIND href 在 webdav_ops.dart 里就 `Uri.decodeFull` 过了，SFTP/FTP
      // 路径本就不是百分号编码。再解一次会踩两个坑：真名含 `%`（`50% off.jpg`）
      // 时 `Uri.decodeComponent` 抛 ArgumentError（当时这里还没有逐卷兜底，整个
      // 来源的扫描当场中止）；真名是 `A%20B.jpg` 时被解成 `A B.jpg`，与下面按
      // payload.url 查表的键对不上，抛 `Missing manga page image`。
      final List<String> segs = e.path
          .substring(prefix.length)
          .split('/')
          .where((String s) => s.isNotEmpty)
          .toList();
      if (segs.isEmpty) continue;
      remoteByRel[segs.join('/')] = e.path;
    }

    // 页图根与本地导入同一口径（[resolveMokuroPageRoot]）：远端同样有「img_path
    // 自带卷名前缀」和「卷子目录布局裸文件名」两种惯例，这里若仍硬编码同级，
    // 卷子目录布局的远端卷在查表阶段就报缺图（BUG-1830 的远端同源分身）。
    final String remoteVolumeName = p.basenameWithoutExtension(mokuroName);
    final List<String>? pageRoot = resolveMokuroPageRoot(
      payload: payload,
      volumeName: remoteVolumeName,
      pageExists: remoteByRel.containsKey,
    );
    if (pageRoot == null) {
      final String searched =
          mokuroPageRootCandidates(volumeName: remoteVolumeName)
              .map(
                (List<String> candidate) => candidate.isEmpty
                    ? parentDir
                    : '$prefix${candidate.join('/')}',
              )
              .join(', ');
      throw MangaImportException(
        'Missing manga page image: ${payload.images.first.url} '
        '(searched: $searched)',
      );
    }

    final Directory tmp = Directory.systemTemp.createTempSync(
      'm1c_scan_manga_',
    );
    try {
      // 逐页镜像，**连页图根一起原样保留**（`<根>/<url>`）：本地导入器对着镜像
      // 目录再解析一次根，两边同一口径，于是镜像布局与远端逐段同构。`..` 段直接
      // 拒绝：临时镜像在书目录 sanitize 之前落盘，不能靠后面那道防穿越。
      for (final MokuroImage page in payload.images) {
        final List<String> segs = page.url
            .split(RegExp(r'[\\/]+'))
            .where((String s) => s.isNotEmpty)
            .toList();
        if (segs.isEmpty || segs.contains('..')) {
          throw MangaImportException('Invalid manga page path: ${page.url}');
        }
        final String rel = joinMokuroPageRoot(pageRoot, segs.join('/'));
        final String? remotePath = remoteByRel[rel];
        if (remotePath == null) {
          throw MangaImportException('Missing manga page image: $rel');
        }
        final List<String> destSegs = <String>[
          ...pageRoot,
          ...segs.sublist(0, segs.length - 1),
        ];
        final Directory destDir = Directory(
          p.joinAll(<String>[tmp.path, ...destSegs]),
        );
        destDir.createSync(recursive: true);
        await fs.copyToLocal(remotePath, destDir.path);
      }
      final String localMokuro = p.join(tmp.path, mokuroName);
      await File(localMokuro).writeAsString(jsonStr, flush: true);
      final String bookKey = await MangaImporter.importFromMokuroPath(
        db: _db,
        mokuroPath: localMokuro,
        title: title,
        sourceId: id.sourceId,
        policy: policy,
      );
      await id.record(item.mokuroPath, bookKey);
      return true;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 远端一卷 mokuro 0.1 旧版产物（`<父>/<卷名>.html` + `<父>/<卷名>/` 页图 +
  /// `<父>/_ocr/<卷名>/` 逐页 JSON）：标题只由路径派生（与本地同一个
  /// [legacyMokuroRoot]），先过判据，放行才把页图与逐页 JSON 按原布局镜像进临时
  /// 目录，再交本地导入器——`.html` 本身不下载（导入器不读它的内容，只认布局）。
  Future<bool> _importRemoteLegacyMokuroVolume({
    required ScanMangaItem item,
    required _MangaSourceIdentity id,
    required SourceFileSystem fs,
  }) async {
    final String htmlName = sourceEntryBasename(item.mokuroPath);
    final String parentDir = _remoteParentDir(item.mokuroPath);
    final String volumeName = p.basenameWithoutExtension(htmlName);
    final String title = MangaImporter.deriveMokuroTitle(
      legacyMokuroRoot(item.mokuroPath, context: p.url),
      htmlName,
    );
    final DuplicatePolicy? policy = await id.policyFor(item.mokuroPath, title);
    if (policy == null) return false;
    final String prefix = parentDir.isEmpty ? '' : '$parentDir/';
    final Directory tmp = Directory.systemTemp.createTempSync(
      'm1c_scan_manga_legacy_',
    );
    try {
      // 标题已按远端路径定好并显式传给导入器，镜像根叫什么不影响身份。
      final Directory root = Directory(p.join(tmp.path, 'volume'))
        ..createSync();
      await _mirrorRemoteMangaPages(
        fs,
        '$prefix$volumeName',
        Directory(p.join(root.path, volumeName)),
      );
      await _mirrorRemoteMangaPages(
        fs,
        '$prefix$kMokuroLegacyOcrDirName/$volumeName',
        Directory(p.join(root.path, kMokuroLegacyOcrDirName, volumeName)),
        extensions: const <String>{'.json'},
      );
      final String localHtml = p.join(root.path, htmlName);
      File(localHtml).writeAsStringSync('');
      final String bookKey = await MangaImporter.importFromMokuroPath(
        db: _db,
        mokuroPath: localHtml,
        title: title,
        sourceId: id.sourceId,
        policy: policy,
      );
      await id.record(item.mokuroPath, bookKey);
      return true;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 远端一个单文件漫画卷：先过判据（含负向表：判过不是漫画、远端指纹没变的包不再
  /// 下载），放行才把包（连同包旁的 `.mokuro` sidecar）下载到临时目录，再走与本地
  /// 同一个 [_importMangaCarrierFile]。
  ///
  /// sidecar 必须一起下：压缩包导入器按「包旁同名文件」找 OCR 文字层，只下包的话
  /// 远端来源导进来的卷永远没有文字。下载保留原文件名，所以包与 sidecar 在临时
  /// 目录里的相对关系与远端一致。返回 false = 已在库 / 按重复跳过 / 内容不是漫画。
  Future<bool> _importRemoteMangaCarrier({
    required ScanMangaArchiveItem item,
    required _MangaSourceIdentity id,
    required SourceFileSystem fs,
  }) async {
    final String path = item.archivePath;
    if (id.isIndexed(path) || id.isRejected(path)) return false;
    final String title = p.basenameWithoutExtension(sourceEntryBasename(path));
    final DuplicatePolicy? policy = await id.policyFor(path, title);
    if (policy == null) return false;
    final Directory tmp = Directory.systemTemp.createTempSync(
      'm1c_scan_manga_archive_',
    );
    try {
      final String localArchive = await fs.copyToLocal(path, tmp.path);
      final String? sidecar = item.mokuroSidecarPath;
      if (sidecar != null) {
        await fs.copyToLocal(sidecar, tmp.path);
      }
      final String? bookKey = await _importMangaCarrierFile(
        localPath: localArchive,
        title: title,
        sourceId: id.sourceId,
        policy: policy,
      );
      if (bookKey == null) {
        // 指纹取远端列目录给的元数据：下次列出来没变就不再下载这个包。
        id.reject(path);
        return false;
      }
      await id.record(path, bookKey);
      return true;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 远端一卷纯页图目录：标题与本地同口径（卷目录名，解码态末段），先过判据再
  /// 下载，重扫零页图流量。返回 false = 已在库 / 按重复跳过，未下载。
  Future<bool> _importRemoteMangaFolder({
    required ScanMangaFolderItem item,
    required _MangaSourceIdentity id,
    required SourceFileSystem fs,
  }) async {
    if (id.isIndexed(item.folderPath)) return false;
    final String title =
        item.series?.title ?? sourceEntryBasename(item.folderPath);
    final DuplicatePolicy? policy = await id.policyFor(item.folderPath, title);
    if (policy == null) return false;
    final Directory tmp = Directory.systemTemp.createTempSync(
      'm1c_scan_manga_folder_',
    );
    try {
      final Directory volumeDir = Directory(p.join(tmp.path, 'volume'))
        ..createSync();
      await _mirrorRemoteMangaPages(fs, item.folderPath, volumeDir);
      // 页序 / 宽高 / 缺页判据全部交给本地导入器对镜像目录再枚举一次
      // （enumerateMangaPages），与本地散图卷同一口径，不另写一套。
      final String bookKey = await MangaImporter.importFromImageFolder(
        db: _db,
        imageDirPath: volumeDir.path,
        title: title,
        sourceId: id.sourceId,
        policy: policy,
      );
      await id.record(item.folderPath, bookKey);
      return true;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 把远端纯页图卷目录 [remoteDir] 下的页图按相对路径镜像进 [destRoot]。
  ///
  /// 只下页图扩展名（[kMangaImageExtensions]，与归卷判据、导入器枚举同源），跳过
  /// OCR 产物目录（[kMangaOcrOutDirName]，本地枚举同样排除）——其余文件下了也会被
  /// 导入器忽略，只是白白耗流量。`.` / `..` 段直接拒绝：镜像在书目录 sanitize
  /// 之前落盘，不能靠后面那道防穿越。
  ///
  /// [extensions] 缺省是页图；mokuro 旧版产物的逐页 OCR 目录传 `{'.json'}`。
  static Future<void> _mirrorRemoteMangaPages(
    SourceFileSystem fs,
    String remoteDir,
    Directory destRoot, {
    Set<String> extensions = kMangaImageExtensions,
  }) async {
    final String prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    for (final SourceFileEntry e in await fs.listFiles(
      remoteDir,
      recursive: true,
    )) {
      if (e.isDirectory || !e.path.startsWith(prefix)) continue;
      if (!extensions.contains(p.extension(e.name).toLowerCase())) {
        continue;
      }
      final List<String> segs = e.path
          .substring(prefix.length)
          .split('/')
          .where((String s) => s.isNotEmpty)
          .toList();
      if (segs.isEmpty) continue;
      if (segs.contains('..') || segs.contains('.')) {
        throw MangaImportException('Invalid manga page path: ${e.path}');
      }
      if (segs.sublist(0, segs.length - 1).contains(kMangaOcrOutDirName)) {
        continue;
      }
      final Directory destDir = Directory(
        p.joinAll(<String>[destRoot.path, ...segs.sublist(0, segs.length - 1)]),
      );
      destDir.createSync(recursive: true);
      await fs.copyToLocal(e.path, destDir.path);
    }
  }

  /// 远端路径的父目录（正斜杠语义；SFTP/FTP 路径与 WebDAV href URL 通用）。
  static String _remoteParentDir(String path) {
    final int slash = path.lastIndexOf('/');
    return slash <= 0 ? '' : path.substring(0, slash);
  }

  /// Imports every video in the plan (with sidecar subtitle cues); returns the
  /// physical paths newly inserted plus the per-file failures.
  ///
  /// [fs] is the source file system the scan listed from. Subtitles are read via
  /// [SourceFileSystem.copyToLocal] (local = original path unchanged; network =
  /// downloaded to a temp dir) then decoded with [readTextWithEncoding] so the
  /// SJIS/CP932/EUC-JP charset detection used by the manual import path is
  /// preserved (TODO-817 M1b TODO②).
  ///
  /// **封面不在这里抽（BUG-2569）。** 导入的契约是「把条目放进库」；封面是书架的
  /// best-effort 增强，仓库里早有专门的增量产线做它——`HomeVideoPage`
  /// `_maybeBackfillCovers` 扫「缺封面的本地可抽帧行」逐个补，带节流刷新、
  /// 会话级失败账本（`CoverBackfillLedger`）与 `diagnosticOnly` 降级，并且由
  /// `watchVideoBookUids` 流在**新行落库时**自动触发，所以本方法留空封面不会让
  /// 任何条目漏掉。
  ///
  /// 此前这里内联调 `extractVideoCover`，每个文件最坏两段 30s ffmpeg（内嵌封面 +
  /// 抽帧）、全部串行、全部裹在进程级 [VideoCoverMutationGate] 里、全部在 UI
  /// isolate：50 个文件的文件夹理论上限 50 分钟，用户只看得到一个 spinner。移动端
  /// 更糟——那里的后端是**进程内** ffmpeg-kit，抽帧直接和 UI 抢 CPU，还会把
  /// `VideoSpecsService` 的 ffprobe（并发 2、20s 超时）全部挤到超时，于是整库文件被
  /// 当成「探不出规格」永久记进负缓存，技术规格角标再也不出现。
  Future<
    ({List<String> createdPaths, List<String> failedPaths, Object? firstError})
  >
  _importVideos(ScanPlan plan, int sourceId, SourceFileSystem fs) async {
    if (plan.videos.isEmpty) {
      return (
        createdPaths: const <String>[],
        failedPaths: const <String>[],
        firstError: null,
      );
    }
    // 网络（SFTP/WebDAV/AList 能走到这里，[scan] 入口已拒 FTP）：条目路径就是
    // 可流播地址（http(s) URL，或 SFTP 的 `sftp://` 稳定地址），按流媒体书**原地**
    // 入库——videoPath=地址、sidecar 字幕地址进
    // streamSpecJson，播放走既有 stream 通道（isStreamVideoBook 判据 =
    // videoPath 是 http）。不下载视频、不抽封面、不解析 cue（字幕由播放页按
    // spec.subtitleUrl 现下载，认证头打开时按 sourceId 现解析）。
    final bool streamInPlace = !fs.isLocal;
    final List<VideoBookRow> existingRows = await _videoRepo.listAll();
    // Existing book_uid set for silent same-name dedup (matches import dialog).
    final Set<String> existingKeys = existingRows
        .map((VideoBookRow r) => r.bookUid)
        .toSet();
    // TODO-1237 ②: existing physical paths (normalized) for re-scan dedup — a
    // folder re-scan must SKIP files already imported instead of suffixing
    // `X (2)` duplicates (mirrors _importBooks' skip policy, BUG-443). Grown as
    // we insert so a same-batch duplicate path is skipped too.
    final Set<String> existingPaths = existingRows
        .map((VideoBookRow r) => normalizeVideoPath(r.videoPath))
        .toSet();
    // BUG-2979：文件被搬走（整个剧目录挪进另一个文件夹再加成来源）时，旧行的
    // bookUid 与新路径派生的 bookUid 相同、路径不同——不认出来就会以 `X (2)`
    // 再建一行，同一集在库里两行、合集详情页每集两张卡。
    final Map<String, VideoBookRow> rowByUid = <String, VideoBookRow>{
      for (final VideoBookRow r in existingRows) r.bookUid: r,
    };
    final Map<String, VideoBookRow> rowByPath = <String, VideoBookRow>{
      for (final VideoBookRow r in existingRows)
        normalizeVideoPath(r.videoPath): r,
    };
    List<MediaCollectionItemRow>? collectionItems;

    // Temp dir only used by non-local transports (copyToLocal downloads here);
    // for local transport copyToLocal returns the original path unchanged.
    Directory? subtitleTmp;

    try {
      final List<String> createdPaths = <String>[];
      final List<String> failedPaths = <String>[];
      Object? firstError;
      for (final ScanVideoItem item in plan.videos) {
        final String normalizedPath = normalizeVideoPath(item.videoPath);
        // BUG-2979：同名旧行的文件已经不在原处 = 这就是搬走的那个文件。
        final VideoBookRow? moved = streamInPlace
            ? null
            : rowByUid[singleVideoBookUid(item.videoPath)];
        if (moved != null && await isVideoRowMovedTo(moved, item.videoPath)) {
          final VideoBookRow? live = rowByPath[normalizedPath];
          if (live == null) {
            // 首次扫到搬家后的文件：原行改指新路径，进度 / 字幕 cue / 标签 /
            // 合集归属 / 统计全在原 bookUid 上，原样保住，不再另建 `X (2)`。
            await _videoRepo.updateLocalMediaPaths(
              moved.bookUid,
              videoPath: item.videoPath,
              subtitleSource:
                  item.subtitlePath != null &&
                      await _isDeadLocalPath(moved.subtitleSource)
                  ? item.subtitlePath
                  : null,
            );
            await _videoRepo.assignSourceIfNull(moved.bookUid, sourceId);
            existingPaths.add(normalizedPath);
            rowByPath[normalizedPath] = moved;
            continue;
          }
          if (live.bookUid != moved.bookUid) {
            // 修复前已经建出了 `X (2)`：把旧行并进在世的那一行再删旧行。
            collectionItems ??= await _db.getAllCollectionItems();
            await _mergeMovedVideoDuplicate(
              stale: moved,
              live: live,
              collectionItems: collectionItems,
            );
            rowByUid.remove(moved.bookUid);
          }
        }
        // Skip already-imported physical files (library or same-batch dup).
        if (!existingPaths.add(normalizedPath)) {
          continue;
        }
        // BUG-2570：一个文件的失败只作废这个文件。此前整个循环共用 [scan] 的总
        // catch，任何一处抛错（读不了的 sidecar 字幕、坏编码、单行落库约束冲突）
        // 都会把**本批其余全部视频**一起掀掉——已经成功解析的也不落库，用户拿到
        // 的是「一句裸异常 + 零条入库」。失败路径逐条记账，扫描结束后汇总成一条
        // 指名道姓的错误，成功的照常入库。
        try {
          final String bookUid = uniqueVideoBookUid(
            singleVideoBookUid(item.videoPath),
            existingKeys,
          );
          existingKeys.add(bookUid);

          String? subtitleSource;
          String? subtitleFormat;
          String? streamSpecJson;
          List<AudioCue> cues = const <AudioCue>[];
          if (streamInPlace) {
            final String? subUrl = item.subtitlePath;
            streamSpecJson = StreamVideoSpec(
              subtitleUrl: subUrl,
              subtitleFileName: subUrl == null
                  ? null
                  : sourceEntryBasename(subUrl),
            ).toStorageJson();
          } else if (item.subtitlePath != null) {
            final String fmt = _extOf(p.basename(item.subtitlePath!));
            subtitleTmp ??= Directory.systemTemp.createTempSync(
              'm1c_scan_subs_',
            );
            final String localSub = await fs.copyToLocal(
              item.subtitlePath!,
              subtitleTmp.path,
            );
            // readTextWithEncoding(File) keeps the non-UTF-8 charset detection;
            // local copyToLocal returns the original path so behaviour is
            // unchanged.
            final String content = await readTextWithEncoding(File(localSub));
            cues = parseSubtitleCues(
              content: content,
              format: fmt,
              bookUid: bookUid,
            );
            subtitleSource = item.subtitlePath;
            subtitleFormat = fmt;
          }

          // 标题用解码后的文件名：WebDAV 条目路径是百分号编码的 href，直接取
          // basename 会把 %20 之类渗进书架标题。
          final String title = streamInPlace
              ? p.basenameWithoutExtension(sourceEntryBasename(item.videoPath))
              : p.basenameWithoutExtension(item.videoPath);
          // 封面一律留空入库，抽帧交给书架的补齐产线（见本方法文档 BUG-2569）。
          await _videoRepo.saveVideoBook(
            VideoBooksCompanion(
              bookUid: Value(bookUid),
              title: Value(title),
              videoPath: Value(item.videoPath),
              coverPath: const Value<String?>(null),
              subtitleSource: Value<String?>(subtitleSource),
              subtitleFormat: Value<String?>(subtitleFormat),
              streamSpecJson: Value<String?>(streamSpecJson),
              embeddedSubtitleTrack: subtitleSource == null
                  ? const Value<int?>(0)
                  : const Value<int?>(null),
              importedAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
            sourceId: sourceId,
          );
          if (cues.isNotEmpty) {
            await _videoRepo.saveCues(bookUid: bookUid, cues: cues);
          }
          createdPaths.add(item.videoPath);
        } catch (e, stack) {
          failedPaths.add(item.videoPath);
          firstError ??= e;
          debugPrint(
            'SourceLibraryScanner video import failed for '
            '${item.videoPath}: $e\n$stack',
          );
        }
      }
      return (
        createdPaths: createdPaths,
        failedPaths: failedPaths,
        firstError: firstError,
      );
    } finally {
      if (subtitleTmp != null) {
        try {
          subtitleTmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// BUG-2979：把「文件搬走后旧行没认出、又以 `X (2)` 建出的新行」归并成一行。
  ///
  /// 留在世的 [live]（路径有效、挂着来源、刮削资料 / 规范分集绑定都在它身上），
  /// 把 [stale] 上的用户状态搬过去后删掉 [stale]：观看进度取较晚播放的一份、
  /// 看完取两者之一、标签与合集归属并入（[live] 已在的合集不重复加）。
  /// 学习统计按 bookUid 记账，留在旧键上不迁（统计只累加、不随行删除）。
  Future<void> _mergeMovedVideoDuplicate({
    required VideoBookRow stale,
    required VideoBookRow live,
    required List<MediaCollectionItemRow> collectionItems,
  }) async {
    final bool staleNewer =
        (stale.lastPlayedAt ?? 0) > (live.lastPlayedAt ?? 0);
    await (_db.update(
      _db.videoBooks,
    )..where((t) => t.bookUid.equals(live.bookUid))).write(
      VideoBooksCompanion(
        lastPositionMs: staleNewer
            ? Value<int>(stale.lastPositionMs)
            : const Value<int>.absent(),
        lastPlayedAt: staleNewer
            ? Value<int?>(stale.lastPlayedAt)
            : const Value<int?>.absent(),
        completedAt: live.completedAt == null && stale.completedAt != null
            ? Value<DateTime?>(stale.completedAt)
            : const Value<DateTime?>.absent(),
      ),
    );
    for (final BookTagRow tag in await _db.getTagsForVideoBook(stale.bookUid)) {
      await _db.addTagToVideoBook(live.bookUid, tag.id);
    }
    final String video = MediaKind.video.dbValue;
    final Set<int> liveCollections = <int>{
      for (final MediaCollectionItemRow item in collectionItems)
        if (item.mediaType == video && item.entryKey == live.bookUid)
          item.collectionId,
    };
    for (final MediaCollectionItemRow item in collectionItems) {
      if (item.mediaType != video || item.entryKey != stale.bookUid) continue;
      if (liveCollections.add(item.collectionId)) {
        await _db.addToCollection(
          item.collectionId,
          MediaKind.video,
          live.bookUid,
          userIntent: false,
        );
      }
    }
    await _videoRepo.deleteVideoBooks(<String>[stale.bookUid]);
  }

  /// Imports every m3u8/m3u playlist in the plan into a playlist VideoBook;
  /// returns the count successfully inserted (TODO-1237).
  ///
  /// Mirrors the dialog's manual / drag-drop playlist import but headless:
  /// [parseM3u8] parses the manifest (episode paths resolved via
  /// [resolveM3uEntryPath]: relative -> the m3u8's own dir, absolute /
  /// backslash / UNC handled), then splits it into N independent per-episode
  /// VideoBook rows + one `'playlist'` [MediaCollections] (统一合集 Phase 2, via
  /// [VideoBookRepository.importSplitPlaylist], byte-aligned with the v38
  /// migration).
  ///
  /// Re-scan dedup: there is no single playlist row to key on any more, so the
  /// manifest is deduped on whether its FIRST episode's path is already imported
  /// ([VideoBookRepository.isDuplicateVideoPath], same key the dialog folder
  /// import uses) — a re-scan of an already-imported folder skips it. Unlike the
  /// old first-episode key this now runs after parse (parsing a small manifest
  /// on re-scan is cheap); correctness of idempotency wins over the micro-cost.
  ///
  /// [fs] is the source file system: the manifest is read via
  /// [SourceFileSystem.copyToLocal] (local = original path unchanged; network =
  /// downloaded to a temp dir) then decoded with [readTextWithEncoding], reusing
  /// the same charset detection as [_importVideos]. Cover extraction needs a
  /// local path so it only runs for local transport (like [_importVideos]) and
  /// is applied to the first episode; ffmpeg-missing / any failure degrades to a
  /// null cover (shelf placeholder) and never aborts the scan. An empty /
  /// unparsable manifest inserts nothing (skipped, not counted, not an error).
  /// Returns the number of playlists (collections) newly imported.
  Future<int> _importPlaylists(
    ScanPlan plan,
    int sourceId,
    SourceFileSystem fs, {
    required bool restoreDissolvedGroups,
  }) async {
    if (plan.playlists.isEmpty) return 0;

    // 统一合集：拆集后无单条 playlist 行 → 用「同名 playlist 合集是否已存在」区分
    // 首次导入 vs 重扫。合集名 = m3u8 basename（**不随 manifest 内集路径编辑而变** →
    // 编辑集路径重扫仍幂等，不产生 X (2) 重复，TODO-1237 ②）。首导（不存在）走
    // importSplitPlaylist；已存在走 reconcileSplitPlaylist 把成员对齐到当前清单
    // （BUG-830：磁盘上编辑 m3u8 增删某集后合集成员永不更新）。故必须逐个解析清单
    // （不再「同名即整体跳过」），per-playlist 多读一个小文本清单的开销可接受。
    final Map<String, int> existingPlaylistIds = <String, int>{
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        if (c.collectionType == 'playlist') c.name: c.id,
    };

    // Temp dir only used by non-local transports (copyToLocal downloads here);
    // for local transport copyToLocal returns the original path unchanged.
    Directory? playlistTmp;
    final List<ScanVideoItem> hlsStreams = <ScanVideoItem>[];
    try {
      int count = 0;
      for (final ScanPlaylistItem item in plan.playlists) {
        // 合集名走解码 basename：网络清单的 href 是百分号编码的。
        final String collectionName = p.basenameWithoutExtension(
          sourceEntryBasename(item.playlistPath),
        );

        playlistTmp ??= Directory.systemTemp.createTempSync('m1c_scan_pls_');
        final String localM3u8 = await fs.copyToLocal(
          item.playlistPath,
          playlistTmp.path,
        );
        final String content = await readTextWithEncoding(File(localM3u8));
        // baseDir is the ORIGINAL m3u8 path's directory (source namespace):
        // locally the real on-disk dir, matching manual / drag-drop import when
        // resolving relative episode paths; remotely the manifest's URL dir
        // (resolveM3uEntryPath 对 URL 基底按 URL 语义 join，条目解析成可播的
        // 远端流 URL，逐集入库后与直扫视频同一条 stream 播放链)。
        final String baseDir = fs.isLocal
            ? p.dirname(item.playlistPath)
            : _remoteParentDir(item.playlistPath);
        // HLS 媒体 / master 播放列表是**一条流**，不是分集清单：按行拆会把 `.ts`
        // 分片（或码率档）当成一集一集入库。整份清单按单个视频入库，交给播放内核。
        if (isHlsStreamPlaylist(content)) {
          hlsStreams.add(ScanVideoItem(videoPath: item.playlistPath));
          continue;
        }
        final List<PlaylistEntry> entries = parseM3u8(
          content: content,
          baseDir: baseDir,
        );
        // 空 / 不可解析清单：跳过（不当成「清单变空 → 清光成员」，避免读盘瞬时失败
        // 误删已存在合集，保守降级）。
        if (entries.isEmpty) continue;

        final int? existingId = existingPlaylistIds[collectionName];
        if (existingId != null) {
          // 已存在同名 playlist 合集：以当前清单为准对齐成员（增删差异），不重导、
          // 不计入「新增合集数」；封面首导时已抽，无需重抽。
          await _videoRepo.reconcileSplitPlaylist(
            collectionId: existingId,
            entries: entries,
            sourceId: sourceId,
          );
          continue;
        }

        // BUG-1739：用户删过同名 playlist 合集 → 重扫不复活（importSplitPlaylist
        // 的 createMediaCollection 会清墓碑，把删除静默撤销）。清单文件还在扫描
        // 根里不代表用户想要回这个合集；显式重导（导入对话框）不走本路径。
        if (!restoreDissolvedGroups &&
            await _db.hasCollectionDeletionTombstone(
              collectionName,
              'playlist',
            )) {
          continue;
        }

        final SplitPlaylistImportResult result = await _videoRepo
            .importSplitPlaylist(
              collectionName: collectionName,
              entries: entries,
              sourceId: sourceId,
              reuseExistingPaths: true,
            );
        // 记入 map：同一次扫描里遇到第二个同名清单时走 reconcile，不再重导致重复。
        existingPlaylistIds[collectionName] = result.collectionId;

        // BUG-1351：扫描首导的新 playlist 合集也是用户入库（用户把新清单放进扫描根
        // 再扫描——对常用 m3u8 清单库的用户这就是主导入路径），整本记 1 条 added
        // 活动事件（title=合集名、mediaKey=首集 uid，与对话框 / 拖拽导入同粒度）。
        // 重扫走上面的 reconcile 分支天然不 emit；散装单视频扫描仍保持静默（首扫可
        // 达数百文件，逐条 emit 才是刷屏）。best-effort：方法内自捕获异常，只 log
        // 不影响导入。
        await _videoRepo.recordVideoImportActivity(
          bookUid: result.episodeUids.first,
          title: collectionName,
        );

        // BUG-2569：清单封面同样不在扫描里抽。`extractPlaylistCover` 会**逐集重试**
        // 直到抽出一帧，每集最坏 30s，一个坏清单就能把整次扫描拖到分钟级；拆出来的
        // 各集都是带真实路径的本地行，书架的封面补齐产线会逐个补上（那条产线本来
        // 就是为「拆集导入只有首集有封面」写的，见 `_maybeBackfillCovers` 文档）。
        count++;
      }
      if (hlsStreams.isNotEmpty) {
        // 与散装视频同一条入库路径（重扫按路径去重、网络来源原地流播）。
        final ({
          List<String> createdPaths,
          List<String> failedPaths,
          Object? firstError,
        })
        imported = await _importVideos(
          ScanPlan(videos: hlsStreams),
          sourceId,
          fs,
        );
        count += imported.createdPaths.length;
      }
      return count;
    } finally {
      if (playlistTmp != null) {
        try {
          playlistTmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 把扫描根里认出的蓝光盘导入成合集。
  ///
  /// 形状与 m3u8 清单完全同构（一张盘 = 一个 `playlist` 合集，一条标题 = 一行
  /// `VideoBooks`），所以幂等性、墓碑守卫、重扫对齐直接复用 [_importPlaylists] 那套：
  /// 合集名取盘名，重扫时按合集名找到既有合集并把成员对齐到当前标题表。
  ///
  /// 每条标题的 `videoPath` 是它自己的 `.mpls` 绝对路径——一个真实存在的文件，于是
  /// 「文件还在不在」「这路径被谁引用着」这些既有判据原样可用，不需要为 BD 另开一套。
  Future<int> _importBlurayDiscs(
    ScanPlan plan,
    int sourceId, {
    required bool restoreDissolvedGroups,
  }) async {
    if (plan.blurayDiscs.isEmpty) return 0;

    final List<MediaCollectionRow> collections = await _db
        .getAllMediaCollections();
    final Map<String, int> existingCollectionIds = <String, int>{
      for (final MediaCollectionRow c in collections)
        if (c.collectionType == 'playlist') c.name: c.id,
    };
    final Map<int, String?> collectionCovers = <int, String?>{
      for (final MediaCollectionRow c in collections) c.id: c.coverPath,
    };

    // 用户单独删掉的特典：挂在盘合集自然键下的成员墓碑（见
    // [planBlurayExtraDeletionTombstones]）。整轮一次查询。
    final Map<String, Set<String>> deletedExtras =
        await deletedBlurayExtraKeysByCollection(_db);

    int count = 0;
    for (final ScanBlurayDiscItem item in plan.blurayDiscs) {
      final BlurayDisc? disc = await readBlurayDisc(item.discRootPath);
      // 半张盘 / 一条标题都选不出来：跳过而不是记错。盘里的文件已经在规划层被摘出
      // 散装视频，这里再报错只会把整次扫描标红。
      if (disc == null) continue;

      final List<PlaylistEntry> entries = <PlaylistEntry>[
        for (final BlurayTitle title in disc.titles)
          PlaylistEntry(title: title.name, path: title.playlistPath),
      ];

      // 合集名不能只按盘名全局对号：`S1/DISC1` 与 `S2/DISC1` 同名不同盘，对到一起
      // 会互相吞成员（见 [blurayCollectionNameCandidates]）。撞上别的盘 / 别的
      // 清单的合集就换下一个候选名，直到找到本盘的或一个空位。
      String collectionName = disc.name;
      int? existingId;
      for (final String candidate in blurayCollectionNameCandidates(
        disc.name,
        disc.rootPath,
      )) {
        collectionName = candidate;
        existingId = existingCollectionIds[candidate];
        if (existingId == null) break;
        if (await _collectionBelongsToDisc(existingId, disc.rootPath)) break;
        existingId = null;
      }
      int? collectionId = existingId;
      if (existingId != null) {
        await _videoRepo.reconcileSplitPlaylist(
          collectionId: existingId,
          entries: entries,
          sourceId: sourceId,
        );
      } else {
        // BUG-1739 同款守卫：用户删过同名合集，重扫不复活——整张盘都不复活，
        // 特典也不例外（它们挂在这张盘的正片下，盘都删了特典没有归处）。
        if (!restoreDissolvedGroups &&
            await _db.hasCollectionDeletionTombstone(
              collectionName,
              'playlist',
            )) {
          continue;
        }

        final SplitPlaylistImportResult result = await _videoRepo
            .importSplitPlaylist(
              collectionName: collectionName,
              entries: entries,
              sourceId: sourceId,
              reuseExistingPaths: true,
            );
        existingCollectionIds[collectionName] = result.collectionId;
        collectionId = result.collectionId;
        await _videoRepo.recordVideoImportActivity(
          bookUid: result.episodeUids.first,
          title: collectionName,
        );
        count++;
      }
      await _applyBlurayDiscArtwork(
        collectionId,
        disc.rootPath,
        currentCover: collectionCovers[collectionId],
      );

      // 特典（菜单里的「特典映像」等）入库、带来源，但不进盘合集：索引器随后把它们
      // 挂到正片作品下，作品资料页的特典区就能看到、点开就播。排在合集墓碑守卫
      // 之后，且跳过用户单独删掉的那几条（PR #2058 审查：原先排在守卫之前，删掉
      // 整盘合集后重扫特典照样复活）。盘已读好，整盘一次入库。
      final Set<String> deleted =
          deletedExtras[collectionName] ?? const <String>{};
      final List<String> extras = <String>[
        for (final BlurayTitle extra in disc.extras)
          if (!deleted.contains(blurayExtraTombstoneKey(extra.playlistPath)))
            extra.playlistPath,
      ];
      if (extras.isNotEmpty) {
        await ensureBlurayDiscTitlesInLibrary(
          _db,
          discRoot: disc.rootPath,
          playlistPaths: extras,
          disc: disc,
          sourceId: sourceId,
        );
      }
    }
    return count;
  }

  /// 盘合集用盘内自带的盘面图（`BDMV/META/DL`，见 [readBlurayDiscArtwork]）：
  /// 同一部作品的几张盘刮削出来是同一张海报，盘面图才分得开。新建与重扫的老合集
  /// 都走这里，老库重扫一次就补上。
  ///
  /// 按图本身解码出的朝向分流（阈值与卡片判横竖同一个
  /// [PortraitCoverImage.portraitAspectThreshold]）：
  /// * 竖图 → 合集主封面（竖卡墙）。合集已有自有封面（用户手选 / 先前写过）且
  ///   文件还在就不动。
  /// * 横图 → 附加图组的 [MediaImageKind.discArt]，只给横向槽位用；竖卡墙仍是
  ///   刮削海报，不把横图垫进竖卡。已有且文件还在就不动。
  ///
  /// 选哪份语言的元数据跟界面语言（[blurayLanguageCodes]），没有就按盘上的顺序。
  /// 写入走 [MediaCoverService]（刮削清理期租约 + 封面写互斥）；拿不到租约、图
  /// 解不开都只跳过，不让整次扫描失败。
  Future<void> _applyBlurayDiscArtwork(
    int? collectionId,
    String discRootPath, {
    required String? currentCover,
  }) async {
    if (collectionId == null) return;
    final List<BlurayDiscArtwork> artwork = await readBlurayDiscArtwork(
      discRootPath,
      preferredLanguages: blurayLanguageCodes(
        LocaleSettings.currentLocale.languageCode,
      ),
    );
    if (artwork.isEmpty) return;
    BlurayDiscArtwork? largest(bool portrait) {
      BlurayDiscArtwork? best;
      for (final BlurayDiscArtwork a in artwork) {
        if ((a.aspect <= PortraitCoverImage.portraitAspectThreshold) !=
            portrait) {
          continue;
        }
        if (best == null || a.area > best.area) best = a;
      }
      return best;
    }

    final BlurayDiscArtwork? portrait = largest(true);
    final BlurayDiscArtwork? landscape = largest(false);
    try {
      if (portrait != null && !await _existingFile(currentCover)) {
        await MediaCoverService.applyCollectionCover(
          database: _db,
          collectionId: collectionId,
          pickedPath: portrait.path,
        );
      }
      if (landscape != null) {
        final String? currentArt =
            (await _db.getMediaImagesForCollection(collectionId))
                .where(
                  (MediaImageRow r) => r.kind == MediaImageKind.discArt.dbValue,
                )
                .map((MediaImageRow r) => r.path)
                .firstOrNull;
        if (!await _existingFile(currentArt)) {
          await MediaCoverService.applyCollectionDiscArt(
            database: _db,
            collectionId: collectionId,
            sourcePath: landscape.path,
          );
        }
      }
    } on StateError catch (e) {
      debugPrint('[SourceLibraryScanner] disc artwork skipped: $e');
    } on CoverImageInvalidException catch (e) {
      // 盘上的图是不可信输入：解不开就当没有，合集照旧回落到刮削图。
      debugPrint('[SourceLibraryScanner] disc artwork skipped: $e');
    } on FileSystemException catch (e) {
      debugPrint('[SourceLibraryScanner] disc artwork skipped: $e');
    }
  }

  static Future<bool> _existingFile(String? path) async =>
      path != null && path.isNotEmpty && await File(path).exists();

  /// 把扫描根里认出的 DVD 导入成合集：一张盘一个 `playlist` 合集，一个入选 title 一行
  /// `VideoBooks`，与 [_importBlurayDiscs] 同构（合集名候选、重扫对齐、墓碑守卫
  /// 全部复用）。成员路径是虚拟的 `VIDEO_TS/TITLE_nn.dvdtitle`（见 `dvd_disc.dart`）。
  ///
  /// 多张盘先全部读完，再按 [compareDvdDiscOrder]（同一上级目录内按卷号，再按目录名）
  /// 排序后入库，入库时刻顺序就是盘序。IFO 损坏的盘记进返回的 `failed`，不中断其它盘。
  ///
  /// `.iso` 镜像经 `readDvdDiscImage` 读出同样的 IFO 字节、走同一条选片链；成员路径是
  /// `<iso>/VIDEO_TS/TITLE_nn.dvdtitle`。镜像里是 BD 的暂不入库：蓝光的播放 / 规格 /
  /// 封面 / 制卡链路全部建立在真实的 `STREAM/*.m2ts` 文件上（EDL 拼接），镜像里没有
  /// 可给出的本地文件，要等原生 libbluray 直接吃镜像那一路接上。
  ///
  /// 特典（[DvdDisc.extras]）与蓝光同一规则：入库、带来源、不进盘合集，跳过用户
  /// 单独删掉的（盘合集自然键下的成员墓碑）；整盘合集被删时连特典一起不复活。
  Future<({int imported, List<String> failed})> _importDvdDiscs(
    ScanPlan plan,
    int sourceId, {
    required bool restoreDissolvedGroups,
  }) async {
    if (plan.dvdDiscs.isEmpty) {
      return (imported: 0, failed: const <String>[]);
    }
    final List<DvdDisc> discs = <DvdDisc>[];
    final List<String> failed = <String>[];
    for (final ScanDvdDiscItem item in plan.dvdDiscs) {
      try {
        final DvdDisc? disc = await readDvdDisc(item.discRootPath);
        if (disc != null) discs.add(disc);
      } on DvdIfoFormatException catch (e) {
        failed.add('${p.basename(item.discRootPath)} — ${e.message}');
      }
    }
    discs.sort(compareDvdDiscOrder);

    final Map<String, Set<String>> deletedExtras =
        await deletedBlurayExtraKeysByCollection(_db);
    final Map<String, int> existingCollectionIds = <String, int>{
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        if (c.collectionType == 'playlist') c.name: c.id,
    };
    int count = 0;
    for (final DvdDisc disc in discs) {
      final List<PlaylistEntry> entries = <PlaylistEntry>[
        for (final DvdTitle title in disc.titles)
          PlaylistEntry(title: title.name, path: title.titlePath),
      ];
      // 合集名同蓝光：撞上别的盘 / 别的清单的同名合集就换下一个候选名。
      String collectionName = disc.name;
      int? existingId;
      for (final String candidate in blurayCollectionNameCandidates(
        disc.name,
        disc.rootPath,
      )) {
        collectionName = candidate;
        existingId = existingCollectionIds[candidate];
        if (existingId == null) break;
        if (await _collectionBelongsToDisc(existingId, disc.rootPath)) break;
        existingId = null;
      }
      if (existingId != null) {
        await _videoRepo.reconcileSplitPlaylist(
          collectionId: existingId,
          entries: entries,
          sourceId: sourceId,
        );
      } else {
        // BUG-1739 同款守卫：用户删过同名合集，重扫不复活（特典也不复活）。
        if (!restoreDissolvedGroups &&
            await _db.hasCollectionDeletionTombstone(
              collectionName,
              'playlist',
            )) {
          continue;
        }
        final SplitPlaylistImportResult result = await _videoRepo
            .importSplitPlaylist(
              collectionName: collectionName,
              entries: entries,
              sourceId: sourceId,
              reuseExistingPaths: true,
            );
        existingCollectionIds[collectionName] = result.collectionId;
        await _videoRepo.recordVideoImportActivity(
          bookUid: result.episodeUids.first,
          title: collectionName,
        );
        count++;
      }

      final Set<String> deleted =
          deletedExtras[collectionName] ?? const <String>{};
      final List<String> extras = <String>[
        for (final DvdTitle extra in disc.extras)
          if (!deleted.contains(blurayExtraTombstoneKey(extra.titlePath)))
            extra.titlePath,
      ];
      if (extras.isNotEmpty) {
        await ensureDvdDiscExtrasInLibrary(
          _db,
          disc: disc,
          titlePaths: extras,
          sourceId: sourceId,
        );
      }
    }
    return (imported: count, failed: List<String>.unmodifiable(failed));
  }

  /// 既有合集 [collectionId] 是不是 [discRootPath] 这张盘的：成员全是本盘的原盘标题
  /// （蓝光 `BDMV/PLAYLIST/*.mpls` / DVD `VIDEO_TS/TITLE_nn.dvdtitle`，或还没有任何
  /// 视频成员）才算；有任何一条来自别的盘、或根本不是原盘标题（同名 m3u8 清单合集），
  /// 都不算。
  Future<bool> _collectionBelongsToDisc(
    int collectionId,
    String discRootPath,
  ) async {
    final String root = p.normalize(discRootPath);
    for (final MediaCollectionItemRow item
        in await _videoRepo.getCollectionItems(collectionId)) {
      final VideoBookRow? row = await _videoRepo.getByBookUid(item.entryKey);
      if (row == null) continue;
      final String? owner = discRootForMemberPath(row.videoPath);
      if (owner == null || p.normalize(owner) != root) return false;
    }
    return true;
  }
}

/// BUG-2979：[row] 是不是「被搬到 [newPath] 的那个文件」的旧行。
///
/// 判据全部成立才算：同文件名（bookUid 同源派生，调用方已按它取出 [row]）、
/// 路径不同、旧行是普通本地文件（不是流媒体 / 播放列表 / URL）、旧文件已不存在，
/// 而且**旧路径所在的盘还在线**——网络盘 / 移动硬盘没挂上时旧文件当然「不存在」，
/// 那不是搬家，绝不能把仍然有效的旧行并掉。
///
/// 文件判据 async：扫描跑在 UI isolate，源库常是网络盘（rclone / SMB），同步 stat
/// 冷目录要数秒、冻结界面与同 isolate 的互联 host（BUG-3756）。
Future<bool> isVideoRowMovedTo(VideoBookRow row, String newPath) async {
  final String oldPath = row.videoPath;
  if (row.playlistJson != null || row.streamSpecJson != null) return false;
  if (oldPath.contains('://')) return false;
  if (normalizeVideoPath(oldPath) == normalizeVideoPath(newPath)) return false;
  if (_crossPlatformBasename(oldPath).toLowerCase() !=
      _crossPlatformBasename(newPath).toLowerCase()) {
    return false;
  }
  if (!p.isAbsolute(oldPath)) return false;
  final String root = p.rootPrefix(oldPath);
  if (root.isEmpty || !await Directory(root).exists()) return false;
  // 原盘成员按它背后的真实文件判（DVD title 是虚拟路径，裸 File 恒「不存在」）；
  // async：库根常在网络盘上（BUG-3756）。
  return !await videoMemberExists(oldPath);
}

String _crossPlatformBasename(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// 本地路径已失效（null / URL / 哨兵值都不算失效，不去动它）。
Future<bool> _isDeadLocalPath(String? path) async {
  if (path == null || path.isEmpty || path.contains('://')) return false;
  if (!p.isAbsolute(path)) return false;
  return !await File(path).exists();
}
