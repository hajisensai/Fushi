import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/src/pages/implementations/managed_video_source_prompt.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/torrent/magnet_utils.dart'
    show magnetUriFromInfoHash;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart'
    show VideoResourceCandidate;
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_discovery_submit.dart'
    show enqueueLocalVideoDownload;
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendTarget;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;

void _showVideoResourceSearchMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(FushiSnackBar(content: Text(message)));
}

/// 受管视频来源清单；为空时**弹「添加视频来源」引导**，用户加完再读一次。
///
/// 此前这一环用错了 i18n key：拿通用扫描根的 `media_source_no_sources`
/// （「暂无来源」）去描述「缺下载落地文件夹」，既说不清缺什么也没处点，用户自然
/// 猜成「没配下载后端」（下载页在 BUG-1706 已把原因拆开，这里漏改）。
/// 返回空表 = 用户取消或加完仍为空，调用方直接返回。
///
/// **重读仍为空必须给回一句提示**：本条路径上没有可停留的空态门（有空态门的页面
/// 关掉对话框后会重算前置条件、空态门继续留在页面上说明缺什么），静默返回等于
/// 整个流程无声消失。`promptManagedVideoSourceSetup` 返回 true 只表示用户走进了
/// 来源对话框，不表示真加成了。
Future<List<MediaSourceRow>> managedVideoDownloadSourcesOrPrompt(
  BuildContext context, {
  required AppModel appModel,
}) async {
  final List<MediaSourceRow> sources = await appModel
      .getManagedVideoDownloadSources();
  if (sources.isNotEmpty || !context.mounted) return sources;
  final bool added = await promptManagedVideoSourceSetup(context: context);
  if (!added) return const <MediaSourceRow>[];
  final List<MediaSourceRow> retried = await appModel
      .getManagedVideoDownloadSources();
  if (retried.isEmpty && context.mounted) {
    _showVideoResourceSearchMessage(
      context,
      t.download_no_managed_video_source,
    );
  }
  return retried;
}

/// 合集名 / 关系边标题常带刮削附加的年份后缀（`FX戦士くるみちゃん (2026)`），
/// 拿整串当检索词与手动身份标题会多出噪声（反馈 4Np5-EyJgE）。预填前剥掉尾部的
/// `(YYYY)` / `（YYYY）` / `[YYYY]`；剥完为空则保持原样。
String resourceSearchSeedQuery(String raw) {
  final String trimmed = raw.trim();
  final String stripped = trimmed
      .replaceFirst(RegExp(r'\s*[(（\[]\s*(?:19|20)\d{2}\s*[)）\]]\s*$'), '')
      .trim();
  return stripped.isEmpty ? trimmed : stripped;
}

