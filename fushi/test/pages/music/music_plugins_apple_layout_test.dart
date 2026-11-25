// 音乐「在线 › 插件」的 Cupertino 版（用户 2026-11-24「音乐来源和插件排版还是有点怪，
// 看看和歌单一样吧」）：与曲库「歌单」同一套 Apple Music 资料库式列表——首行强调色
// 「从文件安装…」动作行、插件行（与封面同尺寸的图标方块 + 名称 + 版本 / id + 行尾
// Apple 开关，行高与歌单行一致），点行 / Enter 弹「权限 · 卸载」菜单；没有色块按钮。
// M3E 不变。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart' show buildFushiThemeData;
import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_list_layout.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSwitch;
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
        rootDir: Directory('${Directory.systemTemp.path}/fushi-plugins-apple'),
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
      );

  final List<InstalledMusicPlugin> plugins;

  @override
  Future<List<InstalledMusicPlugin>> listInstalled() async => plugins;

  @override
  Future<List<InstalledMusicPlugin>> list() async => plugins;
}

Future<void> _pump(
  WidgetTester tester,
  List<InstalledMusicPlugin> plugins, {
  required bool glass,
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  tester.view.devicePixelRatio = 1;
  // 测试字体每字等宽于字号：给足宽度让副行单行，行高按单行比。
  tester.view.physicalSize = const Size(1000, 900);
  addTearDown(tester.view.reset);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(prefs.loadFromDb);
  final AppModel app = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db)
    ..wirePreferencesForTesting(prefs)
    ..wireMusicPluginManagerForTesting(_FakeManager(plugins));
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: glass
            ? buildFushiThemeData(
                scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
                textTheme: Typography.material2021().black,
                glassDesign: true,
              ).copyWith(platform: TargetPlatform.iOS)
            : ThemeData(useMaterial3: true),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: SingleChildScrollView(
              child: MusicPluginSettingsBody(appModel: app),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const ValueKey<String> _install = ValueKey<String>('music_plugin_install');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Apple：首行「从文件安装…」动作行，插件行与歌单行同几何、行尾 Apple 开关', (
    WidgetTester tester,
  ) async {
    await _pump(tester, <InstalledMusicPlugin>[
      _plugin('p.one', 'One'),
      _plugin('p.two', 'Two'),
    ], glass: true);
    expect(find.byType(FushiFilledButton), findsNothing);
    final Finder install = find.byKey(_install);
    expect(install, findsOneWidget);
    expect(tester.widget(install), isA<AppleMusicListActionRow>());
    expect(
      find.descendant(
        of: install,
        matching: find.text('${t.music_plugins_install}…'),
      ),
      findsOneWidget,
    );
    final Finder rows = find.byType(AppleMusicListRow);
    expect(rows, findsNWidgets(2));
    // 安装行在最前，插件行紧随其后，三者同高。
    final Rect installRect = tester.getRect(install);
    final Rect first = tester.getRect(rows.first);
    expect(first.top, installRect.bottom);
    expect(first.height, installRect.height);
    // 行首方块与歌单封面同尺寸。
    final double cover = appleMusicRowCoverExtent(tester.element(rows.first));
    expect(
      tester
          .getSize(
            find.descendant(
              of: rows.first,
              matching: find.byType(AppleMusicListIconTile),
            ),
          )
          .width,
      cover,
    );
    expect(
      find.descendant(of: rows.first, matching: find.byType(FushiSwitch)),
      findsOneWidget,
    );
    // M3E 的「权限 / 卸载」文字按钮行不出现：都在行菜单里。
    expect(find.text(t.music_plugins_uninstall), findsNothing);
    expect(find.text(t.music_plugins_hint), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Apple：焦点在插件行上按 Enter 弹出「权限 · 卸载」菜单', (
    WidgetTester tester,
  ) async {
    await _pump(tester, <InstalledMusicPlugin>[
      _plugin('p.one', 'One'),
    ], glass: true);
    Focus.of(
      tester.element(
        find.descendant(
          of: find.byType(AppleMusicListRow),
          matching: find.text('One'),
        ),
      ),
    ).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t.music_plugins_uninstall), findsOneWidget);
    expect(find.text(t.music_plugins_permissions), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Apple：没装插件时只剩安装行 + 一行说明', (WidgetTester tester) async {
    await _pump(tester, const <InstalledMusicPlugin>[], glass: true);
    expect(find.byKey(_install), findsOneWidget);
    expect(find.byType(AppleMusicListRow), findsNothing);
    expect(find.textContaining(t.music_plugins_empty), findsOneWidget);
    expect(find.byType(FushiFilledButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('M3E 不变：色块「从文件安装」+ 行内「权限 / 卸载」', (WidgetTester tester) async {
    await _pump(tester, <InstalledMusicPlugin>[
      _plugin('p.one', 'One'),
    ], glass: false);
    expect(tester.widget(find.byKey(_install)), isA<FushiFilledButton>());
    expect(find.text(t.music_plugins_uninstall), findsOneWidget);
    expect(find.byType(AppleMusicListRow), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
