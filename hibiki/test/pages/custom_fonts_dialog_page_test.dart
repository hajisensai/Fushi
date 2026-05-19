import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/custom_fonts_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: home),
    );
  }

  testWidgets('font url import dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(const CustomFontUrlImportDialog()),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('font download progress dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        CustomFontDownloadProgressDialog(
          title: 'Very long recommended font family name for compact windows',
          progressNotifier: ValueNotifier<double?>(0.42),
          onCancel: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
