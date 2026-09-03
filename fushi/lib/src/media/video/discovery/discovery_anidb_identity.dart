/// 发现 → 下载/订阅确认时的 AniDB 身份就地解析（刮削重设计 P1，BUG-2003/2004）。
///
/// 为什么在这里解析：AniDB 是刮削唯一的规范主源，而发现层（AniList/TMDB）从不
/// 产出 AniDB id。修前这个缺口被推迟到下载管线深处，以「拿本地化显示名模糊搜 →
/// 歧义 → needsAttention 卡死」收场。用户确认下载/订阅的这一刻本来就在交互，
/// 就地用 AniDB **本地标题目录**解析（无网络代价）：
/// * 唯一严格命中 → 静默把 anidbId 补进 reference；
/// * 歧义 → 当场弹一次候选让用户选；
/// * 查无/目录不可用 → 明示一句后照常下载（导入后进待确认队列）。
///
/// 只对 `discoveryCategory == anime` 的条目解析：AniDB 不收真人影视，对它们
/// 解析必然查无，只会制造噪音。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_candidate_tile.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';

enum AniDbDiscoveryIdentityStatus {
  /// reference 已带 anidbId，或解析唯一命中并已写入。
  confirmed,

  /// 多个候选通过严格门，需要人工挑一个。
  ambiguous,

  /// 严格匹配查无此作品。
  notFound,

  /// 非 anime 条目：AniDB 不适用，不解析。
  notApplicable,

  /// 标题目录不可用（首次下载失败/离线）。
  unavailable,
}

class AniDbDiscoveryIdentityResult {
  const AniDbDiscoveryIdentityResult({
    required this.status,
    required this.reference,
    this.candidates = const <VideoSourceScrapeConfirmationCandidate>[],
  });

  final AniDbDiscoveryIdentityStatus status;

  /// confirmed 时带上 anidbId 的新 reference；其余状态原样返回入参。
  final VideoMediaReference reference;
  final List<VideoSourceScrapeConfirmationCandidate> candidates;
}

/// 把解析出的 AniDB id 写进 reference（`anidbId` + `externalIds['anidb']`）。
VideoMediaReference videoReferenceWithAniDbId(
  VideoMediaReference reference,
  int anidbId,
) =>
    VideoMediaReference(
      providerId: reference.providerId,
      mediaId: reference.mediaId,
      mediaKind: reference.mediaKind,
      discoveryCategory: reference.discoveryCategory,
      title: reference.title,
      originalTitle: reference.originalTitle,
      aliases: reference.aliases,
      year: reference.year,
      season: reference.season,
      episode: reference.episode,
      tmdbId: reference.tmdbId,
      imdbId: reference.imdbId,
      tvdbId: reference.tvdbId,
      anidbId: anidbId,
      anilistId: reference.anilistId,
      bangumiId: reference.bangumiId,
      externalIds: <String, String>{
        ...reference.externalIds,
        'anidb': '$anidbId',
      },
    );

