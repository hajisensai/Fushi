// 「迁移旧 Lapis 到新模板」页与笔记类型页入口：MD3 与 Apple 两套设计系统。
//
// 内存库 + 确定性假排程内核；数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_legacy_lapis_migration_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

/// 让真异步（drift）与帧都推进。
Future<void> _settle(WidgetTester tester, {int rounds = 16}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  required Widget page,
}) async {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = SrsTestAppModel();
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

/// 内置 Lapis 上加一个用户字段「来源」，建一条只在「来源」里有出处的笔记。
Future<(String note, String srcField)> _seedLapisWithSource(
  WidgetTester tester,
  SrsDbStore store,
) async {
  final String src = await _db(
    tester,
    () => store.addField(store.lapisNoteTypeId, '来源'),
  );
  final String note = await _db(
    tester,
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(store.profileUid, 'Expression'): '切磋琢磨',
        src: '《三月のライオン》',
      },
    ),
  );
  return (note, src);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 迁移页：预演内置 Lapis，确认后迁到 Fushi 卡片并补上「来源」', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final (String note, _) = await _seedLapisWithSource(tester, store);
      final String lapisId = store.lapisNoteTypeId;
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsLegacyLapisMigrationPage(),
      );

      expect(
        find.byKey(ValueKey<String>('srs-lapis-migration-source-$lapisId')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          t.srs_lapis_migration_kind_builtin,
          findRichText: true,
        ),
        findsWidgets,
      );
      final Finder migrate = find.byKey(
        ValueKey<String>('srs-lapis-migration-migrate-$lapisId'),
      );
      await tester.ensureVisible(migrate);
      await _settle(tester, rounds: 4);
      await tester.tap(migrate);
      await _settle(tester);
      await tester.tap(find.text(t.srs_lapis_migration_migrate).last);
      await _settle(tester);

      final SrsNoteView after = (await _db(tester, () => store.note(note)))!;
      expect(after.noteTypeId, store.fushiCardNoteTypeId);
      expect(
        after.field(srsFushiCardFieldId(store.profileUid, 'Expression')),
        '切磋琢磨',
      );
      expect(
        after.field(srsFushiCardFieldId(store.profileUid, 'MiscInfo')),
        '《三月のライオン》',
      );
      // 迁完后页面回到「没有可迁移的」。
      expect(
        find.byKey(const ValueKey<String>('srs-lapis-migration-nothing')),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 迁移页：选了目标牌组，迁移后笔记与卡片都移过去', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String fushiDeck = await _db(
        tester,
        () => store.createDeck('Fushi'),
      );
      final (String note, _) = await _seedLapisWithSource(tester, store);
      final String lapisId = store.lapisNoteTypeId;
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsLegacyLapisMigrationPage(),
      );

      final Finder deckRow = find.byKey(
        const ValueKey<String>('srs-lapis-migration-target-deck'),
      );
      expect(
        find.descendant(
          of: deckRow,
          matching: find.text(t.srs_lapis_migration_keep_deck),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(t.srs_lapis_migration_target_deck));
      await _settle(tester);
      await tester.tap(find.text('Fushi').last);
      await _settle(tester);
      expect(
        find.descendant(of: deckRow, matching: find.text('Fushi')),
        findsOneWidget,
      );

      final Finder migrate = find.byKey(
        ValueKey<String>('srs-lapis-migration-migrate-$lapisId'),
      );
      await tester.ensureVisible(migrate);
      await _settle(tester, rounds: 4);
      await tester.tap(migrate);
      await _settle(tester);
      expect(
        find.textContaining(
          t.srs_lapis_migration_confirm_deck(deck: 'Fushi'),
          findRichText: true,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(t.srs_lapis_migration_migrate).last);
      await _settle(tester);

      final SrsNoteView after = (await _db(tester, () => store.note(note)))!;
      expect(after.noteTypeId, store.fushiCardNoteTypeId);
      expect(after.deckId, fushiDeck);
      final Map<String, List<SrsCardCacheRow>> cards = await _db(
        tester,
        () => store.cardsOfNotes(<String>[note]),
      );
      // 隐藏的是被换掉的旧模板卡（只作前身留历史），不移。
      expect(
        <String>{
          for (final SrsCardCacheRow c in cards[note]!)
            if (!c.hidden) c.deckId,
        },
        <String>{fushiDeck},
      );
      await _unmount(tester);
    });

    testWidgets('[$ds] 迁移页：旧版迁移漏掉的字段一键补迁，已有内容不动', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final (String note, String src) = await _seedLapisWithSource(
        tester,
        store,
      );
      // 旧版迁移：只按同名，「来源」整列丢失。
      await _db(tester, () async {
        final SrsNoteTypeView to = (await store.noteType(
          store.fushiCardNoteTypeId,
        ))!;
        final SrsNoteTypeView from = (await store.noteType(
          store.lapisNoteTypeId,
        ))!;
        await store.changeNoteType(
          noteIds: <String>[note],
          targetTypeId: to.id,
          fieldMap: <String, String?>{
            for (final SrsFieldDef f in to.fields)
              f.id: from.fields
                  .where((SrsFieldDef x) => x.name == f.name)
                  .firstOrNull
                  ?.id,
          },
          templateMap: <String, String?>{
            to.templates.single.id: from.templates.single.id,
          },
        );
      });
      expect(src, isNotEmpty);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsLegacyLapisMigrationPage(),
      );
      final Finder apply = find.byKey(
        const ValueKey<String>('srs-lapis-migration-backfill-apply'),
      );
      expect(apply, findsOneWidget);
      await tester.ensureVisible(apply);
      await _settle(tester, rounds: 4);
      await tester.tap(apply);
      await _settle(tester);
      await tester.tap(find.text(t.srs_lapis_migration_backfill_action).last);
      await _settle(tester);
      expect(
        (await _db(
          tester,
          () => store.note(note),
        ))!.field(srsFushiCardFieldId(store.profileUid, 'MiscInfo')),
        '《三月のライオン》',
      );
      expect(apply, findsNothing);
      await _unmount(tester);
    });

    testWidgets('[$ds] 笔记类型页：有旧 Lapis 笔记时显示迁移入口，点开迁移页', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _seedLapisWithSource(tester, store);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsNoteTypesPage(),
      );
      final Finder entry = find.byKey(
        const ValueKey<String>('srs-note-types-lapis-migration'),
      );
      expect(entry, findsOneWidget);
      expect(
        find.text(t.srs_lapis_migration_entry_summary(n: 1)),
        findsOneWidget,
      );
      await tester.tap(entry);
      await _settle(tester);
      expect(find.byType(SrsLegacyLapisMigrationPage), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表：有旧 Lapis 笔记时默认提醒迁移，点「迁移」打开迁移页', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _seedLapisWithSource(tester, store);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-lapis-migration-reminder')),
        findsOneWidget,
      );
      expect(
        find.text(t.srs_lapis_migration_entry_summary(n: 1)),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-lapis-migration-reminder-open')),
      );
      await _settle(tester);
      expect(find.byType(SrsLegacyLapisMigrationPage), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表：「不再提醒」后提醒消失；没有旧 Lapis 时不提醒', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      final Finder reminder = find.byKey(
        const ValueKey<String>('srs-lapis-migration-reminder'),
      );
      expect(reminder, findsNothing);
      await _unmount(tester);

      await _seedLapisWithSource(tester, store);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      expect(reminder, findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('srs-lapis-migration-reminder-dismiss'),
        ),
      );
      await _settle(tester);
      expect(reminder, findsNothing);
      await _unmount(tester);
    });
  }
}
