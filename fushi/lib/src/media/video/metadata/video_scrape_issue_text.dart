/// 刮削运行记录里的一条 issue message → 用户可见文案。
///
/// 记录本身是自由文本，但 AI 的参与情况（`ai:matched` / `ai:declined` /
/// `ai:failed` / `ai:searched`，见 `video_scrape_ai_identity.dart`）与挂起原因
/// （`pending:`，见 `video_scrape_pending_note.dart`）用固定前缀标记，这里把它们
/// 翻成本地化文案；其它 message 原样返回。
library;

import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
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
  final String confidence = t.video_scrape_ai_confidence(
    percent: note.confidencePercent,
  );
  final String headline = switch (note.kind) {
    VideoScrapeAiNoteKind.matched =>
      '${t.video_scrape_ai_matched} · $confidence',
    VideoScrapeAiNoteKind.declined =>
      '${t.video_scrape_ai_declined} · $confidence',
    VideoScrapeAiNoteKind.failed => t.video_scrape_ai_failed,
    VideoScrapeAiNoteKind.searched => t.video_scrape_ai_searched,
  };
  // 失败理由是 AiChatFailure 的脱敏短码（或异常类型名），翻成与设置页同一套文案。
  final String reason = note.kind == VideoScrapeAiNoteKind.failed
      ? aiFailureText(note.reason)
      : note.reason;
  return reason.isEmpty ? headline : '$headline\n$reason';
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
  VideoScrapePendingCause.error => t.video_scrape_pending_cause_error,
};

String? _aiOutcomeText(VideoScrapeAiOutcome outcome) => switch (outcome) {
  VideoScrapeAiOutcome.notAsked || VideoScrapeAiOutcome.accepted => null,
  VideoScrapeAiOutcome.unavailable => t.video_scrape_pending_ai_unavailable,
  VideoScrapeAiOutcome.unassigned => t.video_scrape_pending_ai_unassigned,
  VideoScrapeAiOutcome.failed => t.video_scrape_pending_ai_failed,
  VideoScrapeAiOutcome.declined => t.video_scrape_pending_ai_declined,
};
