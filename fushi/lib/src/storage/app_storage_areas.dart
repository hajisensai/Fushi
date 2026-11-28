/// app 的受管存储区域登记（架构重构 D1，模型见 fushi_engine `storage_area.dart`）。
///
/// [AppStorageArea] 的每个值就是一个登记项，[kAppStorageAreas] 是 app 进程的登记表
/// = 引擎区域 + app 区域。以下清单全部由它派生，不再另写：
///
/// - 数据根迁移白名单 `AppPaths.fushiOwnedDocumentsEntries`（迁移 / Android 迷途库
///   合并 / 沙盒重定位 / 库见证的判据）；
/// - 书库证据豁免 `AppPaths.libraryEvidenceIgnoredEntries`；
/// - 存储页类目到目录的映射与区域级可删性（`storage_usage_service.dart`）。
///
/// 新增一个 Fushi 自己的目录：在这里（或引擎的 [EngineStorageArea]）加一个值，所有者
/// 用 `AppPaths.areaDirectory` / [StorageAreaPath.pathUnder] 取目录，别处不用再改。
library;

import 'package:fushi_engine/foundation/storage_area.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart'
    show kInterconnectSyncDataDirName;

import 'package:fushi/src/storage/export_directory.dart'
    show kLegacyExportDirectoryName;

export 'package:fushi_engine/foundation/storage_area.dart';

