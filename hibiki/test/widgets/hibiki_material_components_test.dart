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

  testWidgets('HibikiActionChip uses shared outline action styling',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      buildSubject(
        HibikiActionChip(
          label: 'Open',
          icon: Icons.open_in_new,
          onPressed: () => tapped = true,
        ),
      ),
    );

    final OutlinedButton button =
        tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    final RoundedRectangleBorder shape = button.style!.shape!
        .resolve(<WidgetState>{})! as RoundedRectangleBorder;

    expect(shape.borderRadius, BorderRadius.circular(8));
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);

    await tester.tap(find.byType(HibikiActionChip));
    expect(tapped, isTrue);
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

  testWidgets('HibikiTagChip exposes a compact delete affordance',
      (WidgetTester tester) async {
    bool deleted = false;
    await tester.pumpWidget(
      buildSubject(
        HibikiTagChip(
          label: 'Ctrl+K',
          tone: HibikiTagChipTone.surface,
          onDeleted: () => deleted = true,
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    expect(deleted, isTrue);
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

  testWidgets('HibikiModalSheetFrame owns sheet header and footer chrome',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiModalSheetFrame(
          title: 'Filters',
          leadingIcon: Icons.sell_outlined,
          body: Text('Body'),
          footer: Text('Footer'),
        ),
      ),
    );

    final Icon icon = tester.widget<Icon>(find.byIcon(Icons.sell_outlined));
    final Divider divider = tester.widget<Divider>(find.byType(Divider));

    expect(find.byType(SafeArea), findsOneWidget);
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);
    expect(find.text('Footer'), findsOneWidget);
    expect(icon.size, 20);
    expect(divider.height, 1);
  });

  testWidgets('HibikiModalSheetFrame makes long sheet bodies scrollable',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        HibikiModalSheetFrame(
          title: 'Long sheet',
          scrollable: true,
          body: Column(
            children: List<Widget>.generate(
              20,
              (int index) => Text('Row $index'),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Flexible), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Long sheet'), findsOneWidget);
  });

  testWidgets('HibikiModalSheetFrame can constrain tall sheet height', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiModalSheetFrame(
          maxHeightFactor: 0.5,
          scrollable: true,
          body: SizedBox(height: 1000, child: Text('Tall body')),
        ),
      ),
    );

    final bool hasFrameConstraint =
        tester.widgetList<ConstrainedBox>(find.byType(ConstrainedBox)).any(
              (ConstrainedBox box) => box.constraints.maxHeight == 300,
            );
    expect(hasFrameConstraint, isTrue);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Tall body'), findsOneWidget);
  });

  testWidgets('HibikiDialogFrame owns MD3 dialog shell chrome', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiDialogFrame(
          child: Text('Dialog body'),
        ),
      ),
    );

    final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
    final RoundedRectangleBorder shape =
        dialog.shape! as RoundedRectangleBorder;

    expect(find.text('Dialog body'), findsOneWidget);
    expect(shape.borderRadius, BorderRadius.circular(28));
    expect(dialog.clipBehavior, Clip.antiAlias);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('HibikiPopupSurface can render a borderless popup shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const HibikiPopupSurface(
          showBorder: false,
          clipBehavior: Clip.none,
          child: Text('Popup'),
        ),
      ),
    );

    final Finder surfaceMaterial = find.descendant(
      of: find.byType(HibikiPopupSurface),
      matching: find.byType(Material),
    );
    final Material material = tester.widget<Material>(surfaceMaterial);
    final RoundedRectangleBorder shape =
        material.shape! as RoundedRectangleBorder;

    expect(find.text('Popup'), findsOneWidget);
    expect(material.clipBehavior, Clip.none);
    expect(shape.side, BorderSide.none);
  });
}
