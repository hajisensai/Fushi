import 'dart:io';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/scraper/cover_meta_store.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show setVideoCoverFromPickedFile;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi/src/mining/galgame_cover_resolver.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/misc/gallery_image_picker.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 媒体统一路线 P3：三个媒体岛（书 / 视频 / 游戏）封面「选图 → 落盘 → 缓存驱逐」
/// 的统一服务入口。
///
/// **只统一入口与复用件，不动数据模型**——各岛的存储位置、键派生、保护语义原样
/// 保留（薄路由到既有实现），差异表如下：
///
/// | 岛 | 存储位置 | 键 / 文件名 | 覆盖规则 | 来源标记 |
/// |---|---|---|---|---|
/// | 书（override 缩略图） | `appModel.thumbnailsDirectory`（`<documents>/thumbnails`） | `'<mediaIdentifier>/override_thumbnail'.hashCode`（无扩展名，[MediaSource.getOverrideThumbnailFilename]；BUG-1317 起**不含源键**，读取走 [MediaSource.resolveOverrideThumbnailFile] 以就地迁移旧的 `'<mediaIdentifier>/<sourceId>/override_thumbnail'` 文件名） | override 层：清除即回落源默认封面（EPUB 内嵌图等），不存在「保护」概念 | 无 |
/// | 视频 | `<documents>/video_covers`（[VideoStorage.coversDir]） | `<sanitize(bookUid)>.jpg`（`videoCoverFileName`），与导入自动截帧同名同路径 | 手动封面写 [CoverOrigin.manual] 进 `cover_meta.json`，批量在线刮削**永不覆盖** manual | [CoverMeta]（autoFrame / manual / scraped / sidecar） |
/// | 游戏 | `<documents>/game_covers`（`AppPaths.gameCoversDirectory`） | `<galgames.id>.<ext>`（换扩展名时先删旧文件，无孤儿） | 统一刮削弹窗**显式「使用」候选 = 覆盖下载**（`shouldDownloadExplicitScrapedCover`，与视频/书籍手动刮削同语义，2026-07-28 拍板）；自动/隐式路径只在无可用封面文件时下载（`shouldAutoDownloadScrapedCover`），绝不覆盖 | 无独立元数据（自动路径以「封面文件是否存在」为保护判据） |
///
/// 三条 apply 路径的共同不变量：**落盘后必须 [evictLocalCoverCache]**（裸
/// [FileImage] 键 + `resizedFileImage` 的 ResizeImage 键都清）——三岛封面都是
/// 「同路径覆盖写」，不驱逐则 UI 重建命中旧解码，用户看到的还是旧图。
///
/// 该不变量由统一落盘入口 [applyCoverFile] / [applyCoverBytes] **结构性保证**
/// （写盘与驱逐收在同一函数里，不再依赖每个落盘点自觉补 evict——BUG-1118 的
/// 三处刮削落盘正是漏补的教训）。lib/ 下所有「封面路径写盘」都必须走这两个
/// 入口，由 `test/media/media_cover_write_guard_test.dart` 源码扫描守卫。
///
/// 边界：互联层的远端封面（`sync/remote_cover_image.dart` /
/// `sync/remote_cover_cache.dart`，HTTP `coverUrl` 协议字段冻结）是**网络缓存**
/// 而非本地封面落盘，本轮不收编，仍由互联层自管。
class MediaCoverService {
  const MediaCoverService._();

  /// 统一落盘入口（文件源）：把 [source] 原子地写到 [destPath]（先写
  /// `<dest>.tmp` 再删旧文件 rename——Windows rename 不覆盖；失败清 .tmp、
  /// **不动旧封面**并 rethrow），成功后**必然**双键驱逐旧解码缓存
  /// （[evictLocalCoverCache]）。
  ///
  /// 三岛的目录/文件名派生仍由各调用方负责（红线：`override_thumbnail`
  /// hashCode 派生、`thumbnails/` / `video_covers/` / `game_covers/` 目录名
  /// 全部冻结不动）；本入口只负责「写盘 → 驱逐」这一步的结构保证。
  static Future<void> applyCoverFile({
    required File source,
    required String destPath,
  }) =>
      // 写盘 + 驱逐都在引擎 writer 里（驱逐经 evictImageCacheForFile 钩子回到
      // evictLocalCoverCache 的双键 evict）；这里不再重复 evict，一份真相。
      copyCoverFileAtomically(source: source, destPath: destPath);

  /// 统一落盘入口（内存字节源，下载场景）：语义同 [applyCoverFile]，
  /// 只是源换成 [bytes]（`flush: true` 落稳后 rename）。
  static Future<void> applyCoverBytes({
    required List<int> bytes,
    required String destPath,
  }) =>
      writeCoverBytesAtomically(bytes: bytes, destPath: destPath);

  /// 统一「封面已消失」入口：[destPath] 上的封面文件**已经被删除**时调用，
  /// 双键驱逐它的解码缓存。
  ///
  /// 为什么删也要走收口：BUG-1118 的不变量是「这条路径上的图变了就得驱逐」，
  /// 而删除同样是变。少了这一步，「清理全部刮削记录」之后书架与详情页会继续画一
  /// 张文件已经不在的封面，直到重启——和当年同路径覆盖写不驱逐的表现一模一样。
  ///
  /// 与 [applyCoverFile] / [applyCoverBytes] 的分工：那两条负责「写盘 → 驱逐」，
  /// 这条负责「已删除 → 驱逐」。三条合起来才是 `evictLocalCoverCache` 的**全部**
  /// 合法调用点（`test/media/media_cover_write_guard_test.dart` 的 allowed 名单
  /// 因此仍只有收口这三个文件，删除路径不需要再散点手补 evict）。
  ///
  /// 本入口**不删文件**：删除的时机、准入与回滚由调用方掌握（例如刮削清理要先
  /// 按 ledger SHA 校验再隔离再删），这里只承接删成功之后的缓存后果。
  static Future<void> applyCoverRemoval({required String destPath}) =>
      evictLocalCoverCache(destPath);

