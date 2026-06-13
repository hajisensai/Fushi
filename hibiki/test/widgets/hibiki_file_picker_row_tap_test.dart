// BUG-251 / TODO-307: import file-picker rows were not tappable on the whole
// row — only the trailing icon fired a pick action. HibikiFilePickerRow has an
// `onTap` that wires HibikiListItem.onTap, but the import dialogs left it null.
// These tests guard the component contract (whole-row tap fires onTap, trailing
// icon taps stay scoped to the icon) plus a source-scan guard that the import
// dialog rows actually pass onTap so they can't silently regress to icon-only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );
  }

  group('HibikiFilePickerRow whole-row tap', () {
    testWidgets('tapping the title text fires onTap', (tester) async {
      bool rowTapped = false;
      await tester.pumpWidget(buildSubject(
        HibikiFilePickerRow(
          title: 'Pick EPUB',
          icon: Icons.menu_book_outlined,
          onTap: () => rowTapped = true,
        ),
      ));

      await tester.tap(find.text('Pick EPUB'));
      await tester.pumpAndSettle();

      expect(rowTapped, isTrue);
    });

    testWidgets('disabled row does not fire onTap', (tester) async {
      bool rowTapped = false;
      await tester.pumpWidget(buildSubject(
        HibikiFilePickerRow(
          title: 'Pick EPUB',
          icon: Icons.menu_book_outlined,
          enabled: false,
          onTap: () => rowTapped = true,
        ),
      ));

      await tester.tap(find.text('Pick EPUB'));
      await tester.pumpAndSettle();

      expect(rowTapped, isFalse);
    });

    testWidgets('trailing icon tap fires the icon callback, not the row',
        (tester) async {
      bool rowTapped = false;
      bool iconTapped = false;
      await tester.pumpWidget(buildSubject(
        HibikiFilePickerRow(
          title: 'Pick subtitle',
          icon: Icons.subtitles_outlined,
          onTap: () => rowTapped = true,
          actions: [
            HibikiIconButton(
              icon: Icons.close,
              tooltip: 'Clear',
              isWideTapArea: true,
              onTap: () => iconTapped = true,
            ),
          ],
        ),
      ));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(iconTapped, isTrue);
      expect(rowTapped, isFalse);
    });
  });

  group('import dialog rows pass onTap (source guard)', () {
    test('book_import_dialog rows are all tappable', () {
      final String source = File(
        'lib/src/media/audiobook/book_import_dialog.dart',
      ).readAsStringSync();

      String rowBody(String methodName) {
        final int start = source.indexOf('Widget $methodName()');
        expect(start, greaterThanOrEqualTo(0),
            reason: 'missing $methodName in book_import_dialog.dart');
        // Each *Row method returns a single HibikiFilePickerRow; slice up to the
        // closing `);` of that return statement followed by the method `}`.
        final int rowStart = source.indexOf('HibikiFilePickerRow(', start);
        final int rowEnd = source.indexOf('actions:', rowStart);
        return source.substring(rowStart, rowEnd);
      }

      expect(rowBody('_epubRow'), contains('onTap:'));
      expect(rowBody('_subtitleRow'), contains('onTap:'));
      expect(rowBody('_audioRow'), contains('onTap:'));
      expect(rowBody('_coverRow'), contains('onTap:'));
    });

    test('audiobook_import_dialog alignment row is tappable', () {
      final String source = File(
        'lib/src/media/audiobook/audiobook_import_dialog.dart',
      ).readAsStringSync();

      final int start = source.indexOf('Widget _alignmentRow()');
      expect(start, greaterThanOrEqualTo(0));
      final int rowStart = source.indexOf('HibikiFilePickerRow(', start);
      final int rowEnd = source.indexOf('actions:', rowStart);
      expect(source.substring(rowStart, rowEnd), contains('onTap:'));
    });
  });
}
