import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<bool> waitForHome(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
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
  if (find.byType(TextField).evaluate().isNotEmpty) {
    return find.byType(TextField).first;
  }
  if (find.byType(TextFormField).evaluate().isNotEmpty) {
    return find.byType(TextFormField).first;
  }
  return find.byType(SearchBar).first;
}
