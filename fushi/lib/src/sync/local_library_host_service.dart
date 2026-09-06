import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/models/dictionary_directory.dart';
import 'package:fushi/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show parseSubtitleCues;
import 'package:fushi/src/media/video/video_sidecar.dart'
    show findSidecarSubtitle, isSidecarSubtitleSuffix, pickSidecar;
import 'package:fushi_audio/fushi_audio.dart'
    show AudioCue, readTextWithEncoding;
import 'package:fushi/src/media/media_source.dart'
    show MediaSource, dbSourcePrefKey;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi/src/media/video/series_playback_prefs.dart'
    show
        effectiveSeriesAudioTrackId,
        effectiveSeriesDelayMs,
        effectiveSeriesSecondaryDelayMs;
import 'package:fushi/src/sync/manga_sync_package.dart'
    show kMangaPackageMarker, repackageMangaBook;
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/override_title_lookup.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/collection_sync_engine.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/interconnect_profile_transfer.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_manager.dart'
    show repackageExtractedEpub, resolveExtractedEpubRoot;
import 'package:fushi/src/utils/misc/error_log_service.dart'
    show ErrorLogService;
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show extractAudioSegmentViaFfmpeg;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudiobookStorage;
import 'package:path/path.dart' as p;

part 'local_library_host_service/dictionaries.part.dart';
part 'local_library_host_service/books.part.dart';
part 'local_library_host_service/local_audio.part.dart';
part 'local_library_host_service/audiobooks.part.dart';
part 'local_library_host_service/videos.part.dart';
part 'local_library_host_service/sync_state.part.dart';

// ── 跨域共享的顶层 helper（原 LocalLibraryHostService 的 private static；mixin 体内看不到宿主类
//    的 static，故提到库顶层——对包外零可见性变化）。

/// 校验词典名称不含路径穿越字符。
///
/// 名称为空、或含 `/`、`\`、`..` 时抛 [ArgumentError]，
/// 确保服务层自身也防御路径穿越，不依赖上层端点网关的单点防护。
void _assertSafeName(String name) {
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..')) {
    throw ArgumentError.value(name, 'name', 'unsafe dictionary name');
  }
}

String? _existingFilePath(String? path) {
  if (path == null || path.isEmpty) return null;
  return File(path).existsSync() ? path : null;
}

/// [LocalLibraryHostService] 的抽象骨架：宣告全部 host 接口，并把具体类的注入字段以抽象私有
/// getter 暴露给各域 mixin（`mixin _X on _Base` 只能看到 `on` 类型声明的成员）。
/// 库私有，包外不可见；接口成员由各域 mixin 逐字实现（B4 按域拆分）。
abstract class _LocalLibraryHostBase
    implements
        FushiLibraryHostService,
        DeletionTombstoneHost,
        VideoDeletionHost,
        VideoPlaybackSyncHost,
        AudiobookDelayHost,
        InterconnectServiceConfigHost,
        InterconnectProfileHost {
  FushiDatabase get _db;
  Directory get _dictionaryResourceRoot;
  SyncAssetPackageService get _packages;
  Future<void> Function() get _refreshDictionaryCache;
  Future<void> Function(Future<void> Function() body) get _runExclusive;
  Future<bool> Function()? get _isProfileTransferEnabled;
  Future<String> Function()? get _exportActiveProfileJson;
  Future<String> Function(String json)? get _importProfileJson;
  Future<String?> Function(File epubFile)? get _importBookFromFile;
  Future<void> Function(EpubBookRow row)? get _cleanupBookOnDisk;
  List<LocalAudioDbEntry> get _localAudioEntries;
  Directory? get _localAudioStagingDir;
  Future<void> Function(LocalAudioPackageContents)? get _onLocalAudioImported;
  Directory? get _audioDatabaseRoot;
  Future<void> Function(String displayName)? get _removeLocalAudioEntry;
  String get _videoSubtitleLangCode;
  Directory? get _uploadedVideoRoot;
  Directory? get _videoCoversDirectory;
  Future<String?> Function(
      {required String videoPath,
      required String bookUid})? get _extractVideoCover;
}

