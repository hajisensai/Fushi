/// 刮削运行记录里的一条 issue message → 用户可见文案。
///
/// 记录本身是自由文本，但 AI 判定与挂起原因用固定前缀标记（见
/// `video_scrape_ai_identity.dart` / `video_scrape_pending_note.dart`），这里把
/// 它们翻成本地化文案；其它 message 原样返回。
library;

import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:fushi/utils.dart';

String describeVideoScrapeIssueMessage(String message) {
  final VideoScrapePendingNote? pending = parseVideoScrapePendingNote(message);
  if (pending != null) {
    final String headline = describeVideoScrapePendingNote(pending);
    return pending.reason.isEmpty ? headline : '$headline\n${pending.reason}';
  }
  final VideoScrapeAiIdentityNote? note = parseVideoScrapeAiIdentityNote(
    message,
  );
  if (note == null) {
    return message;
  }
  final String headline =
      '${t.video_scrape_ai_matched} · '
      '${t.video_scrape_ai_confidence(percent: note.confidencePercent)}';
  return note.reason.isEmpty ? headline : '$headline\n${note.reason}';
}

/// 挂起原因的一行摘要：「原因 · AI 结果」，AI 没被问到时只有原因。
String describeVideoScrapePendingNote(VideoScrapePendingNote note) {
  final String? ai = _aiOutcomeText(note.aiOutcome);
  final String cause = _causeText(note);
  return ai == null ? cause : '$cause · $ai';
}

String _causeText(VideoScrapePendingNote note) => switch (note.cause) {
  VideoScrapePendingCause.hashConflict =>
    t.video_scrape_pending_cause_hash_conflict,
  VideoScrapePendingCause.noUsableCandidate =>
    t.video_scrape_pending_cause_no_usable_candidate,
  VideoScrapePendingCause.awaitingConfirmation =>
    t.video_scrape_pending_cause_awaiting_confirmation(
      count: note.candidateCount,
    ),
  VideoScrapePendingCause.dismissed => t.video_scrape_pending_cause_dismissed,
  VideoScrapePendingCause.notFound => t.video_scrape_pending_cause_not_found,
  VideoScrapePendingCause.providerUnavailable =>
    t.video_scrape_pending_cause_provider_unavailable,
};

String? _aiOutcomeText(VideoScrapeAiOutcome outcome) => switch (outcome) {
  VideoScrapeAiOutcome.notAsked || VideoScrapeAiOutcome.accepted => null,
  VideoScrapeAiOutcome.unavailable => t.video_scrape_pending_ai_unavailable,
  VideoScrapeAiOutcome.unassigned => t.video_scrape_pending_ai_unassigned,
  VideoScrapeAiOutcome.failed => t.video_scrape_pending_ai_failed,
  VideoScrapeAiOutcome.declined => t.video_scrape_pending_ai_declined,
};
