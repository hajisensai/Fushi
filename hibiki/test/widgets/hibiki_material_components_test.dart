import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
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

  test('log and editor panels use token typography for monospace text', () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String logPanel = source.substring(
      source.indexOf('class HibikiLogPanel'),
      source.indexOf('class HibikiEditorPanel'),
    );
    final String editorPanel = source.substring(
      source.indexOf('class HibikiEditorPanel'),
      source.indexOf('class HibikiPopupSurface'),
    );

    expect(logPanel, contains('tokens.type.metadata.copyWith'));
    expect(editorPanel, contains('tokens.type.listSubtitle.copyWith'));
    expect(logPanel, isNot(contains('fontSize: 12')));
    expect(editorPanel, isNot(contains('fontSize: 12')));
  });

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

  testWidgets('HibikiSelectableChip registers with the focus root',
      (WidgetTester tester) async {
    bool selected = false;
    await tester.pumpWidget(buildSubject(
      HibikiFocusRoot(
        child: HibikiSelectableChip(
          focusId: const HibikiFocusId('theme-chip'),
          label: 'Theme',
          selected: selected,
          onSelected: (bool value) => selected = value,
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController root = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(ChoiceChip)),
    );
    expect(root.requestById(const HibikiFocusId('theme-chip')), isTrue);
    await tester.pump();
    expect(root.activeId, const HibikiFocusId('theme-chip'));

    Actions.maybeInvoke<ActivateIntent>(
      root.activeContext!,
      const ActivateIntent(),
    );
    expect(selected, isTrue);
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

  testWidgets('HibikiListItem resolves standard and compact density heights',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HibikiListItem(title: Text('Standard')),
            HibikiListItem(
              title: Text('Compact'),
              density: HibikiListDensity.compact,
            ),
          ],
        ),
      ),
    );

    final RenderBox standard = tester.renderObject<RenderBox>(
      find
          .ancestor(
            of: find.text('Standard'),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );
    final RenderBox compact = tester.renderObject<RenderBox>(
      find
          .ancestor(
            of: find.text('Compact'),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );

    expect(standard.size.height, 56);
    expect(compact.size.height, 44);
  });

  testWidgets('HibikiActionChip registers with the focus root',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(buildSubject(
      HibikiFocusRoot(
        child: HibikiActionChip(
          focusId: const HibikiFocusId('open-chip'),
          label: 'Open',
          icon: Icons.open_in_new,
          onPressed: () => tapped = true,
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController root = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(OutlinedButton)),
    );
    expect(root.requestById(const HibikiFocusId('open-chip')), isTrue);
    await tester.pump();

    Actions.maybeInvoke<ActivateIntent>(
      root.activeContext!,
      const ActivateIntent(),
    );
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
    final AnimatedContainer darkContainer =
        tester.widget<AnimatedContainer>(find
            .ancestor(
              of: find.text('Dark'),
              matching: find.byType(AnimatedContainer),
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

    final Iterable<AnimatedContainer> containers =
        tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer));
    final AnimatedContainer chip =
        containers.firstWhere((AnimatedContainer widget) {
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

  testWidgets('HibikiOverflowMenu registers with the focus root and opens',
      (WidgetTester tester) async {
    int? selected;
    await tester.pumpWidget(
      buildSubject(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiOverflowMenu<int>(
                items: <PopupMenuEntry<int>>[
                  HibikiPopupMenuItem<int>(label: 'Delete', value: 1),
                ],
                onSelected: (int value) => selected = value,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(HibikiOverflowMenu<int>)),
    );
    controller.ensureFocus();
    await tester.pump();

    expect(controller.activeId, isNotNull,
        reason:
            'overflow menus are real command surfaces, not mouse-only dots');
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('HibikiPageHeader keeps actions on one row when content fits',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildSubject(
        SizedBox(
          width: 360,
          child: HibikiPageHeader(
            title: '书架',
            padding: EdgeInsets.zero,
            actions: <Widget>[
              HibikiIconButton(
                tooltip: 'Import',
                icon: Icons.library_add_outlined,
                size: 48,
                onTap: () {},
              ),
              HibikiIconButton(
                tooltip: 'Collections',
                icon: Icons.collections_bookmark_outlined,
                size: 48,
                onTap: () {},
              ),
              HibikiIconButton(
                tooltip: 'Statistics',
                icon: Icons.bar_chart_outlined,
                size: 48,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final double importTop =
        tester.getTopLeft(find.byIcon(Icons.library_add_outlined)).dy;
    final double collectionsTop =
        tester.getTopLeft(find.byIcon(Icons.collections_bookmark_outlined)).dy;
    final double statisticsTop =
        tester.getTopLeft(find.byIcon(Icons.bar_chart_outlined)).dy;

    expect(collectionsTop, importTop);
    expect(statisticsTop, importTop);
  });

  // TODO-667: 手机竖排 / 窄窗（compact 尺寸类，宽 < 600）下页头顶距应收到 `page`
  // (16)，而桌面 / 平板（>= 600）保持 `page + 8`(24)。验证三档行为，并守住手机首页
  // 书架标题不再离顶部多空一行。
  Future<double> measureHeaderTop(
    WidgetTester tester, {
    required double width,
    bool compact = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: HibikiPageHeader(
                  title: '书架',
                  compact: compact,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final double headerTop =
        tester.getTopLeft(find.byType(HibikiPageHeader)).dy;
    final double titleTop = tester.getTopLeft(find.text('书架')).dy;
    return titleTop - headerTop;
  }

  testWidgets('HibikiPageHeader trims top gap to page on compact (phone) width',
      (WidgetTester tester) async {
    final double phoneTop = await measureHeaderTop(tester, width: 360);
    // page = 16；不再是 page + 8 = 24。
    expect(phoneTop, moreOrLessEquals(16, epsilon: 0.5));
  });

  testWidgets('HibikiPageHeader keeps page + 8 top gap on desktop/tablet width',
      (WidgetTester tester) async {
    final double tabletTop = await measureHeaderTop(tester, width: 700);
    final double desktopTop = await measureHeaderTop(tester, width: 1000);
    // page + 8 = 24，桌面 / 平板不变。
    expect(tabletTop, moreOrLessEquals(24, epsilon: 0.5));
    expect(desktopTop, moreOrLessEquals(24, epsilon: 0.5));
  });

  testWidgets(
      'HibikiPageHeader compact mode uses the smallest gap regardless '
      'of window width', (WidgetTester tester) async {
    final double phoneCompact =
        await measureHeaderTop(tester, width: 360, compact: true);
    final double desktopCompact =
        await measureHeaderTop(tester, width: 1000, compact: true);
    // gap = 8，compact（上方有 AppBar）顶距最小，且不受窗口尺寸类影响。
    expect(phoneCompact, moreOrLessEquals(8, epsilon: 0.5));
    expect(desktopCompact, moreOrLessEquals(8, epsilon: 0.5));
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

    final AnimatedContainer swatch = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .firstWhere((AnimatedContainer widget) {
      final Decoration decoration = widget.decoration!;
      return decoration is BoxDecoration && decoration.color == Colors.green;
    });
    final BoxDecoration decoration = swatch.decoration as BoxDecoration;

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

  testWidgets(
      'HibikiToolScaffold default back button registers with focus root',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: const Scaffold(body: Text('home')),
        routes: <String, WidgetBuilder>{
          '/tool': (BuildContext context) => const HibikiFocusRoot(
                child: HibikiToolScaffold(
                  title: 'Tool',
                  body: Text('tool'),
                ),
              ),
        },
      ),
    );
    Navigator.of(tester.element(find.text('home'))).pushNamed('/tool');
    await tester.pumpAndSettle();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Tool')),
    );
    controller.ensureFocus();
    await tester.pump();

    expect(controller.activeId, isNotNull,
        reason: 'the default tool-page back button must be reachable by '
            'custom gamepad focus, not only by touch or system back');
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('HibikiCompactSearchRow icon buttons register with focus root',
      (WidgetTester tester) async {
    final TextEditingController textController =
        TextEditingController(text: 'term');
    final FocusNode fieldFocus = FocusNode();
    int closes = 0;
    String? submitted;
    addTearDown(textController.dispose);
    addTearDown(fieldFocus.dispose);

    await tester.pumpWidget(
      buildSubject(
        HibikiFocusRoot(
          child: HibikiCompactSearchRow(
            controller: textController,
            focusNode: fieldFocus,
            hintText: 'Search',
            onClose: () => closes += 1,
            onSubmit: (String value) => submitted = value,
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(HibikiCompactSearchRow)),
    );
    controller.ensureFocus();
    await tester.pump();

    expect(controller.activeId, isNotNull,
        reason: 'compact search close/search buttons must not be pointer-only');
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(closes, 1);

    // Row order on mobile is [close] [field] [paste] [search]: the default test
    // platform is android, where the input suffix is now a one-tap paste button
    // sitting between the field and the search button. Step right past it.
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(submitted, 'term');
  });
}