/// 用真实 Hibiki 库（Drift DB + [SyncAssetPackageService]）实现 host 库服务。
///
/// 库变动经注入的 [runExclusive] 串行（生产传 `runExclusiveWithSync`），
/// 并经 [refreshDictionaryCache] 刷新内存词典缓存。
/// 抽象不直接依赖 AppModel，便于测试用内存 DB 注入。
///
/// ## 构造参数说明
///
/// | 参数 | 用途 | 生产传值 |
/// |---|---|---|
/// | [importBookFromFile] | 把 .epub 导入书库的真实逻辑 | `EpubImporter.importFromPath` |
/// | [cleanupBookOnDisk] | deleteBook 时清理 DB 行以外的磁盘资源（Audiobook persist dir 等） | `ReaderFushiSource.instance.deleteBook` 磁盘部分 |
/// | [localAudioEntries] | 当前已注册的本地音频来源列表（T3.1）| `AppModel.localAudioEntries` |
/// | [localAudioStagingDir] | importLocalAudio 解包用临时目录（T3.1）| `Directory.systemTemp` 或应用 temp |
/// | [onLocalAudioImported] | 注册已解包的本地音频包（T3.1）| `AppModel.importSyncedLocalAudioDb` |
/// | [audioDatabaseRoot] | importAudiobook 音频文件落盘根目录（T3.1）| AppModel 的 audiobook root |
/// | [videoSubtitleLangCode] | 视频 sidecar 字幕匹配语言代码（P4-1）| AppModel 目标学习语言 |
///
/// T2/T3 后续接线任务会在 AppModel 初始化时传入真实值。
class LocalLibraryHostService extends _LocalLibraryHostBase
    with
        _LocalLibraryHostShared,
        _LocalLibraryHostDictionaries,
        _LocalLibraryHostBooks,
        _LocalLibraryHostLocalAudio,
        _LocalLibraryHostAudiobooks,
        _LocalLibraryHostVideos,
        _LocalLibraryHostSyncState {
  LocalLibraryHostService({
    required FushiDatabase db,
    required Directory dictionaryResourceRoot,
    required SyncAssetPackageService packages,
    required Future<void> Function() refreshDictionaryCache,
    required Future<void> Function(Future<void> Function() body) runExclusive,
    Future<String?> Function(File epubFile)? importBookFromFile,
    Future<void> Function(EpubBookRow row)? cleanupBookOnDisk,
    List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
    Directory? localAudioStagingDir,
    Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
    Directory? audioDatabaseRoot,
    Future<void> Function(String displayName)? removeLocalAudioEntry,
    Future<bool> Function()? isProfileTransferEnabled,
    Future<String> Function()? exportActiveProfileJson,
    Future<String> Function(String json)? importProfileJson,
    String videoSubtitleLangCode = 'ja',
    Directory? uploadedVideoRoot,
    Directory? videoCoversDirectory,
    Future<String?> Function({
      required String videoPath,
      required String bookUid,
    })? extractVideoCover,
  })  : _db = db,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _packages = packages,
        _refreshDictionaryCache = refreshDictionaryCache,
        _runExclusive = runExclusive,
        _importBookFromFile = importBookFromFile,
        _cleanupBookOnDisk = cleanupBookOnDisk,
        _localAudioEntries = localAudioEntries,
        _localAudioStagingDir = localAudioStagingDir,
        _onLocalAudioImported = onLocalAudioImported,
        _audioDatabaseRoot = audioDatabaseRoot,
        _removeLocalAudioEntry = removeLocalAudioEntry,
        _isProfileTransferEnabled = isProfileTransferEnabled,
        _exportActiveProfileJson = exportActiveProfileJson,
        _importProfileJson = importProfileJson,
        _videoSubtitleLangCode = videoSubtitleLangCode,
        _uploadedVideoRoot = uploadedVideoRoot,
        _videoCoversDirectory = videoCoversDirectory,
        _extractVideoCover = extractVideoCover;

  @override
  final FushiDatabase _db;
  @override
  final Directory _dictionaryResourceRoot;
  @override
  final SyncAssetPackageService _packages;
  @override
  final Future<void> Function() _refreshDictionaryCache;
  @override
  final Future<void> Function(Future<void> Function() body) _runExclusive;

  /// 互联「配置文件」（Profile）搬运的三个可选依赖（与本类其余可选能力同范式：
  /// 注入回调而不是把 ProfileRepository 的构造依赖整条拖进来）。生产由 AppModel
  /// 传入；未注入时开关判据恒为 false，端点对外表现为「host 关着」。
  @override
  final Future<bool> Function()? _isProfileTransferEnabled;
  @override
  final Future<String> Function()? _exportActiveProfileJson;
  @override
  final Future<String> Function(String json)? _importProfileJson;

  /// 书籍导入回调（可选；null 时 importBook 抛 [UnsupportedError]）。
  /// 生产传 `(f) => EpubImporter.importFromPath(db: db, filePath: f.path, fileName: p.basename(f.path))`。
  /// BUG-1503：返回落地后的真实 bookKey（重名加 `(2)` 后缀会改变派生键），
  /// 供 [importBook] 把推送方随行的显示名挂到正确的书上。
  @override
  final Future<String?> Function(File epubFile)? _importBookFromFile;

  /// 书籍磁盘清理回调（可选；null 时只执行 DB 删除，跳过 AudiobookStorage/SrtBook 清理）。
  /// 生产传 ReaderFushiSource 实例的磁盘清理部分。
  @override
  final Future<void> Function(EpubBookRow row)? _cleanupBookOnDisk;

  // ── 本地音频（T3.1）──────────────────────────────────────────────────────

  /// 当前已注册的本地音频来源列表。生产传 AppModel.localAudioEntries。
  @override
  final List<LocalAudioDbEntry> _localAudioEntries;

  /// importLocalAudio 解包用临时目录。null 时用 Directory.systemTemp。
  @override
  final Directory? _localAudioStagingDir;

  /// 本地音频包解包后的注册回调（可选；null 时 importLocalAudio 抛 [UnsupportedError]）。
  /// 生产传 AppModel.importSyncedLocalAudioDb。
  @override
  final Future<void> Function(LocalAudioPackageContents)? _onLocalAudioImported;

  // ── 有声书（T3.1）────────────────────────────────────────────────────────

  /// importAudiobook 音频文件落盘根目录（可选；null 时 importAudiobook 抛 [UnsupportedError]）。
  /// 生产传 AppModel 的 audioDatabaseRoot。
  @override
  final Directory? _audioDatabaseRoot;

  /// deleteLocalAudio 回调（可选；null 时 deleteLocalAudio 仅做名称校验，静默跳过删除）。
  /// 生产传按 displayName 从 LocalAudioManager 移除条目的回调（T3.4 接线）。
  @override
  final Future<void> Function(String displayName)? _removeLocalAudioEntry;

  // ── 视频（P4-1）──────────────────────────────────────────────────────────────

  /// 视频 sidecar 字幕匹配的目标语言代码（默认 'ja'）。
  /// 生产传 JapaneseLanguage.instance.languageCode（P4 接线任务完成后注入真实值）。
  @override
  final String _videoSubtitleLangCode;

  /// client→host 上传视频的落盘根目录（可选；null 时 [importVideo] 抛 [UnsupportedError]）。
  /// 生产传 `<documents>/remote_videos`（[AppPaths.remoteVideosDirectory] 同目录，与
  /// client 下载远端视频落点一致）。
  @override
  final Directory? _uploadedVideoRoot;
  @override
  final Directory? _videoCoversDirectory;

  /// 上传视频后的封面抽取回调（可选、best-effort；null 时上传的视频无封面占位）。
  /// 生产传 `extractVideoCover`（桌面 ffmpeg 抽帧；移动端无 ffmpeg 返 null 留空占位）。
  @override
  final Future<String?> Function(
      {required String videoPath, required String bookUid})? _extractVideoCover;
}

