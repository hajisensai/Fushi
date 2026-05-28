import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/audio_recorder_page.dart';
import 'package:hibiki/src/utils/spacing.dart';

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
          builder: (context, child) => Spacing(
            dataBuilder: (context) => SpacingData.generate(10),
            child: child ?? const SizedBox.shrink(),
          ),
          home: home,
        ),
      ),
    );
  }

  testWidgets('audio recorder dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudioRecorderDialogPage(
          filePath: 'test-recording.mp3',
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('--:-- / --:--'), findsNothing);
  });
}
