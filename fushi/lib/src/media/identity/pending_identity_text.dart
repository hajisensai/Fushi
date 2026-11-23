/// 待确认身份的原因文案（视频、书 / 漫画、游戏共用一套）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';

/// 原因的一行摘要：「原因 · AI 结果」，AI 没被问到 / 没记录时只有原因。
String describePendingIdentityCause(
  PendingIdentityCause cause,
  PendingIdentityAiOutcome? aiOutcome,
  int candidateCount,
) {
  final String? ai = aiOutcome == null
      ? null
      : pendingIdentityAiOutcomeText(aiOutcome);
  final String text = pendingIdentityCauseText(cause, candidateCount);
  return ai == null ? text : '$text · $ai';
}

String pendingIdentityCauseText(
  PendingIdentityCause cause,
  int candidateCount,
) => switch (cause) {
  PendingIdentityCause.hashConflict =>
    t.video_scrape_pending_cause_hash_conflict,
  PendingIdentityCause.noUsableCandidate =>
    t.video_scrape_pending_cause_no_usable_candidate,
  // 旧的书 / 游戏待确认记录没有候选数：不说「有 0 个候选」。
  PendingIdentityCause.awaitingConfirmation =>
    candidateCount > 0
        ? t.video_scrape_pending_cause_awaiting_confirmation(
            count: candidateCount,
          )
        : t.identity_pending_cause_awaiting_confirmation_unknown,
  PendingIdentityCause.dismissed => t.video_scrape_pending_cause_dismissed,
  PendingIdentityCause.notFound => t.video_scrape_pending_cause_not_found,
  PendingIdentityCause.providerUnavailable =>
    t.video_scrape_pending_cause_provider_unavailable,
  PendingIdentityCause.error => t.video_scrape_pending_cause_error,
};

/// AI 结论文案；没问 / 已采用为 null（不值得单独说）。
String? pendingIdentityAiOutcomeText(
  PendingIdentityAiOutcome outcome,
) => switch (outcome) {
  PendingIdentityAiOutcome.notAsked ||
  PendingIdentityAiOutcome.accepted => null,
  PendingIdentityAiOutcome.unavailable => t.video_scrape_pending_ai_unavailable,
  PendingIdentityAiOutcome.unassigned => t.video_scrape_pending_ai_unassigned,
  PendingIdentityAiOutcome.failed => t.video_scrape_pending_ai_failed,
  PendingIdentityAiOutcome.declined => t.video_scrape_pending_ai_declined,
};

/// 一条待确认条目的原因行（没有记录时如实说），带上次尝试时刻。
String describePendingIdentityEntry(PendingIdentityEntry entry) {
  final PendingIdentityCause? cause = entry.cause;
  final String reason = cause == null
      ? t.video_scrape_pending_record_missing
      : describePendingIdentityCause(
          cause,
          entry.aiOutcome,
          entry.candidateCount,
        );
  final DateTime? at = entry.lastAttemptAt;
  if (at == null) return reason;
  return '$reason\n${t.identity_pending_last_attempt(time: FushiTimeFormat.dateHourMinute(at))}';
}

/// 库页提醒条文案（按媒体）。
String pendingIdentityBannerText(
  PendingIdentityMediaKind kind,
  int count,
) => switch (kind) {
  PendingIdentityMediaKind.video => t.video_library_scrape_pending_banner(
    count: count,
  ),
  PendingIdentityMediaKind.book => t.identity_pending_banner_book(count: count),
  PendingIdentityMediaKind.manga => t.identity_pending_banner_manga(
    count: count,
  ),
  PendingIdentityMediaKind.game => t.identity_pending_banner_game(count: count),
};
