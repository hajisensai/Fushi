import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/media_source_picker_dialog_page.dart';
import 'package:hibiki/src/utils/spacing.dart';

class PickerTestAppModel extends AppModel {
  PickerTestAppModel() {
    populateMediaTypes();
    populateMediaSources();
  }

  @override
  Locale get appLocale => const Locale('en');

  @override
  MediaSource getCurrentSourceForMediaType({
    required MediaType mediaType,
  }) {
    return mediaSources[mediaType]!.values.first;
  }

  @override
  void setCurrentSourceForMediaType({
    required MediaType mediaType,
    required MediaSource mediaSource,
  }) {}
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp({
    required AppModel appModel,
    required Widget home,
  }) {
    return ProviderScope(
      overrides: [
        appProvider.overrideWith((ref) => appModel),
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

  testWidgets('media source picker fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    final AppModel appModel = PickerTestAppModel();

    await tester.pumpWidget(
      buildApp(
        appModel: appModel,
        home: MediaSourcePickerDialogPage(
          mediaType: ReaderMediaType.instance,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ListTile), findsOneWidget);
  });
}