/// 纯解析（无 UI）：复用来源刮削管线的严格解析器与判据。
///
/// 标题候选按可靠度排序：日文原名 → 别名（含罗马字/英文名）→ 本地化显示名。
/// 显示名（TMDB 类目常是中文）放最后兜底，与 nyaa 搜索词的取名顺序同一哲学。
Future<AniDbDiscoveryIdentityResult> resolveAniDbDiscoveryIdentity({
  required VideoMediaReference reference,
  required VideoMetadataProviderRegistry registry,
}) async {
  if (reference.anidbId != null) {
    return AniDbDiscoveryIdentityResult(
      status: AniDbDiscoveryIdentityStatus.confirmed,
      reference: reference,
    );
  }
  if (reference.discoveryCategory != VideoDiscoveryCategory.anime) {
    return AniDbDiscoveryIdentityResult(
      status: AniDbDiscoveryIdentityStatus.notApplicable,
      reference: reference,
    );
  }
  final Set<String> seen = <String>{};
  final List<String> candidates = <String>[
    for (final String value in <String>[
      if (reference.originalTitle case final String original) original,
      ...reference.aliases,
      reference.title,
    ])
      if (value.trim().isNotEmpty && seen.add(value.trim().toLowerCase()))
        value.trim(),
  ];
  final VideoMetadataResolution resolution;
  try {
    resolution = await VideoMetadataResolver(registry: registry)
        .resolve(VideoMetadataResolveRequest(
      selectedProvider: VideoMetadataProviderKind.anidb,
      mediaKind: reference.mediaKind,
      titleCandidates: candidates,
      year: reference.year,
      seasonNumber: reference.season,
    ));
  } catch (_) {
    // 标题目录首次下载失败/离线：明示降级，不阻断下载。
    return AniDbDiscoveryIdentityResult(
      status: AniDbDiscoveryIdentityStatus.unavailable,
      reference: reference,
    );
  }
  switch (resolution.status) {
    case VideoMetadataResolutionStatus.matched:
      final int? id = int.tryParse(resolution.lookup?.externalId ?? '');
      if (id == null) {
        return AniDbDiscoveryIdentityResult(
          status: AniDbDiscoveryIdentityStatus.notFound,
          reference: reference,
        );
      }
      return AniDbDiscoveryIdentityResult(
        status: AniDbDiscoveryIdentityStatus.confirmed,
        reference: videoReferenceWithAniDbId(reference, id),
      );
    case VideoMetadataResolutionStatus.ambiguous:
      return AniDbDiscoveryIdentityResult(
        status: AniDbDiscoveryIdentityStatus.ambiguous,
        reference: reference,
        candidates: <VideoSourceScrapeConfirmationCandidate>[
          for (final VideoMetadataWork candidate in resolution.candidates)
            if (_anidbLookupOf(candidate) case final VideoMetadataLookup lookup)
              VideoSourceScrapeConfirmationCandidate(
                lookup: lookup,
                work: candidate,
              ),
        ],
      );
    case VideoMetadataResolutionStatus.notFound:
      return AniDbDiscoveryIdentityResult(
        status: AniDbDiscoveryIdentityStatus.notFound,
        reference: reference,
      );
    case VideoMetadataResolutionStatus.providerUnavailable:
      return AniDbDiscoveryIdentityResult(
        status: AniDbDiscoveryIdentityStatus.unavailable,
        reference: reference,
      );
  }
}

VideoMetadataLookup? _anidbLookupOf(VideoMetadataWork work) {
  for (final VideoMetadataId id in work.ids) {
    if (id.type.toLowerCase() == 'anidb' && id.value.trim().isNotEmpty) {
      return VideoMetadataLookup(
        provider: VideoMetadataProviderKind.anidb,
        externalId: id.value.trim(),
        mediaKind: work.kind,
      );
    }
  }
  return null;
}

/// 交互式确认：解析 + 歧义弹候选 + 查无/降级提示。
///
/// 永不阻断：无论解析结果如何都返回一个可下载的 reference（歧义时用户跳过 =
/// 无身份下载，导入后进待确认队列）。[context] 失活时静默返回原 reference。
Future<VideoMediaReference> confirmAniDbDiscoveryIdentity({
  required BuildContext context,
  required VideoMediaReference reference,
  required VideoMetadataProviderRegistry registry,
}) async {
  final AniDbDiscoveryIdentityResult result =
      await resolveAniDbDiscoveryIdentity(
    reference: reference,
    registry: registry,
  );
  switch (result.status) {
    case AniDbDiscoveryIdentityStatus.confirmed:
    case AniDbDiscoveryIdentityStatus.notApplicable:
      return result.reference;
    case AniDbDiscoveryIdentityStatus.notFound:
    case AniDbDiscoveryIdentityStatus.unavailable:
      FushiToast.show(msg: t.video_discovery_anidb_identity_not_found);
      return result.reference;
    case AniDbDiscoveryIdentityStatus.ambiguous:
      if (!context.mounted || result.candidates.isEmpty) {
        return result.reference;
      }
      final VideoSourceScrapeConfirmationCandidate? selected =
          await showAppDialog<VideoSourceScrapeConfirmationCandidate>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(t.video_discovery_anidb_identity_confirm_title),
          content: SizedBox(
            width: 560,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(t.video_discovery_anidb_identity_confirm_hint),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: result.candidates.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) =>
                          VideoSourceScrapeCandidateTile(
                        candidate: result.candidates[index],
                        onSelected: (
                          VideoSourceScrapeConfirmationCandidate candidate,
                        ) =>
                            Navigator.of(context).pop(candidate),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('discovery-anidb-identity-skip'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.video_source_scrape_confirmation_skip),
            ),
          ],
        ),
      );
      final int? id = int.tryParse(selected?.lookup.externalId ?? '');
      if (id == null) return result.reference;
      return videoReferenceWithAniDbId(result.reference, id);
  }
}