  /// 统一选图入口：移动端 image_picker 系统相册、桌面端 file_picker 原生文件
  /// 对话框（BUG-1074 的平台分流，委托 [pickGalleryImageFile]，分流决策见
  /// [galleryImagePickerBackendFor]）。用户取消返回 null。
  static Future<File?> pickCoverImage() => pickGalleryImageFile();

  /// 书：写 / 清除一个 [MediaItem] 的 override 缩略图。
  ///
  /// 薄路由到 [MediaSource.setOverrideThumbnailFromMediaItem]（存储位置与
  /// hashCode 键派生不变；缓存驱逐已在该方法末尾统一执行，覆盖删除路径
  /// `clearOverrideValues` 等所有写入方）。
  static Future<void> applyBookCoverOverride({
    required AppModel appModel,
    required MediaSource mediaSource,
    required MediaItem item,
    required File? file,
    required bool clearOverrideImage,
  }) {
    return mediaSource.setOverrideThumbnailFromMediaItem(
      appModel: appModel,
      item: item,
      file: file,
      clearOverrideImage: clearOverrideImage,
    );
  }

  /// 视频：用用户手选的图片设置封面，返回落盘路径。
  ///
  /// 薄路由到 [setVideoCoverFromPickedFile]（拷盘 + 双键驱逐 + 落库 `coverPath`），
  /// 先持久化 [CoverOrigin.manual] 保护标记，再覆盖文件与 `coverPath`；标记失败
  /// 时 fail closed，不把一张尚未受保护的用户文件暴露给自动维护流程。
  /// [coversDirectory] 是测试接缝：默认生产封面目录 [VideoStorage.coversDir]。
  static Future<String> applyVideoCoverManual({
    required VideoBookRepository repo,
    required String bookUid,
    required String pickedPath,
    Directory? coversDirectory,
  }) async {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw StateError('视频刮削资料正在清理');
    try {
      return await VideoCoverMutationGate.runExclusive(() async {
        final Directory covers =
            coversDirectory ?? await VideoStorage.coversDir();
        await CoverMetaStore(covers)
            .set(bookUid, const CoverMeta(origin: CoverOrigin.manual));
        return setVideoCoverFromPickedFile(
          repo: repo,
          bookUid: bookUid,
          pickedPath: pickedPath,
          coversDirectory: covers,
        );
      });
    } finally {
      lease.release();
    }
  }

  /// 合集：用用户手选的图片设置**合集自有**封面，返回落盘路径。
  ///
  /// 落 `video_covers/collections/<collectionId>.jpg`
  /// （[VideoStorage.collectionCoversDir] + [videoCoverFileName]，与番剧下载导入
  /// 器写合集海报**同目录同命名**），再写 [MediaCollections.coverPath]。固定文件
  /// 名意味着换封面就是同路径覆盖，不留孤儿；扩展名恒 `.jpg` 只是沿用视频封面的
  /// 命名约定（内容按原字节拷贝、不转码，解码不看扩展名）。
  ///
  /// 为什么不需要额外的「手动封面」保护标记（对比 [applyVideoCoverManual] 的
  /// [CoverOrigin.manual]）：合集封面的刮削覆盖判据是
  /// `coverPath == null || isUnmodifiedGeneratedArtifact(coverPath)` ——后者按
  /// `video_sidecar_artifacts` 登记表的 sha256 比对，手选图从不进那张表，因而
  /// **结构性**不会被在线刮削覆盖。
  ///
  /// 与刮削并发的互斥沿用视频侧同一对门：[VideoScrapeOperationGate]（清理期禁写）
  /// + [VideoCoverMutationGate]（封面写互斥），与
  /// `video_source_scrape_coordinator` 写同一路径时不打架。
  /// [collectionCoversDirectory] 是测试接缝。
  static Future<String> applyCollectionCover({
    required FushiDatabase database,
    required int collectionId,
    required String pickedPath,
    Directory? collectionCoversDirectory,
  }) async {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw StateError('视频刮削资料正在清理');
    try {
      return await VideoCoverMutationGate.runExclusive(() async {
        final Directory covers = collectionCoversDirectory ??
            await VideoStorage.collectionCoversDir();
        await covers.create(recursive: true);
        final String destPath =
            p.join(covers.path, videoCoverFileName('$collectionId'));
        await applyCoverFile(source: File(pickedPath), destPath: destPath);
        await database.updateMediaCollectionCoverPath(collectionId, destPath);
        return destPath;
      });
    } finally {
      lease.release();
    }
  }

  /// 游戏：用用户手选的图片设置封面，返回落盘路径；失败返回 null。
  ///
  /// 薄路由到 [saveGameCoverFromFile]（`game_covers/<id>.<ext>` 落盘、换扩展名
  /// 清旧文件；其写盘已走 [applyCoverFile]，双键驱逐结构性内含）。
  /// [coverDirectory] 是测试接缝。
  static Future<String?> applyGameCover({
    required String gameId,
    required String sourcePath,
    Directory? coverDirectory,
  }) {
    return saveGameCoverFromFile(
      gameId: gameId,
      sourcePath: sourcePath,
      coverDirectory: coverDirectory,
    );
  }
}
