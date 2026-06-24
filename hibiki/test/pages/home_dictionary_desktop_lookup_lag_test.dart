import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_foreground_guard.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

class _DesktopLookupLagAppModel extends AppModel {
  _DesktopLookupLagAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];

  @override
  bool get desktopClipboardEnabled => false;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    searchedTerms.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Widget _wrap(_DesktopLookupLagAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) => Spacing(
          dataBuilder: (BuildContext context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    // The lookup is an *external* copy: pin the foreground guard so the real
    // Windows GetForegroundWindow FFI probe (added after this test) cannot
    // non-deterministically report Hibiki as already-foreground and early-return
    // bringPendingLookupToFront before it reaches the mocked window_manager.
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = null;
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    DesktopLookupService.instance.debugReset();
  });

  testWidgets('external desktop lookup searches before window focus completes',
      (WidgetTester tester) async {
    final _DesktopLookupLagAppModel appModel = _DesktopLookupLagAppModel();
    final Completer<void> showCompleter = Completer<void>();
    final Completer<void> focusCompleter = Completer<void>();
    final List<String> windowCalls = <String>[];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) {
        windowCalls.add(call.method);
        if (call.method == 'isMinimized') return Future<bool>.value(false);
        // External desktop lookup = Hibiki is NOT in the foreground (the user
        // copied in another app). bringPendingLookupToFront only attempts the
        // show/focus path when isFocused() is false (TODO-341 gates the path
        // for an already-foreground window to avoid the Windows taskbar flash).
        if (call.method == 'isFocused') return Future<bool>.value(false);
        if (call.method == 'show') return showCompleter.future;
        if (call.method == 'focus') return focusCompleter.future;
        return Future<void>.value();
      },
    );

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    DesktopLookupService.instance.submitText(' lookupterm ');
    expect(
      DesktopLookupService.instance.pendingText,
      isNull,
      reason:
          'HomeDictionaryPage should synchronously consume the pending hit.',
    );
    await tester.pump();
    await tester.pump();

    expect(
      appModel.searchedTerms,
      <String>['lookupterm'],
      reason: 'The visible lookup must not wait for a slow OS foreground call.',
    );
    expect(windowCalls, contains('show'));

    showCompleter.complete();
    await tester.pump();
    focusCompleter.complete();
    await tester.pump();
  });
}
