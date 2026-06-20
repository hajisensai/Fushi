import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_episode_panel.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  List<PlaylistEntry> episodes(int n) => <PlaylistEntry>[
        for (int i = 0; i < n; i++)
          PlaylistEntry(title: 'Episode ${i + 1}', path: '/v/$i.mp4'),
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
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('Episode 3'), findsOneWidget);

    await tester.tap(find.text('Episode 3'));
    expect(tapped, <int>[2]);
  });

  testWidgets(
      'highlights the current episode with a play_arrow leading icon '
      '(TODO-638)', (WidgetTester tester) async {
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

    // 仅当前集（Episode 2, index 1）有 play_arrow leading 标记。
    final Finder currentTile = find.ancestor(
      of: find.text('Episode 2'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: currentTile, matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
    );
    final Finder otherTile = find.ancestor(
      of: find.text('Episode 1'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: otherTile, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
    // 非当前集显示序号。
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
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
        episodes: const <PlaylistEntry>[],
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
}
