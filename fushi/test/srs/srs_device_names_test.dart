// 复习同步 v2「设备可识别」（native/fushi_fsrs/src/store/sync2/devices.rs）：两台真实 v2 副本经内存位置同步。
// - 同步页「设备」列表：对端显示「<型号>（Fushi X.Y）」与状态；点它「这台设备不用了」→ 确认框 → 已停用；再点恢复。
// - 冲突中心：每一边显示设备名，给推荐与理由，勾「同类都按这个选」一次处理同类全部。
// MD3 与 Apple 两套设计系统各跑一遍；数据库读写一律放 tester.runAsync。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
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

class _Env {
  _Env(this.dbs, this.a, this.b, this.location, this.app, this.dir);

  final List<FushiDatabase> dbs;
  final SrsDbStore a;
  final SrsDbStore b;
  final SrsMemoryLocationStore location;
  final AppModel app;
  final Directory dir;

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

Future<String> _note(SrsDbStore s, String text) => s.createNote(
  noteTypeId: s.lapisNoteTypeId,
  fieldsById: <String, String>{
    srsLapisFieldId(kSrsTestProfile, 'Expression'): text,
  },
);

/// A 自报「iPhone 17 / 3.3 / ios」；[flagConflicts] 时两张卡的标志两边同时改（同类两条冲突）。
Future<_Env> _open(WidgetTester tester, {bool flagConflicts = false}) =>
    _io(tester, () async {
      final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
        deviceId: 'a',
      );
      final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
        deviceId: 'b',
      );
      final PreferencesRepository prefs = PreferencesRepository(dbB);
      await prefs.loadFromDb();
      final Directory dir = await Directory.systemTemp.createTemp(
        'srs_device_names_',
      );
      final AppModel app = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
      final _Env env = _Env(
        <FushiDatabase>[dbA, dbB],
        a,
        b,
        SrsMemoryLocationStore(),
        app,
        dir,
      );
      await a.sync2DeviceInfo(model: 'iPhone 17', app: '3.3', platform: 'ios');
      await b.sync2DeviceInfo(
        model: 'DESKTOP-1',
        app: '3.3',
        platform: 'windows',
        nick: 'Desk',
      );
      final List<String> notes = <String>[
        await _note(a, '花'),
        await _note(a, '魚'),
      ];
      await env.syncAll();
      if (flagConflicts) {
        for (final String n in notes) {
          final String card = (await a.cardsOfNote(n)).single.id;
          await a.setFlag(card, 1);
          await b.setFlag(card, 2);
        }
        await env.syncAll();
      }
      return env;
    });

Future<void> _close(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await _io(tester, () async {
    for (final FushiDatabase db in env.dbs) {
      await db.close();
    }
    try {
      await env.dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：临时目录留给系统清理。
    }
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Env env,
  Widget home, {
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => env.app),
        srsStoreProvider.overrideWith((Ref ref) async => env.b),
        srsAppRuntimeProvider.overrideWithValue(null),
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
          home: home,
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<Map<String, Object?>> _rowOf(
  WidgetTester tester,
  SrsDbStore store,
  String device,
) async {
  final Map<String, Object?> st = await _io(tester, store.sync2Status);
  return (st['devices']! as List<Object?>)
      .cast<Map<Object?, Object?>>()
      .firstWhere((Map<Object?, Object?> d) => d['device'] == device)
      .cast<String, Object?>();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 设备列表：对端显示「型号（Fushi 版本）」与状态；停用要确认、可恢复', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      final String aId = env.a.sync2Device!;
      await _pump(tester, env, const SrsHistoryPage(), apple: apple);
      final Finder row = find.byKey(
        ValueKey<String>('srs_timeline_device_$aId'),
      );
      await _pumpUntil(tester, row);
      // Apple 分组标题按平台惯例转大写。
      expect(
        find.text(
          apple ? t.srs_devices_section.toUpperCase() : t.srs_devices_section,
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            t.srs_device_label_versioned(name: 'iPhone 17', version: '3.3'),
          ),
        ),
        findsOneWidget,
      );
      final Finder state = find.byKey(
        ValueKey<String>('srs_device_state_$aId'),
      );
      expect(
        find.descendant(of: state, matching: find.text(t.srs_device_state_ok)),
        findsOneWidget,
      );

      // 本机行：标题是本机自己的名字，副标题「本机」（与其它行同一版式）。
      final Finder selfRow = find.byKey(
        ValueKey<String>('srs_timeline_device_${env.b.sync2Device!}'),
      );
      expect(
        find.descendant(
          of: selfRow,
          matching: find.text(
            t.srs_device_label_versioned(name: 'Desk', version: '3.3'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: selfRow,
          matching: find.text(t.srs_timeline_this_device),
        ),
        findsOneWidget,
      );

      // 停用：确认框说明后果，确认后状态变「已停用」、内核记下停用时刻。
      await tester.tap(row);
      await _pumpUntil(tester, find.text(t.srs_device_retire_action));
      expect(find.textContaining('Nothing is deleted'), findsOneWidget);
      await tester.tap(find.text(t.srs_device_retire_action));
      await _pumpUntil(
        tester,
        find.descendant(
          of: state,
          matching: find.text(t.srs_device_state_retired),
        ),
      );
      expect((await _rowOf(tester, env.b, aId))['retiredAt'], isNotNull);

      // 已停用的点一下就恢复（可逆、不删数据，不用确认）。
      await tester.tap(row);
      await _pumpUntil(
        tester,
        find.descendant(of: state, matching: find.text(t.srs_device_state_ok)),
      );
      expect((await _rowOf(tester, env.b, aId))['retiredAt'], isNull);
      await _close(tester, env);
    });

    testWidgets('[$ds] 冲突中心：两边显示设备名、给推荐理由，同类可一次按同一选择处理', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester, flagConflicts: true);
      expect(await _io(tester, env.b.syncConflicts), hasLength(2));
      await _pump(tester, env, const SrsConflictsPage(), apple: apple);
      final Finder cards = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('srs-conflict-') &&
            !(w.key! as ValueKey<String>).value.startsWith(
              'srs-conflict-apply',
            ) &&
            (w.key! as ValueKey<String>).value.length > 30,
      );
      await _pumpUntil(tester, cards);
      expect(cards, findsNWidgets(2));
      final Finder first = cards.first;
      // 一边是 A（自报名字），一边是本机。
      expect(
        find.descendant(
          of: first,
          matching: find.textContaining(
            t.srs_device_label_versioned(name: 'iPhone 17', version: '3.3'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: first,
          matching: find.textContaining(t.srs_timeline_this_device),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: first,
          matching: find.byKey(
            const ValueKey<String>('srs-conflict-recommendation'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: first,
          matching: find.textContaining(t.srs_conflict_reason_later),
        ),
        findsOneWidget,
      );
      final Finder same = find.descendant(
        of: first,
        matching: find.text(t.srs_conflict_apply_same(n: 2)),
      );
      expect(same, findsOneWidget);
      await tester.tap(same);
      await _settle(tester, rounds: 4);
      await tester.tap(
        find.descendant(
          of: first,
          matching: find.byKey(const ValueKey<String>('srs-conflict-confirm')),
        ),
      );
      await _pumpUntil(tester, find.text(t.srs_conflicts_empty));
      expect(await _io(tester, env.b.syncConflicts), isEmpty);
      await _close(tester, env);
    });
  }
}
