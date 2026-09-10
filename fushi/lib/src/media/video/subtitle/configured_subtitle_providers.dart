import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 「用户当前配了哪些在线字幕来源」的**唯一真相源**。
///
/// 此前这段按偏好装配 provider 的代码只长在下载管线的启动路径里
/// （`AppModel._startVideoDownloadPipeline`），于是任何**不经过下载管线**的入口
/// 都得自己再实现一遍「哪家算配好了」——浏览器扩展的查字幕桥就是这么变成
/// Jimaku 独一家的（它直连 JimakuClient，只认 API key，AJATT / OpenSubtitles 在
/// 扩展里根本不存在）。抽到这里之后，管线与扩展桥共用同一份判据，加一家新来源
/// 只需改这一个函数。
///
/// 三家的门控形状**有意不同**，不要往一起合：
/// - Jimaku / OpenSubtitles：`enabled && key`（有 key 才谈得上启用）；
/// - AJATT：零配置，只有开关。
Future<List<VideoSubtitleProvider>> createConfiguredVideoSubtitleProviders({
  required PreferencesRepository prefs,
  required Future<http.Client> Function() httpClientFactory,
  required Future<Directory> Function() supportRootProvider,
}) async {
  final List<VideoSubtitleProvider> providers = <VideoSubtitleProvider>[];
  // Jimaku：`enabled && key` 双门控（形状对齐 OpenSubtitles）。开关默认 true，
  // 所以存量已填 key 的用户升级后行为不变。
  if (prefs.jimakuEnabled && prefs.jimakuApiKey.trim().isNotEmpty) {
    providers.add(
      JimakuVideoSubtitleProvider(
        client: JimakuClient(
          apiKey: prefs.jimakuApiKey,
          client: await httpClientFactory(),
        ),
        closesClient: true,
      ),
    );
  }
  final OpenSubtitlesConfig? openSubtitles =
      prefs.videoSubtitleOpenSubtitlesConfig;
  if (openSubtitles != null &&
      openSubtitles.enabled &&
      openSubtitles.effectiveApiKey.isNotEmpty) {
    providers.add(
      OpenSubtitlesClient(
        config: openSubtitles,
        client: await httpClientFactory(),
        closesClient: true,
      ),
    );
  }
  // AJATT（kitsunekko 镜像）：零配置，只有开关。目录 HTML 约 9 MB，解析结果落
  // support 目录缓存 24 小时（`subtitle_catalogs/ajatt.json`）。
  if (prefs.videoSubtitleAjattEnabled) {
    final Directory supportRoot = await supportRootProvider();
    providers.add(
      AjattVideoSubtitleProvider(
        client: AjattClient(
          client: await httpClientFactory(),
          closesClient: true,
          cache: AjattCatalogCache(
            file: File(
              path.join(supportRoot.path, 'subtitle_catalogs', 'ajatt.json'),
            ),
          ),
        ),
      ),
    );
  }
  return providers;
}
