import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/card_source_origin.dart';
import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/media/music/music_mining_origin.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 「回到出处」L3（docs/specs/2026-10-24-cross-media-links.md §4）的跳转路由：
/// - 复习卡片的游戏来源链接经 [openCardSource] 落到游戏详情页；
/// - 收藏夹「制卡」里的游戏行点按同样落到游戏详情页（同一个出口）；
/// - 出处不在本机时不跳、不崩；
/// - 出处定位串（第几集 / 第几页 / 时间）与音乐出处写入 helper 的契约。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory pathProviderDir;

  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_origin_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<({AppModel app, FushiDatabase db})> buildModel() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir = Directory.systemTemp.createTempSync(
      'fushi_origin_',
    );
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db);
    await app.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'alpha',
        exePath: r'Z:\a\alpha.exe',
        workdir: r'Z:\a',
        addedAt: DateTime(2026, 1, 1),
        playStatus: GalgamePlayStatus.playing,
      ),
    ]);
    return (app: app, db: db);
  }

  group('复习卡片来源链接 → openCardSource', () {
    Future<WidgetRef> pumpHost(WidgetTester tester, AppModel app) async {
      late WidgetRef captured;
      FushiToast.navigatorKey = app.navigatorKey;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[appProvider.overrideWith((_) => app)],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: app.navigatorKey,
              home: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) {
                  captured = ref;
                  return const Scaffold(body: Text('review'));
                },
              ),
            ),
          ),
        ),
      );
      return captured;
    }

    testWidgets('游戏出处打开该游戏的详情页', (WidgetTester tester) async {
      final ({AppModel app, FushiDatabase db}) m = await buildModel();
      final WidgetRef ref = await pumpHost(tester, m.app);
      await tester.runAsync(
        () => openCardSource(
          ref: ref,
          link: CardSourceLink.tryGame(gameId: 'g1')!,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GalgameDetailPage), findsOneWidget);
      final GalgameDetailPage page = tester.widget(
        find.byType(GalgameDetailPage),
      );
      expect(page.gameId, 'g1');
    });

    testWidgets('游戏不在本机：不跳转、留在原页', (WidgetTester tester) async {
      final ({AppModel app, FushiDatabase db}) m = await buildModel();
      final WidgetRef ref = await pumpHost(tester, m.app);
      await tester.runAsync(
        () => openCardSource(
          ref: ref,
          link: CardSourceLink.tryGame(gameId: 'missing')!,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GalgameDetailPage), findsNothing);
      expect(find.text('review'), findsOneWidget);
    });
  });

  testWidgets('收藏夹「制卡」游戏行点按 → 游戏详情页', (WidgetTester tester) async {
    final ({AppModel app, FushiDatabase db}) m = await buildModel();
    await m.db.addMinedSentence(
      source: 'game',
      dateKey: '2026-10-24',
      expression: '台詞',
      sentence: 'ゲームの台詞です。',
      documentTitle: 'alpha',
      bookKey: 'g1',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => m.app)],
        child: TranslationProvider(
          child: const MaterialApp(home: CollectionsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ゲームの台詞です。'), findsOneWidget);
    // 来源前缀：游戏行不再宽松回退成书（无前缀）。
    expect(find.textContaining(t.nav_game), findsWidgets);

    await tester.tap(find.text('ゲームの台詞です。'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(GalgameDetailPage), findsOneWidget);
  });

  group('出处定位串', () {
    const String sourceId = '12345678-1234-4234-8234-123456789abc';

    test('漫画 = 第几页（1 起显示）；音乐 = 时间；书 / 游戏无定位', () {
      final CardSourceLink manga = CardSourceLink(
        kind: CardSourceKind.manga,
        uid: 'book_1',
        sourceId: sourceId,
        pageIndex: 11,
      );
      expect(cardSourceLocatorLabel(manga), t.card_source_origin_page(n: 12));
      final CardSourceLink music = CardSourceLink.tryMusic(
        trackUid: 'trk',
        startMs: 83000,
        endMs: 86000,
        sourceId: sourceId,
      )!;
      expect(cardSourceLocatorLabel(music), '1:23');
      expect(
        cardSourceLocatorLabel(CardSourceLink.tryGame(gameId: 'g1')!),
        isNull,
      );
    });

    test('视频只在多集播放列表里标「第几集」', () {
      final CardSourceLink video = CardSourceLink(
        kind: CardSourceKind.video,
        uid: 'video/stream/yt:abc',
        sourceId: sourceId,
        episodeIndex: 2,
        startMs: 3723000,
        endMs: 3725000,
      );
      expect(cardSourceLocatorLabel(video), '1:02:03');
      expect(
        cardSourceLocatorLabel(video, playlistEpisodes: 12),
        '${t.card_source_origin_episode(n: 3)} · 1:02:03',
      );
    });

    test('笔记字段里取第一个来源链接', () {
      final String html = CardSourceLink.tryGame(
        gameId: 'g1',
        sourceId: sourceId,
      )!.toHtml(label: 'alpha');
      final CardSourceLink? link = cardSourceLinkOfFields(<String>[
        '<b>no link</b>',
        html,
      ]);
      expect(link?.kind, CardSourceKind.game);
      expect(cardSourceLinkOfFields(<String>['plain']), isNull);
    });
  });

  group('音乐出处写入 helper（供音乐歌词制卡调用）', () {
    test('recordMusicMinedSentence 写 music 来源 + 曲目时间轴', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await recordMusicMinedSentence(
        db: db,
        trackUid: 'trk-1',
        dateKey: '2026-10-24',
        lineStartMs: 61000,
        lineEndMs: 64500,
        trackTitle: ' 歌 ',
        artist: 'Singer',
        expression: '歌',
        sentence: '歌を歌う',
      );
      final MinedSentenceRow row = (await db.getAllMinedSentences()).single;
      expect(row.source, 'music');
      expect(row.bookKey, 'trk-1');
      expect(row.positionMs, 61000);
      expect(row.durationMs, 3500);
      expect(row.normCharOffset, isNull);
      expect(row.documentTitle, '歌');
      expect(row.chapterLabel, 'Singer');
    });

    test('musicCardSourceLink：缺结束时刻按零长区间', () {
      final CardSourceLink link = musicCardSourceLink(
        trackUid: 'trk-1',
        lineStartMs: 5000,
      )!;
      expect(link.kind, CardSourceKind.music);
      expect(link.startMs, 5000);
      expect(link.endMs, 5000);
    });
  });
}
