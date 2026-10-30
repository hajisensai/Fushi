import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_providers.dart';
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
              child: MusicLyricsProvidersBody(appModel: app),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('LRCLIB 固定在最前，无开关；插件按存储顺序列出', (WidgetTester tester) async {
    await build(
      tester,
      <InstalledMusicPlugin>[_plugin('a.one', 'One'), _plugin('b.two', 'Two')],
      stored: serializeLyricsProviders(const <LyricsProviderEntry>[
        LyricsProviderEntry(id: 'b.two', enabled: true),
        LyricsProviderEntry(id: 'a.one', enabled: false),
      ]),
    );
    final Finder lrclib = find.byKey(
      const ValueKey<String>('music-lyrics-provider-lrclib'),
    );
    expect(lrclib, findsOneWidget);
    expect(
      find.descendant(of: lrclib, matching: find.byType(Switch)),
      findsNothing,
    );
    expect(find.text(t.music_lyrics_providers_builtin_note), findsOneWidget);
    expect(
      tester.getTopLeft(lrclib).dy,
      lessThan(tester.getTopLeft(find.text('Two')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Two')).dy,
      lessThan(tester.getTopLeft(find.text('One')).dy),
    );
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('开关与上移 / 下移写入偏好', (WidgetTester tester) async {
    final AppModel app = await build(tester, <InstalledMusicPlugin>[
      _plugin('a.one', 'One'),
      _plugin('b.two', 'Two'),
    ]);
    // 新装插件默认启用，按已装顺序排列。
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(parseLyricsProviders(app.prefsRepo.musicLyricsProvidersRaw), const [
      LyricsProviderEntry(id: 'a.one', enabled: false),
      LyricsProviderEntry(id: 'b.two', enabled: true),
    ]);

    await tester.tap(
      find.byKey(const ValueKey<String>('music-lyrics-provider-down-a.one')),
    );
    await tester.pumpAndSettle();
    expect(parseLyricsProviders(app.prefsRepo.musicLyricsProvidersRaw), const [
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
    expect(
      parseLyricsProviders(
        app.prefsRepo.musicLyricsProvidersRaw,
      ).map((LyricsProviderEntry e) => e.id),
      <String>['a.one', 'b.two'],
    );
  });

  testWidgets('没有歌词插件：空态 + 安装按钮，LRCLIB 仍在', (WidgetTester tester) async {
    await build(tester, const <InstalledMusicPlugin>[]);
    expect(find.text(t.music_lyrics_providers_empty), findsOneWidget);
    expect(find.text(t.music_lyrics_providers_install_action), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-lyrics-provider-lrclib')),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsNothing);
  });
}
