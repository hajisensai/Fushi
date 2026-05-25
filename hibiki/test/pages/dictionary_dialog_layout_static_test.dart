import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/pages.dart';

void main() {
  test('dictionary manager dialog does not use compact Cupertino alert layout',
      () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();
    final int buildStart =
        source.indexOf('  Widget build(BuildContext context) {');
    final int actionsStart = source.indexOf('  List<Widget> get actions');

    expect(buildStart, isNonNegative);
    expect(actionsStart, greaterThan(buildStart));

    final String buildSource = source.substring(buildStart, actionsStart);

    expect(buildSource, contains('isCupertinoPlatform(context)'));
    expect(buildSource, contains('DictionaryManagerDialogFrame'));
    expect(buildSource, contains('adaptiveAlertDialog('));
  });

  testWidgets('dictionary manager frame uses a large scrollable dialog on iOS',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const Scaffold(
          body: DictionaryManagerDialogFrame(
            content: SizedBox.expand(child: Text('Dictionary list')),
            actions: <Widget>[
              TextButton(onPressed: null, child: Text('Close')),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Dictionary list'), findsOneWidget);

    final Size dialogSize = tester.getSize(find.byType(Dialog));
    expect(dialogSize.width, greaterThan(300));
    expect(dialogSize.height, greaterThan(500));
  });
}
