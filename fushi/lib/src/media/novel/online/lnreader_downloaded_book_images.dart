import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_missing_images.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show LnReaderOnlinePluginMissing, lnReaderOnlineChapterFile;
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// LNReader「下载」成 EPUB 的书的缺图提示与补取。
///
/// 下载成的书入库后是一本普通 EPUB（没有按需取章加载器，书行 `sourceMetadata`
/// 是导入时写的系列描述符），和源站的关联全在章节正文里的缺图占位上：每个占位
/// 记着原图地址、引用页（章节页）和插件 id（`lnreader_missing_images.dart`）。所以
/// 这里不需要书级描述符——章节文件里有占位就能补，没有就是 0 张，普通书走到这里
/// 也只是读一下章节文件、什么都不做。
///
/// 章节文件按网文装配器的形状认（`OEBPS/chapter-<n>.xhtml`，第 n 章 = spine 第
/// n 项），与在线书相同。补到的图写回解压树（书的正文就在解压树里，没有另存的
/// EPUB 原件），章节文件里换回 `<img>`。
class LnReaderDownloadedBookImages implements OnlineNovelMissingImagesRetrier {
  LnReaderDownloadedBookImages({
    required this.extractDir,
    required LnReaderManager Function() manager,
    required LnReaderBookDownload Function(LnReaderManager manager) download,
  }) : _managerFactory = manager,
       _downloadFactory = download;

  final String extractDir;
  final LnReaderManager Function() _managerFactory;
  final LnReaderBookDownload Function(LnReaderManager manager) _downloadFactory;

  /// 惰性：普通书 / 不缺图的章不该为此把 LNReader 运行时（headless WebView）拉起来。
  LnReaderManager? _manager;
  LnReaderBookDownload? _download;

  final MissingImagesRetryQueue _retries = MissingImagesRetryQueue();

  @override
  int? chapterIndexForFile(String filePath) =>
      onlineNovelChapterIndexForFile(extractDir, filePath);

  @override
  Future<OnlineNovelMissingImages> missingImages(int index) async =>
      summarizeChapterMissingImages(
        index,
        index < 0
            ? const <LnReaderMissingImage>[]
            : await readChapterMissingImages(
                lnReaderOnlineChapterFile(extractDir, index),
              ),
      );

  @override
  Future<OnlineNovelMissingImagesRetry> retryMissingImages(
    int index, {
    required bool automatic,
  }) => _retries.run(() => _retry(index, automatic: automatic));

  Future<OnlineNovelMissingImagesRetry> _retry(
    int index, {
    required bool automatic,
  }) async {
    if (index < 0) {
      return OnlineNovelMissingImagesRetry(
        index: index,
        recovered: 0,
        remaining: 0,
      );
    }
    late final LnReaderManager manager;
    late final LnReaderBookDownload download;
    late final HttpClient client;
    bool opened = false;
    // 一章里的图几乎都来自同一个插件；按插件 id 只装载一次。
    final Map<String, LnReaderPluginInfo> infos =
        <String, LnReaderPluginInfo>{};
    try {
      return await retryChapterMissingImages(
        index: index,
        extractDir: extractDir,
        file: lnReaderOnlineChapterFile(extractDir, index),
        automatic: automatic,
        write: writeOnlineNovelFileAtomically,
        prepare: () async {
          manager = _manager ??= _managerFactory();
          download = _download ??= _downloadFactory(manager);
          // ensureReady 而不是 initialise：state.json 读不出来时 initialise 不抛、
          // 已装列表是空占位，下面就会误报「插件没装」，把读盘错误藏起来。
          await manager.ensureReady();
          client = download.openClient();
          opened = true;
        },
        fetch:
            (
              LnReaderMissingImage image,
              void Function(String reason) onFailure,
            ) async {
              final String? pluginId = image.pluginId;
              final String? referer = image.referer;
              if (pluginId == null || referer == null) {
                // 不是下载时写的占位（缺来源）：补不了，记一次失败。
                onFailure('no source recorded');
                return null;
              }
              final LnReaderPluginInfo info = infos[pluginId] ??= await manager
                  .load(_installed(manager, pluginId));
              return download.fetchChapterImage(
                client: client,
                info: info,
                referer: referer,
                url: image.url,
                fileName: image.fileName,
                onFailure: onFailure,
              );
            },
        onStillMissing: (int failed, int attempted, String? firstFailure) {
          ErrorLogService.instance.log(
            'LnReaderDownloadedBookImages.retryMissingImages',
            '$extractDir chapter ${index + 1}: still missing $failed of '
                '$attempted images (first: $firstFailure)',
          );
        },
      );
    } finally {
      if (opened) client.close(force: true);
    }
  }

  /// 已装列表里的插件；没装（被删了）抛 [LnReaderOnlinePluginMissing]，整轮不补。
  static LnReaderInstalledPlugin _installed(
    LnReaderManager manager,
    String pluginId,
  ) {
    for (final LnReaderInstalledPlugin candidate in manager.installed) {
      if (candidate.id == pluginId) return candidate;
    }
    throw LnReaderOnlinePluginMissing(pluginId);
  }
}

/// 阅读器开书时调用（没有按需取章加载器的书）：给出下载书的缺图补取。
///
/// [onlineSourcesAvailable] 没过（iOS 合规门 / 无 headless WebView 的平台）时
/// null：书会随备份恢复到这些平台，开书不得因此拉起在线小说宿主联网；占位不可见，
/// 书照常读，只是不提示、不补。[manager] 是惰性的（同在线书）。
LnReaderDownloadedBookImages? lnReaderDownloadedBookImagesFor({
  required EpubBookRow? row,
  required String extractDir,
  required FushiDatabase database,
  required LnReaderManager Function() manager,
  bool? onlineSourcesAvailable,
}) {
  if (!(onlineSourcesAvailable ?? isNovelOnlineSourcesAvailable)) return null;
  if (row == null) return null;
  return LnReaderDownloadedBookImages(
    extractDir: extractDir,
    manager: manager,
    download: (LnReaderManager resolved) => LnReaderBookDownload(
      manager: resolved,
      database: database,
      httpClientFactory: createAppHttpClient,
    ),
  );
}
