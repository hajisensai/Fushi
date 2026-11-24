// 音乐 Cupertino 浏览类页面（用户 2026-11-24「都要改 apple 风格啊，彩色渐变」）：
// 单服务器就地浏览按 `isGlassDesign` 分派到 Apple 版（分区胶囊、艺人圆形头像货架、
// 「热门歌曲」分页列、彩色渐变流派块），M3E 不变；分类块渐变按 id 稳定映射、深浅色
// 各取系统色；平封面卡 / 曲目行 / 骨架在不同 textScaler 与 macOS 档缩放下不溢出。

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoColors;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_recommend_widgets.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 一台能按统计浏览的服务器（Jellyfin 家族形态）：主页三项、流派、专辑 / 艺人。
class _DiscoveryServer implements MusicServerBrowser, MusicServerDiscovery {
  static const List<MusicServerAlbum> _albums = <MusicServerAlbum>[
    MusicServerAlbum(id: 'a1', title: 'Album One', artist: 'Artist A'),
    MusicServerAlbum(id: 'a2', title: 'Album Two', artist: 'Artist B'),
  ];

  static final List<MusicServerTrack> _tracks = <MusicServerTrack>[
    for (int i = 0; i < 9; i++)
      MusicServerTrack(
        id: 't$i',
        title: 'Track $i',
        artist: 'Artist A',
        album: 'Album One',
        durationMs: 200000,
      ),
  ];

  @override
  String get serverId => 'srv';

  @override
  String get displayName => 'Home Jellyfin';

  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async => const MusicServerPage<MusicServerAlbum>(items: _albums);

  @override
  Future<List<MusicServerArtist>> listArtists() async =>
      const <MusicServerArtist>[
        MusicServerArtist(id: 'r1', name: 'Artist A', albumCount: 2),
      ];

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async => const MusicServerPage<MusicServerPlaylist>(
    items: <MusicServerPlaylist>[],
  );

  @override
  Future<List<MusicServerGenre>> listGenres() async => const <MusicServerGenre>[
    MusicServerGenre(id: 'g-rock', name: 'Rock', albumCount: 3),
    MusicServerGenre(id: 'g-jazz', name: 'Jazz', trackCount: 12),
  ];

  @override
  Future<List<MusicServerAlbum>> recentlyAddedAlbums({int limit = 30}) async =>
      _albums;

  @override
  Future<MusicServerItems> mostPlayed({int limit = 30}) async =>
      MusicServerItems(
        tracks: _tracks,
        artists: const <MusicServerArtist>[
          MusicServerArtist(id: 'r1', name: 'Artist A'),
          MusicServerArtist(id: 'r2', name: 'Artist B'),
        ],
      );

  @override
  Future<MusicServerItems> recentlyPlayed({int limit = 30}) async =>
      const MusicServerItems();

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) => null;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  Widget body, {
  required bool glass,
  TargetPlatform platform = TargetPlatform.iOS,
  Size size = const Size(420, 2400),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
            textTheme: brightness == Brightness.dark
                ? Typography.material2021().white
                : Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: platform),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          home: FushiGlassScope(child: Scaffold(body: body)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey<String>(k), skipOffstage: false);

