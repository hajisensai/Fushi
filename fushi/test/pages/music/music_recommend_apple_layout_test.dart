import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_recommend_widgets.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_sources_recommend.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show FushiCoverTint;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiRefreshIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// 音乐「推荐」（在线）Cupertino 重设计（方案 A，用户 2026-11-24 拍板）：
/// - 分派：Apple 主题走 Apple 布局，M3E 主题不变（段头刷新键、无 Apple 段头）；
/// - 「为你精选」= 主卡 + 我喜欢 + 私人电台；主卡整卡可点进「段落曲目」页（Q4）；
/// - 排行榜卡：全部带预览的榜单、每张前 3 名；歌曲分页列 4 行一列；
/// - 「全部」按来源分组（组头 + ⋯），单插件视图无组头、保留我喜欢 / 电台、无最近
///   播放（Q13）；
/// - 刷新：iOS 下拉、macOS 工具栏入口（[MusicRecommendRefreshHandle]）+ ⌘R；
/// - 最近播放：Apple 平封面无取色、M3E 仍取色（Q11）；
/// - 来源胶囊切换与回落「全部」；焦点 + Enter 起播。
const String _a = 'netease';
const String _b = 'asmr';

MusicPluginManifest _manifest(String id, String name) =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': id,
      'name': name,
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>['search', 'home', 'radio', 'like'],
    });

MusicPluginTrack _track(String id) =>
    MusicPluginTrack(id: id, title: 'Track $id', artists: const []);

MusicPluginPlaylist _chart(int i) => MusicPluginPlaylist(
  id: 'c$i',
  title: 'Chart $i',
  previewTracks: <MusicPluginTrack>[
    for (int k = 0; k < 4; k++) _track('c$i-$k'),
  ],
);

List<MusicPluginHomeSection> _sections() => <MusicPluginHomeSection>[
  MusicPluginHomeSection(
    id: 'daily',
    title: 'Daily picks',
    kind: MusicPluginHomeKind.tracks,
    items: <Object>[for (int i = 0; i < 5; i++) _track('h$i')],
  ),
  MusicPluginHomeSection(
    id: 'charts',
    title: 'Charts',
    kind: MusicPluginHomeKind.playlists,
    items: <Object>[for (int i = 0; i < 3; i++) _chart(i)],
  ),
  MusicPluginHomeSection(
    id: 'new-songs',
    title: 'New songs',
    kind: MusicPluginHomeKind.tracks,
    items: <Object>[for (int i = 0; i < 9; i++) _track('s$i')],
  ),
];

class _Likes implements MusicPluginLikeHost {
  _Likes(this.manifests);

  final List<MusicPluginManifest> manifests;

  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async => manifests;

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async =>
      const MusicPluginLikes(trackIds: <String>{});

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {}
}

class _Source extends MusicPluginSource {
  _Source(super.manager, super.pluginId, this.owner);

  final _Manager owner;

  @override
  Future<List<MusicPluginHomeSection>> home({bool refresh = false}) async {
    if (refresh) owner.refreshes++;
    return _sections();
  }
}

class _Manager extends MusicPluginManager {
  _Manager(Directory root)
    : super(
        rootDir: root,
        httpClientFactory: HttpClient.new,
        log: (String _, String __, String ___) {},
      );

  int refreshes = 0;

  @override
  MusicPluginSource source(String id) => _Source(this, id, this);
}

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async {}

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

