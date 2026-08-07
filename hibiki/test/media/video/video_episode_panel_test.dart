import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:fushi/src/media/video/video_episode_panel.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  List<VideoEpisodeEntry> episodes(
    int n, {
    ImageProvider? cover,
  }) =>
      <VideoEpisodeEntry>[
        for (int i = 0; i < n; i++)
          VideoEpisodeEntry(title: 'Episode ${i + 1}', cover: cover),
      ];

  testWidgets('lists episodes; tap reports the episode index (TODO-638)',
      (WidgetTester tester) async {
    final List<int> tapped = <int>[];
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        currentIndex: 1,
        onTapEpisode: tapped.add,
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    expect(find.text('Episode 1'), findsOneWidget);
    // 当前集同时出现在面板摘要与自己的卡片中。
    expect(find.text('Episode 2'), findsNWidgets(2));
    expect(find.text('Episode 3'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('video-episode-card-2')));
    expect(tapped, <int>[2]);
  });

  testWidgets(
      'highlights the current episode card with a play icon and keeps '
      'number labels on other cards', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(3),
        currentIndex: 1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    final Finder currentCard =
        find.byKey(const ValueKey<String>('video-episode-card-1'));
    expect(
      find.descendant(
          of: currentCard, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsOneWidget,
    );
    final Finder otherCard =
        find.byKey(const ValueKey<String>('video-episode-card-0'));
    expect(
      find.descendant(
          of: otherCard, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsNothing,
    );
    expect(find.text('01'), findsOneWidget);
    expect(find.text('03'), findsOneWidget);
  });

  testWidgets('header × button reports onClose (TODO-638)',
      (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(2),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () => closed++,
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    expect(find.text('Episodes'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, 1);
  });

  testWidgets('empty episode list shows the empty hint (TODO-638)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: const <VideoEpisodeEntry>[],
        currentIndex: -1,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes here',
      ),
    ));

    expect(find.text('No episodes here'), findsOneWidget);
  });

  testWidgets(
      'two-digit episode numbers stay single-line in the horizontal rail at '
      'large font', (WidgetTester tester) async {
    const double largeFontSize = 42; // 14 * appUiScale(3.0)
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(12),
        currentIndex: 0, // 当前集 0 用 play_arrow；序号从「2」起全是显式 Text。
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
        fontSize: largeFontSize,
      ),
    ));
    await tester.pumpAndSettle();

    final Finder tenText = find.text('10');
    await tester.scrollUntilVisible(tenText, 200,
        scrollable: find.byType(Scrollable));
    await tester.pumpAndSettle();

    expect(tenText, findsOneWidget);
    final Text tenWidget = tester.widget<Text>(tenText);
    expect(tenWidget.maxLines, 1);
    expect(tenWidget.softWrap, false);

    final Size tenSize = tester.getSize(tenText);
    expect(tenSize.height, lessThan(largeFontSize * 1.6),
        reason: 'episode number must render on a single line, not wrap');
  });

  testWidgets('renders a cover as the full 16:9 episode card background',
      (WidgetTester tester) async {
    final MemoryImage cover = MemoryImage(kTransparentImage);
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(2, cover: cover),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    final Finder firstCard =
        find.byKey(const ValueKey<String>('video-episode-card-0'));
    final Finder image =
        find.descendant(of: firstCard, matching: find.byType(Image));
    expect(image, findsOneWidget);
    expect(tester.widget<Image>(image).image, same(cover));
    expect(tester.getSize(firstCard).aspectRatio, closeTo(16 / 9, 0.01));
  });

  testWidgets('episode rail scrolls horizontally', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      VideoEpisodePanel(
        episodes: episodes(8),
        currentIndex: 0,
        onTapEpisode: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.light(),
        title: 'Episodes',
        emptyHint: 'No episodes',
      ),
    ));

    final ListView list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.horizontal);
  });
}
