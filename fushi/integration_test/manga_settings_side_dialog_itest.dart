/// Real Windows reader evidence using synthetic pages and keyboard navigation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/reader/reader_settings_side_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('漫画设置固定右侧、方向按钮与返回开头真实路径', (WidgetTester tester) async {
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);
    final bool focusBefore = appModel.experimentalFocusNavigationEnabled;
    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);
    final Directory bookDir = Directory.systemTemp.createTempSync(
      'manga_side_settings_',
    );
    final Directory images = Directory(p.join(bookDir.path, 'images'))
      ..createSync();
    const TestImageGenerator generator = TestImageGenerator();
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int index = 0; index < 8; index++) {
      final String filename = 'p${index.toString().padLeft(3, '0')}.png';
      File(p.join(images.path, filename)).writeAsBytesSync(
        generator.pngBytes(width: 800, height: 1200, seed: index + 1),
      );
      pages.add(<String, Object?>{
        'url': filename,
        'width': 800,
        'height': 1200,
        'blocks': <Object?>[],
      });
    }
    File(
      p.join(bookDir.path, 'manga.json'),
    ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
    final String bookKey =
        'side-settings-${DateTime.now().microsecondsSinceEpoch}';
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: '漫画の読書設定 — Desktop settings',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: pages.length,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    final EpubBookRow book = await (appModel.database.select(
      appModel.database.epubBooks,
    )..where((table) => table.bookKey.equals(bookKey))).getSingle();
    await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
      'ocrTrigger': 'manual',
      'direction': 'rtl',
      'mode': 'spread',
      'autoMode': false,
      'invertColors': false,
    });
    final bool floatingBefore = appModel.mangaChromeFloating;
    final String directionBefore = appModel.mangaReadingDirection;
    final String sideBefore =
        appModel.prefsRepo.getPref(
              kReaderSettingsPanelSidePref,
              defaultValue: 'right',
            )
            as String;
    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    bool readerOpen = false;

    Future<bool> focusControl(Finder target) => driver.focusUntil(() {
      final Set<Element> targets = target.evaluate().toSet();
      final BuildContext? focusedContext = driver.focused?.context;
      if (focusedContext == null || targets.isEmpty) return false;
      bool found = targets.contains(focusedContext);
      focusedContext.visitAncestorElements((Element ancestor) {
        if (targets.contains(ancestor)) found = true;
        return !found;
      });
      return found;
    });

    Future<void> activateKey(String key) async {
      expect(
        await focusControl(find.byKey(ValueKey<String>(key))),
        isTrue,
        reason: '$key must be keyboard reachable',
      );
      debugPrint(
        '[manga-settings] activate=$key focus=${driver.focused?.debugLabel}',
      );
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 400));
    }

    int currentPage() => tester
        .widget<MangaReaderBottomBar>(find.byType(MangaReaderBottomBar))
        .currentPage();

    Future<void> waitForPanel(Finder panel) async {
      for (
        int attempt = 0;
        attempt < 100 && panel.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        panel,
        findsOneWidget,
        reason:
            'Settings must appear after the database and WebView pause complete',
      );
    }

    // 关闭动画（180ms）结束后路由要到下一帧才离树：单帧 pump 会把「已关闭」
    // 误判成「没关」（早先几轮 Esc 断言失败就是这个时序假象）。
    Future<void> waitForPanelGone(Finder panel) async {
      for (
        int attempt = 0;
        attempt < 30 && panel.evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<Map<String, Object?>> savedOverrides() async {
      final MangaReaderOverrideRow? row = await appModel.database
          .getMangaReaderOverride(book.uid);
      return (jsonDecode(row!.overridesJson) as Map).cast<String, Object?>();
    }

    Future<Map<String, Object?>> domSnapshot() async {
      final dynamic reader = tester.state(find.byType(MangaFushiPage));
      final Object? raw = await reader.debugReaderDomSnapshot();
      expect(raw, isA<String>());
      return (jsonDecode(raw! as String) as Map).cast<String, Object?>();
    }

    try {
      await appModel.setMangaChromeFloating(false);
      // 小说阅读器把共用的换边偏好设成了左侧：漫画设置面板不认它，固定右侧。
      await appModel.prefsRepo.setPref(kReaderSettingsPanelSidePref, 'left');
      final BuildContext navContext = navigator.context;
      if (!navContext.mounted) fail('navigator context unmounted');
      unawaited(
        navigator.push(
          adaptivePageRoute<void>(
            context: navContext,
            builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
              child: MangaFushiPage(item: null, bookKey: bookKey),
            ),
          ),
        ),
      );
      readerOpen = true;
      final Finder content = find.byKey(
        const ValueKey<String>('manga_content_ready'),
      );
      for (
        int attempt = 0;
        attempt < 80 && content.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(content, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      final Rect contentBounds = tester.getRect(content);
      final Finder panel = find.byKey(
        const ValueKey<String>('fushi_reader_side_sheet'),
      );
      // 打开后什么都不做就按 Esc（焦点在面板第一个控件上）也必须能关。
      await activateKey('manga_reader_settings_button');
      await waitForPanel(panel);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitForPanelGone(panel);
      expect(panel, findsNothing, reason: 'Escape right after opening');
      await activateKey('manga_reader_settings_button');
      await waitForPanel(panel);
      final Rect rightBounds = tester.getRect(panel);
      expect(rightBounds.right, closeTo(contentBounds.right, 1));
      expect(rightBounds.width, lessThan(contentBounds.width));
      expect(
        (await captureFlutterFrame(tester, 'manga-settings-right')).saved,
        isTrue,
      );

      // 面板里没有换边按钮。
      expect(
        find.byKey(const ValueKey<String>('reader_settings_side_toggle')),
        findsNothing,
      );
      expect(
        await focusControl(
          find
              .ancestor(
                of: find.widgetWithText(Tab, t.manga_reader_filters),
                matching: find.byType(InkWell),
              )
              .first,
        ),
        isTrue,
      );
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        await focusControl(
          find.widgetWithText(
            AdaptiveSettingsSwitchRow,
            t.manga_reader_invert_colors,
          ),
        ),
        isTrue,
      );
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 500));
      expect((await savedOverrides())['invertColors'], true);
      expect((await domSnapshot())['filter'], contains('invert(1)'));
      expect(
        (await captureFlutterFrame(
          tester,
          'manga-settings-filters-live',
        )).saved,
        isTrue,
      );
      // 改设置会整窗重载正文（contentReady）：焦点不能被收回正文，Esc 仍归面板。
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<Material>()
            ?.key,
        const ValueKey<String>('fushi_reader_side_sheet'),
        reason: 'A live reload must not steal focus from the settings panel',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitForPanelGone(panel);
      expect(panel, findsNothing, reason: 'Escape after a live setting change');

      await activateKey('manga_reader_direction_button');
      expect((await savedOverrides())['direction'], 'ltr');
      expect((await domSnapshot())['direction'], 'ltr');
      expect(appModel.mangaReadingDirection, directionBefore);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('manga_reader_start_button')),
          matching: find.byIcon(Icons.first_page),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(seconds: 1));
      expect(currentPage(), greaterThan(0));
      final int advancedPage = currentPage();
      await activateKey('manga_reader_start_button');
      expect(currentPage(), 0);
      expect((await domSnapshot())['page'], '0');
      await activateKey('manga_reader_direction_button');
      expect((await savedOverrides())['direction'], 'rtl');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('manga_reader_start_button')),
          matching: find.byIcon(Icons.last_page),
        ),
        findsOneWidget,
      );
      expect(
        (await captureFlutterFrame(tester, 'manga-settings-start-rtl')).saved,
        isTrue,
      );
      debugPrint(
        '[manga-settings] content=$contentBounds right=$rightBounds '
        'advancedPage=$advancedPage restoredPage=${currentPage()}',
      );
    } finally {
      if (readerOpen) {
        navigator.popUntil((Route<dynamic> route) => route.isFirst);
        await tester.pump(const Duration(seconds: 1));
      }
      await appModel.setMangaChromeFloating(floatingBefore);
      await appModel.prefsRepo.setPref(
        kReaderSettingsPanelSidePref,
        sideBefore,
      );
      await appModel.setExperimentalFocusNavigationEnabled(focusBefore);
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    }
  });
}
