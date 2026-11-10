// 复习同步 v2「设备信任」（native/fushi_fsrs/src/store/sync2/trust.rs）：三台真实 v2 副本经内存位置同步。
// A 有库，B 之后加入（全新库，信任 A），C 是更晚加入的新设备、删了一条笔记。B 上 C 待确认：
// - 冲突中心「待确认的设备」卡片显示设备名、扣着的条数；笔记仍可见；信任（确认框）→ 删除生效、卡片消失；
// - 拒绝 → 卡片转「已拒绝」，笔记仍可见；
// - 同步页设备列表里 C 标「待确认」。
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
  _Env(this.dbs, this.b, this.cId, this.noteId, this.app, this.dir);

  final List<FushiDatabase> dbs;
  final SrsDbStore b;
  final String cId;
  final String noteId;
  final AppModel app;
  final Directory dir;
}

Future<void> _round(SrsDbStore s, SrsMemoryLocationStore location) =>
    srsSync2Round(
      host: s,
      location: location,
      locationId: 'test',
      nowMs: () => s.now().$1,
    );

Future<_Env> _open(WidgetTester tester) => _io(tester, () async {
  final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
    deviceId: 'a',
  );
  final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
    deviceId: 'b',
  );
  final (FushiDatabase dbC, SrsDbStore c) = await openSrsTestStore(
    deviceId: 'c',
  );
  final PreferencesRepository prefs = PreferencesRepository(dbB);
  await prefs.loadFromDb();
  final Directory dir = await Directory.systemTemp.createTemp(
    'srs_device_trust_',
  );
  final AppModel app = AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();
  await c.sync2DeviceInfo(model: 'Pixel 9', app: '3.3', platform: 'android');
  final String noteId = await a.createNote(
    noteTypeId: a.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kSrsTestProfile, 'Expression'): '魚',
    },
  );
  await _round(a, location);
  await _round(b, location);
  // C 更晚加入（全新库：信任 A、B），删掉 A 的笔记。
  await _round(c, location);
  await c.deleteNote(noteId);
  await _round(c, location);
  await _round(b, location);
  final String cId =
      (await c.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': c.now().$1,
          })).map['device']!
          as String;
  return _Env(<FushiDatabase>[dbA, dbB, dbC], b, cId, noteId, app, dir);
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

Future<bool> _hidden(WidgetTester tester, _Env env) async =>
    (await _io(tester, () => env.b.cardsOfNote(env.noteId))).single.hidden;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 冲突中心：新设备的删除扣着，信任后生效', (WidgetTester tester) async {
      final _Env env = await _open(tester);
      expect(await _hidden(tester, env), isFalse, reason: 'C 的删除在 B 上扣着');
      await _pump(tester, env, const SrsConflictsPage(), apple: apple);
      final Finder card = find.byKey(ValueKey<String>('srs-trust-${env.cId}'));
      await _pumpUntil(tester, card);
      expect(find.text(t.srs_trust_section), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.textContaining('Pixel 9')),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(t.srs_trust_pending_body(deletes: 1, purges: 0)),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey<String>('srs-trust-accept')),
        ),
      );
      await _settle(tester, rounds: 4);
      await tester.tap(find.text(t.srs_trust_action_trust).last);
      await _pumpUntil(tester, find.text(t.srs_conflicts_empty));
      expect(card, findsNothing);
      expect(await _hidden(tester, env), isTrue);
      await _close(tester, env);
    });

    testWidgets('[$ds] 冲突中心：拒绝后继续扣着；同步页标「待确认」', (WidgetTester tester) async {
      final _Env env = await _open(tester);
      await _pump(tester, env, const SrsHistoryPage(), apple: apple);
      final Finder tag = find.byKey(
        ValueKey<String>('srs_device_trust_${env.cId}'),
      );
      await _pumpUntil(tester, tag);
      expect(
        find.descendant(
          of: tag,
          matching: find.text(t.srs_device_trust_pending),
        ),
        findsOneWidget,
      );

      await _pump(tester, env, const SrsConflictsPage(), apple: apple);
      final Finder card = find.byKey(ValueKey<String>('srs-trust-${env.cId}'));
      await _pumpUntil(tester, card);
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey<String>('srs-trust-reject')),
        ),
      );
      await _pumpUntil(tester, find.text(t.srs_device_trust_rejected));
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey<String>('srs-trust-reject')),
        ),
        findsNothing,
      );
      expect(await _hidden(tester, env), isFalse);
      await _close(tester, env);
    });
  }
}
