/// 刮削运行记录里的一条 issue message → 用户可见文案。
///
/// 记录本身是自由文本，但 AI 判定用固定前缀标记（见
/// `video_scrape_ai_identity_note.dart`），这里把它翻成本地化的
/// 「AI 判定 · 置信度 N%」+ 理由；其它 message 原样返回。
library;

import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/utils.dart';

String describeVideoScrapeIssueMessage(String message) {
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
