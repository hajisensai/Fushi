// 复习「同步与历史」页（取代旧的定时备份页，docs/specs/2026-10-25-srs-sync-v2-design.md §10）：
// MD3 与 Apple 两套设计系统各 pump 一次。
//
// 内存主库 + 临时目录里的真 srs.db（Rust 内核），可拨的可信时钟让还原点 / 复习的先后确定；
// 数据库与文件 IO 一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
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

/// 页面里的真异步（drift + Rust 内核）要很多轮才能走完：推进直到 [done] 成立（最多约 10 秒）。
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

class _Env {
  _Env(this.db, this.store, this.clock, this.prefs, this.app, this.dir);

  final FushiDatabase db;
  final SrsDbStore store;
  final SrsTestClock clock;
  final PreferencesRepository prefs;
  final AppModel app;
  final Directory dir;
}

Future<_Env> _open(WidgetTester tester) => _io(tester, () async {
  final SrsTestClock clock = SrsTestClock();
  final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore(
    clock: clock,
  );
  final PreferencesRepository prefs = PreferencesRepository(db);
  await prefs.loadFromDb();
  final Directory dir = await Directory.systemTemp.createTemp(
    'srs_history_page_',
  );
  final AppModel app = AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
  return _Env(db, store, clock, prefs, app, dir);
});

