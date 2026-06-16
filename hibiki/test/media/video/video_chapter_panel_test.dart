import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_chapter_panel.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('lists chapters with titles; tap reports the chapter (TODO-424)',
      (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.debugSetChaptersForTesting(<VideoChapter>[
      const VideoChapter(index: 0, title: 'Chapter 01', start: Duration.zero),
      const VideoChapter(
          index: 1, title: 'Chapter 02', start: Duration(seconds: 300)),
      const VideoChapter(
          index: 2, title: 'Chapter 03', start: Duration(seconds: 600)),
    ]);

    final List<VideoChapter> tapped = <VideoChapter>[];
    await tester.pumpWidget(wrap(
      VideoChapterPanel(
        controller: controller,
        currentIndex: 1,
        colorScheme: const ColorScheme.light(),
        emptyHint: 'No chapters',
        onTapChapter: tapped.add,
      ),
    ));

    expect(find.text('Chapter 01'), findsOneWidget);
    expect(find.text('Chapter 02'), findsOneWidget);
    expect(find.text('Chapter 03'), findsOneWidget);
    // 时间戳子标题：第二章 5:00、第三章 10:00。
    expect(find.text('5:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);

    await tester.tap(find.text('Chapter 03'));
    expect(tapped.length, 1);
    expect(tapped.single.index, 2);
  });

  testWidgets(
      'highlights the current chapter with a play_arrow trailing icon '
      '(TODO-424)', (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.debugSetChaptersForTesting(<VideoChapter>[
      const VideoChapter(index: 0, title: 'Intro', start: Duration.zero),
      const VideoChapter(
          index: 1, title: 'Body', start: Duration(seconds: 120)),
    ]);

    await tester.pumpWidget(wrap(
      VideoChapterPanel(
        controller: controller,
        currentIndex: 1,
        colorScheme: const ColorScheme.light(),
        emptyHint: 'No chapters',
        onTapChapter: (_) {},
      ),
    ));

    // 仅当前章（Body, index 1）有 play_arrow trailing 标记。
    final Finder bodyTile = find.ancestor(
      of: find.text('Body'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: bodyTile, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    final Finder introTile = find.ancestor(
      of: find.text('Intro'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: introTile, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
  });

  testWidgets('blank chapter title falls back to localized 「章节 N」 (TODO-424)',
      (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.debugSetChaptersForTesting(<VideoChapter>[
      const VideoChapter(index: 0, title: '', start: Duration.zero),
      const VideoChapter(index: 1, title: '   ', start: Duration(seconds: 60)),
    ]);

    await tester.pumpWidget(wrap(
      VideoChapterPanel(
        controller: controller,
        currentIndex: 0,
        colorScheme: const ColorScheme.light(),
        emptyHint: 'No chapters',
        onTapChapter: (_) {},
      ),
    ));

    // 空标题（含纯空白）回退成「Chapter 1」/「Chapter 2」（默认英文 i18n）。
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsOneWidget);
  });

  testWidgets('empty chapter list shows the empty hint (TODO-424)',
      (WidgetTester tester) async {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    // 不注入章节：chapters 为空。

    await tester.pumpWidget(wrap(
      VideoChapterPanel(
        controller: controller,
        currentIndex: -1,
        colorScheme: const ColorScheme.light(),
        emptyHint: 'No chapters here',
        onTapChapter: (_) {},
      ),
    ));

    expect(find.text('No chapters here'), findsOneWidget);
  });
}
