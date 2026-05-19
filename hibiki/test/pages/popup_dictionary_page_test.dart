import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:spaces/spaces.dart';

Widget buildTestApp({
  required AppModel appModel,
  required Widget home,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: home,
      ),
    ),
  );
}

void main() {
  final List<String> launchedUrls = <String>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async {
        if (call.method == 'launch') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          launchedUrls.add(args['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  testWidgets('renders an in-app close button when requested', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    final AppModel appModel = AppModel();

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: PopupDictionaryPage(
          searchTerm: 'search',
          closeInApp: () => closed = true,
          autoSearchOnOpen: false,
        ),
      ),
    );

    await tester.pump();

    final Finder closeButton = find.byKey(
      const ValueKey<String>('popup_dictionary_close_button'),
    );

    expect(closeButton, findsOneWidget);

    await tester.tap(closeButton);
    await tester.pump();

    expect(closed, isTrue);
  });

  testWidgets('desktop lookup opens in-app instead of launching hibiki url', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = AppModel();

    await tester.pumpWidget(
      buildTestApp(
        appModel: appModel,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    unawaited(appModel.openPopupDictionaryLookup(searchTerm: 'search'));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('popup_dictionary_close_button')),
      findsOneWidget,
    );
    expect(launchedUrls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('popup_dictionary_close_button')),
    );
    await tester.pump();
  });
}
