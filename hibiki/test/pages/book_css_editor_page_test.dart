import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';

// Minimal Slang stub — the real strings.g.dart pulls in too many
// dependencies for a focused widget test.  We wrap the page in a
// MaterialApp whose Localizations delegate is the generated one, but
// if that causes import issues the tests can be run with
// `flutter test --dart-define=SLANG_MOCK=true` and a conditional
// import.  For now we import the real generated file:
import 'package:hibiki/i18n/strings.g.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    tmpDir = Directory.systemTemp.createTempSync('css_editor_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Widget buildApp(String extractDir) {
    return TranslationProvider(
      child: MaterialApp(
        home: BookCssEditorPage(extractDir: extractDir),
      ),
    );
  }

  void createCss(Directory root, String rel, String content) {
    final File f = File(p.join(root.path, rel.replaceAll('/', p.separator)));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  testWidgets(
    'cancel tab switch keeps _selectedIndex on original tab',
    (WidgetTester tester) async {
      createCss(tmpDir, 'a.css', 'aaa');
      createCss(tmpDir, 'b.css', 'bbb');

      await tester.pumpWidget(buildApp(tmpDir.path));
      await tester.pumpAndSettle();

      // Verify two chips rendered, first selected
      expect(find.text('a.css'), findsOneWidget);
      expect(find.text('b.css'), findsOneWidget);

      // Type in the editor to create unsaved changes
      await tester.enterText(find.byType(TextField).first, 'modified');
      await tester.pumpAndSettle();

      // Tab label should now show *
      expect(find.text('* a.css'), findsOneWidget);

      // Tap the second chip to trigger guard dialog
      await tester.tap(find.text('b.css'));
      await tester.pumpAndSettle();

      // Dialog should appear
      expect(find.text(t.book_css_editor_unsaved_changes), findsOneWidget);

      // Tap Cancel
      await tester.tap(find.text(t.book_css_editor_cancel));
      await tester.pumpAndSettle();

      // First chip should still be selected (editor still shows modified text)
      final TextField tf =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller!.text, 'modified');
    },
  );

  testWidgets(
    'unsaved changes dialog fits a compact desktop window',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);

      createCss(tmpDir, 'a.css', 'aaa');
      createCss(tmpDir, 'b.css', 'bbb');

      await tester.pumpWidget(buildApp(tmpDir.path));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'modified');
      await tester.pumpAndSettle();

      await tester.tap(find.text('b.css'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(t.book_css_editor_unsaved_changes), findsOneWidget);
    },
  );

  testWidgets(
    'reset current discards editor changes when no .original exists',
    (WidgetTester tester) async {
      createCss(tmpDir, 'style.css', 'original content');

      await tester.pumpWidget(buildApp(tmpDir.path));
      await tester.pumpAndSettle();

      // Type to create unsaved changes
      await tester.enterText(find.byType(TextField).first, 'user edits');
      await tester.pumpAndSettle();

      // Reset Current should be enabled (unsaved editor changes)
      final Finder resetBtn = find.text(t.book_css_editor_reset_current);
      expect(resetBtn, findsOneWidget);
      await tester.tap(resetBtn);
      await tester.pumpAndSettle();

      // Confirm dialog
      expect(find.text(t.book_css_editor_confirm_reset), findsOneWidget);
      await tester.tap(find.text(t.book_css_editor_reset_current).last);
      await tester.pumpAndSettle();

      // Editor should be back to disk content
      final TextField tf =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller!.text, 'original content');

      // No .original file should exist on disk
      expect(
          File('${tmpDir.path}${p.separator}style.css.original').existsSync(),
          isFalse);
    },
  );
}
