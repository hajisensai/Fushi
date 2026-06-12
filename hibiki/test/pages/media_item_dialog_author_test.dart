import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// BUG-220 子3-a: the EPUB shelf MediaItem now carries the DB author, and the
/// detail dialog must surface it. These tests exercise the pure layout frame
/// ([MediaItemDialogFrame]) so they do not depend on AppModel / a database.
void main() {
  Future<void> pumpFrame(WidgetTester tester, {String? author}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemDialogFrame(
              title: 'こころ',
              author: author,
              launchLabel: 'Read',
              onLaunch: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the author line when an author is present',
      (WidgetTester tester) async {
    await pumpFrame(tester, author: '夏目漱石');
    expect(find.text('夏目漱石'), findsOneWidget);
    expect(find.text('こころ'), findsOneWidget);
  });

  testWidgets('hides the author line when author is null',
      (WidgetTester tester) async {
    await pumpFrame(tester, author: null);
    expect(find.text('夏目漱石'), findsNothing);
    expect(find.text('こころ'), findsOneWidget);
  });
}
