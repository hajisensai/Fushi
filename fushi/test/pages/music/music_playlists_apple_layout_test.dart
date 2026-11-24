// 音乐曲库「歌单」页签的 Cupertino 版（用户 2026-11-24「歌单页布局有问题」）：
// Apple 下是 Apple Music 资料库式分组列表——没有色块胶囊按钮，「新建歌单…」只出现
// 一次（本地段首行），「导入歌单文件…」是紧随其后的同几何动作行（焦点 + Enter 可达），
// 空段不叠空态插画与大按钮；列表不再自留顶部内边距（页头那档间距由大字页头统一给），
// 段头自带 FushiAppleMetrics.groupSpacing（iOS 档 22、macOS 档 20 × 缩放）。M3E 不变。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_playlists_layout.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';
import 'package:fushi/src/utils/components/fushi_apple_glyph_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

MusicPluginManager _noPlugins() => MusicPluginManager(
  rootDir: Directory(
    '${Directory.systemTemp.path}/fushi-music-playlists-apple-no-plugins',
  ),
  httpClientFactory: HttpClient.new,
  log: (_, _, _) {},
);

ThemeData _theme({required bool glass, required TargetPlatform platform}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      glassDesign: glass,
    ).copyWith(platform: platform);

/// 一份有一首歌（曲库非空）+ [playlists] 个本地歌单的库，打开音乐页切到「歌单」。
Future<void> _pumpLibrary(
  WidgetTester tester, {
  required bool glass,
  required List<String> playlists,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(tester.view.reset);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.runAsync(() async {
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          MusicTracksCompanion.insert(
            trackUid: 't1',
            path: '/m/t1.flac',
            title: 'Song t1',
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
    for (final String name in playlists) {
      await db.createMusicPlaylist(name, at: 1);
    }
  });
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(prefs.loadFromDb);
  final AppModel app = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db)
    ..wirePreferencesForTesting(prefs)
    ..wireMusicPluginManagerForTesting(_noPlugins());
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: _theme(glass: glass, platform: TargetPlatform.iOS),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: FushiGlassScope(
            child: const Scaffold(body: MusicLibraryPage()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 窄窗下页签行横滑：先滚到可见再点。
  final Finder tab = find.text(t.music_section_playlists).first;
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

const ValueKey<String> _appleList = ValueKey<String>(
  'music-library-playlists-apple',
);
const ValueKey<String> _newRow = ValueKey<String>('music_new_local_playlist');
const ValueKey<String> _importRow = ValueKey<String>(
  'music_import_local_playlist',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Apple：无色块胶囊、「新建歌单…」只一行、导入是同几何次行、列表不自留顶距', (
    WidgetTester tester,
  ) async {
    await _pumpLibrary(tester, glass: true, playlists: <String>['Mix A', 'B']);
    expect(find.byKey(_appleList), findsOneWidget);
    // 整页没有 M3E 色块按钮（段头 / 空态都不放胶囊）。
    expect(find.byType(FushiFilledButton), findsNothing);
    // 「新建歌单」字样全页只此一处，且是动作行。
    expect(find.text('${t.music_action_new_playlist}…'), findsOneWidget);
    expect(find.text(t.music_action_new_playlist), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(_newRow),
        matching: find.text('${t.music_action_new_playlist}…'),
      ),
      findsOneWidget,
    );
    // 导入歌单文件仍可达：紧跟在新建行下面的同高动作行。
    expect(find.byKey(_importRow), findsOneWidget);
    final Rect newRect = tester.getRect(find.byKey(_newRow));
    final Rect importRect = tester.getRect(find.byKey(_importRow));
    expect(importRect.top, newRect.bottom);
    expect(importRect.height, newRect.height);
    // 两个歌单是 Apple 实体行，行高与动作行一致。
    final Finder rows = find.byType(AppleMusicEntityRow);
    expect(rows, findsNWidgets(2));
    expect(tester.getRect(rows.first).height, newRect.height);
    // 行首方块与歌单封面同尺寸。
    final double cover =
        48 * FushiAppleMetrics.of(tester.element(find.byKey(_newRow))).scale;
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byKey(_newRow),
              matching: find.byWidgetPredicate(
                (Widget w) => w is SizedBox && w.width == cover,
              ),
            ),
          )
          .height,
      cover,
    );
    // 列表首行贴着列表视口顶：页签行到首段的间距只有大字页头统一给的那一档，
    // 不再有分区自己的 page padding + 段头 section 间距叠出来的空白。
    expect(newRect.top, tester.getRect(find.byKey(_appleList)).top);
    await _unmount(tester);
  });

  testWidgets('Apple：空的本地歌单只剩两条动作行，不叠空态文案与大按钮', (WidgetTester tester) async {
    await _pumpLibrary(tester, glass: true, playlists: const <String>[]);
    expect(find.byKey(_newRow), findsOneWidget);
    expect(find.byKey(_importRow), findsOneWidget);
    expect(find.text(t.music_playlists_empty), findsNothing);
    expect(find.byType(FushiFilledButton), findsNothing);
    await _unmount(tester);
  });

  testWidgets('Apple：焦点在「新建歌单…」上按 Enter 弹出命名对话框', (WidgetTester tester) async {
    await _pumpLibrary(tester, glass: true, playlists: const <String>[]);
    final BuildContext rowText = tester.element(
      find.descendant(
        of: find.byKey(_newRow),
        matching: find.text('${t.music_action_new_playlist}…'),
      ),
    );
    Focus.of(rowText).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t.music_action_playlist_name), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('M3E 不变：色块「新建歌单」「导入歌单文件」照旧，无 Apple 列表', (
    WidgetTester tester,
  ) async {
    await _pumpLibrary(tester, glass: false, playlists: <String>['Mix A']);
    expect(find.byKey(_appleList), findsNothing);
    expect(
      find.ancestor(
        of: find.text(t.music_action_new_playlist),
        matching: find.byType(FushiFilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text(t.music_action_import_playlist),
        matching: find.byType(FushiFilledButton),
      ),
      findsOneWidget,
    );
    expect(find.byType(AppleMusicEntityRow), findsNothing);
    await _unmount(tester);
  });

  // 段头自带分组间距：iOS 档 22，macOS 档 20 × fushiAppleMacScale（Windows 宽窗 1.15）。
  for (final (TargetPlatform platform, Size size, double spacing)
      in <(TargetPlatform, Size, double)>[
        (TargetPlatform.iOS, const Size(420, 800), 22),
        (TargetPlatform.windows, const Size(1200, 800), 20 * 1.15),
        (TargetPlatform.macOS, const Size(1200, 800), 20),
      ]) {
    testWidgets('段头上方 = groupSpacing（${platform.name}），动作是裸字形', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(glass: true, platform: platform),
          home: FushiGlassScope(
            child: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 100),
                  AppleMusicPlaylistsSectionHeader(
                    key: const ValueKey<String>('header'),
                    title: 'NetEase · My playlists',
                    actions: <Widget>[
                      FushiAppleGlyphButton(
                        icon: FushiIcons.refresh,
                        tooltip: 'Refresh',
                        onPressed: () {},
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder header = find.byKey(const ValueKey<String>('header'));
      final Rect row = tester.getRect(
        find.descendant(of: header, matching: find.byType(Row)).first,
      );
      expect(row.top - tester.getRect(header).top, closeTo(spacing, 0.001));
      expect(
        FushiAppleMetrics.of(tester.element(header)).groupSpacing,
        closeTo(spacing, 0.001),
      );
      // 标题与字形同一行竖直居中。
      final Rect title = tester.getRect(find.text('NetEase · My playlists'));
      final Rect glyph = tester.getRect(find.byType(FushiAppleGlyphButton));
      expect(title.center.dy, closeTo(glyph.center.dy, 0.5));
      expect(find.byType(FushiFilledButton), findsNothing);
    });
  }

  testWidgets('Apple 实体行的分隔线贴在行底、左端对齐文字', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(glass: true, platform: TargetPlatform.iOS),
        home: FushiGlassScope(
          child: Scaffold(
            body: Column(
              children: <Widget>[
                AppleMusicEntityRow(
                  key: const ValueKey<String>('row'),
                  title: 'Playlist',
                  subtitle: 'Me · 3 songs',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Rect row = tester.getRect(find.byKey(const ValueKey<String>('row')));
    final Rect line = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('row')),
        matching: find.byWidgetPredicate(
          (Widget w) => w is SizedBox && w.height == 0.5,
        ),
      ),
    );
    expect(line.bottom, row.bottom);
    expect(line.left, row.left + 48 + 11);
    expect(tester.getRect(find.text('Playlist')).left, line.left);
  });
}
