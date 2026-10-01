/// 刮削运行记录里的一条 issue message → 用户可见文案。
///
/// 记录本身是自由文本，但 AI 的参与情况用固定前缀标记（`ai:matched` /
/// `ai:declined` / `ai:failed` / `ai:searched`，见
/// `video_scrape_ai_identity.dart`），这里把它翻成本地化的标题 + 理由；其它
/// message 原样返回。
library;

import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/utils.dart';

String describeVideoScrapeIssueMessage(String message) {
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