void main() {
  group('分类块渐变', () {
    test('同一个 id 每次落在同一组系统色上（FNV-1a，不靠 String.hashCode）', () {
      expect(appleMusicStableHash('rock'), 974867124);
      expect(appleMusicCategoryPairIndex('jazz'), 4);
      expect(
        appleMusicCategoryPairIndex('anime'),
        appleMusicCategoryPairIndex('anime'),
      );
      final Set<int> spread = <int>{
        for (final String s in <String>[
          'rock',
          'jazz',
          'anime',
          'classical',
          'all-works',
        ])
          appleMusicCategoryPairIndex(s),
      };
      expect(spread.length, greaterThanOrEqualTo(4));
    });

    testWidgets('浅色取系统色浅色值、深色取深色值；白色粗体标题', (WidgetTester tester) async {
      Future<LinearGradient> gradientIn(Brightness b) async {
        late LinearGradient g;
        await _pump(
          tester,
          Builder(
            builder: (BuildContext context) {
              g = appleMusicCategoryGradient(context, 'pop');
              return SizedBox(
                width: 160,
                height: 96,
                child: AppleMusicCategoryTile(
                  key: const ValueKey<String>('tile'),
                  label: 'Pop',
                  seed: 'pop',
                  icon: FushiIcons.tag,
                  onTap: () {},
                ),
              );
            },
          ),
          glass: true,
          brightness: b,
        );
        return g;
      }

      final LinearGradient light = await gradientIn(Brightness.light);
      // 'pop' → 第 0 组：systemPink → systemOrange。
      expect(light.colors, <Color>[
        CupertinoColors.systemPink.color,
        CupertinoColors.systemOrange.color,
      ]);
      final Text title = tester.widget<Text>(find.text('Pop'));
      expect(title.style?.color, Colors.white);
      expect(title.style?.fontWeight, FontWeight.w700);
      final LinearGradient dark = await gradientIn(Brightness.dark);
      expect(dark.colors, <Color>[
        CupertinoColors.systemPink.darkColor,
        CupertinoColors.systemOrange.darkColor,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('单服务器就地浏览分派', () {
    testWidgets('Cupertino：分区胶囊 + 主页 Apple 货架 / 艺人圆形头像 / 热门歌曲分页列', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        MusicServerBrowsePage(browser: _DiscoveryServer(), embedded: true),
        glass: true,
      );
      expect(find.byType(AppleMusicSourcePills), findsOneWidget);
      expect(_key('music-server-section-home'), findsOneWidget);
      expect(_key('music-server-section-genres'), findsOneWidget);
      expect(_key('music_server_search'), findsOneWidget);
      // 最近添加 = 平封面货架（Apple 段头），最常播放 = 分页列 + 艺人圆形头像货架。
      expect(find.byType(AppleMusicCoverShelfSection), findsWidgets);
      expect(_key('music-server-song-column-0'), findsOneWidget);
      expect(_key('music-server-home-most-artists'), findsOneWidget);
      final AppleMusicCoverShelfSection artists = tester
          .widget<AppleMusicCoverShelfSection>(
            _key('music-server-home-most-artists'),
          );
      expect(artists.circular, isTrue);
      expect(find.byType(AppleMusicSongRow), findsWidgets);
      expect(tester.takeException(), isNull);

      // 流派：彩色渐变分类块（带副行计数）。
      await tester.tap(_key('music-server-section-genres'));
      await tester.pumpAndSettle();
      expect(_key('music-server-genre-g-rock'), findsOneWidget);
      expect(
        tester.widget(_key('music-server-genre-g-rock')),
        isA<AppleMusicCategoryTile>(),
      );
      expect(find.byType(AppleMusicCategoryGrid), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('M3E：不出 Apple 胶囊 / Apple 货架（原样）', (WidgetTester tester) async {
      await _pump(
        tester,
        MusicServerBrowsePage(browser: _DiscoveryServer(), embedded: true),
        glass: false,
        platform: TargetPlatform.android,
      );
      expect(find.byType(AppleMusicSourcePills), findsNothing);
      expect(find.byType(AppleMusicCoverShelfSection), findsNothing);
      expect(find.byType(AppleMusicSongRow), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('不溢出（不同 textScaler / macOS 档缩放）', () {
    for (final (TargetPlatform platform, Size size) in <(TargetPlatform, Size)>[
      (TargetPlatform.iOS, const Size(420, 1600)),
      (TargetPlatform.windows, const Size(1300, 1600)),
    ]) {
      for (final double scale in <double>[1, 1.3, 2]) {
        testWidgets('${platform.name} ×$scale：货架卡 / 曲目分页列 / 骨架', (
          WidgetTester tester,
        ) async {
          await _pump(
            tester,
            ListView(
              children: <Widget>[
                AppleMusicCoverShelfSection(
                  title: 'Albums',
                  children: <Widget>[
                    for (int i = 0; i < 6; i++)
                      AppleMusicAutoCoverTile(
                        title: 'Album $i with a long title',
                        subtitle: 'Artist · 2024',
                        cover: null,
                        onTap: () {},
                      ),
                  ],
                ),
                AppleMusicSongColumns(
                  itemCount: 9,
                  rowBuilder: (BuildContext context, int i, bool separator) =>
                      AppleMusicSongRow(
                        title: 'Track $i',
                        subtitle: 'Artist · Album',
                        cover: null,
                        separator: separator,
                        durationText: '3:20',
                        onTap: () {},
                      ),
                ),
                // 别的页面按自己的度量定了高的货架：卡片让出封面边长装进去。
                SizedBox(
                  height: 190,
                  width: 160,
                  child: AppleMusicAutoCoverTile(
                    title: 'Squeezed',
                    subtitle: 'Artist',
                    cover: null,
                    onTap: () {},
                  ),
                ),
                const SizedBox(
                  height: 900,
                  child: AppleMusicRecommendSkeleton(),
                ),
              ],
            ),
            glass: true,
            platform: platform,
            size: size,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
