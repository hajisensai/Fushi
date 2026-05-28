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

  testWidgets('HibikiTagChip surface tone keeps a tag color swatch',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiTagChip(
          label: 'Fiction',
          color: Colors.red,
          selected: true,
          tone: HibikiTagChipTone.surface,
        ),
      ),
    );

    final Iterable<Container> containers =
        tester.widgetList<Container>(find.byType(Container));
    final Container chip = containers.firstWhere((Container widget) {
      final Decoration? decoration = widget.decoration;
      return decoration is BoxDecoration && decoration.border != null;
    });
    final DecoratedBox swatch = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .firstWhere((DecoratedBox widget) {
      final Decoration decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.color == Colors.red &&
          decoration.shape == BoxShape.circle;
    });
    final BoxDecoration chipDecoration = chip.decoration! as BoxDecoration;
    final BoxDecoration swatchDecoration = swatch.decoration as BoxDecoration;

    expect(chipDecoration.borderRadius, BorderRadius.circular(8));
    expect(chipDecoration.border, isNotNull);
    expect(swatchDecoration.color, Colors.red);
    expect(swatchDecoration.shape, BoxShape.circle);
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

  testWidgets('HibikiColorSwatch uses token radius and selected border',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      buildSubject(
        HibikiColorSwatch(
          color: Colors.green,
          selected: true,
          onTap: () => tapped = true,
        ),
      ),
    );

    final Container swatch = tester.widget<Container>(find.byType(Container));
    final BoxDecoration decoration = swatch.decoration! as BoxDecoration;

    expect(decoration.color, Colors.green);
    expect(decoration.borderRadius, BorderRadius.circular(8));
    expect(decoration.border, isNotNull);

    await tester.tap(find.byType(HibikiColorSwatch));
    expect(tapped, isTrue);
  });

  testWidgets('HibikiPreviewSwitch renders a real disabled MD3 switch',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiPreviewSwitch(
          trackColor: Colors.blue,
          thumbColor: Colors.white,
        ),
      ),
    );

    final Switch previewSwitch = tester.widget<Switch>(find.byType(Switch));
    final Color trackColor = previewSwitch.trackColor!.resolve(
      <WidgetState>{WidgetState.disabled, WidgetState.selected},
    )!;
    final Color thumbColor = previewSwitch.thumbColor!.resolve(
      <WidgetState>{WidgetState.disabled, WidgetState.selected},
    )!;

    expect(previewSwitch.value, isTrue);
    expect(previewSwitch.onChanged, isNull);
    expect(trackColor, Colors.blue);
    expect(thumbColor, Colors.white);
  });

  testWidgets('HibikiTransientScaffold uses the page surface',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HibikiTransientScaffold(
          body: Text('loading'),
        ),
      ),
    );

    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));

    expect(scaffold.backgroundColor, ThemeData().colorScheme.surface);
    expect(find.text('loading'), findsOneWidget);
  });

  testWidgets('HibikiOverlayScaffold preserves transparent overlay chrome',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HibikiOverlayScaffold(
          body: Text('popup'),
        ),
      ),
    );

    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));

    expect(scaffold.backgroundColor, Colors.transparent);
    expect(find.text('popup'), findsOneWidget);
  });
}
