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

  testWidgets('VideoTranslucentSidePanel mirrors rounded side on the left',
      (WidgetTester tester) async {
    Future<Material> pumpPanel(Alignment alignment) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 480,
            child: VideoTranslucentSidePanel(
              title: alignment == Alignment.centerLeft ? 'Left' : 'Right',
              alignment: alignment,
              child: const Text('Panel'),
            ),
          ),
        ),
      );
      return tester.widget<Material>(
        find
            .ancestor(
              of: find
                  .text(alignment == Alignment.centerLeft ? 'Left' : 'Right'),
              matching: find.byType(Material),
            )
            .first,
      );
    }

    final Material left = await pumpPanel(Alignment.centerLeft);
    expect(
      left.borderRadius,
      const BorderRadiusDirectional.horizontal(end: Radius.circular(8)),
      reason: '左侧面板贴左边，内侧应是右边圆角',
    );
    expect(tester.getTopLeft(find.byType(Material).last).dx, 10);

    final Material right = await pumpPanel(Alignment.centerRight);
    expect(
      right.borderRadius,
      const BorderRadiusDirectional.horizontal(start: Radius.circular(8)),
      reason: '右侧面板贴右边，内侧应是左边圆角',
    );
    expect(tester.getTopRight(find.byType(Material).last).dx, 790);
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
      'VideoFavoriteSentencesPanel orders sentences by subtitle time ascending '
      '(TODO-397)', (WidgetTester tester) async {
    // 输入顺序模拟 FavoriteSentenceRepository.getAll() 的「按添加时间倒序」：
    // 后收藏（createdAt 较晚）的句子排在前，但它的字幕时间（normCharOffset = cue.startMs）
    // 反而较早。面板默认排序必须改为按字幕时间升序，与播放进度一致。
    // 字幕时间靠后（00:30）的句子是最近收藏的 → getAll 的 createdAt 倒序把它排在前。
    // 若面板不重排，它就会先渲染，与「按字幕时间升序」相反，故能真正鉴别排序逻辑。
    final FavoriteSentence early = FavoriteSentence(
      text: 'Early cue at 00:05',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13), // 先添加 → getAll 排在后
      bookKey: 'video/show',
      sectionIndex: 1,
      normCharOffset: 5000,
      source: kFavoriteSentenceSourceVideo,
    );
    final FavoriteSentence late = FavoriteSentence(
      text: 'Late cue at 00:30',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 14), // 后添加 → getAll 排在前
      bookKey: 'video/show',
      sectionIndex: 1,
      normCharOffset: 30000,
      source: kFavoriteSentenceSourceVideo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/show',
            currentEpisode: 1,
            // 模拟 getAll 的 createdAt 倒序：late-added（晚字幕时间）排在前。
            sentences: <FavoriteSentence>[late, early],
            onTapSentence: (_) {},
          ),
        ),
      ),
    );

    final double earlyY = tester.getTopLeft(find.text('Early cue at 00:05')).dy;
    final double lateY = tester.getTopLeft(find.text('Late cue at 00:30')).dy;
    expect(
      earlyY,
      lessThan(lateY),
      reason: '字幕时间较早（normCharOffset 较小）的收藏句必须排在前面（TODO-397）',
    );
  });

  testWidgets(
      'VideoFavoriteSentencesPanel keeps null-timestamp sentences ahead of '
      'timed ones in default sort (TODO-397)', (WidgetTester tester) async {
    // 没有 cue 的视频收藏句 normCharOffset == null，排序时按 0 处理，落在最前。
    final FavoriteSentence noTime = FavoriteSentence(
      text: 'No timestamp sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 13),
      bookKey: 'video/show',
      sectionIndex: 1,
      normCharOffset: null,
      source: kFavoriteSentenceSourceVideo,
    );
    final FavoriteSentence timed = FavoriteSentence(
      text: 'Timed sentence',
      bookTitle: 'Show',
      createdAt: DateTime(2026, 6, 14),
      bookKey: 'video/show',
      sectionIndex: 1,
      normCharOffset: 8000,
      source: kFavoriteSentenceSourceVideo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoFavoriteSentencesPanel(
            currentBookKey: 'video/show',
            currentEpisode: 1,
            sentences: <FavoriteSentence>[timed, noTime],
            onTapSentence: (_) {},
          ),
        ),
      ),
    );

    final double noTimeY =
        tester.getTopLeft(find.text('No timestamp sentence')).dy;
    final double timedY = tester.getTopLeft(find.text('Timed sentence')).dy;
    expect(
      noTimeY,
      lessThan(timedY),
      reason: '无字幕时间的收藏句按 0 处理，应排在有时间的句子前面（TODO-397）',
    );
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

  // ── TODO-611：侧栏面板锁定按钮（仅收藏列表传 onToggleLock）─────────────
  testWidgets(
      'VideoTranslucentSidePanel shows no lock button when onToggleLock is null '
      '(non-lockable panels, TODO-611)', (WidgetTester tester) async {
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

    expect(find.byIcon(Icons.lock), findsNothing);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });

  testWidgets(
      'VideoTranslucentSidePanel renders a lock toggle when onToggleLock is set '
      'and reflects locked state (TODO-611)', (WidgetTester tester) async {
    Widget panel({required bool locked}) => MaterialApp(
          home: Stack(
            children: <Widget>[
              const ColoredBox(color: Colors.green),
              VideoTranslucentSidePanel(
                title: 'Favorites',
                onClose: () {},
                locked: locked,
                onToggleLock: () {},
                child: const Text('body'),
              ),
            ],
          ),
        );

    await tester.pumpWidget(panel(locked: false));
    expect(find.byIcon(Icons.lock_open), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);

    await tester.pumpWidget(panel(locked: true));
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });

  testWidgets(
      'VideoTranslucentSidePanel lock toggle fires onToggleLock (TODO-611)',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              title: 'Favorites',
              onClose: () {},
              locked: false,
              onToggleLock: () => toggles++,
              child: const Text('body'),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.lock_open));
    await tester.pump();
    expect(toggles, 1);
  });
}
