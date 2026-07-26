import 'dart:io';

import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/media/media_source.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show setVideoCoverFromPickedFile;
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/mining/galgame_cover_resolver.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/cover_image.dart';
import 'package:hibiki/src/utils/misc/gallery_image_picker.dart';

/// 媒体统一路线 P3：三个媒体岛（书 / 视频 / 游戏）封面「选图 → 落盘 → 缓存驱逐」
/// 的统一服务入口。
///
/// **只统一入口与复用件，不动数据模型**——各岛的存储位置、键派生、保护语义原样
/// 保留（薄路由到既有实现），差异表如下：
///
/// | 岛 | 存储位置 | 键 / 文件名 | 覆盖规则 | 来源标记 |
/// |---|---|---|---|---|
/// | 书（override 缩略图） | `appModel.thumbnailsDirectory`（`<documents>/thumbnails`） | `'<mediaIdentifier>/<sourceId>/override_thumbnail'.hashCode`（无扩展名，[MediaSource.getOverrideThumbnailFilename]） | override 层：清除即回落源默认封面（EPUB 内嵌图等），不存在「保护」概念 | 无 |
/// | 视频 | `<documents>/video_covers`（[VideoStorage.coversDir]） | `<sanitize(bookUid)>.jpg`（`videoCoverFileName`），与导入自动截帧同名同路径 | 手动封面写 [CoverOrigin.manual] 进 `cover_meta.json`，批量在线刮削**永不覆盖** manual | [CoverMeta]（autoFrame / manual / scraped / sidecar） |
/// | 游戏 | `<documents>/game_covers`（`AppPaths.gameCoversDirectory`） | `<galgames.id>.<ext>`（换扩展名时先删旧文件，无孤儿） | 刮削封面**只在无可用封面文件时**自动下载（`shouldAutoDownloadScrapedCover`）；手动/自动/已下载的一律不覆盖 | 无独立元数据（以「封面文件是否存在」为保护判据） |
///
/// 三条 apply 路径的共同不变量：**落盘后必须 [evictLocalCoverCache]**（裸
/// [FileImage] 键 + `resizedFileImage` 的 ResizeImage 键都清）——三岛封面都是
/// 「同路径覆盖写」，不驱逐则 UI 重建命中旧解码，用户看到的还是旧图。
class MediaCoverService {
  const MediaCoverService._();

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
  /// 再补记 [CoverOrigin.manual] 保护标记——批量在线刮削永不覆盖手动封面。
  /// 标记为 best-effort：元数据记账失败不影响封面已设置。
  /// [coversDirectory] 是测试接缝：默认生产封面目录 [VideoStorage.coversDir]。
  static Future<String> applyVideoCoverManual({
    required VideoBookRepository repo,
    required String bookUid,
    required String pickedPath,
    Directory? coversDirectory,
  }) async {
    final String dest = await setVideoCoverFromPickedFile(
      repo: repo,
      bookUid: bookUid,
      pickedPath: pickedPath,
      coversDirectory: coversDirectory,
    );
    try {
      final Directory covers =
          coversDirectory ?? await VideoStorage.coversDir();
      await CoverMetaStore(covers)
          .set(bookUid, const CoverMeta(origin: CoverOrigin.manual));
    } catch (_) {
      // 元数据记账失败不影响封面已设置（best-effort，保护性标记）。
    }
    return dest;
  }

  /// 游戏：用用户手选的图片设置封面，返回落盘路径；失败返回 null。
  ///
  /// 薄路由到 [saveGameCoverFromFile]（`game_covers/<id>.<ext>` 落盘、换扩展名
  /// 清旧文件），落盘成功后统一双键驱逐。[coverDirectory] 是测试接缝。
  static Future<String?> applyGameCover({
    required String gameId,
    required String sourcePath,
    Directory? coverDirectory,
  }) async {
    final String? saved = await saveGameCoverFromFile(
      gameId: gameId,
      sourcePath: sourcePath,
      coverDirectory: coverDirectory,
    );
    if (saved != null) {
      await evictLocalCoverCache(saved);
    }
    return saved;
  }
}
