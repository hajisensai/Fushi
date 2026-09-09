import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('mobile library toolbar and resource filter sheet',
      (WidgetTester tester) async {
    final FlutterExceptionHandler? originalHandler = FlutterError.onError;
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      await enableFocusNavigation(tester);
      await seedReaderBook(tester);
      final FocusDriver driver = FocusDriver(tester);
      await showBooksTab(tester);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final Finder search =
          find.byKey(const ValueKey<String>('shelf_search_field'));
      final Finder settings =
          find.byKey(const ValueKey<String>('library_tag_settings'));
      expect(tester.getCenter(search).dy, tester.getCenter(settings).dy);
      final Finder sort = find.widgetWithIcon(IconButton, Icons.sort);
      final Finder select =
          find.widgetWithIcon(IconButton, Icons.checklist_outlined);
      expect(tester.getCenter(sort).dy, tester.getCenter(select).dy);
      expect(tester.getSize(select).height, greaterThanOrEqualTo(44));
      debugPrint(
          '[mobile-layout] search=${tester.getRect(search)} settings=${tester.getRect(settings)} sort=${tester.getRect(sort)}');
      final Finder header = find.byType(FushiPageHeader).first;
      final FushiPageHeader headerWidget =
          tester.widget<FushiPageHeader>(header);
      final double safeTop =
          tester.view.padding.top / tester.view.devicePixelRatio;
      final Rect headerBounds = tester.getRect(header);
      final Rect tabsBounds =
          tester.getRect(find.byWidget(headerWidget.titleWidget!));
      debugPrint(
          '[mobile-layout] safeTop=$safeTop header=$headerBounds tabs=$tabsBounds');
      expect(headerBounds.top, inInclusiveRange(safeTop, safeTop + 8));
      expect(tabsBounds.top - headerBounds.top, lessThanOrEqualTo(4));
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('mobile-book-library');

      HomePage.debugSelectTab!(HomeTab.downloads);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final Finder picker =
          find.byKey(const ValueKey<String>('downloads-resource-type-picker'));
      debugPrint(
          '[mobile-layout] resource picker visible=${picker.evaluate().length}');
      final Finder videoSegment = find.ancestor(
        of: find.descendant(of: picker, matching: find.text(t.nav_video)),
        matching: find.byType(TextButton),
      );
      expect(await driver.focusWidget(videoSegment), isTrue,
          reason: 'video resource segment must receive focus');
      await driver.activate();
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final Finder filters =
          find.byKey(const ValueKey<String>('video-discovery-open-filters'));
      debugPrint(
          '[mobile-layout] filters visible=${filters.evaluate().length}');
      expect(filters, findsOneWidget);
      await binding.takeScreenshot('mobile-video-resources');
      expect(await driver.focusWidget(filters), isTrue);
      await driver.activate();
      expect(find.byKey(const ValueKey<String>('video-discovery-filter-sheet')),
          findsOneWidget);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final Rect sheetBounds = tester.getRect(find.byKey(
        const ValueKey<String>('video-discovery-filter-sheet'),
      ));
      debugPrint('[mobile-layout] filterSheet=$sheetBounds');
      expect(
          sheetBounds.top,
          lessThan(
              tester.view.physicalSize.height / tester.view.devicePixelRatio));
      await binding.takeScreenshot('mobile-resource-filters');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
    } catch (error, stack) {
      debugPrint('[mobile-layout] FAILURE $error\n$stack');
      rethrow;
    } finally {
      FlutterError.onError = originalHandler;
    }
  });
}
