import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/media_source_picker_dialog_page.dart';

import '../helpers/test_platform_services.dart';

class PickerTestAppModel extends AppModel {
  PickerTestAppModel() : super(testPlatformServices()) {
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
          builder: (context, child) => child ?? const SizedBox.shrink(),
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
    final String sourceKey =
        appModel.mediaSources[ReaderMediaType.instance]!.values.first.uniqueKey;
    expect(find.byKey(ValueKey<String>(sourceKey)), findsOneWidget);
  });
}
