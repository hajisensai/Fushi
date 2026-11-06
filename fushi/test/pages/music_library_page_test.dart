import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_subtitle_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart'
    show kMusicSearchDebounce;
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart'
    show FushiIconButton;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_search.dart'
    show FushiSearchBar;

import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiFloatingTopBar;
import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show MusicCover;

import '../helpers/test_platform_services.dart';

MusicTracksCompanion _track(
  String uid,
  String album, {
  int? disc,
  int? no,
  int sampleRate = 96000,
  int bitDepth = 24,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Song $uid',
  albumUid: Value<String?>(album),
  artistCredit: const Value<String?>('Singer'),
  codec: const Value<String?>('flac'),
  isLossless: const Value<bool>(true),
  sampleRate: Value<int?>(sampleRate),
  bitDepth: Value<int?>(bitDepth),
  discNo: Value<int?>(disc),
  trackNo: Value<int?>(no),
  durationMs: const Value<int?>(185000),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

Future<FushiDatabase> _seed() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  await db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        _track('t1', 'al', disc: 1, no: 1),
        _track('t2', 'al', disc: 2, no: 1),
      ],
      albums: <MusicAlbumsCompanion>[
        MusicAlbumsCompanion.insert(
          albumUid: 'al',
          title: 'Night Album',
          albumArtistCredit: const Value<String?>('Singer'),
          addedAt: 1,
          updatedAt: 1,
        ),
      ],
      artists: <MusicArtistsCompanion>[
        MusicArtistsCompanion.insert(
          artistUid: 'ar',
          name: 'Singer',
          addedAt: 1,
        ),
      ],
      credits: <MusicTrackCreditsCompanion>[
        MusicTrackCreditsCompanion.insert(
          trackUid: 't1',
          artistUid: 'ar',
          role: 'artist',
          creditName: 'Singer',
        ),
      ],
    ),
  );
  return db;
}

