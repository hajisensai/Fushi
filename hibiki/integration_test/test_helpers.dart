import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

bool get screenshotsAreRequired =>
    !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;

Future<bool> waitForHome(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (isHomeReady()) {
      debugPrint('[test] Home ready at iteration $i (${i * 500}ms)');
      await tester.pump(const Duration(seconds: 1));
      return true;
    }
    if (i > 0 && i % 20 == 0) {
      debugPrint('[test] Still waiting for home... iteration $i');
    }
  }
  return false;
}

bool isHomeReady() {
  return findPrimaryNavigationTargets().length >= 2;
}

Future<int> takeScreenshot(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[test] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[test] Screenshot skipped ($name): $e');
    return 0;
  }
}

void assertStrictErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Errors (including WebView/renderer) are fatal: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}

Finder findBookEntries() {
  return find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    if (k is ValueKey<String>) {
      return k.value.startsWith('book_entry_') ||
          k.value.startsWith('srt_entry_');
    }
    return false;
  });
}

Finder findSearchField() {
  final Finder homeDictionarySearch =
      find.byKey(const ValueKey<String>('home_dictionary_search_field'));
  if (homeDictionarySearch.evaluate().isNotEmpty) {
    return homeDictionarySearch.first;
  }
  if (find.byType(TextField).evaluate().isNotEmpty) {
    return find.byType(TextField).first;
  }
  if (find.byType(TextFormField).evaluate().isNotEmpty) {
    return find.byType(TextFormField).first;
  }
  final Finder searchBar = find.byType(SearchBar);
  expect(searchBar, findsWidgets,
      reason: 'No TextField, TextFormField, or SearchBar found');
  return searchBar.first;
}

Finder findDictionaryResultEvidence() {
  return find.byKey(
    const ValueKey<String>('home_dictionary_result_evidence'),
  );
}

List<Finder> findPrimaryNavigationTargets() {
  final Finder rail = find.byType(NavigationRail);
  if (rail.evaluate().isNotEmpty) {
    return _navigationIconsInside(rail);
  }

  final Finder bottomNav = find.byType(BottomNavigationBar);
  if (bottomNav.evaluate().isNotEmpty) {
    return _navigationIconsInside(bottomNav);
  }

  final Finder navigationBar = find.byType(NavigationBar);
  if (navigationBar.evaluate().isNotEmpty) {
    return _navigationIconsInside(navigationBar);
  }

  return const <Finder>[];
}

List<Finder> _navigationIconsInside(Finder navigationRoot) {
  final Finder icons = find.descendant(
    of: navigationRoot,
    matching: find.byType(Icon),
  );
  return List<Finder>.generate(
    icons.evaluate().length,
    (int index) => icons.at(index),
  );
}
