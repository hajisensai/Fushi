/// 视频的待确认身份数据源：适配既有补刮调度（[VideoLibraryScrapeSweep]），行为
/// 一字不变——清单就是 `pendingWorksWithReasons()` / `ignoredWorks()`，忽略就是
/// `setWorksIgnored`（偏好键 `video_scrape_ignored_works`，见 `pending_identity.dart`）。
library;

import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';

/// 一部待确认视频作品对应的统一条目。
PendingIdentityEntry pendingIdentityEntryOfVideoWork(
  VideoPendingScrapeWork work,
) {
  final VideoScrapePendingNote? note = work.pendingNote;
  return PendingIdentityEntry(
    kind: PendingIdentityMediaKind.video,
    key: work.work.stableKey,
    title: work.work.title,
    cause: note?.cause,
    aiOutcome: note?.aiOutcome,
    candidateCount: note?.candidateCount ?? 0,
    lastAttemptAt: work.pendingNoteAt,
    detail: note == null || note.reason.isEmpty ? null : note.reason,
  );
}

/// [PendingIdentitySource] 的视频实现。
class VideoPendingIdentitySource implements PendingIdentitySource {
  const VideoPendingIdentitySource(this.sweep);

  final VideoLibraryScrapeSweep sweep;

  @override
  Future<PendingIdentityListing> load() async => PendingIdentityListing(
    pending: <PendingIdentityEntry>[
      for (final VideoPendingScrapeWork w
          in await sweep.pendingWorksWithReasons())
        pendingIdentityEntryOfVideoWork(w),
    ],
    ignored: <PendingIdentityEntry>[
      for (final VideoPendingScrapeWork w in await sweep.ignoredWorks())
        pendingIdentityEntryOfVideoWork(w),
    ],
  );

  @override
  Future<void> setIgnored(Iterable<String> keys, {required bool ignored}) =>
      sweep.setWorksIgnored(keys, ignored: ignored);
}
