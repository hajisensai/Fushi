import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'package:hibiki/src/media/video/video_favorite_sentences_panel.dart';
import 'package:hibiki/src/media/video/video_side_panel.dart';
import 'package:hibiki/utils.dart';

void main() {
  testWidgets('VideoTranslucentSidePanel keeps the video area visible',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              title: 'Speed',
              onClose: () {},
              child: const Text('1.5x'),
            ),
          ],
        ),
      ),
    );

    final Material material = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('Speed'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, isNotNull);
    expect(material.color!.a, lessThan(1));
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('1.5x'), findsOneWidget);
    // BUG-254：右上角 X 关闭按钮已删除（关闭改由页面层全屏 barrier 点面板外承载）。
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('VideoFavoriteSentencesPanel shows only the current episode',
      (WidgetTester tester) async {
    final List<FavoriteSentence> tapped = <FavoriteSentence>[];
    final FavoriteSentence current = FavoriteSentence(
      text: 'Current episode sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13),
      bookKey: 'video/show',
      sectionIndex: 1,
      normCharOffset: 12000,
      source: kFavoriteSentenceSourceVideo,
    );
    final FavoriteSentence other = FavoriteSentence(
      text: 'Other episode sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13),
      bookKey: 'video/show',
      sectionIndex: 2,
      normCharOffset: 24000,
      source: kFavoriteSentenceSourceVideo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/show',
            currentEpisode: 1,
            sentences: <FavoriteSentence>[current, other],
            onTapSentence: tapped.add,
          ),
        ),
      ),
    );

    expect(find.text('Current episode sentence'), findsOneWidget);
    expect(find.text('Other episode sentence'), findsNothing);

    await tester.tap(find.text('Current episode sentence'));
    expect(tapped, <FavoriteSentence>[current]);
  });

  testWidgets(
      'VideoFavoriteSentencesPanel isolates by bookKey across single videos '
      '(BUG-274)', (WidgetTester tester) async {
    // 用户场景：两个独立单集视频，都把收藏写在 sectionIndex == 0。仅按集号过滤
    // 会让 B 视频的句子混进 A 视频的「本集收藏」面板。
    final FavoriteSentence inThisVideo = FavoriteSentence(
      text: 'Sentence from this video',
      bookTitle: 'Movie A',
      createdAt: DateTime(2026, 6, 14),
      bookKey: 'video/movie-a',
      sectionIndex: 0,
      normCharOffset: 1000,
      source: kFavoriteSentenceSourceVideo,
    );
    final FavoriteSentence inOtherVideo = FavoriteSentence(
      text: 'Sentence from another video',
      bookTitle: 'Movie B',
      createdAt: DateTime(2026, 6, 14),
      bookKey: 'video/movie-b',
      sectionIndex: 0,
      normCharOffset: 2000,
      source: kFavoriteSentenceSourceVideo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/movie-a',
            currentEpisode: 0,
            sentences: <FavoriteSentence>[inThisVideo, inOtherVideo],
            onTapSentence: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Sentence from this video'), findsOneWidget);
    expect(
      find.text('Sentence from another video'),
      findsNothing,
      reason: '另一个视频的收藏句不得出现在当前视频的本集收藏面板里（BUG-274）',
    );
  });

  // ── TODO-357：收藏面板顶部加收藏数统计 header ──────────────────────────
  testWidgets(
      'VideoFavoriteSentencesPanel shows a count header for the current episode '
      '(TODO-357)', (WidgetTester tester) async {
    final List<FavoriteSentence> sentences = <FavoriteSentence>[
      for (int i = 0; i < 3; i++)
        FavoriteSentence(
          text: 'Sentence $i',
          bookTitle: 'Show',
          createdAt: DateTime(2026, 6, 13),
          bookKey: 'video/show',
          sectionIndex: 1,
          normCharOffset: 1000 * (i + 1),
          source: kFavoriteSentenceSourceVideo,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/show',
            currentEpisode: 1,
            sentences: sentences,
            onTapSentence: (_) {},
          ),
        ),
      ),
    );

    // 顶部 header 显示本集收藏数（3 句），文案走 i18n 的 video_favorite_sentences_count。
    expect(
      find.text(t.video_favorite_sentences_count(count: 3)),
      findsOneWidget,
      reason: '面板顶部应显示本集收藏数统计 header',
    );
    // header 在所有句子条目之上（最顶）。
    final double headerY = tester
        .getTopLeft(
          find.text(t.video_favorite_sentences_count(count: 3)),
        )
        .dy;
    final double firstSentenceY = tester.getTopLeft(find.text('Sentence 0')).dy;
    expect(headerY, lessThan(firstSentenceY), reason: '收藏数 header 必须在条目列表上方');
  });

  testWidgets(
      'VideoFavoriteSentencesPanel hides the count header when the episode is '
      'empty (TODO-357)', (WidgetTester tester) async {
    // 空状态只显示 emptyLabel，不叠加「0 句」header（避免文案重复）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/show',
            currentEpisode: 1,
            sentences: const <FavoriteSentence>[],
            onTapSentence: (_) {},
            emptyLabel: 'Empty',
          ),
        ),
      ),
    );

    expect(find.text('Empty'), findsOneWidget);
    expect(
      find.text(t.video_favorite_sentences_count(count: 0)),
      findsNothing,
      reason: '空状态不应显示收藏数 header',
    );
  });

  test('收藏数统计 i18n key 带 count 占位符（TODO-357）', () {
    // 英文模板含数量占位符 + 「episode」语义；zh-CN 翻译为「本集收藏 N 句」。
    expect(t.video_favorite_sentences_count(count: 5), contains('5'));
    expect(
      t.video_favorite_sentences_count(count: 5).toLowerCase(),
      contains('episode'),
    );
  });
}