Future<void> _close(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await _io(tester, () async {
    await env.db.close();
    try {
      await env.dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：临时目录留给系统清理。
    }
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
        appProvider.overrideWith((Ref ref) => env.app),
        srsStoreProvider.overrideWith((Ref ref) async => env.store),
        // 运行时（同步调度器 / AnkiConnect 端点）不在页面测试范围：保存文件夹位置后的那一轮同步跳过。
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
          home: const SrsHistoryPage(),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// 内核里叫 [name] 的还原点。
Future<SrsCheckpointView> _checkpoint(
  WidgetTester tester,
  SrsDbStore store,
  String name,
) async {
  final List<Map<String, Object?>> all = await _io(
    tester,
    store.sync2Checkpoints,
  );
  return SrsCheckpointView.fromJson(
    all.firstWhere((Map<String, Object?> c) => c['name'] == name),
  );
}

Finder _checkpointRow(SrsCheckpointView c) =>
    find.byKey(ValueKey<String>('srs-checkpoint-${c.at}-${c.name}'));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));
  tearDown(() => debugRealDirectoryPathOverride = null);

  test('恢复预览只预演一次：不撤回复习的一份 = 撤回那份去掉复习数', () {
    final SrsRestorePlanView retract = SrsRestorePlanView.fromJson(
      <String, Object?>{
        'fields': 3,
        'revived': 1,
        'removed': 2,
        'tags': 4,
        'reviews': 5,
      },
    );
    final SrsRestorePlanView keep = retract.withoutReviews();
    expect(
      <int>[keep.fields, keep.revived, keep.removed, keep.tags, keep.reviews],
      <int>[3, 1, 2, 4, 0],
    );
    final SrsRestorePlanView onlyReviews = SrsRestorePlanView.fromJson(
      <String, Object?>{'reviews': 2},
    );
    expect(onlyReviews.isEmpty, isFalse);
    expect(onlyReviews.withoutReviews().isEmpty, isTrue);
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 渲染：同步状态、存储位置、按时间点恢复、还原点列表（从新到旧）', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      await _addNote(tester, env.store, '雪');
      env.clock.advance(const Duration(minutes: 1));
      await _io(tester, () => env.store.sync2Checkpoint('older', 'manual'));
      env.clock.advance(const Duration(minutes: 1));
      await _io(
        tester,
        () => env.store.sync2Checkpoint('newer', 'bulk_delete'),
      );
      final SrsCheckpointView older = await _checkpoint(
        tester,
        env.store,
        'older',
      );
      final SrsCheckpointView newer = await _checkpoint(
        tester,
        env.store,
        'newer',
      );

      await _pump(tester, env, apple: apple);
      expect(isGlassDesign(tester.element(find.byType(SrsHistoryPage))), apple);
      await _pumpUntil(tester, _checkpointRow(older));

      for (final String key in <String>[
        'srs_timeline_status_summary',
        'srs_timeline_location_add',
        'srs_timeline_restore_moment',
        'srs_timeline_checkpoint',
        'srs_timeline_export',
        'srs_timeline_import',
      ]) {
        expect(
          find.byKey(ValueKey<String>(key)),
          findsAtLeastNWidgets(1),
          reason: key,
        );
      }
      expect(
        find.byKey(
          ValueKey<String>('srs_timeline_device_${env.store.sync2Device}'),
        ),
        findsOneWidget,
        reason: '本机设备行',
      );
      expect(find.text(t.srs_timeline_this_device), findsOneWidget);
      expect(_checkpointRow(newer), findsOneWidget);
      expect(
        find.descendant(
          of: _checkpointRow(older),
          matching: find.text(t.srs_timeline_reason_manual),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _checkpointRow(newer),
          matching: find.text(t.srs_timeline_reason_bulk_delete),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(_checkpointRow(newer)).dy,
        lessThan(tester.getTopLeft(_checkpointRow(older)).dy),
        reason: '从新到旧',
      );
      expect(tester.takeException(), isNull);
      await _close(tester, env);
    });

    testWidgets('[$ds] 同步在跑时状态卡说进行中与进度，不说「所有改动都已同步」', (
      WidgetTester tester,
    ) async {
      addTearDown(() => srsSyncProgress.value = null);
      final _Env env = await _open(tester);
      await _pump(tester, env, apple: apple);
      final Finder summary = find.byKey(
        const ValueKey<String>('srs_timeline_status_summary'),
      );
      await _pumpUntil(tester, summary);
      Finder inSummary(String text) =>
          find.descendant(of: summary, matching: find.text(text));

      const SrsSyncProgress running = SrsSyncProgress(
        stage: SrsSyncStage.downloading,
        done: 123,
        total: 2048,
      );
      srsSyncProgress.value = running;
      await tester.pump();
      expect(inSummary(t.srs_timeline_syncing), findsOneWidget);
      expect(inSummary(srsSyncProgressLine(running)), findsOneWidget);
      expect(inSummary(t.srs_timeline_all_published), findsNothing);
      // 页顶同步进度条同时亮出同一行进度。
      expect(
        find.byKey(const ValueKey<String>('sync-progress-banner-srs')),
        findsOneWidget,
      );

      srsSyncProgress.value = null;
      await _settle(tester, rounds: 6);
      expect(inSummary(t.srs_timeline_syncing), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('sync-progress-banner-srs')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _close(tester, env);
    });

    testWidgets('[$ds] 没有还原点：显示空状态', (WidgetTester tester) async {
      final _Env env = await _open(tester);
      final List<Map<String, Object?>> before = await _io(
        tester,
        env.store.sync2Checkpoints,
      );
      await _pump(tester, env, apple: apple);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('srs_timeline_restore_moment')),
      );
      if (before.isEmpty) {
        expect(find.text(t.srs_timeline_checkpoints_empty), findsOneWidget);
      } else {
        // 内核开库时自己打过还原点（迁移 / 导入等）：空状态不该出现。
        expect(find.text(t.srs_timeline_checkpoints_empty), findsNothing);
      }
      await _close(tester, env);
    });

    for (final bool retract in <bool>[true, false]) {
      testWidgets('[$ds] 点还原点 → 确认框'
          '${retract ? '勾上' : '不勾'}「同时撤回之后的复习」→ 恢复按这个选择执行', (
        WidgetTester tester,
      ) async {
        final _Env env = await _open(tester);
        final String note = await _addNote(tester, env.store, '雪');
        final String card = (await _io(
          tester,
          () => env.store.cardsOfNote(note),
        )).first.id;
        env.clock.advance(const Duration(minutes: 1));
        await _io(tester, () => env.store.sync2Checkpoint('cp', 'manual'));
        final SrsCheckpointView cp = await _checkpoint(tester, env.store, 'cp');
        env.clock.advance(const Duration(minutes: 1));
        await _io(tester, () => env.store.answer(card, 3));
        expect(
          (await _io(tester, () => env.store.history(card))).effective,
          hasLength(1),
        );

        await _pump(tester, env, apple: apple);
        await _pumpUntil(tester, _checkpointRow(cp));
        await tester.tap(_checkpointRow(cp));
        await _pumpUntil(
          tester,
          find.byKey(const ValueKey<String>('srs_timeline_restore_confirm')),
        );
        expect(find.text(t.srs_timeline_restore_title), findsOneWidget);
        if (retract) {
          await tester.tap(
            find.byKey(const ValueKey<String>('srs_timeline_restore_retract')),
          );
          await _settle(tester, rounds: 4);
          // 勾上后预览切到「连复习一起撤回」那份：多出一行复习条数。
          expect(
            find.textContaining(t.srs_timeline_plan_reviews(n: 1)),
            findsOneWidget,
          );
        }
        await tester.tap(
          find.byKey(const ValueKey<String>('srs_timeline_restore_confirm')),
        );
        // 恢复前内核自动打一个「恢复」还原点，页面随后重载列表：以界面上出现它为恢复已执行的信号。
        // 等界面而不是在 runAsync 里查 store：页面的写入跑在 fake zone 里、持着 store 的独占锁，
        // 只有 pump 才能推进它，runAsync 里再拿同一把锁会互等。
        await _pumpUntil(tester, find.text(t.srs_timeline_reason_restore));
        expect(
          (await _io(tester, () => env.store.history(card))).effective,
          hasLength(retract ? 0 : 1),
          reason: retract ? '勾上：之后的复习撤回' : '不勾：之后的复习保留',
        );
        await _close(tester, env);
      });
    }

    testWidgets('[$ds] 存储位置：添加文件夹 / 改用途停用 / 移除，都写进 prefs', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      final String usb = p.join(env.dir.path, 'usb');
      final String nas = p.join(env.dir.path, 'nas');
      await _io(tester, () async {
        await Directory(usb).create();
        await Directory(nas).create();
        await env.prefs.setSrsFolderLocations(<SrsFolderLocation>[
          SrsFolderLocation(id: 'usb', path: usb),
        ]);
      });
      await _pump(tester, env, apple: apple);
      final Finder usbRow = find.byKey(
        const ValueKey<String>('srs_timeline_folder_usb'),
      );
      await _pumpUntil(tester, usbRow);
      expect(find.text(usb), findsOneWidget);

      // 添加：目录选择器返回 nas。
      debugRealDirectoryPathOverride = nas;
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_timeline_location_add')),
      );
      await _pumpUntilTrue(
        tester,
        () async => env.prefs.srsFolderLocations.length == 2,
        reason: 'folder added',
      );
      final SrsFolderLocation added = env.prefs.srsFolderLocations.last;
      expect(added.path, nas);
      expect(added.id, isNotEmpty);
      expect(
        (added.sync, added.media, added.archive),
        (true, true, false),
        reason: '新位置默认同步 + 媒体，归档默认不开',
      );
      await _pumpUntil(
        tester,
        find.byKey(ValueKey<String>('srs_timeline_folder_${added.id}')),
      );

      // 停用：把 usb 的同步与媒体都关掉 → 一个用途都没有 = 保留配置但不跑。
      await tester.tap(usbRow);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('srs_timeline_purposes_save')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_timeline_purpose_sync')),
      );
      await _settle(tester, rounds: 2);
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_timeline_purpose_media')),
      );
      await _settle(tester, rounds: 2);
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_timeline_purposes_save')),
      );
      await _pumpUntilTrue(
        tester,
        () async => env.prefs.srsFolderLocations.first.idle,
        reason: 'usb disabled',
      );
      expect(env.prefs.srsFolderLocations.first.path, usb);
      expect(env.prefs.srsFolderLocations, hasLength(2));
      await _pumpUntil(
        tester,
        find.descendant(
          of: usbRow,
          matching: find.textContaining(t.srs_timeline_location_idle),
        ),
      );
      expect(Directory(usb).existsSync(), isTrue, reason: '停用不删文件');

      // 移除：确认后只从配置里拿掉，文件夹本身不动。
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_timeline_folder_remove_usb')),
      );
      await _pumpUntil(
        tester,
        find.text(t.srs_timeline_location_remove_confirm),
      );
      await tester.tap(find.text(t.srs_timeline_location_remove).last);
      await _pumpUntilTrue(
        tester,
        () async => env.prefs.srsFolderLocations.length == 1,
        reason: 'usb removed',
      );
      expect(env.prefs.srsFolderLocations.single.path, nas);
      expect(Directory(usb).existsSync(), isTrue, reason: '移除不删文件');
      await _close(tester, env);
    });
  }
}
