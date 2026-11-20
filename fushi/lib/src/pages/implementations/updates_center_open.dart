/// 更新中心的条目跳转（v101）。
///
/// 与页面分开：`UpdatesCenterPage` 只认识「一条更新」，跳转要认识四个域各自的页面
/// 与它们的装配，塞进页面就等于把四棵依赖树焊进一个本该能独立构建的 widget。
///
/// 四个域的落点都在 app 内：番剧播那一集、漫画开作品页、扩展开扩展页、app 新版本
/// 走应用内检查 + 下载安装。这里没有 `launchUrl`——「更新」不该把人送出 app。
library;

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, UpdateFeedEntryRow;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/debug_pulse_panel.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi/src/updates/debug_pulse_service.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart'
    show UpdateChannel, updaterForCurrentPlatform;
import 'package:fushi/src/utils/misc/update_checker.dart'
    show channelForUpdateVersion, currentReleaseSequence;
import 'package:fushi/src/utils/misc/build_version.dart'
    show resolveCurrentAppVersion;
import 'package:fushi_engine/updates/debug_pulse.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';

/// 打开更新中心页（首页横幅、系统通知的「查看更新」都落到这里）。
Future<void> openUpdatesCenter(
  BuildContext context,
  UpdateFeedService service,
) => Navigator.of(context).push(
  adaptivePageRoute<void>(
    context: context,
    builder: (BuildContext pageContext) => UpdatesCenterPage(
      service: service,
      onOpenEntry: (UpdateFeedEntryRow entry) =>
          openUpdateFeedEntry(pageContext, entry),
      appReleaseHeader: _debugPulsePanelFor(pageContext),
    ),
  ),
);

/// 调试版流水线面板对谁有意义：选了 debug 通道的人，或者**本机跑的就是调试包**的人。
///
/// 只看更新通道设置（BUG-4906 之前）会漏掉后一类：TestFlight 每次 develop push 都
/// 推调试包，iOS 用户装上的就是 `x.y.z-debug.N`，却从不去改通道设置（默认 stable），
/// 安卓直接装调试 APK 的人同理——他们正站在这条时间线上，却看不到它。stable / beta
/// 用户跑正式包、通道也没选 debug 时仍不挂：他们收不到调试包，看流水线只会误以为
/// 「有新版不给我」。
bool showsDebugPulsePanel({
  required UpdateChannel configuredChannel,
  required String runningVersion,
}) =>
    configuredChannel == UpdateChannel.debug ||
    channelForUpdateVersion(runningVersion) == UpdateChannel.debug;

/// 调试版流水线面板「更新」按钮按哪条通道检查；null = 不给按钮。
///
/// 面板讲的永远是 debug 时间线，按钮就只按 debug 查（BUG-4906 审查：通道设 stable /
/// beta、跑调试包的人，按设置通道查会拿正式版 manifest 和调试包比，回「已是最新」，
/// 和面板说的「有新调试版」打架）。唯一例外是安装方式把通道钉死在别的轨上（Flatpak
/// 的 branch）：检查层会无条件改用那条轨（`update_checker_release.dart` 的
/// `updater.installedChannel ?? channel`），从这里点下去查到的必然不是面板说的那个
/// 调试版，不如不给按钮。
UpdateChannel? debugPulseUpdateChannel({
  required UpdateChannel? installationChannel,
}) => installationChannel == null || installationChannel == UpdateChannel.debug
    ? UpdateChannel.debug
    : null;

Widget? _debugPulsePanelFor(BuildContext context) {
  final AppModel appModel = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  final String version = resolveCurrentAppVersion(appModel.packageInfo.version);
  if (!showsDebugPulsePanel(
    configuredChannel: appUpdateChannelOf(appModel),
    runningVersion: version,
  )) {
    return null;
  }
  // 只认调试版自己的 seq：正式版 / 预发布的 seq 与调试版同一序列，但它们不在
  // 调试版时间线上，标「已装」会指错。
  final int? seq = channelForUpdateVersion(version) == UpdateChannel.debug
      ? currentReleaseSequence(
          version: version,
          buildNumber: appModel.packageInfo.buildNumber,
        )
      : null;
  final UpdateChannel? updateChannel = debugPulseUpdateChannel(
    installationChannel: updaterForCurrentPlatform().installedChannel,
  );
  return DebugPulsePanel(
    service: DebugPulseService.instance,
    installedSeq: seq,
    platform: DebugPulsePlatform.fromOperatingSystem(Platform.operatingSystem),
    customProxy: appModel.updateCustomProxy,
    onUpdate: updateChannel == null
        ? null
        : () => unawaited(
            checkAppUpdateNow(context, appModel, channel: updateChannel),
          ),
  );
}

/// 打开一条更新。
///
/// 番剧新集直接**播放那一集**：走 [VideoFushiPage.neutralized]——与「从 app 外
/// 打开视频」同一条进程级入口，只要 bookUid + 合集 id，不需要合集详情页那五个
/// 回调（那套装配只在 `home_video_page` 有一份，这里不复制第二份）。带上
/// `playlistCollectionId` 播放器就有兄弟集列表、上下集与连播。
Future<void> openUpdateFeedEntry(
  BuildContext context,
  UpdateFeedEntryRow entry,
) async {
  final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(entry.kind);
  if (kind == null) return;
  final Map<String, Object?> detail = decodeUpdateFeedDetail(entry.detailJson);
  switch (kind) {
    case UpdateFeedKind.mangaChapter:
      final String? bookKey = detail['bookKey'] as String?;
      if (bookKey == null || !context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) =>
              MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
        ),
      );
    case UpdateFeedKind.mangaExtension:
      if (!context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => const MihonExtensionsPage(),
        ),
      );
    case UpdateFeedKind.animeExtension:
      if (!context.mounted) return;
      // 视频扩展页 = 同一个扩展页挂视频（Aniyomi）manager。条目只会在有视频
      // 在线源的平台投递（探针自己过门），这里再问一次门：旧库搬到 iOS 上点开
      // 也不能起在线源宿主。
      if (!isVideoOnlineSourcesAvailable) return;
      final AppModel animeAppModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) =>
              MihonExtensionsPage(manager: animeAppModel.animeMihonManager),
        ),
      );
    case UpdateFeedKind.appRelease:
      // app 新版本走应用内更新：检查 → 「发现新版本」对话框 → 下载 + 安装。
      // detailJson 里的 releaseUrl 只是投递时的元数据，**不是**落点——把用户丢
      // 到浏览器手动下载，等于绕过 UpdateChecker 已有的整条安装链路。
      if (!context.mounted) return;
      final AppModel appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
      await checkAppUpdateNow(context, appModel);
    case UpdateFeedKind.videoEpisode:
      final String? bookUid = detail['bookUid'] as String?;
      final int? collectionId = detail['collectionId'] as int?;
      if (bookUid == null || !context.mounted) return;
      final FushiDatabase database = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider).database;
      final VideoBookRepository repo = VideoBookRepository(database);
      // 那集可能已被用户删掉：不进播放页对着空路径报错，留在列表里。
      if (await repo.getByBookUid(bookUid) == null || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage.neutralized(
            bookUid: bookUid,
            repo: repo,
            playlistCollectionId: collectionId,
          ),
        ),
      );
  }
}
