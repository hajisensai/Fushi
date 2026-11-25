// BUG-251 / TODO-307: import file-picker rows were not tappable on the whole
// row — only the trailing icon fired a pick action. FushiFilePickerRow has an
// `onTap` that wires FushiListItem.onTap, but the import dialogs left it null.
// These tests guard the component contract (whole-row tap fires onTap, trailing
// icon taps stay scoped to the icon) plus a source-scan guard that the import
// dialog rows actually pass onTap so they can't silently regress to icon-only.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );
  }

  group('FushiFilePickerRow whole-row tap', () {
    testWidgets('tapping the title text fires onTap', (tester) async {
      bool rowTapped = false;
      await tester.pumpWidget(
        buildSubject(
          FushiFilePickerRow(
            title: 'Pick EPUB',
            icon: Icons.menu_book_outlined,
            onTap: () => rowTapped = true,
          ),
        ),
      );

      await tester.tap(find.text('Pick EPUB'));
      await tester.pumpAndSettle();

      expect(rowTapped, isTrue);
    });

    testWidgets('disabled row does not fire onTap', (tester) async {
      bool rowTapped = false;
      await tester.pumpWidget(
        buildSubject(
          FushiFilePickerRow(
            title: 'Pick EPUB',
            icon: Icons.menu_book_outlined,
            enabled: false,
            onTap: () => rowTapped = true,
          ),
        ),
      );

      await tester.tap(find.text('Pick EPUB'));
      await tester.pumpAndSettle();

      expect(rowTapped, isFalse);
    });

    testWidgets('trailing icon tap fires the icon callback, not the row', (
      tester,
    ) async {
      bool rowTapped = false;
      bool iconTapped = false;
      await tester.pumpWidget(
        buildSubject(
          FushiFilePickerRow(
            title: 'Pick subtitle',
            icon: Icons.subtitles_outlined,
            onTap: () => rowTapped = true,
            actions: [
              FushiIconButton(
                icon: Icons.close,
                tooltip: 'Clear',
                isWideTapArea: true,
                onTap: () => iconTapped = true,
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(iconTapped, isTrue);
      expect(rowTapped, isFalse);
    });
  });

  // 2026-11 导入对话框第二版：每个文件选择是共享拼贴色块（ImportPickBlock /
  // ImportPickTile），整块可点——方法体里必须给色块 onTap。
  group('import dialog pick blocks pass onTap (source guard)', () {
    String methodBody(String source, String methodName) {
      final int start = source.indexOf('Widget $methodName()');
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $methodName');
      final int end = source.indexOf('\n  }\n', start);
      return source.substring(start, end);
    }

    void expectTappableBlock(String body) {
      expect(body, matches(RegExp(r'ImportPick(Block|Tile)\(')));
      expect(body, contains('onTap:'));
    }

    test('book_import_dialog picks are all tappable', () {
      final String source = File(
        'lib/src/media/audiobook/book_import_dialog.dart',
      ).readAsStringSync();
      for (final String row in <String>[
        '_epubRow',
        '_subtitleRow',
        '_audioRow',
        '_coverRow',
      ]) {
        expectTappableBlock(methodBody(source, row));
      }
    });

    test('audiobook_import_dialog picks are tappable', () {
      final String source = File(
        'lib/src/media/audiobook/audiobook_import_dialog.dart',
      ).readAsStringSync();
      expectTappableBlock(methodBody(source, '_audioSourceRow'));
      expectTappableBlock(methodBody(source, '_alignmentRow'));
    });
  });
}
