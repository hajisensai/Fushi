import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_providers.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

InstalledMusicPlugin _plugin(String id, String name) => InstalledMusicPlugin(
  id: id,
  enabled: true,
  info: MusicPluginPackageInfo(
    manifest: MusicPluginManifest(
      id: id,
      name: name,
      version: '1.0.0',
      api: 1,
      capabilities: const <String>['lyricsSearch', 'lyricsFetch'],
      searchTypes: const <String>[],
      permissions: const <String>['network'],
      networkDomains: const <String>['example.com'],
    ),
    digest: 'd',
    signer: null,
    files: const <String>[],
  ),
);

class _FakeManager extends MusicPluginManager {
  _FakeManager(this.plugins)
    : super(
        rootDir: Directory('${Directory.systemTemp.path}/fushi-lyr-prov-none'),
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
      );

  final List<InstalledMusicPlugin> plugins;

  @override
  Future<List<InstalledMusicPlugin>> list() async => plugins;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppModel> build(
    WidgetTester tester,
    List<InstalledMusicPlugin> plugins, {
    String? stored,
    bool canInstall = true,
  }) async {
    LocaleSettings.setLocale(AppLocale.en);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    if (stored != null) await prefs.setMusicLyricsProvidersRaw(stored);
    final Directory tmp = Directory.systemTemp.createTempSync('lyr_prov_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp)
      ..wireDatabaseForTesting(db)
      ..wireMusicPluginManagerForTesting(_FakeManager(plugins));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MusicLyricsProvidersBody(
                appModel: app,
                canInstall: canInstall,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  const ValueKey<String> lrclibKey = ValueKey<String>(
    'music-lyrics-provider-${MusicLyricsSource.lrclib}',
  );

  List<LyricsProviderEntry> stored(AppModel app) =>
      parseLyricsProviders(app.prefsRepo.musicLyricsProvidersRaw);

  testWidgets('LRCLIB 与插件同一列表：旧偏好（无 LRCLIB 项）补在最前，带开关', (
    WidgetTester tester,
  ) async {
    await build(
      tester,
      <InstalledMusicPlugin>[_plugin('a.one', 'One'), _plugin('b.two', 'Two')],
      stored: serializeLyricsProviders(const <LyricsProviderEntry>[
        LyricsProviderEntry(id: 'b.two', enabled: true),
        LyricsProviderEntry(id: 'a.one', enabled: false),
      ]),
    );
    final Finder lrclib = find.byKey(lrclibKey);
    expect(lrclib, findsOneWidget);
    expect(
      find.descendant(of: lrclib, matching: find.byType(Switch)),
      findsOneWidget,
    );
    expect(find.text('LRCLIB'), findsOneWidget);
    expect(find.text(t.music_lyrics_providers_builtin_note), findsOneWidget);
    expect(
      tester.getTopLeft(lrclib).dy,
      lessThan(tester.getTopLeft(find.text('Two')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Two')).dy,
      lessThan(tester.getTopLeft(find.text('One')).dy),
    );
    expect(find.byType(Switch), findsNWidgets(3));
  });

  testWidgets('LRCLIB 能和插件一起排序：下移后排在插件之后并写入偏好', (WidgetTester tester) async {
    // 反馈 h7d6Pa_g-7。
    final AppModel app = await build(tester, <InstalledMusicPlugin>[
      _plugin('a.one', 'One'),
    ]);
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'music-lyrics-provider-down-${MusicLyricsSource.lrclib}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(stored(app).map((LyricsProviderEntry e) => e.id), <String>[
      'a.one',
      MusicLyricsSource.lrclib,
    ]);
    expect(
      tester.getTopLeft(find.text('One')).dy,
      lessThan(tester.getTopLeft(find.byKey(lrclibKey)).dy),
    );

    // LRCLIB 也能停用。
    await tester.tap(
      find.descendant(of: find.byKey(lrclibKey), matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(stored(app), const <LyricsProviderEntry>[
      LyricsProviderEntry(id: 'a.one', enabled: true),
      LyricsProviderEntry(id: MusicLyricsSource.lrclib, enabled: false),
    ]);
  });

  testWidgets('开关与上移 / 下移写入偏好', (WidgetTester tester) async {
    final AppModel app = await build(tester, <InstalledMusicPlugin>[
      _plugin('a.one', 'One'),
      _plugin('b.two', 'Two'),
    ]);
    // 新装插件默认启用，按已装顺序排在 LRCLIB 之后。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('music-lyrics-provider-a.one')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(stored(app), const <LyricsProviderEntry>[
      LyricsProviderEntry(id: MusicLyricsSource.lrclib, enabled: true),
      LyricsProviderEntry(id: 'a.one', enabled: false),
      LyricsProviderEntry(id: 'b.two', enabled: true),
    ]);

    await tester.tap(
      find.byKey(const ValueKey<String>('music-lyrics-provider-down-a.one')),
    );
    await tester.pumpAndSettle();
    expect(stored(app), const <LyricsProviderEntry>[
      LyricsProviderEntry(id: MusicLyricsSource.lrclib, enabled: true),
      LyricsProviderEntry(id: 'b.two', enabled: true),
      LyricsProviderEntry(id: 'a.one', enabled: false),
    ]);
    expect(
      tester.getTopLeft(find.text('Two')).dy,
      lessThan(tester.getTopLeft(find.text('One')).dy),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('music-lyrics-provider-up-a.one')),
    );
    await tester.pumpAndSettle();
    expect(stored(app).map((LyricsProviderEntry e) => e.id), <String>[
      MusicLyricsSource.lrclib,
      'a.one',
      'b.two',
    ]);
  });

  testWidgets('没有歌词插件：空态 + 安装按钮，LRCLIB 仍在', (WidgetTester tester) async {
    await build(tester, const <InstalledMusicPlugin>[]);
    expect(find.text(t.music_lyrics_providers_empty), findsOneWidget);
    expect(find.text(t.music_lyrics_providers_install_action), findsOneWidget);
    expect(find.byKey(lrclibKey), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_provider_install_more')),
      findsNothing,
    );
  });

  testWidgets('已有歌词插件时仍保留安装入口', (WidgetTester tester) async {
    await build(tester, <InstalledMusicPlugin>[_plugin('a.one', 'One')]);
    expect(find.byType(Switch), findsNWidgets(2));
    final Finder more = find.byKey(
      const ValueKey<String>('music_lyrics_provider_install_more'),
    );
    expect(more, findsOneWidget);
    expect(
      find.descendant(
        of: more,
        matching: find.text(t.music_lyrics_providers_install_action),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('One')).dy,
      lessThan(tester.getTopLeft(more).dy),
    );
  });

  testWidgets('经互联中继用 host 插件（本机装不了）：能启停，不出安装入口', (WidgetTester tester) async {
    await build(tester, <InstalledMusicPlugin>[
      _plugin('a.one', 'One'),
    ], canInstall: false);
    expect(find.byType(Switch), findsNWidgets(2));
    expect(find.text(t.music_lyrics_providers_install_action), findsNothing);
  });

  testWidgets('中继端没有歌词插件：空态不带安装按钮', (WidgetTester tester) async {
    await build(tester, const <InstalledMusicPlugin>[], canInstall: false);
    expect(find.text(t.music_lyrics_providers_empty), findsOneWidget);
    expect(find.text(t.music_lyrics_providers_install_action), findsNothing);
  });

  group('安装确认框的隐私告知', () {
    Future<void> pumpDetails(
      WidgetTester tester,
      List<String> capabilities,
    ) async {
      LocaleSettings.setLocale(AppLocale.en);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MusicPluginPackageDetails(
                  info: MusicPluginPackageInfo(
                    manifest: MusicPluginManifest(
                      id: 'moe.example.lyrics',
                      name: 'Example',
                      version: '1.0.0',
                      api: 1,
                      capabilities: capabilities,
                      searchTypes: const <String>[],
                      permissions: const <String>['network'],
                      networkDomains: const <String>['lyric-api.example.com'],
                    ),
                    digest: 'd',
                    signer: null,
                    files: const <String>[],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('歌词来源插件：写明会发出曲目信息，并列出声明的域名', (WidgetTester tester) async {
      await pumpDetails(tester, const <String>['lyricsSearch', 'lyricsFetch']);
      expect(
        find.byKey(const ValueKey<String>('music-plugin-lyrics-privacy')),
        findsOneWidget,
      );
      expect(find.text(t.music_plugins_lyrics_privacy), findsOneWidget);
      expect(find.text('lyric-api.example.com'), findsOneWidget);
    });

    testWidgets('非歌词来源插件不显示这条告知', (WidgetTester tester) async {
      await pumpDetails(tester, const <String>['stream', 'lyrics']);
      expect(
        find.byKey(const ValueKey<String>('music-plugin-lyrics-privacy')),
        findsNothing,
      );
    });
  });

  test('选来源候选标题区分平台自带歌词与歌词插件', () {
    LocaleSettings.setLocale(AppLocale.en);
    expect(
      musicLyricsCandidateTitle(MusicLyricsSource.plugin('p'), 'p'),
      'p · ${t.music_plugins_cap_lyrics}',
    );
    expect(
      musicLyricsCandidateTitle(MusicLyricsSource.lyricsPlugin('p'), 'p'),
      'p · ${t.music_plugins_cap_lyrics_search}',
    );
    expect(
      musicLyricsCandidateTitle(MusicLyricsSource.lrclib, 'LRCLIB'),
      'LRCLIB',
    );
  });
}