/// 打开视频资源搜索页（BT 搜索 = 用户添加的 RSS 搜索站 + Torznab，统一经
/// [VideoResourceRegistry]）的**唯一装配点**：发现详情页「搜索资源」、作品详情页
/// 「获取途径 › BT」、合集详情页「去下载 / 补齐缺集 / 相关作品去下载」、作品图谱
/// 未入库灰卡「去搜」共用这一处，不各写一套。
///
/// [item] 有作品身份时直接按它搜；为 null 时页面进「手动身份」模式（不造假身份，
/// 用户补 AniDB / TMDB / AniList id），[initialQuery] 预填进搜索框。
///
/// [resolveAliases] 见 [VideoDiscoveryItemAliasResolver]（只有首页拿得到发现服务，
/// 其余入口传 null）。
///
/// 入口自己的模块 / 合规门（`ModuleId.browse` / `StoreRestrictedCapability`）由调用方
/// 判，本函数只管前置条件引导：下载后端、受管落地来源、已配对 host。
Future<void> openVideoResourceSearch(
  BuildContext context, {
  required AppModel appModel,
  VideoDiscoveryItem? item,
  String? initialQuery,
  VideoDiscoveryItemAliasResolver? resolveAliases,
}) async {
  final VideoResourceRegistry? registry = appModel.videoResourceRegistry;
  final VideoDownloadPipelineService? pipeline =
      appModel.videoDownloadPipelineService;
  Future<bool> configureBackend(BuildContext context) =>
      promptDownloadBackendSetup(context: context, appModel: appModel);
  // 下载可以交给已配对 host（设计 §3.3，手机让电脑下）：先探一遍，有 host 时
  // 本地下载后端 / 落地源都不是硬前置——手机上常常两个都没有。
  final InterconnectDownloadClient downloadClient = InterconnectDownloadClient(
    repo: SyncRepository(appModel.database),
  );
  final List<HostDownloadTarget> remoteTargets = await downloadClient
      .probeAll();
  if (!context.mounted) return;
  if (registry == null || (pipeline == null && remoteTargets.isEmpty)) {
    unawaited(configureBackend(context));
    return;
  }
  // 本机没有管线时「本机」这一档根本提交不了：不列本地落地源，下拉只剩 host。
  final List<MediaSourceRow> sources = pipeline == null
      ? const <MediaSourceRow>[]
      : remoteTargets.isEmpty
      ? await managedVideoDownloadSourcesOrPrompt(context, appModel: appModel)
      : await appModel.getManagedVideoDownloadSources();
  // PR #1021 把「后端 runtime 是否可用」延后到真正提交下载时（target 在
  // onSubmit 里取），后端没配好也能先搜资源。但「有没有受管视频来源」是另一
  // 回事：没有落地文件夹时来源下拉是空的、提交按钮永远灰着，所以 BUG-1872 的
  // 引导必须留在打开页面之前。两个原因本来就是两条分支，别再合成一条。
  // 有 host 可用时例外：落点在 host，没有本地来源也能下。
  if (!context.mounted || (sources.isEmpty && remoteTargets.isEmpty)) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => VideoDiscoveryResourceSearchPage(
        item: item,
        initialQuery: initialQuery == null
            ? null
            : resourceSearchSeedQuery(initialQuery),
        registry: registry,
        sources: sources,
        defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
        // 后端 runtime 的可用性延后到提交时才判（见上），所以「后端没配好」这条
        // 失败必然发生在页面里。页面自己拿不到 AppModel，把配置引导按端口注入，
        // 失败态那句话才有一颗能真正解决它的按钮。
        onConfigureBackend: configureBackend,
        resolveAliases: resolveAliases,
        remoteTargets: remoteTargets,
        defaultRemoteTargetUrl: appModel.prefsRepo.downloadExecutionHostUrl,
        onRemoteSubmit:
            (VideoDiscoveryRemoteDownloadSelection selection) async {
              final VideoResourceCandidate resource = selection.resource;
              // host 只收磁链：索引器没给现成磁链就用 infoHash 造一条；两者都没有
              // （Torznab 只给 .torrent 地址）的候选投不了远端，如实报。
              final String? infoHash = resource.infoHash;
              final String? magnet =
                  resource.magnetUri ??
                  (infoHash == null
                      ? null
                      : magnetUriFromInfoHash(
                          infoHash,
                          displayName: resource.title,
                        ));
              if (magnet == null) {
                throw const HostDownloadException('magnet_only');
              }
              await downloadClient.addMagnet(
                selection.target,
                magnetUri: magnet,
                title: resource.title,
                mediaKind:
                    selection.media.mediaKind == VideoMetadataMediaKind.tv
                    ? 'tv'
                    : 'movie',
              );
            },
        onSubmit: (VideoDiscoveryDownloadSelection selection) async {
          if (pipeline == null) {
            // 本机没有管线时 sources 为空、「本机」档不渲染，这里到不了；留
            // 一道硬门免得日后有人把 sources 接回来。
            throw const VideoDownloadPipelineActionRequired(
              'no local download pipeline',
            );
          }
          final VideoDownloadBackendTarget target = await appModel
              .currentVideoDownloadBackendTarget();
          await enqueueLocalVideoDownload(
            pipeline: pipeline,
            coverUrl: item?.posterUrl,
            selection: selection,
            target: target,
          );
        },
      ),
    ),
  );
}
