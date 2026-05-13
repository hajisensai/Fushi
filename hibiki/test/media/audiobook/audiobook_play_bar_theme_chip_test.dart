import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

void main() {
  testWidgets('reader settings custom theme chip uses selected ChoiceChip',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return buildReaderThemeChip(
                context: context,
                label: 'Custom Theme',
                selected: true,
                onSelected: (_) {},
                avatar: const Icon(Icons.palette),
              );
            },
          ),
        ),
      ),
    );

    final Finder chip = find.byType(ChoiceChip);

    expect(chip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.byType(ActionChip), findsNothing);
  });
}
