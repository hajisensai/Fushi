// 冲突中心「删除被扣住」一节（同步 v2，设计 §5.3）：两台真实 v2 副本经内存位置同步，A 删笔记、B 离线改
// 同一条笔记 → 删除不自动判赢、进冲突中心；点「保留」/「删除」按选择落地并从列表消失。
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

/// 两台设备、一条被 A 删除且被 B 并发修改的笔记，B 这边已经收到冲突。
class _Env {
  _Env(this.dbs, this.a, this.b, this.location, this.noteId, this.conflictId);

  final List<FushiDatabase> dbs;
  final SrsDbStore a;
  final SrsDbStore b;
  final SrsMemoryLocationStore location;
  final String noteId;
  final String conflictId;

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
}

Future<_Env> _open(WidgetTester tester) => _io(tester, () async {
  final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
    deviceId: 'a',
  );
  final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
    deviceId: 'b',
  );
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();
  final String noteId = await a.createNote(
    noteTypeId: a.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kSrsTestProfile, 'Expression'): '魚',
    },
  );
  final _Env pre = _Env(<FushiDatabase>[dbA, dbB], a, b, location, noteId, '');
  await pre.syncAll();
  // 离线：A 删除，B 改字段。
  await a.deleteNote(noteId);
  await b.updateNote(
    noteId,
    fieldsById: <String, String>{
      srsLapisFieldId(kSrsTestProfile, 'Sentence'): '離線編集',
    },
  );
  await pre.syncAll();
  final List<Map<String, Object?>> held = await b.sync2Conflicts();
  return _Env(pre.dbs, a, b, location, noteId, held.single['id']! as String);
});

Future<void> _close(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await _io(tester, () async {
    for (final FushiDatabase db in env.dbs) {
      await db.close();
    }
  });
}

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

    for (final bool delete in <bool>[false, true]) {
      testWidgets('[$ds] 删除与并发修改被扣住：列在「删除被扣住」，'
          '点「${delete ? '删除' : '保留'}」按选择落地并同步到对端', (WidgetTester tester) async {
        final _Env env = await _open(tester);
        // 前提：两端都把删除扣住了、笔记仍可见。
        for (final SrsDbStore s in <SrsDbStore>[env.a, env.b]) {
          final List<Map<String, Object?>> c = await _io(
            tester,
            s.sync2Conflicts,
          );
          expect(c.single['kind'], 'delete_edit');
          expect(
            (await _io(tester, () => s.cardsOfNote(env.noteId))).single.hidden,
            isFalse,
          );
        }

        await _pump(tester, env.b, apple: apple);
        expect(
          isGlassDesign(tester.element(find.byType(SrsConflictsPage))),
          apple,
        );
        final Finder card = find.byKey(
          ValueKey<String>('srs-held-${env.conflictId}'),
        );
        await _pumpUntil(tester, card);
        expect(find.text(t.srs_conflicts_deletions), findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.textContaining('魚')),
          findsWidgets,
          reason: '按笔记第一个字段认',
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byKey(const ValueKey<String>('srs-held-delete')),
          ),
          findsOneWidget,
        );

        await tester.tap(
          find.descendant(
            of: card,
            matching: find.byKey(
              ValueKey<String>(delete ? 'srs-held-delete' : 'srs-held-keep'),
            ),
          ),
        );
        // 等界面（而不是在 runAsync 里查 store）：页面的写入跑在 fake zone 里、持着 store 的独占锁，
        // 只有 pump 才能推进它；runAsync 里再去拿同一把锁会互等到超时（实测挂死整个 suite）。
        await _pumpUntil(tester, find.text(t.srs_conflicts_empty));
        expect(card, findsNothing);
        expect(await _io(tester, env.b.sync2Conflicts), isEmpty);
        expect(
          (await _io(
            tester,
            () => env.b.cardsOfNote(env.noteId),
          )).single.hidden,
          delete,
        );

        // 结论是普通操作：同步到 A 后 A 的冲突也消失、状态一致。
        await _io(tester, env.syncAll);
        expect(await _io(tester, env.a.sync2Conflicts), isEmpty);
        expect(
          (await _io(
            tester,
            () => env.a.cardsOfNote(env.noteId),
          )).single.hidden,
          delete,
        );
        await _close(tester, env);
      });
    }
  }
}
