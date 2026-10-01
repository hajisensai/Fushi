import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/media/video/metadata/video_scrape_issue_text.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 刮削运行记录里 `ai:*` 标记 → 用户可见文案（2026-10-01）。编码端与解码端
/// 在两个包里，任何一侧改了格式都会让 UI 退回显示原始 `ai:…` 字串。
void main() {
  test('ai:matched 译成「AI 匹配 · 置信度」+ 理由', () {
    final String message = encodeVideoScrapeAiIdentityNote(
      const AiVideoIdentityDecision(
        key: 'anidb:1',
        confidence: 0.93,
        reason: 'same year and studio',
      ),
    );
    expect(
      describeVideoScrapeIssueMessage(message),
      '${t.video_scrape_ai_matched} · '
      '${t.video_scrape_ai_confidence(percent: 93)}\nsame year and studio',
    );
  });

  test('ai:declined 译成「AI 未采用 · 置信度」+ 理由', () {
    final String message = encodeVideoScrapeAiDeclinedNote(
      const AiVideoIdentityDecision(
        key: null,
        confidence: 0.4,
        reason: 'two seasons share the title',
      ),
    );
    expect(
      describeVideoScrapeIssueMessage(message),
      '${t.video_scrape_ai_declined} · '
      '${t.video_scrape_ai_confidence(percent: 40)}\n'
      'two seasons share the title',
    );
  });

  test('ai:failed 只给失败标题（无置信度）+ 脱敏原因', () {
    final String described = describeVideoScrapeIssueMessage(
      encodeVideoScrapeAiFailedNote('timeout'),
    );
    expect(described, '${t.video_scrape_ai_failed}\ntimeout');
    expect(
      described,
      isNot(contains(t.video_scrape_ai_confidence(percent: 0))),
    );
  });

  test('ai:searched 给重搜标题 + AI 建议的搜索词', () {
    expect(
      describeVideoScrapeIssueMessage(
        encodeVideoScrapeAiSearchedNote(<String>['ドラえもん', 'Doraemon']),
      ),
      '${t.video_scrape_ai_searched}\nドラえもん / Doraemon',
    );
  });

  test('没有理由时只剩标题行', () {
    expect(
      describeVideoScrapeIssueMessage(encodeVideoScrapeAiFailedNote('  ')),
      t.video_scrape_ai_failed,
    );
    expect(
      describeVideoScrapeIssueMessage(
        encodeVideoScrapeAiIdentityNote(
          const AiVideoIdentityDecision(key: 'anidb:1', confidence: 0.9),
        ),
      ),
      '${t.video_scrape_ai_matched} · '
      '${t.video_scrape_ai_confidence(percent: 90)}',
    );
  });

  test('非 ai:* 的消息原样返回，缺置信度的打分标记也不误译', () {
    expect(describeVideoScrapeIssueMessage('No match found'), 'No match found');
    expect(
      describeVideoScrapeIssueMessage('ai:matched reason=x'),
      'ai:matched reason=x',
    );
  });
}