/// app 独有的区域（引擎派生的那几个在 [EngineStorageArea]）。
enum AppStorageArea implements StorageArea {
  /// 游戏库封面 `<documents>/game_covers`：手选与自动获取同名混放，还进备份包。
  gameCovers(
    id: 'game_covers',
    relativePath: 'game_covers',
    category: StorageCategoryId.covers,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 音乐专辑封面 `<documents>/music_covers/<发行 MBID>.jpg`（`music_albums.cover_path` 指着）。
  musicCovers(
    id: 'music_covers',
    relativePath: 'music_covers',
    category: StorageCategoryId.covers,
    lifecycle: StorageLifecycle.userData,
  ),

  /// `<documents>/thumbnails`：用户手设的书籍封面（override 缩略图）与刮削图 / 撤销备份。
  thumbnails(
    id: 'thumbnails',
    relativePath: 'thumbnails',
    category: StorageCategoryId.covers,
    lifecycle: StorageLifecycle.userData,
  ),

  /// mpv 着色器 `<documents>/mpv_shaders`：Anime4K 下载与用户自导入混放（Anime4K 由
  /// 它的拥有方原语 `deleteAnime4kShaderFiles` 按清单回收）。
  mpvShaders(
    id: 'mpv_shaders',
    relativePath: 'mpv_shaders',
    category: StorageCategoryId.shaders,
    lifecycle: StorageLifecycle.userData,
  ),

  /// mpv Lua 脚本 `<documents>/mpv_scripts`（全是用户导入的）。
  mpvScripts(
    id: 'mpv_scripts',
    relativePath: 'mpv_scripts',
    category: StorageCategoryId.shaders,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 备份恢复的视频落点 / iOS 收件箱旧扁平布局 `<documents>/videos`。
  restoredVideos(
    id: 'videos',
    relativePath: 'videos',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 动画下载 `<documents>/anime_downloads`（`AppModel.startAnimeDownloadService`）。
  animeDownloads(
    id: 'anime_downloads',
    relativePath: 'anime_downloads',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 下载页「手动添加任务」的 .torrent 元数据（随任务长期持久化）。
  manualTorrents(
    id: 'manual_torrents',
    relativePath: 'manual_torrents',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.control,
  ),

  /// 音频 CD 抓轨产物（BUG-3312，`<documents>/audio_cd/<卷标> (<光盘id>)/`）。
  audioCd(
    id: 'audio_cd',
    relativePath: 'audio_cd',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 在线音源插件曲目下载的旧落点（`<documents>/music_downloads/<插件>/<专辑>/`）。
  musicDownloads(
    id: 'music_downloads',
    relativePath: 'music_downloads',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// iOS「文件」App 收件箱收进来的文件（拍板台 nLXhu0d7gV，`inbox_imports/<域>/<批次>/`）。
  inboxImports(
    id: 'inbox_imports',
    relativePath: 'inbox_imports',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 自定义字体 `<documents>/custom_fonts`（字体配置指着）。
  customFonts(
    id: 'custom_fonts',
    relativePath: 'custom_fonts',
    category: StorageCategoryId.customFonts,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 导出目录 `<documents>/fushiExport`（W2-4 前叫 [kLegacyExportDirectoryName]）。
  /// 冷启动会往里放 `.nomedia`，不算书库证据（#4366）。
  exports(
    id: 'fushi_export',
    relativePath: 'fushiExport',
    legacyNames: <String>[kLegacyExportDirectoryName],
    category: StorageCategoryId.exports,
    lifecycle: StorageLifecycle.userData,
    deletabilityOverride: StorageEntryDeletability.confirm,
    countsAsLibraryEvidence: false,
  ),

  /// 卡片来源回看的待回写草稿（`card_source_drafts/<sourceId>`）。
  cardSourceDrafts(
    id: 'card_source_drafts',
    relativePath: 'card_source_drafts',
    category: StorageCategoryId.exports,
    lifecycle: StorageLifecycle.userData,
    deletabilityOverride: StorageEntryDeletability.confirm,
  ),

  /// 内置浏览器数据（登录态 / Cookie）。
  browser(
    id: 'browser',
    relativePath: 'browser',
    category: StorageCategoryId.web,
    lifecycle: StorageLifecycle.userData,
    deletabilityOverride: StorageEntryDeletability.confirm,
  ),

  /// 网页存档（用户存的）。
  webArchive(
    id: 'web_archive',
    relativePath: 'webArchive',
    category: StorageCategoryId.web,
    lifecycle: StorageLifecycle.userData,
    deletabilityOverride: StorageEntryDeletability.confirm,
  ),

  /// 词典资源 `<documents>/dictionaryResources/<词典名>`（每部词典有库行）。
  dictionaryResources(
    id: 'dictionary_resources',
    relativePath: 'dictionaryResources',
    category: StorageCategoryId.dictionaries,
    lifecycle: StorageLifecycle.libraryContent,
  ),

  /// 词典导入工作目录（过程物，不算书库证据）。
  dictionaryImportWorking(
    id: 'dictionary_import_working',
    relativePath: 'dictionaryImportWorkingDirectory',
    category: StorageCategoryId.dictionaries,
    lifecycle: StorageLifecycle.derived,
    deletabilityOverride: StorageEntryDeletability.no,
    countsAsLibraryEvidence: false,
  ),

  /// 新手引导推荐包的下载暂存（含 `.part` 续传半截，导入成功后整目录删除）。
  recommendedPack(
    id: 'recommended_pack',
    relativePath: 'recommended_pack',
    category: StorageCategoryId.dictionaries,
    lifecycle: StorageLifecycle.cache,
    deletabilityOverride: StorageEntryDeletability.no,
    countsAsLibraryEvidence: false,
  ),

  /// 新手引导进度（过程物，不算书库证据）。
  onboardingTutorial(
    id: 'onboarding_tutorial',
    relativePath: 'onboarding_tutorial',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.control,
    countsAsLibraryEvidence: false,
  ),

  /// 旧版复习自动备份（同步 v2 后留 30 天，`srs_legacy_backup_cleanup.dart`）。
  srsBackups(
    id: 'srs_backups',
    relativePath: 'srs_backups',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 删 Profile 前自动做的复习数据备份（撤销途径，BUG-3818）。
  srsProfileBackups(
    id: 'srs_profile_backups',
    relativePath: 'srs_profile_backups',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 互联 host 的 WebDAV 根与配对 / TLS 身份 `<support>/sync-data`（`FushiSyncServer`）。
  interconnectSyncData(
    id: 'interconnect_sync_data',
    root: StorageRootId.support,
    relativePath: kInterconnectSyncDataDirName,
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.control,
  ),

  /// 视频剪辑导出 `<导出基目录>/video_clips`：交给用户的导出物，直连平台目录，
  /// 刻意不随数据根走（[StorageRootId.userExports]）。
  videoClips(
    id: 'video_clips',
    root: StorageRootId.userExports,
    relativePath: 'video_clips',
    category: StorageCategoryId.exports,
    lifecycle: StorageLifecycle.userData,
  );

  const AppStorageArea({
    required this.id,
    required this.relativePath,
    required this.category,
    required this.lifecycle,
    this.root = StorageRootId.documents,
    this.legacyNames = const <String>[],
    this.deletabilityOverride,
    this.countsAsLibraryEvidence = true,
  });

  @override
  final String id;
  @override
  final StorageRootId root;
  @override
  final String relativePath;
  @override
  final List<String> legacyNames;
  @override
  final StorageCategoryId category;
  @override
  final StorageLifecycle lifecycle;
  @override
  final StorageEntryDeletability? deletabilityOverride;
  @override
  final bool countsAsLibraryEvidence;
}

/// app 进程的区域登记表（引擎区域 + app 区域；构造期校验唯一性与可删性约束）。
final StorageAreaRegistry kAppStorageAreas = StorageAreaRegistry(<StorageArea>[
  ...EngineStorageArea.values,
  ...AppStorageArea.values,
]);
