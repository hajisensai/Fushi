import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 决定台 2Z0ogo7v-Q（asmr.one 插件作者的反馈）：插件原生浏览——可点标签、带条件且按
/// hasMore 续载的列表（下一批失败保留已有结果、可重试）、条件栏增删条件 / 开关、推荐段
/// 「查看全部」带条件、专辑详情的结构化信息 / 曲目分组 / 关联作品。
///
/// 真页面（[MusicPluginBrowseListPage] / [MusicPluginCollectionPage] /
/// [MusicPluginRecommendView]），插件源换成固定数据并记下收到的条件。
const String _pluginId = 'asmr';

const MusicPluginTag _whisper = MusicPluginTag(
  facet: 'tag',
  id: '12',
  name: 'Whisper',
);

MusicPluginManifest _manifest() =>
    MusicPluginManifest.fromJson(<String, Object?>{
      'id': _pluginId,
      'name': 'ASMR',
      'version': '1.0.0',
      'api': 1,
      'capabilities': <String>['search', 'home', 'album', 'browse'],
    });

class _NoLikes implements MusicPluginLikeHost {
  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      const <MusicPluginManifest>[];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) async => null;

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) async {}
}

/// 插件源的固定数据与调用记录（每个 [MusicPluginSource] 实例共用一份）。
class _Log {
  final List<(MusicPluginBrowseQuery, int)> lists =
      <(MusicPluginBrowseQuery, int)>[];

  /// 第 1 页（0 起）先失败这么多次再成功。
  int failPage1 = 1;
}

class _Source extends MusicPluginSource {
  _Source(super.manager, super.pluginId, this.log);

  final _Log log;

  @override
  Future<List<MusicPluginHomeSection>> home({bool refresh = false}) async =>
      <MusicPluginHomeSection>[
        MusicPluginHomeSection(
          id: 'sub',
          title: 'Chinese with subtitles',
          kind: MusicPluginHomeKind.albums,
          items: const <Object>[MusicPluginAlbum(id: 'h1', title: 'H1')],
          more: const MusicPluginBrowseQuery(
            toggles: <String>{'subtitle'},
            choices: <String, String>{'lang': 'zh'},
          ),
        ),
      ];

  @override
  Future<MusicPluginBrowseSchema> browseSchema() async =>
      const MusicPluginBrowseSchema(
        facets: <MusicPluginBrowseOption>[
          MusicPluginBrowseOption(id: 'tag', label: 'Tags'),
        ],
        sorts: <MusicPluginBrowseOption>[
          MusicPluginBrowseOption(id: 'sales', label: 'Sales'),
        ],
        toggles: <MusicPluginBrowseOption>[
          MusicPluginBrowseOption(id: 'subtitle', label: 'Subtitled'),
        ],
      );

  @override
  Future<MusicPluginBrowseResult> browseList(
    MusicPluginBrowseQuery query, {
    int page = 0,
    int pageSize = 30,
  }) async {
    log.lists.add((query, page));
    if (page == 1 && log.failPage1 > 0) {
      log.failPage1--;
      throw MusicPluginException('boom', pluginId: pluginId);
    }
    return MusicPluginBrowseResult(
      kind: MusicPluginHomeKind.albums,
      items: <Object>[
        for (int i = 0; i < 3; i++)
          MusicPluginAlbum(
            id: 'p$page-$i',
            title: 'Work $page-$i',
            tags: const <MusicPluginTag>[_whisper],
          ),
      ],
      hasMore: page == 0,
    );
  }

