import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('HibikiSelectableChip uses MD3 selected and outline tokens',
      (WidgetTester tester) async {
    bool selected = true;
    await tester.pumpWidget(
      buildSubject(
        HibikiSelectableChip(
          label: 'Theme',
          selected: selected,
          onSelected: (bool value) => selected = value,
        ),
      ),
    );

    final ChoiceChip chip = tester.widget<ChoiceChip>(find.byType(ChoiceChip));
    final RoundedRectangleBorder shape = chip.shape! as RoundedRectangleBorder;

    expect(chip.selected, isTrue);
    expect(chip.showCheckmark, isFalse);
    expect(shape.borderRadius, BorderRadius.circular(8));
    expect(
      chip.selectedColor,
      Theme.of(tester.element(find.byType(ChoiceChip)))
          .colorScheme
          .primaryContainer,
    );

    await tester.tap(find.byType(ChoiceChip));
    expect(selected, isFalse);
  });

  testWidgets('HibikiTagChip derives readable text color from tag color',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const Wrap(
          children: <Widget>[
            HibikiTagChip(label: 'Dark', color: Colors.black),
            HibikiTagChip(label: 'Light', color: Colors.white),
          ],
        ),
      ),
    );

    final Text darkText = tester.widget<Text>(find.text('Dark'));
    final Text lightText = tester.widget<Text>(find.text('Light'));
    final Container darkContainer = tester.widget<Container>(find
        .ancestor(
          of: find.text('Dark'),
          matching: find.byType(Container),
        )
        .first);

    expect(darkText.style?.color, Colors.white);
    expect(lightText.style?.color, Colors.black);
    expect(
      (darkContainer.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(8),
    );
  });

  testWidgets('HibikiBadge uses the shared compact radius',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiBadge(
          icon: Icons.headphones_outlined,
        ),
      ),
    );

    final Container badge = tester.widget<Container>(find.byType(Container));

    expect(
      (badge.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(8),
    );
    expect(find.byIcon(Icons.headphones_outlined), findsOneWidget);
  });
}
