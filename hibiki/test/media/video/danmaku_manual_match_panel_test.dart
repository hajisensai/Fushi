import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/danmaku_manual_match_panel.dart';

DandanplaySearchResult _hitResult() => const DandanplaySearchResult(
      status: DandanplayFetchStatus.hit,
      animes: <DandanplaySearchAnime>[
        DandanplaySearchAnime(
          animeId: 1,
          animeTitle: 'Demo Show',
          typeDescription: 'TV',
          episodes: <DandanplaySearchEpisode>[
            DandanplaySearchEpisode(episodeId: 11, episodeTitle: 'Episode 01'),
            DandanplaySearchEpisode(episodeId: 12, episodeTitle: 'Episode 02'),
          ],
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 480, height: 600, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('search invokes onSearch with the keyword and renders episodes',
      (WidgetTester tester) async {
    String? searched;
    await _pump(
      tester,
      DanmakuManualMatchPanel(
        initialKeyword: 'demo',
        onSearch: (String keyword) async {
          searched = keyword;
          return _hitResult();
        },
        onEpisodeSelected: (_) async {},
      ),
    );

    expect(
        find.byKey(const Key('danmaku-manual-search-field')), findsOneWidget);
    await tester.tap(find.byKey(const Key('danmaku-manual-search-button')));
    await tester.pumpAndSettle();

    expect(searched, 'demo', reason: 'search must call the injected弹弹play回调');
    expect(find.text('Demo Show'), findsOneWidget);
    expect(find.text('Episode 01'), findsOneWidget);
    expect(find.text('Episode 02'), findsOneWidget);
  });

  testWidgets('selecting an episode reports it to onEpisodeSelected',
      (WidgetTester tester) async {
    DandanplaySearchEpisode? picked;
    await _pump(
      tester,
      DanmakuManualMatchPanel(
        initialKeyword: 'demo',
        onSearch: (String keyword) async => _hitResult(),
        onEpisodeSelected: (DandanplaySearchEpisode ep) async {
          picked = ep;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('danmaku-manual-search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Episode 02'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.episodeId, 12);
  });

  testWidgets('no-match result renders no episode list',
      (WidgetTester tester) async {
    await _pump(
      tester,
      DanmakuManualMatchPanel(
        initialKeyword: 'x',
        onSearch: (String keyword) async =>
            const DandanplaySearchResult(status: DandanplayFetchStatus.noMatch),
        onEpisodeSelected: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('danmaku-manual-search-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('danmaku-manual-results')), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });
}