  @override
  Future<({MusicPluginAlbum album, List<MusicPluginTrack> tracks})> album(
    String id,
  ) async => (
    album: MusicPluginAlbum(
      id: id,
      title: 'Album $id',
      code: 'RJ01000001',
      language: 'Chinese',
      durationMs: 3600000 + 25 * 60000,
      hasSubtitles: true,
      sourceUrl: 'https://asmr.example.com/work/$id',
      tags: <MusicPluginTag>[
        _whisper,
        for (int i = 0; i < 14; i++)
          MusicPluginTag(facet: 'tag', id: 'x$i', name: 'Tag $i'),
      ],
      related: const <MusicPluginRelatedAlbum>[
        MusicPluginRelatedAlbum(
          label: 'Original',
          album: MusicPluginAlbum(id: 'orig', title: 'Original work'),
        ),
      ],
    ),
    tracks: const <MusicPluginTrack>[
      MusicPluginTrack(id: 't1', title: 'Main 1', group: 'Main'),
      MusicPluginTrack(id: 't2', title: 'Ambient 1', group: 'Ambient'),
      MusicPluginTrack(id: 't3', title: 'Main 2', group: 'Main'),
    ],
  );
}

class _Manager extends MusicPluginManager {
  _Manager(Directory root)
    : super(
        rootDir: root,
        httpClientFactory: HttpClient.new,
        log: (String _, String __, String ___) {},
      );

  final _Log log = _Log();

