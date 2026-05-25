import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_dialog_delete_page.dart';
import 'package:hibiki/src/pages/implementations/dictionary_dialog_import_page.dart';
import 'package:hibiki/src/utils/spacing.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return ProviderScope(
      overrides: [
        appProvider.overrideWith((ref) => AppModel()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => Spacing(
            dataBuilder: (context) => SpacingData.generate(10),
            child: child ?? const SizedBox.shrink(),
          ),
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
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
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
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
