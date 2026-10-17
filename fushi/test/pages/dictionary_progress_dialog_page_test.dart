import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_delete_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_import_page.dart';

import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import '../helpers/test_platform_services.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return ProviderScope(
      overrides: [
        appProvider.overrideWith((ref) => AppModel(testPlatformServices())),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => child ?? const SizedBox.shrink(),
          home: home,
        ),
      ),
    );
  }

  testWidgets('dictionary import progress fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDialogImportPage(
          progressNotifier: ValueNotifier<String>(
            'Importing a dictionary with a long visible progress message',
          ),
          countNotifier: ValueNotifier<int?>(1),
          totalNotifier: ValueNotifier<int?>(3),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // MD3 下不定态进度是 Expressive 加载指示（变形形状），取代原圆形进度。
    expect(find.byType(FushiExpressiveLoadingIndicator), findsOneWidget);
  });

  testWidgets('dictionary delete progress fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        const DictionaryDialogDeletePage(
          name: 'Very long dictionary name used for compact window testing',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // MD3 下不定态进度是 Expressive 加载指示（变形形状），取代原圆形进度。
    expect(find.byType(FushiExpressiveLoadingIndicator), findsOneWidget);
  });
}
