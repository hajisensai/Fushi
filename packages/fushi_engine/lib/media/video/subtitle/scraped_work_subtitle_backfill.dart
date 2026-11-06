/// 刮完一个作品 → 给它仍缺字幕的成员各补一条（BUG-1698）。
///
/// app（`AppModel` 下载管线的刮削协调器）与无头服务端（`ServerSubtitleBackfill`）
/// 共用这一份：刮削是全仓唯一解析出规范身份（AniDB 主身份 + TMDB/AniList
/// crossref + 原名）的地方，而字幕准确率几乎完全取决于身份准不准。
///
/// 进场闸门（偏好开关、有没有配字幕来源）由调用方判；这里只做「作品 → 目标 →
/// 逐条补」。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart'
    show DownloadConfirmedIdentityResolver;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart'
    show VideoScrapedWorkNotice;
import 'package:fushi_engine/media/video/subtitle/library_video_subtitle_backfill.dart'
    show withDownloadConfirmedIdentity;
import 'package:fushi_engine/media/video/subtitle/scraped_subtitle_targets.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_backfill.dart';

/// 诊断日志的 source tag。
const String kScrapedWorkSubtitleBackfillLogSource = 'SubtitleBackfill.scraped';

/// 给 [notice] 里刚刮完的作品补字幕；返回每个目标的结果（按成员顺序）。
///
/// 已有字幕（DB 里的 `subtitleSource` 非空，或目录里已有 sidecar）的成员不动。
/// [seriesLanguage] 按合集名（小写）查每系列字幕语言记忆；单文件作品没有合集，
/// 也就没有记忆可查。
///
/// 逐条串行而不是并发：一次刮削可能带来整季十几集，并发打同一个字幕站是滥用；
/// 而且这条路径跑在刮削的后台任务里，没人在等它。
Future<List<({SubtitleBackfillTarget target, SubtitleBackfillResult result})>>
backfillScrapedWorkSubtitles({
  required FushiDatabase database,
  required VideoSubtitleBackfillService service,
  required VideoScrapedWorkNotice notice,
  required String? Function(String seriesKey) seriesLanguage,
}) async {
  final Set<String> withSubtitle = <String>{
    for (final VideoBookRow book in notice.work.members)
      if (book.subtitleSource?.trim().isNotEmpty == true) book.bookUid,
  };
  final MediaCollectionRow? collection = notice.work.collection;
  final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
    members: notice.work.members,
    metadata: notice.metadata,
    hasExistingSubtitle: withSubtitle.contains,
    explicitLanguage: collection == null
        ? null
        : seriesLanguage(collection.name.trim().toLowerCase()),
  );
  // 整季共用一个解析器：下载文件行只扫一次，不是逐集全表扫描。
  final DownloadConfirmedIdentityResolver confirmedIdentities =
      DownloadConfirmedIdentityResolver(database);
  final List<({SubtitleBackfillTarget target, SubtitleBackfillResult result})>
  out = <({SubtitleBackfillTarget target, SubtitleBackfillResult result})>[];
  for (final SubtitleBackfillTarget scraped in targets) {
    // 刮削主源是 TMDB 时身份不带 AniList，补回下载确认的身份（BUG-3926）。
    final SubtitleBackfillTarget target = scraped.withMedia(
      await withDownloadConfirmedIdentity(
        confirmedIdentities,
        videoPath: scraped.videoPath,
        media: scraped.media,
      ),
    );
    final SubtitleBackfillResult result = await service.backfill(target);
    if (result.installed) {
      engineLog.logDiagnostic(
        kScrapedWorkSubtitleBackfillLogSource,
        'installed ${result.language} for ${target.bookUid}: '
        '${result.installedPath}',
      );
    }
    out.add((target: target, result: result));
  }
  return out;
}
