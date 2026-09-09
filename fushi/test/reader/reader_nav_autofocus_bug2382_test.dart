import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2382：移动端打开导航抽屉不再 autofocus 书内搜索框——软键盘一顶起来就把
/// 抽屉里本来是主角的章节目录压掉半屏，用户得先收键盘才能点章节。桌面端（有物理
/// 键盘、键盘不占屏）行为逐字不变。
class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel(FushiDatabase db) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

void main() {
  test('navigation sheet autofocuses search on desktop only', () {
    expect(
        readerNavigationAutofocusesSearch(
            navigationPresentation: true, desktop: true),
        isTrue);
    expect(
        readerNavigationAutofocusesSearch(
            navigationPresentation: true, desktop: false),
        isFalse,
        reason: '移动端导航抽屉 autofocus 会立刻顶起软键盘');
    // 外观 / 有声书面板两端都不聚焦搜索框（它们根本没有「搜索」这个动作）。
    expect(
        readerNavigationAutofocusesSearch(
            navigationPresentation: false, desktop: true),
        isFalse);
    expect(
        readerNavigationAutofocusesSearch(
            navigationPresentation: false, desktop: false),
        isFalse);
  });

  test('chrome wires autofocusSearch through the platform-aware predicate', () {
    final String chrome =
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync();
    expect(
        chrome, contains('autofocusSearch: readerNavigationAutofocusesSearch('),
        reason: '接线必须走判据，否则移动端又会恒 autofocus');
    expect(chrome, contains('desktop: isDesktopPlatform,'));
    expect(
        chrome,
        isNot(contains('autofocusSearch:\n'
            '          presentation == ReaderQuickSettingsPresentation.sideSheetNavigation')),
        reason: '旧的「导航形态即 autofocus」裸比较不得复活');
  });

  for (final bool autofocus in <bool>[false, true]) {
    testWidgets(
        'navigation sheet ${autofocus ? '' : 'does not '}raise the soft keyboard '
        'when autofocusSearch is $autofocus', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final AppModel model = _testAppModel(db);
      final ReaderSettings? previousSettings = ReaderFushiSource.readerSettings;
      ReaderFushiSource.readerSettings = ReaderSettings(db)
        ..applyPrefsSnapshot(const <String, String>{});
      addTearDown(() {
        ReaderFushiSource.readerSettings = previousSettings;
      });

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
                  epubBook:
                      EpubBook(title: '本', chapters: const <EpubChapter>[]),
                  onSearchJump: (_, __) async {},
                  readerProgress: const (1, 3),
                  onJumpSection: (_, __) async {},
                  onExitReader: () {},
                  webViewController: _FakeInAppWebViewController(),
                  appModel: model,
                  ref: ref,
                  isFushiReader: true,
                  presentation:
                      ReaderQuickSettingsPresentation.sideSheetNavigation,
                  autofocusSearch: autofocus,
                  onStyleChanged: () async {},
                  onThemeChanged: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // testTextInput.isVisible == 「引擎收到了 TextInput.show」，也就是真机上软
      // 键盘会不会顶起来——这正是用户报的现象，不是「焦点在哪」的代理指标。
      expect(tester.testTextInput.isVisible, autofocus);
    });
  }
}
