import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_episode_panel.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';

/// BUG-2520：播放器「选集」面板对多季合集要出季 chip，与合集详情页季 tab 同一
/// 分组真相源（文件名纯函数）。单季合集头部零变化。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  String label(String key) {
    final int? n = seasonNumberOfGroupKey(key);
    return n == null ? 'Extras' : 'Season $n';
  }

  // 全局序：S1E1, S1E2, PV, S2E1, S2E2（PV 混在中间，检验 chip 序与切片映射）。
  List<VideoEpisodeEntry> multiSeason() => <VideoEpisodeEntry>[
    VideoEpisodeEntry(
      title: 'S1E1',
      episodeNumber: 1,
      groupKey: collectionGroupKeyForFilename('Show S01E01.mkv'),
    ),
    VideoEpisodeEntry(
      title: 'S1E2',
      episodeNumber: 2,
      groupKey: collectionGroupKeyForFilename('Show S01E02.mkv'),
    ),
    VideoEpisodeEntry(
      title: 'PV',
      groupKey: collectionGroupKeyForFilename('Show PV.mkv'),
    ),
    VideoEpisodeEntry(
      title: 'S2E1',
      episodeNumber: 1,
      groupKey: collectionGroupKeyForFilename('Show S02E01.mkv'),
    ),
    VideoEpisodeEntry(
      title: 'S2E2',
      episodeNumber: 2,
      groupKey: collectionGroupKeyForFilename('Show S02E02.mkv'),
    ),
  ];

  Widget panel({
    required List<VideoEpisodeEntry> episodes,
    required int currentIndex,
    ValueChanged<int>? onTap,
  }) => wrap(
    VideoEpisodePanel(
      episodes: episodes,
      currentIndex: currentIndex,
      onTapEpisode: onTap ?? (_) {},
      onClose: () {},
      colorScheme: const ColorScheme.light(),
      title: 'Episodes',
      emptyHint: 'No episodes',
      seasonLabelOf: label,
    ),
  );

  Finder chip(String key) =>
      find.byKey(ValueKey<String>('video-episode-season-chip-$key'));
  Finder card(int globalIndex) =>
      find.byKey(ValueKey<String>('video-episode-card-$globalIndex'));

  testWidgets('single-season list renders no season chips', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      panel(
        episodes: <VideoEpisodeEntry>[
          for (int i = 1; i <= 3; i++)
            VideoEpisodeEntry(
              title: 'E$i',
              episodeNumber: i,
              groupKey: collectionGroupKeyForFilename('Show E0$i.mkv'),
            ),
        ],
        currentIndex: 0,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('video-episode-season-chips')),
      findsNothing,
    );
    expect(card(2), findsOneWidget);
  });

  testWidgets(
    'multi-season list shows season chips (season asc, extras last) and '
    'opens on the current episode\'s season',
    (WidgetTester tester) async {
      // 当前集 = S2E1（全局下标 3）→ 面板一开就停在第 2 季。
      await tester.pumpWidget(panel(episodes: multiSeason(), currentIndex: 3));

      expect(chip('s1'), findsOneWidget);
      expect(chip('s2'), findsOneWidget);
      expect(chip(kCollectionExtrasGroupKey), findsOneWidget);
      // chip 序：季升序、extras 殿后。
      expect(
        tester.getTopLeft(chip('s1')).dx,
        lessThan(tester.getTopLeft(chip('s2')).dx),
      );
      expect(
        tester.getTopLeft(chip('s2')).dx,
        lessThan(tester.getTopLeft(chip(kCollectionExtrasGroupKey)).dx),
      );
      expect(tester.widget<ChoiceChip>(chip('s2')).selected, isTrue);

      // 轨道只有第 2 季的卡片，且 key 仍是全局下标。
      expect(card(3), findsOneWidget);
      expect(card(4), findsOneWidget);
      expect(card(0), findsNothing);
      expect(card(2), findsNothing);
      expect(
        find.descendant(
          of: card(3),
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'switching season swaps the rail; tapping a card reports the global '
    'index; switching episode follows to its season',
    (WidgetTester tester) async {
      final List<int> tapped = <int>[];
      int current = 0;
      late StateSetter setOuter;
      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setOuter = setState;
              return VideoEpisodePanel(
                episodes: multiSeason(),
                currentIndex: current,
                onTapEpisode: tapped.add,
                onClose: () {},
                colorScheme: const ColorScheme.light(),
                title: 'Episodes',
                emptyHint: 'No episodes',
                seasonLabelOf: label,
              );
            },
          ),
        ),
      );
      expect(tester.widget<ChoiceChip>(chip('s1')).selected, isTrue);
      expect(card(0), findsOneWidget);

      await tester.tap(chip('s2'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip('s2')).selected, isTrue);
      expect(card(0), findsNothing);
      expect(card(4), findsOneWidget);

      await tester.tap(card(4));
      expect(tapped, <int>[4]);

      // 切到 PV·特典：顺位号从 01 数起（轨道内位置），而非全局下标 03。
      await tester.tap(chip(kCollectionExtrasGroupKey));
      await tester.pumpAndSettle();
      expect(card(2), findsOneWidget);
      expect(
        find.descendant(of: card(2), matching: find.text('01')),
        findsOneWidget,
      );

      // 页面换集到 S1E2（全局 1）→ chip 跟回第 1 季。
      setOuter(() => current = 1);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip('s1')).selected, isTrue);
      expect(card(1), findsOneWidget);
      expect(
        find.descendant(
          of: card(1),
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
    },
  );
}
