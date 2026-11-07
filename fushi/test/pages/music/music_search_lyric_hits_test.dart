import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart';
import 'package:fushi_core/fushi_core.dart' show MusicTrackRow;
import 'package:fushi_corpus/fushi_corpus.dart'
    show CorpusHit, CorpusSourceKind;
import 'package:fushi_music/fushi_music.dart' show MusicPluginManifest;
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 曲库统一搜索的「歌词命中」段（Feedback QAondMh4M5「记得支持搜索」）：曲库歌词 / 生成
/// 字幕的全文命中单独一段，与插件结果互不等待；点一条把命中交给出处跳转；不在曲库的曲目
/// 不出。
MusicSearchLocalActions _noLocalActions() => MusicSearchLocalActions(
  albumCard: (BuildContext context, Object _) => const SizedBox.shrink(),
  openAlbum: (_) {},
  openArtist: (_) {},
);

CorpusHit _hit(String uid, int pos, String text) => CorpusHit(
  kind: CorpusSourceKind.music,
  key: uid,
  part: 0,
  title: 'Drama CD 1',
  section: 0,
  pos: pos,
  len: text.length,
  text: text,
  highlights: const <({int start, int length})>[(start: 0, length: 2)],
);

MusicTrackRow _track(String uid) => MusicTrackRow(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  isLossless: true,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: false,
  addedAt: 1,
);

Future<void> _pump(WidgetTester tester, Widget body) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      ),
    ),
  );
}

Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump(kMusicSearchDebounce + const Duration(milliseconds: 10));
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('歌词命中成段出现；点一条把命中（曲目 + 行时间）交给出处跳转', (WidgetTester tester) async {
    final List<String> queries = <String>[];
    final List<CorpusHit> opened = <CorpusHit>[];
    await _pump(
      tester,
      MusicSearchOverview(
        query: '台詞 ',
        sources: const <MusicPluginManifest>[],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
        onSeeAll: (_) {},
        searchLyrics: (String q) async {
          queries.add(q);
          return <CorpusHit>[_hit('uid-7', 65000, '台詞がここに')];
        },
        onLyricHit: (CorpusHit h) async => opened.add(h),
      ),
    );
    await _settleSearch(tester);

    expect(queries, <String>['台詞'], reason: '查询词去空白后只搜一次');
    expect(
      find.byKey(const ValueKey<String>('music-search-lyric-hits')),
      findsOneWidget,
    );
    expect(find.text(t.music_search_lyrics_hits), findsOneWidget);
    expect(find.text('Drama CD 1 · 1:05'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('music-search-lyric-hit-0')),
    );
    await tester.pump();
    expect(opened.single.key, 'uid-7');
    expect(opened.single.pos, 65000);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('没有歌词命中也没有别的结果：显示「无结果」；不传搜索不出歌词段', (WidgetTester tester) async {
    await _pump(
      tester,
      MusicSearchOverview(
        query: 'zzz',
        sources: const <MusicPluginManifest>[],
        local: MusicSearchLocalItems.none,
        localActions: _noLocalActions(),
        onSeeAll: (_) {},
        searchLyrics: (String q) async => const <CorpusHit>[],
      ),
    );
    await _settleSearch(tester);
    expect(find.text(t.music_library_search_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-search-lyric-hits')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('来源过滤排除本地后歌词命中清掉，放回本地后重取（查询词没变）', (WidgetTester tester) async {
    int calls = 0;
    Future<List<CorpusHit>> search(String q) async {
      calls++;
      return <CorpusHit>[_hit('uid-7', 65000, '台詞がここに')];
    }

    Widget overview(bool local) => MusicSearchOverview(
      query: '台詞',
      sources: const <MusicPluginManifest>[],
      local: MusicSearchLocalItems.none,
      localActions: _noLocalActions(),
      onSeeAll: (_) {},
      searchLyrics: local ? search : null,
    );
    final Finder section = find.byKey(
      const ValueKey<String>('music-search-lyric-hits'),
    );

    await _pump(tester, overview(true));
    await _settleSearch(tester);
    expect(section, findsOneWidget);
    expect(calls, 1);

    await _pump(tester, overview(false));
    await tester.pumpAndSettle();
    expect(section, findsNothing);

    await _pump(tester, overview(true));
    await tester.pumpAndSettle();
    expect(section, findsOneWidget);
    expect(calls, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('歌词命中只留仍在曲库里的曲目', () {
    final List<CorpusHit> hits = <CorpusHit>[
      _hit('live', 0, 'a'),
      _hit('gone', 0, 'b'),
    ];
    expect(
      musicLyricHitsInLibrary(hits, <MusicTrackRow>[
        _track('live'),
      ]).map((CorpusHit h) => h.key),
      <String>['live'],
    );
  });
}
