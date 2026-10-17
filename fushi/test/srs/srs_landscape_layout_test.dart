// 复习（SRS）表单页在手机横屏 / 桌面宽窗下的两栏布局，竖屏仍是单列。
//
// 判据：不溢出（takeException 为 null）；宽窗两栏都在、左右并排（水平不重叠、
// 顶边同一行）、关键分区落在约定的那一栏；竖屏不出现右栏。MD3 与 Apple 两套都跑。
//
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_change_note_type_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_type_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_import_options_dialog.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 被测的三种画面（逻辑像素）。
const Size _landscapePhone = Size(915, 412);
const Size _desktop = Size(1280, 800);
const Size _portraitPhone = Size(390, 844);

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _settle(WidgetTester tester, {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  required Size size,
  required Widget page,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: page,
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

final Finder _primary = find.byKey(SrsAdaptiveSections.primaryPaneKey);
final Finder _secondary = find.byKey(SrsAdaptiveSections.secondaryPaneKey);

/// 宽窗：两栏并排（水平不重叠、顶边同一行）；[inPrimary] / [inSecondary] 落在
/// 各自那一栏里。窄窗：没有分栏，单列从 [inPrimary] 的首项开始。
void _expectLayout(
  WidgetTester tester, {
  required bool wide,
  required List<Finder> inPrimary,
  required List<Finder> inSecondary,
}) {
  expect(tester.takeException(), isNull);
  if (!wide) {
    expect(_secondary, findsNothing, reason: '竖屏单列');
    expect(_primary, findsNothing, reason: '竖屏单列');
    expect(inPrimary.first, findsWidgets, reason: '单列从首个分区开始');
    return;
  }
  expect(_primary, findsOneWidget);
  expect(_secondary, findsOneWidget);
  final Rect left = tester.getRect(_primary);
  final Rect right = tester.getRect(_secondary);
  expect(left.right, lessThanOrEqualTo(right.left), reason: '左右不重叠');
  expect((left.top - right.top).abs(), lessThan(1), reason: '两栏同一行');
  expect(left.width, greaterThan(250));
  expect(right.width, greaterThan(250));
  for (final Finder f in inPrimary) {
    expect(find.descendant(of: _primary, matching: f), findsWidgets);
  }
  for (final Finder f in inSecondary) {
    expect(find.descendant(of: _secondary, matching: f), findsWidgets);
  }
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late SrsDbStore store;
  late FushiDatabase db;

  Future<void> open(WidgetTester tester) async {
    final (FushiDatabase d, SrsDbStore s) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    db = d;
    store = s;
    addTearDown(() => tester.runAsync(db.close));
  }

  Future<String> lapisNote(WidgetTester tester) => _db(
    tester,
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '犬',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'dog',
      },
    ),
  );

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';
    for (final (String name, Size size, bool wide) in <(String, Size, bool)>[
      ('landscape', _landscapePhone, true),
      ('desktop', _desktop, true),
      ('portrait', _portraitPhone, false),
    ]) {
      testWidgets('[$ds][$name] 更改笔记类型：左栏目标类型 + 模板，右栏字段映射', (
        WidgetTester tester,
      ) async {
        await open(tester);
        final String note = await lapisNote(tester);
        final SrsNoteTypeView from = (await _db(
          tester,
          () => store.noteType(store.lapisNoteTypeId),
        ))!;
        final SrsNoteTypeView to = (await _db(
          tester,
          () => store.noteType(store.fushiCardNoteTypeId),
        ))!;
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: SrsChangeNoteTypePage(
            noteIds: <String>[note],
            from: from,
            targets: <SrsNoteTypeView>[to],
          ),
        );
        _expectLayout(
          tester,
          wide: wide,
          inPrimary: <Finder>[
            _key('srs-change-type-summary'),
            _key('srs-change-type-target'),
            _key('srs-change-type-templates'),
          ],
          inSecondary: <Finder>[_key('srs-change-type-fields')],
        );
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 牌组选项：左栏基础项，右栏高级项（宽窗默认展开）', (
        WidgetTester tester,
      ) async {
        await open(tester);
        final String deck = await _db(
          tester,
          () => store.ensureDeckPath('Japanese'),
        );
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: SrsDeckSettingsPage(deckId: deck),
        );
        _expectLayout(
          tester,
          wide: wide,
          inPrimary: <Finder>[
            _key('srs-settings-name'),
            _key('srs-settings-new'),
          ],
          inSecondary: <Finder>[_key('srs-settings-advanced')],
        );
        // 宽窗右栏的高级项不用再点开：折叠时子项不建，展开后「算法」就在右栏首屏。
        // 不用 hitTestable——MD3 版控件的顶层渲染对象不在其中心点的命中路径上
        // （中心命中的是控件自己的墨水层），会把已展开、可点的控件判成不可点。
        final Finder algorithm = _key('srs-settings-algorithm');
        expect(algorithm, wide ? findsOneWidget : findsNothing);
        if (wide) {
          final Rect r = tester.getRect(algorithm);
          final Rect secondary = tester.getRect(
            find.byKey(SrsAdaptiveSections.secondaryPaneKey),
          );
          expect(secondary.contains(r.center), isTrue);
          expect(r.bottom, lessThanOrEqualTo(size.height));
        }
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 笔记编辑：左栏字段，右栏类型 / 牌组与标签', (
        WidgetTester tester,
      ) async {
        await open(tester);
        final String note = await lapisNote(tester);
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: SrsNoteEditorPage(noteId: note),
        );
        _expectLayout(
          tester,
          wide: wide,
          inPrimary: <Finder>[_key('srs-field-Expression')],
          inSecondary: <Finder>[
            _key('srs-note-type-row'),
            _key('srs-note-tags'),
          ],
        );
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 笔记类型编辑：左栏属性与模板，右栏字段', (
        WidgetTester tester,
      ) async {
        await open(tester);
        final String nt = await _db(
          tester,
          () => store.createStockNoteType(SrsStockNoteType.basic, 'Mine'),
        );
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: SrsNoteTypeEditorPage(noteTypeId: nt),
        );
        _expectLayout(
          tester,
          wide: wide,
          inPrimary: <Finder>[
            _key('srs-note-type-name-row'),
            _key('srs-note-type-add-template'),
          ],
          inSecondary: <Finder>[_key('srs-note-type-add-field')],
        );
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 卡片预览：横屏矮区域按钮竖排在卡面右侧', (
        WidgetTester tester,
      ) async {
        await open(tester);
        final String note = await lapisNote(tester);
        final String card = (await _db(
          tester,
          () => store.cardsOfNote(note),
        )).single.id;
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: Scaffold(
            body: SafeArea(
              child: SrsBrowsePreview(
                cardId: card,
                revision: 0,
                showAnswer: false,
                onCommand: (_) {},
                onEdit: () {},
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final Finder rail = _key('srs-browse-preview-rail');
        // 只有横屏手机是「又宽又矮」；桌面 800 高、竖屏都还是按钮在卡面下方。
        if (size != _landscapePhone) {
          expect(rail, findsNothing);
          final Rect face = tester.getRect(_key('srs-browse-preview-surface'));
          expect(
            tester.getRect(_key('srs-preview-flip')).top,
            greaterThanOrEqualTo(face.bottom),
          );
          await _unmount(tester);
          return;
        }
        expect(rail, findsOneWidget);
        final Rect face = tester.getRect(_key('srs-browse-preview-surface'));
        final Rect side = tester.getRect(rail);
        expect(face.right, lessThanOrEqualTo(side.left), reason: '按钮栏在卡面右侧');
        expect(side.top, lessThan(face.bottom), reason: '同一行');
        expect(
          find.descendant(of: rail, matching: _key('srs-preview-flip')),
          findsOneWidget,
        );
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 导入选项：横屏两组并排，其余单列', (WidgetTester tester) async {
        await open(tester);
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: Builder(
            builder: (BuildContext context) => Center(
              child: FushiFilledButton(
                key: const ValueKey<String>('open-import'),
                onPressed: () => showSrsImportOptionsDialog(
                  context: context,
                  fileName: 'Core.apkg',
                  initial: const SrsAnkiImportOptions(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(_key('open-import'));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final Finder basic = _key('srs-import-options-basic');
        final Finder updates = _key('srs-import-options-updates');
        if (size != _landscapePhone) {
          expect(basic, findsNothing);
          expect(_key('srs-import-with-scheduling'), findsOneWidget);
          await _unmount(tester);
          return;
        }
        expect(basic, findsOneWidget);
        expect(updates, findsOneWidget);
        final Rect l = tester.getRect(basic);
        final Rect r = tester.getRect(updates);
        expect(l.right, lessThanOrEqualTo(r.left));
        expect((l.top - r.top).abs(), lessThan(1));
        expect(
          find.descendant(
            of: updates,
            matching: _key('srs-import-update-notes'),
          ),
          findsOneWidget,
        );
        await _unmount(tester);
      });

      testWidgets('[$ds][$name] 模板编辑器：左栏源码，右栏预览', (WidgetTester tester) async {
        await open(tester);
        final String nt = await _db(
          tester,
          () => store.createStockNoteType(SrsStockNoteType.basic, 'Mine'),
        );
        final SrsNoteTypeView v = (await _db(
          tester,
          () => store.noteType(nt),
        ))!;
        await _pump(
          tester,
          store: store,
          apple: apple,
          size: size,
          page: SrsTemplateEditorPage(
            noteTypeId: nt,
            templateId: v.templates.single.id,
          ),
        );
        _expectLayout(
          tester,
          wide: wide,
          inPrimary: <Finder>[_key('srs-template-tabs')],
          inSecondary: <Finder>[_key('srs-template-preview')],
        );
        await _unmount(tester);
      });
    }
  }
}
