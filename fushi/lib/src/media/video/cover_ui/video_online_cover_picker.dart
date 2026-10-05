import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';

/// 取一个候选作品的封面图 URL：候选摘要里带了 cover 图就直接用；搜索摘要没带图
/// （AniDB 标题搜索只给身份与标题）时，经 [fetchWork] 拉完整资料再取。
///
/// 只认 [VideoMetadataImageKind.cover]：背景图 / logo 的比例和内容都不是封面，拿来
/// 顶封面会让卡片裁出一条横幅。返回 null = 这部作品在资料源上确实没有封面图。
Future<String?> resolveVideoCandidateCoverUrl(
  VideoSourceScrapeConfirmationCandidate candidate, {
  required Future<VideoMetadataWork?> Function(VideoMetadataLookup lookup)
  fetchWork,
}) async {
  final String? inline = _firstCoverUrl(candidate.work);
  if (inline != null) return inline;
  final VideoMetadataWork? full = await fetchWork(candidate.lookup);
  return full == null ? null : _firstCoverUrl(full);
}

String? _firstCoverUrl(VideoMetadataWork work) {
  for (final VideoMetadataImage image in work.images) {
    if (image.kind != VideoMetadataImageKind.cover) continue;
    final String url = image.url.trim();
    final Uri? uri = Uri.tryParse(url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return url;
    }
  }
  return null;
}

/// 视频条目 / 合集「在线搜索封面」：在资料源（AniDB / MAL / TMDB，与手动指定作品
/// 同一条 [VideoSourceScrapeTaskController.searchManualCandidates]）里搜作品 → 用户
/// 选一条 → 下载它的封面到临时文件并返回。
///
/// 只取图、不改作品身份：返回的文件交给调用方走与「选择本地图片」完全相同的落盘
/// 通道（单集 [MediaCoverService.applyVideoCoverManual]、合集
/// [MediaCoverService.applyCollectionCover]），所以手选保护标记、旧缓存驱逐都不变。
///
/// 返回 null = 用户取消，或失败已就地 toast + 记错误日志。
Future<File?> pickVideoOnlineCoverFile({
  required BuildContext context,
  required String workTitle,
  required VideoSourceScrapeTaskController controller,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final VideoSourceScrapeConfirmationCandidate? candidate =
      await showVideoMetadataCandidateSearchDialog(
        context: context,
        workTitle: workTitle,
        title: t.video_cover_online_search,
        hint: t.video_cover_online_hint,
        search: (String query) => controller.searchManualCandidates(
          workTitle: workTitle,
          query: query,
        ),
      );
  if (candidate == null) return null;
  try {
    final String? url = await resolveVideoCandidateCoverUrl(
      candidate,
      fetchWork: controller.fetchWorkForLookup,
    );
    if (url == null) {
      FushiToast.show(
        msg: t.video_cover_online_no_image,
        severity: ToastSeverity.warning,
      );
      return null;
    }
    return await download(url);
  } on Object catch (e, stack) {
    // 失败必须可见 + 可查：toast 给「失败了 + 大概因为什么」，原始原因进日志。
    ErrorLogService.instance.log('video.onlineCover', e, stack);
    final int? status = e is ImageDownloadException ? e.statusCode : null;
    FushiToast.show(
      msg:
          '${t.book_scrape_failed}\n'
          '${status == null ? t.scrape_reason_network : t.scrape_reason_server}',
      severity: ToastSeverity.error,
    );
    return null;
  }
}
