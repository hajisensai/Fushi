import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/glass_unwrap.dart';
import '../helpers/test_platform_services.dart';

/// 2026-10 阅读设置侧板：「歌词模式」专属分页——歌词模式下置首、按任务分三组、
/// 版式与边距默认折叠，「当前行高亮色」开关真写穿偏好并触发实时样式更新。
class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppModel> _testAppModel(WidgetTester tester, FushiDatabase db) async {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  // 查词页的 schema 项可见性读 prefsRepo：给一份真实偏好仓库。
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await tester.runAsync(prefsRepo.loadFromDb);
  final Directory tempDir = Directory.systemTemp.createTempSync('fushi_lyr_');
  final AppModel appModel = AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db)
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    await db.close();
  });
  return appModel;
}

void main() {
  testWidgets('歌词模式：歌词页置首、三组控件、版式默认折叠、高亮色写穿偏好', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final AppModel model = await _testAppModel(tester, db);
    final ReaderSettings? previous = ReaderFushiSource.readerSettings;
    ReaderFushiSource.readerSettings = ReaderSettings(db)
      ..applyPrefsSnapshot(const <String, String>{});
    addTearDown(() => ReaderFushiSource.readerSettings = previous);
    int styleChanges = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                    controller: null,
                    toc: const [],
                    readerProgress: const (1, 3),
                    onJumpSection: (_, __) async {},
                    onExitReader: () {},
                    webViewController: _FakeInAppWebViewController(),
                    appModel: model,
                    ref: ref,
                    isFushiReader: true,
                    lyricsMode: true,
                    onToggleLyricsMode: () {},
                    presentation:
                        ReaderQuickSettingsPresentation.sideSheetAppearance,
                    onStyleChanged: () async => styleChanges++,
                    onThemeChanged: () async {},
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final TabBar tabBar = tester.widget<TabBar>(
      glassUnwrap<TabBar>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('fushi_side_sheet_tabs')),
          matching: find.byType(TabBar),
        ),
      ),
    );
    expect(tabBar.controller!.index, 0);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('fushi_side_sheet_tabs')),
        matching: find.text(t.lyrics_mode),
      ),
      findsOneWidget,
      reason: '歌词模式下「歌词模式」页置首并默认选中',
    );
    expect(
      find.text(t.reader_panel_tab_layout),
      findsNothing,
      reason: '歌词页不读正文排版项',
    );

    // 模式切换行 + 三组。
    expect(
      find.byKey(const ValueKey<String>('fushi_lyrics_mode_toggle')),
      findsOneWidget,
    );
    expect(find.text(t.reader_panel_lyrics_section_text), findsOneWidget);
    expect(find.text(t.lyrics_font_size), findsOneWidget);
    expect(find.text(t.lyrics_text_color), findsOneWidget);
    expect(find.text(t.lyrics_highlight_color), findsOneWidget);
    expect(find.text(t.lyrics_blur), findsOneWidget);

    // 版式与边距默认折叠：边距行不入树，点标题展开。
    expect(find.text(t.margin_top), findsNothing);
    await tester.tap(find.text(t.reader_panel_lyrics_section_layout));
    await tester.pumpAndSettle();
    expect(find.text(t.margin_top), findsOneWidget);
    expect(find.text(t.lyrics_vertical_writing), findsOneWidget);

    // 当前行高亮色：开 = 写入不透明自定义色并触发实时样式更新；关 = 回哨兵 0。
    expect(ReaderFushiSource.instance.lyricsHighlightColor, 0);
    final Finder highlightSwitch = find.descendant(
      of: find.byKey(const ValueKey<String>('reader_lyrics_highlight_color')),
      matching: find.byWidgetPredicate((Widget w) => w is Switch),
    );
    await tester.ensureVisible(highlightSwitch.first);
    await tester.tap(highlightSwitch.first);
    await tester.pumpAndSettle();
    final int stored = ReaderFushiSource.instance.lyricsHighlightColor;
    expect(stored, isNot(0));
    expect(stored >>> 24, 0xFF, reason: '高亮色强制不透明');
    expect(styleChanges, greaterThan(0));

    await tester.tap(highlightSwitch.first);
    await tester.pumpAndSettle();
    expect(ReaderFushiSource.instance.lyricsHighlightColor, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书籍模式：没有有声书时不出歌词页，默认落「主题与字体」并有实时预览', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final AppModel model = await _testAppModel(tester, db);
    final ReaderSettings? previous = ReaderFushiSource.readerSettings;
    ReaderFushiSource.readerSettings = ReaderSettings(db)
      ..applyPrefsSnapshot(const <String, String>{});
    addTearDown(() => ReaderFushiSource.readerSettings = previous);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                    controller: null,
                    toc: const [],
                    readerProgress: const (1, 3),
                    onJumpSection: (_, __) async {},
                    onExitReader: () {},
                    webViewController: _FakeInAppWebViewController(),
                    appModel: model,
                    ref: ref,
                    isFushiReader: true,
                    onToggleLyricsMode: () {},
                    readerPaperColors: () => (
                      bg: const Color(0xFFF2E8D5),
                      fg: const Color(0xFF333333),
                    ),
                    presentation:
                        ReaderQuickSettingsPresentation.sideSheetAppearance,
                    onStyleChanged: () async {},
                    onThemeChanged: () async {},
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 没有有声书（controller null）且不在歌词模式：歌词页不出现。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('fushi_side_sheet_tabs')),
        matching: find.text(t.lyrics_mode),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reader_settings_preview')),
      findsOneWidget,
    );
    expect(find.text(t.reader_theme), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