  @override
  MusicPluginSource source(String id) => _Source(this, id, log);
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

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_plugin_browse_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(
      db: db,
      favorites: MusicPluginFavorites(_NoLikes()),
      manager: _Manager(dir),
      prefs: prefs,
      dir: dir,
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
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

  Finder work(String id) =>
      find.byKey(ValueKey<String>('music-plugin-album-$id'));

  testWidgets('列表按 hasMore 续载；下一批失败保留已有结果，点重试接着加载', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      MusicPluginBrowseListPage(
        manifest: _manifest(),
        initialQuery: const MusicPluginBrowseQuery(
          filters: <MusicPluginTag>[_whisper],
        ),
      ),
    );
    // 首屏不满一屏：首批到了就自动取下一批，第 1 页第一次失败。
    expect(work('p0-0'), findsOneWidget);
    expect(work('p0-2'), findsOneWidget);
    final Finder retry = find.byKey(
      const ValueKey<String>('music-plugin-browse-retry'),
    );
    expect(retry, findsOneWidget);
    expect(
      app.manager.log.lists.map(((MusicPluginBrowseQuery, int) e) => e.$2),
      <int>[0, 1],
    );
    expect(app.manager.log.lists.first.$1.filters, <MusicPluginTag>[_whisper]);

    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    expect(work('p0-0'), findsOneWidget, reason: '已有结果保留');
    expect(work('p1-0'), findsOneWidget);
    // 第 1 页 hasMore = false：不再请求。
    expect(
      app.manager.log.lists.map(((MusicPluginBrowseQuery, int) e) => e.$2),
      <int>[0, 1, 1],
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('条件栏：移除条件、打开开关都按新条件从第 0 页重取', (WidgetTester tester) async {
    app.manager.log.failPage1 = 0;
    await pump(
      tester,
      MusicPluginBrowseListPage(
        manifest: _manifest(),
        initialQuery: const MusicPluginBrowseQuery(
          filters: <MusicPluginTag>[_whisper],
        ),
      ),
    );
    // 条件 chip 带分类名（「分类: 值」走 i18n，英文界面用半角冒号）。
    expect(find.text('Tags: Whisper'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('music-plugin-browse-toggle-subtitle')),
    );
    await tester.pumpAndSettle();
    final (MusicPluginBrowseQuery, int) toggled = app.manager.log.lists
        .firstWhere(
          ((MusicPluginBrowseQuery, int) e) =>
              e.$1.toggles.contains('subtitle'),
        );
    expect(toggled.$2, 0);
    expect(toggled.$1.filters, <MusicPluginTag>[_whisper]);

    await tester.tap(
      find.byTooltip(t.music_plugin_browse_remove_filter(name: 'Whisper')),
    );
    await tester.pumpAndSettle();
    final (MusicPluginBrowseQuery, int) last = app.manager.log.lists.lastWhere(
      ((MusicPluginBrowseQuery, int) e) => e.$2 == 0,
    );
    expect(last.$1.filters, isEmpty);
    expect(last.$1.toggles, <String>{'subtitle'}, reason: '其余条件保留');
    expect(find.text('Tags: Whisper'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('作品行的可点标签进只带该条件的列表；返回后原列表还在', (WidgetTester tester) async {
    app.manager.log.failPage1 = 0;
    await pump(
      tester,
      MusicPluginBrowseListPage(
        manifest: _manifest(),
        initialQuery: const MusicPluginBrowseQuery(sort: 'sales'),
      ),
    );
    final Finder tag = find
        .descendant(
          of: work('p0-0'),
          matching: find.byKey(
            const ValueKey<String>('music-plugin-tag-tag-12'),
          ),
        )
        .first;
    await tester.tap(tag);
    await tester.pumpAndSettle();
    // 原列表页留在路由栈里（被新页盖住、在 offstage）。
    expect(
      find.byType(MusicPluginBrowseListPage, skipOffstage: false),
      findsNWidgets(2),
    );
    final (MusicPluginBrowseQuery, int) opened = app.manager.log.lists.last;
    expect(opened.$1.filters, <MusicPluginTag>[_whisper]);
    expect(opened.$1.sort, isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MusicPluginBrowseListPage), findsOneWidget);
    expect(work('p1-0'), findsOneWidget, reason: '返回后已加载的结果原样都在');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('专辑详情：结构化信息、可展开的全部标签、曲目分组、关联作品、原站链接', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      MusicPluginCollectionPage.album(
        manifest: _manifest(),
        album: const MusicPluginAlbum(id: 'RJ1', title: 'Album RJ1'),
      ),
    );
    expect(find.textContaining('RJ01000001'), findsWidgets);
    expect(find.textContaining('Chinese'), findsWidgets);
    expect(
      find.textContaining(t.music_plugin_album_subtitles_yes),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey<String>('music_plugin_album_open_source')),
      findsOneWidget,
    );

    // 15 个标签先露 12 个，展开后全部可见。
    expect(
      find.byKey(const ValueKey<String>('music-plugin-tag-tag-x13')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('music-plugin-tags-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('music-plugin-tag-tag-x13')),
      findsOneWidget,
    );

    final Finder scrollable = find.byType(Scrollable).first;
    Future<void> reveal(Finder f) async {
      await tester.scrollUntilVisible(f, 200, scrollable: scrollable);
      await tester.pumpAndSettle();
    }

    await reveal(
      find.byKey(const ValueKey<String>('music-plugin-track-group-Main')),
    );
    expect(
      find.byKey(const ValueKey<String>('music-plugin-track-group-Ambient')),
      findsOneWidget,
    );
    await reveal(
      find.byKey(const ValueKey<String>('music-plugin-related-orig')),
    );
    expect(find.textContaining('Original'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('推荐页：浏览入口在；段带条件时「查看全部」进保留条件的列表', (WidgetTester tester) async {
    app.manager.log.failPage1 = 0;
    await pump(
      tester,
      MusicPluginRecommendView(
        sources: <MusicPluginManifest>[_manifest()],
        showPersonal: false,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('music-plugin-browse-all-$_pluginId')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('music-plugin-browse-facet-$_pluginId-tag'),
      ),
      findsOneWidget,
    );
    final Finder viewAll = find.byKey(
      const ValueKey<String>('music-plugin-home-view-all-$_pluginId-sub'),
    );
    await tester.scrollUntilVisible(
      viewAll,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey<String>('music-plugin-recommend')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(viewAll);
    await tester.pumpAndSettle();
    await tester.tap(viewAll);
    await tester.pumpAndSettle();
    expect(find.byType(MusicPluginBrowseListPage), findsOneWidget);
    final MusicPluginBrowseQuery q = app.manager.log.lists.first.$1;
    expect(q.toggles, <String>{'subtitle'});
    expect(q.choices, <String, String>{'lang': 'zh'});
    expect(find.text('Chinese with subtitles'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