Future<void> _pump(WidgetTester tester, AppModel app, Widget home) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((Ref ref) => app)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 没装任何插件的插件管理器：根目录不存在，列表恒空，不碰磁盘。
MusicPluginManager _noPlugins() => MusicPluginManager(
  rootDir: Directory(
    '${Directory.systemTemp.path}/fushi-music-library-test-no-plugins',
  ),
  httpClientFactory: HttpClient.new,
  log: (_, _, _) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('五个分区；专辑网格 → 歌曲 → 作品空态', (WidgetTester tester) async {
    // 顶栏与其它库页同一套浮动 chrome：动作组至少占半行，窄窗时页签在胶囊里
    // 横滑。给一个桌面宽度，五个页签都在可视区内直接点。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    await _pump(tester, app, const MusicLibraryPage());

    // 推荐页签只在装了带 `home` 能力的插件时出现，这里没有插件。
    for (final MusicLibrarySection s in MusicLibrarySection.values.where(
      (MusicLibrarySection s) => s != MusicLibrarySection.recommend,
    )) {
      expect(find.text(musicLibrarySectionLabel(s)), findsWidgets);
    }
    expect(find.text('Night Album'), findsOneWidget);
    expect(find.textContaining('FLAC 24/96'), findsOneWidget);

    await tester.tap(find.text(t.music_section_songs));
    await tester.pumpAndSettle();
    expect(find.text('Song t1'), findsOneWidget);
    expect(find.text('Song t2'), findsOneWidget);
    expect(find.text('3:05'), findsNWidgets(2));

    await tester.tap(find.text(t.music_section_works));
    await tester.pumpAndSettle();
    expect(find.text(t.music_works_empty), findsOneWidget);

    await tester.tap(find.text(t.music_section_artists));
    await tester.pumpAndSettle();
    expect(find.text('Singer'), findsOneWidget);

    // 没有推荐时一级只剩「曲库」一组：不画一级页签（分区全在二级胶囊里）。
    expect(find.text(t.music_library_tab), findsNothing);
    // 加文件夹 / 管理文件夹 / 加光盘不再占顶栏动作位，收在工具栏右端导入钮的
    // 菜单里（2026-10-30 库页两级页签）。
    for (final String key in <String>[
      'music_add_folder',
      'music_manage_sources',
      'music_add_disc',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsNothing);
    }
    final FushiIconButton importButton = tester.widget(
      find.byKey(const ValueKey<String>('music-library-view-import')),
    );
    expect(importButton.tooltip, t.library_view_import);
    expect(importButton.selected, isFalse, reason: '音乐没有导入页，导入钮恒不选中、点开是菜单');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('二级搜索页：输入筛本地、无匹配给空态、清空回提示', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    await _pump(tester, app, const MusicLibraryPage());
    await tester.tap(find.byKey(const ValueKey<String>('music_open_search')));
    await tester.pumpAndSettle();
    final Finder field = find.byKey(
      const ValueKey<String>('music-search-page-field'),
    );
    expect(field, findsOneWidget);
    // 查询为空：只给提示，不出结果。
    expect(
      find.byKey(const ValueKey<String>('music-search-page-overview')),
      findsNothing,
    );

    await tester.enterText(field, 'song t1');
    await tester.pumpAndSettle();
    expect(find.text('Song t1'), findsWidgets);
    expect(find.text('Song t2'), findsNothing);

    await tester.enterText(field, 'zzzz');
    // 先 pump 一帧让综合结果拿到新查询（防抖计时从这里起算），再推过防抖窗口：
    // 防抖结束前综合结果只转圈；动画关闭时 pumpAndSettle 不会替我们等计时器。
    await tester.pump();
    await tester.pump(kMusicSearchDebounce);
    await tester.pumpAndSettle();
    expect(find.text(t.music_library_search_empty), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('music-search-page-overview')),
      findsNothing,
    );
    expect(find.text(t.music_library_search_empty), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final Size size in const <Size>[Size(400, 860), Size(1424, 951)]) {
    testWidgets('宽窄屏同一套（${size.width.toInt()} 宽）：无常驻搜索框，右上角搜索按钮推入二级搜索页，'
        '返回后首页原样', (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FushiDatabase db = await _seed();
      addTearDown(db.close);
      final AppModel app = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireMusicPluginManagerForTesting(_noPlugins());
      await _pump(tester, app, const MusicLibraryPage());

      expect(find.byType(FushiSearchBar), findsNothing);
      final Finder open = find.byKey(
        const ValueKey<String>('music_open_search'),
      );
      expect(open, findsOneWidget);

      await tester.tap(open);
      await tester.pumpAndSettle();
      final Finder field = find.byKey(
        const ValueKey<String>('music-search-page-field'),
      );
      expect(field, findsOneWidget);
      // 自动聚焦：键盘 / 手柄直接能输入。
      final EditableText editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);

      await tester.enterText(field, 'song t1');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('music-search-page-overview')),
        findsOneWidget,
      );
      expect(find.text('Song t1'), findsWidgets);
      expect(find.text('Song t2'), findsNothing);

      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(open, findsOneWidget);
      expect(find.text('Night Album'), findsOneWidget);
      expect(find.byType(FushiSearchBar), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('空曲库显示添加文件夹入口', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    await _pump(tester, app, const MusicLibraryPage());
    expect(find.text(t.music_library_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_empty_add_folder')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('曲目列表：有没听完的断点的长曲目显示剩余时间 + 进度条；歌曲（< 8 分钟）不显示', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          MusicTracksCompanion.insert(
            trackUid: 'drama',
            path: '/m/drama.flac',
            title: 'Drama 1',
            durationMs: const Value<int?>(40 * 60000),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        ],
        albums: const <MusicAlbumsCompanion>[],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await db.upsertMusicResumePoint('drama', positionMs: 600000, updatedAt: 1);
    await db.upsertMusicResumePoint('t1', positionMs: 60000, updatedAt: 1);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wirePreferencesForTesting(prefs)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    await _pump(
      tester,
      app,
      MusicTrackListPage(
        title: 'Songs',
        tracks: snap.tracks,
        albums: <String, MusicAlbumRow>{
          for (final MusicAlbumRow a in snap.albums) a.albumUid: a,
        },
      ),
    );
    expect(find.text(t.music_track_remaining(time: '30:00')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-track-resume-drama')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music-track-resume-t1')),
      findsNothing,
      reason: '默认只给长曲目续播：3 分钟的歌不显示断点',
    );
    expect(find.text('3:05'), findsNWidgets(2));

    // 设置里切到「全部曲目」：已挂着的列表跟着切档，3 分钟的歌也显示断点。
    unawaited(app.setMusicResumeMode(MusicResumeMode.all));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '2:05')), findsOneWidget);
    // 切到「关」：点开会从头放，列表不再显示剩余时间。
    unawaited(app.setMusicResumeMode(MusicResumeMode.off));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '30:00')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('music-track-resume-drama')),
      findsNothing,
    );
    unawaited(app.setMusicResumeMode(MusicResumeMode.longTracks));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '30:00')), findsOneWidget);

    // 清掉断点：列表跟着断点表的改动重读。
    unawaited(app.musicSession.clearResumePoint('drama'));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '30:00')), findsNothing);
    expect(find.text('40:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('专辑页：碟片分组 + 格式徽章 + Hi-Res', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow album = snap.albums.single;
    await _pump(
      tester,
      app,
      MusicAlbumPage(album: album, tracks: snap.tracksOfAlbum(album.albumUid)),
    );
    expect(find.text(t.music_disc_label(n: 1)), findsOneWidget);
    expect(find.text(t.music_disc_label(n: 2)), findsOneWidget);
    expect(find.text('FLAC 24/96'), findsOneWidget);
    expect(find.text(t.music_hi_res_badge), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('专辑页逐碟曲目：有会被续播的断点的轨显示剩余时间 + 进度条，跟着断点改动与设置切档', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    await db.upsertMusicResumePoint('t2', positionMs: 60000, updatedAt: 1);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setMusicResumeMode(MusicResumeMode.all);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wirePreferencesForTesting(prefs)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow album = snap.albums.single;
    await _pump(
      tester,
      app,
      MusicAlbumPage(album: album, tracks: snap.tracksOfAlbum(album.albumUid)),
    );
    expect(find.text(t.music_track_remaining(time: '2:05')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-track-resume-t2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music-track-resume-t1')),
      findsNothing,
    );

    unawaited(app.setMusicResumeMode(MusicResumeMode.off));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '2:05')), findsNothing);
    unawaited(app.setMusicResumeMode(MusicResumeMode.all));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '2:05')), findsOneWidget);

    unawaited(app.musicSession.clearResumePoint('t2'));
    await tester.pumpAndSettle();
    expect(find.text(t.music_track_remaining(time: '2:05')), findsNothing);
    expect(find.text('3:05'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  // Feedback QAondMh4M5：专辑整张批量生成日语字幕；入口按本机转录能力 + 有本机文件门控。
  // 每个用例只挂一次页面（ProviderScope 卸载会 dispose AppModel）。
  for (final (String name, bool supported, bool localFiles, bool shown)
      in <(String, bool, bool, bool)>[
        ('本机能转录 + 本机文件：出', true, true, true),
        ('本机不能转录：不出', false, true, false),
        ('全是远端 / 插件曲目：不出', true, false, false),
      ]) {
    testWidgets('专辑页「为整张专辑生成字幕」：$name', (WidgetTester tester) async {
      final bool Function() gate = musicSubtitleAsrSupported;
      addTearDown(() => musicSubtitleAsrSupported = gate);
      musicSubtitleAsrSupported = () => supported;
      final FushiDatabase db = await _seed();
      addTearDown(db.close);
      final AppModel app = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireMusicPluginManagerForTesting(_noPlugins());
      final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
      final MusicAlbumRow album = snap.albums.single;
      final List<MusicTrackRow> tracks = <MusicTrackRow>[
        for (final MusicTrackRow r in snap.tracksOfAlbum(album.albumUid))
          r.copyWith(
            path: localFiles
                ? '${Directory.systemTemp.path}${Platform.pathSeparator}'
                      '${r.trackUid}.flac'
                : 'https://example.invalid/${r.trackUid}.flac',
          ),
      ];
      await _pump(tester, app, MusicAlbumPage(album: album, tracks: tracks));
      expect(
        find.byKey(const ValueKey<String>('music_album_generate_subtitles')),
        shown ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('专辑页 MD3：封面不被悬浮顶栏盖住（反馈 yglXWr9DTq）', (WidgetTester tester) async {
    final FushiDatabase db = await _seed();
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_noPlugins());
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow album = snap.albums.single;
    await _pump(
      tester,
      app,
      MusicAlbumPage(album: album, tracks: snap.tracksOfAlbum(album.albumUid)),
    );
    final Rect bar = tester.getRect(find.byType(FushiFloatingTopBar));
    final Rect cover = tester.getRect(find.byType(MusicCover).first);
    expect(bar.height, greaterThan(0));
    expect(
      cover.top,
      greaterThanOrEqualTo(bar.bottom),
      reason: '首项封面必须排在页头底边之下',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('迷你条互斥判据', () {
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: true,
        owner: MediaSessionOwner.audiobook,
      ),
      isFalse,
    );
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: true,
        owner: MediaSessionOwner.music,
      ),
      isTrue,
    );
    expect(
      musicBarVisible(
        musicActive: true,
        audiobookActive: false,
        owner: MediaSessionOwner.none,
      ),
      isTrue,
    );
    expect(
      musicBarVisible(
        musicActive: false,
        audiobookActive: false,
        owner: MediaSessionOwner.music,
      ),
      isFalse,
    );
  });
}