class _AppModel extends AppModel {
  _AppModel({
    required this.db,
    required this.favorites,
    required this.manager,
    required PreferencesRepository prefs,
    required Directory dir,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
  }

  final FushiDatabase db;
  final MusicPluginFavorites favorites;
  final _Manager manager;
  final _Backend backend = _Backend();

  late final MusicSession _session = MusicSession(
    engine: MusicPlayerEngine(backendFactory: () => backend),
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
    favorites: favorites,
  );

  @override
  MusicSession get musicSession => _session;

  @override
  MusicPluginManager get musicPluginManager => manager;
}

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _AppModel app;
  final MusicPluginManifest ma = _manifest(_a, 'Netease');
  final MusicPluginManifest mb = _manifest(_b, 'ASMR');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_music_apple_rec_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(
      db: db,
      favorites: MusicPluginFavorites(_Likes(<MusicPluginManifest>[ma, mb])),
      manager: _Manager(dir),
      prefs: prefs,
      dir: dir,
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    Widget body, {
    required bool glass,
    TargetPlatform platform = TargetPlatform.iOS,
    Size size = const Size(420, 2400),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
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

  Finder key(String k) => find.byKey(ValueKey<String>(k), skipOffstage: false);

  Widget all({MusicRecommendRefreshHandle? handle}) => MusicPluginRecommendView(
    sources: <MusicPluginManifest>[ma, mb],
    refreshHandle: handle,
    trailing: (bool _) => const <Widget>[],
  );

  Widget single() => MusicPluginRecommendView(
    sources: <MusicPluginManifest>[ma],
    showPersonal: false,
  );

  group('分派', () {
    testWidgets('Apple 主题走 Apple 布局（精选 / Apple 段头），无 M3E 段头刷新键', (
      WidgetTester tester,
    ) async {
      await pump(tester, all(), glass: true);
      expect(key('music-top-picks'), findsOneWidget);
      expect(find.byType(AppleMusicSectionHeader), findsWidgets);
      expect(key('music-plugin-home-refresh-$_a'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('M3E 主题不变：段头刷新键在、没有 Apple 件', (WidgetTester tester) async {
      await pump(tester, all(), glass: false, platform: TargetPlatform.android);
      expect(key('music-plugin-home-refresh-$_a'), findsOneWidget);
      expect(key('music-top-picks'), findsNothing);
      expect(find.byType(AppleMusicSectionHeader), findsNothing);
      expect(find.byType(AppleMusicCarousel), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Apple 布局内容', () {
    testWidgets('为你精选 = 主卡 + 我喜欢 + 私人电台（每个插件）', (WidgetTester tester) async {
      await pump(tester, all(), glass: true, size: const Size(2400, 2400));
      final Finder picks = key('music-top-picks');
      for (final String id in <String>[_a, _b]) {
        for (final String k in <String>[
          'music-plugin-hero-$id-daily',
          'music-liked-$id',
          'music-plugin-radio-$id',
        ]) {
          expect(
            find.descendant(of: picks, matching: key(k)),
            findsOneWidget,
            reason: k,
          );
        }
      }
      // 主卡仍留 播放 / 随机。
      expect(key('music-plugin-hero-play-$_a'), findsOneWidget);
      expect(key('music-plugin-hero-shuffle-$_a'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('主卡整卡可点：推入「段落曲目」页，列出该段全部曲目', (WidgetTester tester) async {
      await pump(tester, single(), glass: true);
      await tester.tap(key('music-plugin-hero-$_a-daily'));
      await tester.pumpAndSettle();
      expect(key('music-plugin-section-tracks-$_a-daily'), findsOneWidget);
      for (int i = 0; i < 5; i++) {
        expect(key('music-plugin-track-h$i'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('排行榜：全部带预览的榜单各一张卡，每张只列前 3 名', (WidgetTester tester) async {
      await pump(tester, single(), glass: true, size: const Size(2400, 2400));
      for (int i = 0; i < 3; i++) {
        expect(key('music-plugin-rank-$_a-c$i'), findsOneWidget);
        expect(key('music-plugin-rank-row-c$i-2'), findsOneWidget);
        expect(key('music-plugin-rank-row-c$i-3'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('歌曲段 4 行一列横滑，段头有「播放」', (WidgetTester tester) async {
      await pump(tester, single(), glass: true, size: const Size(2400, 2400));
      expect(key('music-plugin-home-play-$_a-new-songs'), findsOneWidget);
      final Finder songs = key('music-plugin-home-$_a-new-songs');
      Finder column(int c) => find.descendant(
        of: songs,
        matching: key('music-plugin-song-column-$c'),
      );
      for (int i = 0; i < 4; i++) {
        expect(
          find.descendant(
            of: column(0),
            matching: key('music-plugin-track-s$i'),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: column(2), matching: key('music-plugin-track-s8')),
        findsOneWidget,
      );
      expect(column(3), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('「全部」按来源分组：组头 + ⋯（电台 / 刷新 / 来源设置）', (
      WidgetTester tester,
    ) async {
      await pump(tester, all(), glass: true);
      expect(key('music-plugin-group-$_a'), findsOneWidget);
      expect(key('music-plugin-group-$_b'), findsOneWidget);
      await tester.tap(key('music-plugin-group-more-$_a'));
      await tester.pumpAndSettle();
      expect(key('music-plugin-group-radio-$_a'), findsOneWidget);
      expect(key('music-plugin-home-refresh-$_a'), findsOneWidget);
      expect(
        key('music-plugin-group-settings-$_a'),
        isMusicPluginSourcesAvailable ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('单插件视图：无组头、无最近播放，仍有该插件的我喜欢与私人电台（Q13）', (
      WidgetTester tester,
    ) async {
      await pump(tester, single(), glass: true);
      expect(key('music-plugin-group-$_a'), findsNothing);
      expect(key('music-recent-plays'), findsNothing);
      expect(key('music-liked-$_a'), findsOneWidget);
      expect(key('music-plugin-radio-$_a'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('M3E 单插件视图行为不变：不出我喜欢', (WidgetTester tester) async {
      await pump(
        tester,
        single(),
        glass: false,
        platform: TargetPlatform.android,
      );
      expect(key('music-liked-$_a'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('刷新入口', () {
    testWidgets('iOS 档下拉刷新', (WidgetTester tester) async {
      await pump(tester, all(), glass: true);
      expect(find.byType(FushiRefreshIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('macOS 档无下拉刷新；工具栏入口（刷新句柄）重载全部来源', (WidgetTester tester) async {
      final MusicRecommendRefreshHandle handle = MusicRecommendRefreshHandle();
      addTearDown(handle.dispose);
      await pump(
        tester,
        all(handle: handle),
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1280, 2400),
      );
      expect(find.byType(FushiRefreshIndicator), findsNothing);
      expect(handle.available, isTrue);
      final int before = app.manager.refreshes;
      await handle.refresh();
      await tester.pumpAndSettle();
      expect(app.manager.refreshes, before + 2);
      // 刷新中旧内容留着：主卡一直在。
      expect(key('music-plugin-hero-$_a-daily'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(handle.available, isFalse);
    });

    testWidgets('焦点在推荐页内：Enter 起播该行，Ctrl/⌘ + R 刷新全部来源', (
      WidgetTester tester,
    ) async {
      await pump(tester, single(), glass: true, size: const Size(2400, 2400));
      Focus.of(tester.element(find.text('Track s1'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        app.musicSession.engine.current?.trackUid,
        musicPluginTrackUid(_a, 's1'),
      );
      final int before = app.manager.refreshes;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(app.manager.refreshes, before + 1);
      await app.musicSession.engine.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('最近播放取色（Q11）', () {
    Future<void> seedRecent() async {
      final MusicPlayItem item = musicPluginPlayItem(_a, _track('r1'));
      await db.startMusicPlayEvent(
        trackUid: item.trackUid,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        snapshot: musicPlayEventSnapshotOf(item, source: null),
      );
    }

    final String recentKey =
        'music-recent-track-${musicPluginTrackUid(_a, 'r1')}';

    testWidgets('Apple：平封面卡，不铺封面取色底', (WidgetTester tester) async {
      await seedRecent();
      await pump(tester, all(), glass: true);
      final Finder tile = key(recentKey);
      expect(tile, findsOneWidget);
      expect(tester.widget(tile), isA<AppleMusicCoverTile>());
      expect(
        find.ancestor(of: tile, matching: find.byType(FushiCoverTint)),
        findsNothing,
      );
      expect(
        find.descendant(of: tile, matching: find.byType(FushiCoverTint)),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('M3E：快捷格仍按封面取色', (WidgetTester tester) async {
      await seedRecent();
      await pump(tester, all(), glass: false, platform: TargetPlatform.android);
      final Finder tile = key(recentKey);
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(FushiCoverTint)),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('来源胶囊', () {
    testWidgets('Apple：胶囊行切来源，选中来源消失回落「全部」', (WidgetTester tester) async {
      Widget view(List<MusicOnlineSource> sources) =>
          MusicSourcesRecommendView(sources: sources, onSourcesChanged: () {});
      final MusicPluginOnlineSource sa = MusicPluginOnlineSource(ma);
      final MusicPluginOnlineSource sb = MusicPluginOnlineSource(mb);
      await pump(tester, view(<MusicOnlineSource>[sa, sb]), glass: true);
      final Finder pills = find.byType(AppleMusicSourcePills);
      expect(pills, findsOneWidget);
      expect(
        tester.widget<AppleMusicSourcePills>(pills).selected,
        kMusicRecommendAllSources,
      );
      expect(
        tester
            .widget<AppleMusicSourcePills>(pills)
            .pills
            .where((AppleMusicSourcePill p) => p.relayed),
        hasLength(isMusicPluginRelayClient ? 2 : 0),
      );

      await tester.tap(key('music-recommend-source-${sb.key}'));
      await tester.pumpAndSettle();
      expect(tester.widget<AppleMusicSourcePills>(pills).selected, sb.key);
      expect(key('music-recommend-${sb.key}'), findsOneWidget);

      await pump(tester, view(<MusicOnlineSource>[sa]), glass: true);
      expect(
        tester.widget<AppleMusicSourcePills>(pills).selected,
        kMusicRecommendAllSources,
      );
      expect(key('music-recommend-all'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('宿主持有时（页头大字行）Apple 也画胶囊；M3E 仍是页签', (WidgetTester tester) async {
      Widget tabs() => musicRecommendSourceTabs(
        sources: <MusicOnlineSource>[MusicPluginOnlineSource(ma)],
        selected: null,
        onSelect: (String? _) {},
      );
      await pump(tester, tabs(), glass: true);
      expect(find.byType(AppleMusicSourcePills), findsOneWidget);
      await pump(
        tester,
        tabs(),
        glass: false,
        platform: TargetPlatform.android,
      );
      expect(find.byType(AppleMusicSourcePills), findsNothing);
      expect(key('music-recommend-source-all'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('货架条目不溢出（高度出自同一份文字度量）', () {
    for (final (TargetPlatform platform, Size size) in <(TargetPlatform, Size)>[
      (TargetPlatform.iOS, const Size(420, 3200)),
      // Windows 桌面宽窗 = macOS 档 ×1.15（run7 报溢出的形态）。
      (TargetPlatform.windows, const Size(1300, 3200)),
      (TargetPlatform.macOS, const Size(1300, 3200)),
    ]) {
      for (final double scale in <double>[1, 1.3, 2]) {
        testWidgets('${platform.name} textScaler ×$scale：推荐页全部来源无溢出', (
          WidgetTester tester,
        ) async {
          await pump(
            tester,
            all(),
            glass: true,
            platform: platform,
            size: size,
            textScale: scale,
          );
          expect(key('music-top-picks'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
