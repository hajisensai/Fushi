import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comprehensive import flow seeds dictionary font and book',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[comprehensive-imports] ${details.exceptionAsString()}');
    };
    List<Map<String, dynamic>>? originalCustomFonts;

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final FocusDriver driver = FocusDriver(tester);

      final bool dictSeeded = await seedDictionary(tester);
      expect(dictSeeded, isTrue, reason: 'dictionary fixture must import');

      final String bookKey = await seedReaderBook(tester);
      expect(bookKey, isNotEmpty);
      expect(findBookEntries(), findsWidgets);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      originalCustomFonts = ReaderHibikiSource.instance.customFonts
          .where((Map<String, dynamic> font) {
        return font['name'] != 'Comprehensive Test Font';
      }).toList();
      final Directory fontDir =
          Directory('${appModel.appDirectory.path}/custom_fonts')
            ..createSync(recursive: true);
      final File fontFile = File('${fontDir.path}/comprehensive-test-font.ttf');
      await fontFile.writeAsBytes(await _loadSystemFontBytes(), flush: true);

      await ReaderHibikiSource.instance.setCustomFonts(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Comprehensive Test Font',
          'path': fontFile.path,
          'enabled': true,
        },
      ]);
      final ({String fontFamily, String fontFaces}) css =
          ReaderHibikiSource.instance.buildCustomFontCss();
      expect(css.fontFamily, contains('Comprehensive Test Font'));
      expect(css.fontFaces, contains('@font-face'));

      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(2));
      final bool focusedDict = await driver.focusWidget(navTargets[1]);
      expect(focusedDict, isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 2));
      await tester.enterText(findSearchField(), 'testword');
      await tester.pump(const Duration(seconds: 5));
      expect(findDictionaryResultEvidence(), findsWidgets);

      await takeScreenshot(binding, 'comprehensive_imports_result');
      assertStrictErrors(errors);
    } finally {
      if (originalCustomFonts != null) {
        await ReaderHibikiSource.instance.setCustomFonts(originalCustomFonts);
      }
      FlutterError.onError = oldHandler;
    }
  });
}

Future<List<int>> _loadSystemFontBytes() async {
  final List<File> candidates = <File>[
    File(r'C:\Windows\Fonts\arial.ttf'),
    File(r'C:\Windows\Fonts\segoeui.ttf'),
    File('/System/Library/Fonts/Supplemental/Arial.ttf'),
    File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
  ];
  for (final File file in candidates) {
    if (await file.exists()) return file.readAsBytes();
  }
  fail('No system TrueType font fixture was found');
}
