import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart';
import 'package:material_ui/material_ui.dart';

/// PR #3142 拍板：「已读章节变淡」同样作用到视频分集——已看完的集在详情页集卡
/// （[CollectionEpisodeCard]，本地合集 / 媒体服务器共用）与播放器选集轨道
/// （[VideoEpisodeRail]）里整体降到 [kMediaDetailCompletedOpacity]，与漫画章节
/// 已读行同一口径；状态（看完对勾 / 看到 mm:ss）不降，续播 / 正在播放的那一集
/// 不降。
void main() {
  double opacityOf(WidgetTester tester, Finder scope, String key) => tester
      .widget<AnimatedOpacity>(
        find.descendant(of: scope, matching: find.byKey(ValueKey<String>(key))),
      )
      .opacity;

  Widget cardHost({
    required bool completed,
    bool isContinue = false,
    int positionMs = 0,
  }) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            height: kCollectionEpisodeCardHeight,
            child: Builder(
              builder: (BuildContext context) => CollectionEpisodeCard(
                thumb: collectionEpisodeThumb(context, null),
                number: '1',
                title: 'Episode 1',
                summary: 'Summary',
                completed: completed,
                positionMs: positionMs,
                isContinue: isContinue,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  const List<String> dimmedKeys = <String>[
    'collection-episode-thumb',
    'collection-episode-number',
    'collection-episode-content',
    'collection-episode-summary',
  ];

  testWidgets('详情页集卡：已看完的集缩略图 / 集号 / 文字降透明度，状态行不降', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(cardHost(completed: true, positionMs: 60000));
    await tester.pumpAndSettle();
    final Finder card = find.byType(CollectionEpisodeCard);
    for (final String key in dimmedKeys) {
      expect(
        opacityOf(tester, card, key),
        kMediaDetailCompletedOpacity,
        reason: key,
      );
    }
    // 状态行（看完对勾 + 看到 mm:ss）不在任何降透明度子树里。
    final Finder status = find.byKey(
      const ValueKey<String>('collection-episode-status'),
    );
    expect(status, findsOneWidget);
    expect(
      find.ancestor(of: status, matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-episode-completed')),
      findsOneWidget,
    );
  });

  testWidgets('详情页集卡：未看完与续播的已看完集不降透明度', (WidgetTester tester) async {
    await tester.pumpWidget(cardHost(completed: false));
    await tester.pumpAndSettle();
    Finder card = find.byType(CollectionEpisodeCard);
    for (final String key in dimmedKeys) {
      expect(opacityOf(tester, card, key), 1.0, reason: key);
    }

    await tester.pumpWidget(cardHost(completed: true, isContinue: true));
    await tester.pumpAndSettle();
    card = find.byType(CollectionEpisodeCard);
    for (final String key in dimmedKeys) {
      expect(opacityOf(tester, card, key), 1.0, reason: 'continue $key');
    }
  });

  testWidgets('播放器选集轨道：已看完的集降透明度，正在播放与未看的集不降', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoEpisodeRail(
              episodes: const <VideoEpisodeEntry>[
                VideoEpisodeEntry(title: 'EP1', completed: true),
                VideoEpisodeEntry(title: 'EP2', completed: true),
                VideoEpisodeEntry(title: 'EP3'),
              ],
              currentIndex: 1,
              onTapEpisode: (int _) {},
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder cardOf(String title) => find
        .ancestor(of: find.text(title), matching: find.byType(InkWell))
        .first;

    for (final String key in <String>[
      'video-episode-rail-cover',
      'video-episode-rail-text',
    ]) {
      expect(
        opacityOf(tester, cardOf('EP1'), key),
        kMediaDetailCompletedOpacity,
        reason: 'EP1 $key',
      );
      // 正在播放的那一集即使看完也不降。
      expect(opacityOf(tester, cardOf('EP2'), key), 1.0, reason: 'EP2 $key');
      expect(opacityOf(tester, cardOf('EP3'), key), 1.0, reason: 'EP3 $key');
    }
  });
}
