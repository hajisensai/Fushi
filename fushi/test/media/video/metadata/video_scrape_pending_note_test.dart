import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_issue_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';

/// BUG-2828：挂起原因标记的编解码与本地化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));
  tearDown(() => LocaleSettings.setLocale(AppLocale.en));

  VideoScrapePendingNote note({
    VideoScrapePendingCause cause =
        VideoScrapePendingCause.awaitingConfirmation,
    VideoScrapeAiOutcome ai = VideoScrapeAiOutcome.declined,
    String key = 'book:D:/视频/リズと青い鳥 (2018)',
    String reason = '匹配结果存在歧义，需要人工确认：2 candidates\n第二行',
  }) => VideoScrapePendingNote(
    cause: cause,
    aiOutcome: ai,
    candidateCount: 2,
    workKey: key,
    reason: reason,
  );

  test('编码后能原样解回（含空格 / 非 ASCII 作品键与多行原因）', () {
    final VideoScrapePendingNote parsed = parseVideoScrapePendingNote(
      encodeVideoScrapePendingNote(note()),
    )!;
    expect(parsed.cause, VideoScrapePendingCause.awaitingConfirmation);
    expect(parsed.aiOutcome, VideoScrapeAiOutcome.declined);
    expect(parsed.candidateCount, 2);
    expect(parsed.workKey, 'book:D:/视频/リズと青い鳥 (2018)');
    expect(parsed.reason, '匹配结果存在歧义，需要人工确认：2 candidates\n第二行');
  });

  test('wire 值全覆盖且互不相同', () {
    for (final VideoScrapePendingCause cause
        in VideoScrapePendingCause.values) {
      for (final VideoScrapeAiOutcome ai in VideoScrapeAiOutcome.values) {
        final VideoScrapePendingNote? parsed = parseVideoScrapePendingNote(
          encodeVideoScrapePendingNote(note(cause: cause, ai: ai, reason: '')),
        );
        expect(parsed?.cause, cause);
        expect(parsed?.aiOutcome, ai);
        expect(parsed?.reason, '');
      }
    }
  });

  test('旧格式 / 其它 issue 不是挂起标记', () {
    expect(parseVideoScrapePendingNote('匹配结果存在歧义，需要人工确认'), isNull);
    expect(parseVideoScrapePendingNote('ai:matched confidence=0.9'), isNull);
    expect(
      parseVideoScrapePendingNote(
        'pending:bogus ai=declined candidates=1 key=a',
      ),
      isNull,
    );
  });

  test('每个作品键取最新一次运行的原因', () {
    final Map<String, VideoScrapePendingNote> latest =
        latestVideoScrapePendingNotes(<Iterable<String>>[
          <String>[
            encodeVideoScrapePendingNote(
              note(key: 'a', ai: VideoScrapeAiOutcome.unassigned),
            ),
            '无关 issue',
          ],
          <String>[
            encodeVideoScrapePendingNote(
              note(key: 'a', cause: VideoScrapePendingCause.notFound),
            ),
            encodeVideoScrapePendingNote(
              note(key: 'b', cause: VideoScrapePendingCause.dismissed),
            ),
          ],
        ]);
    expect(latest['a']!.aiOutcome, VideoScrapeAiOutcome.unassigned);
    expect(latest['a']!.cause, VideoScrapePendingCause.awaitingConfirmation);
    expect(latest['b']!.cause, VideoScrapePendingCause.dismissed);
  });

  test('运行记录详情把标记翻成「原因 · AI 结果」+ 原文', () {
    expect(
      describeVideoScrapeIssueMessage(encodeVideoScrapePendingNote(note())),
      '有 2 个候选，等你确认 · AI 判断不够确定\n'
      '匹配结果存在歧义，需要人工确认：2 candidates\n第二行',
    );
    expect(
      describeVideoScrapePendingNote(
        note(
          cause: VideoScrapePendingCause.notFound,
          ai: VideoScrapeAiOutcome.notAsked,
        ),
      ),
      '没有找到匹配',
    );
    expect(describeVideoScrapeIssueMessage('普通 issue'), '普通 issue');
  });
}