/// 跨域共享的查询 helper（书 / 视频 / 有声书都用）：主合集归属一趟映射、可导出有声书键集。
/// 方法逐字搬自 LocalLibraryHostService；各域 mixin 以 `on _LocalLibraryHostBase, _LocalLibraryHostShared` 取用。
mixin _LocalLibraryHostShared on _LocalLibraryHostBase {
  /// `'<mediaType>|<entryKey>'` → 该条目的**主合集归属**（多端库联合视图 §2.3
  /// 任务5.1）的一趟映射。归属跟随 [FushiDatabase.getPrimaryCollectionIdByEntry] 的
  /// 「最小 collectionId」折叠语义：一条目属多合集时只带它折进的那一张，与库网格
  /// 折叠 / UI 占位卡归行一致。孤儿引用（合集已删）跳过 = 无归属（散卡）。每个被引用
  /// 合集只 [getCollectionItems] 一次，避免逐条目 N+1。
  Future<Map<String, RemoteCollectionMembership>>
      _primaryCollectionMembership() async =>
          (await _primaryCollectionData()).membership;

  /// [_primaryCollectionMembership] 的富版本：同一趟查询顺带产出
  /// `'<mediaType>|<entryKey>'` → 主归属合集**行**（[MediaCollectionRow]）的映射，
  /// 供 listVideos 解析系列级播放偏好（`subtitleDelayMs` / `audioTrackId`，schema
  /// v52「同系列共享」——此前清单只读 row 级值，host 在合集里调的轴/选的音轨
  /// 远端永远看不到）。
  Future<
      ({
        Map<String, RemoteCollectionMembership> membership,
        Map<String, MediaCollectionRow> collectionByEntry,
      })> _primaryCollectionData() async {
    final Map<String, int> primaryByEntry =
        await _db.getPrimaryCollectionIdByEntry();
    if (primaryByEntry.isEmpty) {
      return (
        membership: const <String, RemoteCollectionMembership>{},
        collectionByEntry: const <String, MediaCollectionRow>{},
      );
    }
    final Map<int, MediaCollectionRow> collectionsById =
        <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in await _db.getAllMediaCollections())
        c.id: c,
    };
    final Map<String, RemoteCollectionMembership> out =
        <String, RemoteCollectionMembership>{};
    final Map<String, MediaCollectionRow> rowByEntry =
        <String, MediaCollectionRow>{};
    // 只遍历真正承载某条目主归属的合集（按 id 去重），逐合集取一次成员行。
    for (final int cid in primaryByEntry.values.toSet()) {
      final MediaCollectionRow? col = collectionsById[cid];
      if (col == null) continue; // 孤儿引用：归属合集已删 → 该条目退化散卡。
      for (final MediaCollectionItemRow item
          in await _db.getCollectionItems(cid)) {
        // v83：epub 成员行 entryKey = 本机 epub_books.uid（透传行 = 对端 bookKey），
        // 本 map 键随成员表面貌走——bookKey 侧消费方（listBooks）负责先换到 uid。
        final String key = '${item.mediaType}|${item.entryKey}';
        // 仅记录以本合集为主归属的成员（该条目也可能在别的更大 id 合集里）。
        if (primaryByEntry[key] != cid) continue;
        out[key] = RemoteCollectionMembership(
          collectionName: col.name,
          collectionType: col.collectionType,
          sortIndex: item.sortIndex,
        );
        rowByEntry[key] = col;
      }
    }
    return (membership: out, collectionByEntry: rowByEntry);
  }

  // ── 有声书包（T3.1）────────────────────────────────────────────────────────

  /// 既有 Audiobooks 行又有 SrtBooks 行的 bookKey 集合——即真正可经 live-sync
  /// 导出的有声书（[exportAudiobook] 要求两表齐备，缺一即抛 StateError → 404）。
  ///
  /// [listBooks] 的 `hasAudiobook` 徽章、[listAudiobooks] 清单、orchestrator
  /// sweep 三处判据全部走此单一派生逻辑，确保徽章/清单/导出契约完全同源（TODO-778）。
  Future<Set<String>> _srtBackedAudiobookKeys() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    final Set<String> keys = <String>{};
    for (final AudiobookRow r in rows) {
      if (await _db.getSrtBookByBookKey(r.bookKey) != null) {
        keys.add(r.bookKey);
      }
    }
    return keys;
  }
}
