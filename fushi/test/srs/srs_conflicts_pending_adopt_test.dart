// 反馈 mvf7Wfz8Q-：冲突中心「等你决定的笔记」上万条时逐条点不完。顶栏「批量处理」加「冲突字段都用某台设备的版本」，
// 选中后再确认一次，按选择落地、列表清空。两台真实 v2 副本经内存位置同步；MD3 与 Apple 两套设计系统各 pump 一次；
// 数据库读写一律放 tester.runAsync。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
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

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 200; i++) {
    if (finder.evaluate().isNotEmpty) {
      await _settle(tester, rounds: 4);
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('timed out waiting: $finder');
}

final String _sentence = srsLapisFieldId(kSrsTestProfile, 'Sentence');

/// 两台设备、[n] 条笔记的例句被两边离线各改一次（真冲突）：B 这边都在「等你决定的笔记」里。
Future<(List<FushiDatabase>, SrsDbStore, List<String>)> _open(
  WidgetTester tester,
  int n,
) => _io(tester, () async {
  final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
    deviceId: 'a',
  );
  final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
    deviceId: 'b',
  );
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();
  Future<void> syncAll() async {
    for (int r = 0; r < 2; r++) {
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        await srsSync2Round(
          host: s,
          location: location,
          locationId: 'test',
          nowMs: () => s.now().$1,
        );
      }
    }
  }

  final List<String> notes = <String>[
    for (int i = 0; i < n; i++)
      await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '魚$i',
        },
      ),
  ];
  await syncAll();
  for (final String id in notes) {
    await a.updateNote(id, fieldsById: <String, String>{_sentence: 'A 側'});
    await b.updateNote(id, fieldsById: <String, String>{_sentence: 'B 側'});
  }
  await syncAll();
  return (<FushiDatabase>[dbA, dbB], b, notes);
});

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
    testWidgets('[$ds] 「批量处理」：等你决定的笔记整批采用本机的版本', (WidgetTester tester) async {
      final (List<FushiDatabase> dbs, SrsDbStore b, List<String> notes) =
          await _open(tester, 3);
      expect(
        (await _io(tester, b.notesPendingDecision)).length,
        3,
        reason: '前提：三条都待裁决',
      );
      await _pump(tester, b, apple: apple);
      await _pumpUntil(tester, find.text(t.srs_conflicts_pending_notes));
      final Finder bulk = find.byKey(
        const ValueKey<String>('srs_conflicts_bulk'),
      );
      expect(bulk, findsOneWidget, reason: '只有等你决定的笔记时批量按钮也在');
      await tester.tap(bulk);
      final String adoptSelf = t.srs_conflicts_bulk_pending_adopt(
        device: t.srs_timeline_this_device,
        n: 3,
      );
      await _pumpUntil(tester, find.text(adoptSelf));
      await tester.tap(find.text(adoptSelf));
      await _settle(tester, rounds: 6);
      // 整批改上万条字段不好撤回：再确认一次。
      expect(
        find.text(t.srs_conflicts_bulk_confirm_title(n: 3)),
        findsOneWidget,
      );
      await tester.tap(find.text(t.dialog_ok));
      await _pumpUntil(tester, find.text(t.srs_conflicts_empty));
      expect(await _io(tester, b.notesPendingDecision), isEmpty);
      for (final String id in notes) {
        expect((await _io(tester, () => b.note(id)))!.field(_sentence), 'B 側');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await _io(tester, () async {
        for (final FushiDatabase db in dbs) {
          await db.close();
        }
      });
    });
  }
}
