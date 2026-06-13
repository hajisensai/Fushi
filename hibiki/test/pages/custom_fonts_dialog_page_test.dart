import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/custom_fonts_page.dart';
import 'package:hibiki/src/reader/font_catalog.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: home),
    );
  }

  testWidgets('font url import dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(const CustomFontUrlImportDialog()),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('font download progress dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        CustomFontDownloadProgressDialog(
          title: 'Very long recommended font family name for compact windows',
          progressNotifier: ValueNotifier<double?>(0.42),
          onCancel: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('font catalog row exposes independent target toggles', (
    WidgetTester tester,
  ) async {
    final List<FontTarget> toggledTargets = <FontTarget>[];

    await tester.pumpWidget(
      buildApp(
        Scaffold(
          body: CustomFontCatalogTile(
            name: 'Klee One',
            isFile: true,
            index: 0,
            isLast: true,
            targets: const <FontTarget>{
              FontTarget.body,
              FontTarget.dictionary,
            },
            onTargetToggled: toggledTargets.add,
            onDelete: () {},
            onMoveUp: () {},
            onMoveDown: () {},
          ),
        ),
      ),
    );

    expect(find.text('Klee One'), findsOneWidget);
    expect(find.text(t.font_target_app_ui), findsOneWidget);
    expect(find.text(t.font_target_body), findsOneWidget);
    expect(find.text(t.font_target_dictionary), findsOneWidget);

    final Finder appUiChip =
        find.widgetWithText(FilterChip, t.font_target_app_ui);
    final Finder bodyChip = find.widgetWithText(FilterChip, t.font_target_body);
    final Finder dictionaryChip =
        find.widgetWithText(FilterChip, t.font_target_dictionary);

    expect(tester.widget<FilterChip>(appUiChip).selected, isFalse);
    expect(tester.widget<FilterChip>(bodyChip).selected, isTrue);
    expect(tester.widget<FilterChip>(dictionaryChip).selected, isTrue);

    await tester.tap(appUiChip);
    await tester.pump();

    expect(toggledTargets, <FontTarget>[FontTarget.appUi]);
  });

  testWidgets('font catalog row keeps three action buttons inline with title', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 420);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        Scaffold(
          body: CustomFontCatalogTile(
            name: 'Aozora Mincho Super Family',
            isFile: false,
            index: 1,
            isLast: false,
            targets: const <FontTarget>{
              FontTarget.appUi,
              FontTarget.body,
              FontTarget.dictionary,
            },
            onTargetToggled: (_) {},
            onDelete: () {},
            onMoveUp: () {},
            onMoveDown: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(HibikiIconButton), findsNWidgets(3));

    final Rect titleRect =
        tester.getRect(find.text('Aozora Mincho Super Family'));
    final Rect moveUpRect = tester.getRect(find.bySemanticsLabel(t.move_up));
    final Rect moveDownRect =
        tester.getRect(find.bySemanticsLabel(t.move_down));
    final Rect deleteRect =
        tester.getRect(find.bySemanticsLabel(t.custom_fonts_removed));

    for (final Rect buttonRect in <Rect>[
      moveUpRect,
      moveDownRect,
      deleteRect,
    ]) {
      expect(
        (buttonRect.center.dy - titleRect.center.dy).abs(),
        lessThanOrEqualTo(6),
        reason: 'Font row actions must visually share the title line.',
      );
    }

    expect(titleRect.right, lessThanOrEqualTo(moveUpRect.left));
    expect(moveUpRect.right, lessThanOrEqualTo(moveDownRect.left));
    expect(moveDownRect.right, lessThanOrEqualTo(deleteRect.left));
  });

  test('font catalog rows include fonts with no target membership', () {
    const FontCatalogState state = FontCatalogState(
      fonts: <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Orphan Visible', path: null),
      ],
      targets: <String, List<FontTargetFont>>{},
    );

    final List<CustomFontCatalogRow> rows =
        customFontCatalogRowsFromState(state);

    expect(rows.single.name, 'Orphan Visible');
    expect(rows.single.targets, isEmpty);

    rows.single.targetEnabled[FontTarget.dictionary] = true;
    final FontCatalogState saved = customFontCatalogStateFromRows(rows);

    expect(saved.fonts.single.id, 'font_1');
    expect(
      saved.fontListForTarget(ReaderSettings.fontKeyDictionary).single['name'],
      'Orphan Visible',
    );
  });

  test('clearing the last target keeps the catalog row visible after refresh',
      () {
    const FontCatalogState state = FontCatalogState(
      fonts: <FontCatalogEntry>[
        FontCatalogEntry(id: 'font_1', name: 'Untargeted', path: null),
      ],
      targets: <String, List<FontTargetFont>>{
        ReaderSettings.fontKeyBody: <FontTargetFont>[
          FontTargetFont(fontId: 'font_1', enabled: true),
        ],
      },
    );

    final List<CustomFontCatalogRow> rows =
        customFontCatalogRowsFromState(state);
    rows.single.targetEnabled.remove(FontTarget.body);

    final FontCatalogState saved = customFontCatalogStateFromRows(rows);
    final List<CustomFontCatalogRow> refreshed =
        customFontCatalogRowsFromState(saved);

    expect(saved.fonts.single.name, 'Untargeted');
    expect(saved.targets[ReaderSettings.fontKeyBody], isEmpty);
    expect(refreshed.single.name, 'Untargeted');
    expect(refreshed.single.targets, isEmpty);
  });

  test('deleting a row prunes catalog and legacy target lists', () {
    final List<CustomFontCatalogRow> rows = <CustomFontCatalogRow>[
      CustomFontCatalogRow(
        id: 'font_1',
        name: 'Keep',
        path: null,
        targetEnabled: <FontTarget, bool>{FontTarget.body: true},
      ),
    ];

    final FontCatalogState saved = customFontCatalogStateFromRows(rows);
    final Map<String, List<Map<String, dynamic>>> legacy =
        customFontLegacyListsFromRows(rows);

    expect(saved.fonts.map((FontCatalogEntry font) => font.name), <String>[
      'Keep',
    ]);
    expect(saved.fontListForTarget(ReaderSettings.fontKeyBody).single['name'],
        'Keep');
    expect(legacy[ReaderSettings.fontKeyBody]!.single['name'], 'Keep');
    expect(legacy[ReaderSettings.fontKeyAppUi], isEmpty);
    expect(legacy[ReaderSettings.fontKeyDictionary], isEmpty);

    final FontCatalogState deleted = customFontCatalogStateFromRows(
      <CustomFontCatalogRow>[],
    );
    final Map<String, List<Map<String, dynamic>>> deletedLegacy =
        customFontLegacyListsFromRows(<CustomFontCatalogRow>[]);

    expect(deleted.fonts, isEmpty);
    expect(deleted.targets[ReaderSettings.fontKeyBody], isEmpty);
    expect(deletedLegacy[ReaderSettings.fontKeyBody], isEmpty);
    expect(deletedLegacy[ReaderSettings.fontKeyAppUi], isEmpty);
    expect(deletedLegacy[ReaderSettings.fontKeyDictionary], isEmpty);
  });

  test('font file deletion is skipped while another row still references it',
      () {
    final List<CustomFontCatalogRow> rows = <CustomFontCatalogRow>[
      CustomFontCatalogRow(
        id: 'font_1',
        name: 'Shared A',
        path: r'C:\fonts\shared.ttf',
        targetEnabled: <FontTarget, bool>{FontTarget.body: true},
      ),
      CustomFontCatalogRow(
        id: 'font_2',
        name: 'Shared B',
        path: r'C:\fonts\shared.ttf',
        targetEnabled: <FontTarget, bool>{FontTarget.dictionary: true},
      ),
    ];

    expect(
      customFontFileStillReferenced(rows, r'C:\fonts\shared.ttf'),
      isTrue,
    );
    expect(
      customFontFileStillReferenced(rows, r'C:\fonts\other.ttf'),
      isFalse,
    );
  });
}
