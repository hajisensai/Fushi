// 复习「备份」页：MD3 与 Apple 两套设计系统各 pump 一次。
//
// 内存库 + 临时目录里的真备份库（真文件读写），数据库与文件 IO 放 tester.runAsync。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_backups_page.dart';
import 'package:fushi/src/srs/srs_backup.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

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

/// 页面里的真异步（文件 IO + drift）要很多轮才能走完：推进直到 [finder] 出现（最多约 10 秒）。
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await _settle(tester, rounds: 4);
}

class _Env {
  _Env(this.db, this.store, this.backups, this.dir, this.controller);

  final FushiDatabase db;
  final SrsDbStore store;
  final SrsBackupStore backups;
  final Directory dir;
  final SrsBackupController controller;
}

Future<_Env> _open(WidgetTester tester) => _io(tester, () async {
  final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
  final Directory dir = await Directory.systemTemp.createTemp('srs_bk_page_');
  final SrsBackupStore backups = SrsBackupStore(
    root: Directory(p.join(dir.path, 'srs_backups')),
    profileUid: store.profileUid,
    mediaDir: Directory(p.join(dir.path, 'srs_media', store.profileUid)),
  );
  final SrsBackupController controller = SrsBackupController(
    readStore: () async => store,
    readBackups: () async => backups,
    autoEnabled: () => true,
    limits: () => const SrsBackupLimits(),
    profileName: (String uid) async => 'Test',
  );
  return _Env(db, store, backups, dir, controller);
});

Future<void> _close(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await _io(tester, () async {
    await env.db.close();
    await env.dir.delete(recursive: true);
  });
}

Future<String> _addNote(WidgetTester tester, SrsDbStore store, String text) =>
    _io(
      tester,
      () => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(store.profileUid, 'Expression'): text,
        },
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  _Env env, {
  required bool apple,
  Size size = const Size(1100, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
        srsStoreProvider.overrideWith((Ref ref) async => env.store),
        srsBackupStoreProvider.overrideWith((Ref ref) async => env.backups),
        srsBackupControllerProvider.overrideWith((Ref ref) => env.controller),
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
          home: const SrsBackupsPage(),
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

    testWidgets('[$ds] 列出备份（从新到旧，笔记 / 复习 / 大小）与自动备份设置', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      await _addNote(tester, env.store, '雪');
      final SrsBackupInfo older = await _io(
        tester,
        () => env.backups.create(
          env.store,
          kind: SrsBackupKind.auto,
          profileName: 'Test',
          nowMs: DateTime(2026, 10, 16, 9).millisecondsSinceEpoch,
        ),
      );
      await _addNote(tester, env.store, '雨');
      final SrsBackupInfo newer = await _io(
        tester,
        () => env.backups.create(
          env.store,
          kind: SrsBackupKind.manual,
          profileName: 'Test',
          nowMs: DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
        ),
      );
      await _pump(tester, env, apple: apple);
      expect(isGlassDesign(tester.element(find.byType(SrsBackupsPage))), apple);
      await _pumpUntil(
        tester,
        find.byKey(ValueKey<String>('srs-backup-${older.id}')),
      );

      final Finder rowNew = find.byKey(
        ValueKey<String>('srs-backup-${newer.id}'),
      );
      final Finder rowOld = find.byKey(
        ValueKey<String>('srs-backup-${older.id}'),
      );
      expect(rowNew, findsOneWidget);
      expect(rowOld, findsOneWidget);
      expect(
        tester.getTopLeft(rowNew).dy,
        lessThan(tester.getTopLeft(rowOld).dy),
        reason: '从新到旧',
      );
      expect(
        find.descendant(of: rowNew, matching: find.textContaining('2 notes')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowNew,
          matching: find.textContaining(t.srs_backup_kind_manual),
        ),
        findsOneWidget,
      );
      for (final String key in <String>[
        'srs_backup_location',
        'srs_backup_auto',
        'srs_backup_interval',
        'srs_backup_keep_daily',
        'srs_backup_keep_weekly',
        'srs_backup_keep_monthly',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      await _close(tester, env);
    });

    testWidgets('[$ds] 立即备份：列表多一份「手动」', (WidgetTester tester) async {
      final _Env env = await _open(tester);
      await _addNote(tester, env.store, '雪');
      await _pump(tester, env, apple: apple);
      await _pumpUntil(tester, find.text(t.srs_backup_empty));
      expect(find.text(t.srs_backup_empty), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_backup_now')).first,
      );
      await _pumpUntil(tester, find.textContaining('1 notes'));
      final List<SrsBackupInfo> list = await _io(tester, env.backups.list);
      expect(list, hasLength(1));
      expect(list.single.manifest.kind, SrsBackupKind.manual);
      expect(
        find.byKey(ValueKey<String>('srs-backup-${list.single.id}')),
        findsOneWidget,
      );
      await _close(tester, env);
    });

    testWidgets('[$ds] 点一份备份 → 确认 → 恢复到那个时间点，并自动存一份「恢复前」', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      final String n1 = await _addNote(tester, env.store, '雪');
      final SrsBackupInfo info = await _io(
        tester,
        () => env.backups.create(
          env.store,
          kind: SrsBackupKind.auto,
          profileName: 'Test',
          nowMs: DateTime(2026, 10, 16, 9).millisecondsSinceEpoch,
        ),
      );
      await _io(tester, () => env.store.deleteNote(n1));
      final String n2 = await _addNote(tester, env.store, '雨');
      await _pump(tester, env, apple: apple);
      await _pumpUntil(
        tester,
        find.byKey(ValueKey<String>('srs-backup-${info.id}')),
      );

      await tester.tap(find.byKey(ValueKey<String>('srs-backup-${info.id}')));
      await _settle(tester);
      expect(find.text(t.srs_backup_restore_confirm_title), findsOneWidget);
      await tester.tap(find.text(t.srs_backup_restore).last);
      await _pumpUntil(
        tester,
        find.textContaining(t.srs_backup_kind_pre_restore),
      );

      expect((await _io(tester, () => env.store.note(n1)))!.deletedAt, isNull);
      expect(
        (await _io(tester, () => env.store.note(n2)))!.deletedAt,
        isNotNull,
      );
      final List<SrsBackupInfo> list = await _io(tester, env.backups.list);
      expect(
        list.map((SrsBackupInfo b) => b.manifest.kind),
        contains(SrsBackupKind.preRestore),
      );
      expect(
        find.byKey(ValueKey<String>('srs-backup-${list.first.id}')),
        findsOneWidget,
        reason: '恢复前的那份出现在列表里，可以再恢复回去',
      );
      await _close(tester, env);
    });

    testWidgets('[$ds] 手机竖屏（390 宽）：设置与列表都能完整显示、无溢出', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      await _addNote(tester, env.store, '雪');
      final SrsBackupInfo info = await _io(
        tester,
        () => env.backups.create(
          env.store,
          kind: SrsBackupKind.preRestore,
          profileName: 'Test',
        ),
      );
      await _pump(tester, env, apple: apple, size: const Size(390, 844));
      await _pumpUntil(tester, find.text(t.srs_backup_list));
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey<String>('srs-backup-${info.id}')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.byKey(ValueKey<String>('srs-backup-${info.id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _close(tester, env);
    });
  }
}
