// 冲突中心「可能重复的笔记」一节（同步 v2，设计 §5.4）：同类型 + 同词形 + 同读音的两条笔记出现合并建议；
// 点「合并」后只剩保留的那条（被吸收那条删除、复习历史并进保留卡），点「不是重复」后建议消失、两条都保留。
// MD3 与 Apple 两套设计系统各 pump 一次；数据库读写一律放 tester.runAsync。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<T> _io<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpUntilTrue(
  WidgetTester tester,
  Future<bool> Function() done, {
  String reason = '',
}) async {
  for (int i = 0; i < 200; i++) {
    if (await _io(tester, done)) {
      await _settle(tester, rounds: 4);
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('timed out waiting: $reason');
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) => _pumpUntilTrue(
  tester,
  () async => finder.evaluate().isNotEmpty,
  reason: '$finder',
);

Future<String> _addNote(SrsDbStore s, String expression, String reading) =>
    s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisReadingFieldId(kSrsTestProfile): reading,
      },
    );

Future<void> _pump(
  WidgetTester tester,
  SrsDbStore store, {
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
        srsStoreProvider.overrideWith((Ref ref) async => store),
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
          home: const SrsConflictsPage(),
        ),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    for (final bool merge in <bool>[true, false]) {
      testWidgets('[$ds] 同词形同读音的两条笔记：出现合并建议，'
          '点「${merge ? '合并' : '不是重复'}」后按选择落地', (WidgetTester tester) async {
        final (FushiDatabase db, SrsDbStore store) = await _io(
          tester,
          openSrsTestStore,
        );
        final (String keep, String other, String keepCard) = await _io(
          tester,
          () async {
            final String keep = await _addNote(store, '雪', 'ゆき');
            final String other = await _addNote(store, '雪', 'ゆき');
            // 不同读音不算重复。
            await _addNote(store, '雪', 'せつ');
            final String keepCard = (await store.cardsOfNote(keep)).first.id;
            final String otherCard = (await store.cardsOfNote(other)).first.id;
            // 复习多的那条排最前、默认保留。
            await store.answer(keepCard, 3);
            await store.answer(keepCard, 3);
            await store.answer(otherCard, 1);
            return (keep, other, keepCard);
          },
        );
        final List<SrsDuplicateGroup> groups = await _io(
          tester,
          store.duplicateNoteGroups,
        );
        expect(groups, hasLength(1));
        expect(groups.single.noteIds, <String>[keep, other]);

        await _pump(tester, store, apple: apple);
        expect(
          isGlassDesign(tester.element(find.byType(SrsConflictsPage))),
          apple,
        );
        final Finder card = find.byKey(
          ValueKey<String>('srs-dup-${groups.single.noteIds.join('-')}'),
        );
        await _pumpUntil(tester, card);
        expect(find.text(t.srs_duplicates_title), findsOneWidget);
        for (final String id in <String>[keep, other]) {
          expect(
            find.descendant(
              of: card,
              matching: find.byKey(ValueKey<String>('srs-dup-row-$id')),
            ),
            findsOneWidget,
          );
        }

        await tester.tap(
          find.descendant(
            of: card,
            matching: find.byKey(
              ValueKey<String>(merge ? 'srs-dup-merge' : 'srs-dup-dismiss'),
            ),
          ),
        );
        // 等界面（而不是在 runAsync 里查 store）：页面的写入跑在 fake zone 里、持着 store 的独占锁，
        // 只有 pump 才能推进它；runAsync 里再去拿同一把锁会互等到超时（实测挂死整个 suite）。
        await _pumpUntil(tester, find.text(t.srs_conflicts_empty));
        expect(card, findsNothing);
        expect(await _io(tester, store.duplicateNoteGroups), isEmpty);

        final Map<String, SrsNoteView?> notes = await _io(
          tester,
          () => store.notes(<String>[keep, other]),
        );
        expect(notes[keep]!.deletedAt, isNull, reason: '保留的那条还在');
        if (merge) {
          expect(
            notes[other] == null || notes[other]!.deletedAt != null,
            isTrue,
            reason: '被吸收的那条删除',
          );
          expect(
            (await _io(tester, () => store.history(keepCard))).effective,
            hasLength(3),
            reason: '两条的复习历史并进保留卡',
          );
        } else {
          expect(notes[other]!.deletedAt, isNull, reason: '不是重复：两条都保留');
          expect(
            (await _io(tester, () => store.history(keepCard))).effective,
            hasLength(2),
          );
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await _io(tester, db.close);
      });
    }
  }
}
