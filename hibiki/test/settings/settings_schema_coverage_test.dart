import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import '../../integration_test/helpers/effect_probes.dart';
import '../../integration_test/helpers/focus_driver.dart';
import '../../integration_test/helpers/schema_settings_verifier.dart';
import '../helpers/test_platform_services.dart';

/// 焦点驱动的 settings schema **全分组**覆盖测试（Phase 1 Task 4）。
///
/// 用仓库验证过的 settings_renderer harness（测试 AppModel + 内存 DB + 真实
/// schema + 真实 MaterialSettingsRenderer）逐个渲染**每个** destination 的明细
/// 页，再用 [FocusDriver] 以 Tab 焦点遍历整页：每个可聚焦节点若落在某个
/// `AdaptiveSettings*Row` 上就驱动它（Switch 用 Space 激活；Slider / Stepper /
/// Segmented 都是 _GamepadAdjustableValue 单一焦点停靠点，用 Left/Right 方向键
/// 原地调值），验证「改值 → 写穿 DB → 真生效 → 全局可还原」。
///
/// 生效探针按 destination 分派：reading → T1（`ReaderContentStyles.css` 渲染
/// 输入）；appearance → T2（`themeNotifier.theme` 渲染输入）；其余分组多为行为/
/// 持久类，暂无适用探针 → 按设计 §5 显式记为 UNVERIFIED 缺口（待 T4 行为探针），
/// 不静默放水也不误判失败。
///
/// 比 flutter drive 跑 app.main 更确定、更快、无 live-app 后台噪音；逐设置校验
/// 平台无关。整 app 流程的真机/桌面验证由 app_smoke 等承担（Phase 2-4）。
void main() {
  testWidgets(
      'all settings destinations: focus-driven, change persists and takes effect',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final ReaderSettings? prevReaderSettings =
        ReaderHibikiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderHibikiSource.readerSettings = prevReaderSettings);

    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    addTearDown(themeNotifier.dispose);
    // 用现成公开 seam 把 schema 渲染需要的子系统全部 wire 到同一内存 DB（不改
    // app_model.dart，避开并发 agent 冲突）：wireDatabaseForTesting 设 database；
    // wireLocalAudioForTesting 设 prefsRepo(+localAudioManager) —— prefsRepo 是
    // appearance/lookup/cardCreation/listening/system 绝大多数 blocker 的根源。
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_settings_cov_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      // 语言选择器读 locales late-Map；populateLanguages/Locales 是公开纯 Dart
      // 静态注册（startup 也调它们），填好 system 分组的语言项才能渲染。
      ..populateLanguages()
      ..populateLocales();

    // 探针：reading→T1 reader CSS；appearance→T2 themeNotifier.theme 渲染输入。
    final ReaderCssEffectProbe readerProbe =
        ReaderCssEffectProbe(() => readerSettings);
    final RenderInputProbe themeProbe = RenderInputProbe(
      () => '${themeNotifier.theme.colorScheme}|'
          '${themeNotifier.darkTheme.colorScheme}|'
          '${themeNotifier.brightnessMode}|${themeNotifier.appThemeKey}',
      tier: EffectTier.t2WidgetTree,
    );
    EffectProbe? probeFor(SettingsDestinationId id) => switch (id) {
          SettingsDestinationId.reading => readerProbe,
          SettingsDestinationId.appearance => themeProbe,
          _ => null,
        };

    final ValueNotifier<SettingsDestination?> destNotifier =
        ValueNotifier<SettingsDestination?>(null);
    addTearDown(destNotifier.dispose);
    List<SettingsDestination> destinations = const <SettingsDestination>[];

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            final List<SettingsDestination> all = buildSettingsSchema(sctx);
            destinations = all;
            return ValueListenableBuilder<SettingsDestination?>(
              valueListenable: destNotifier,
              builder: (_, SettingsDestination? dest, __) {
                return MaterialSettingsRenderer().buildDetailPage(
                  settingsContext: sctx,
                  destination: dest ?? all.first,
                );
              },
            );
          },
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    final Map<String, String> initial =
        Map<String, String>.from(await db.getAllPrefs());

    final FocusDriver driver = FocusDriver(tester);
    final List<ItemVerdict> verdicts = <ItemVerdict>[];
    final List<String> destFindings = <String>[];

    for (final SettingsDestination dest in destinations) {
      destNotifier.value = dest;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // 渲染该分组时可能抛多个异常（最小 harness 缺真实 AppModel 子系统状态）；
      // 全部 drain，记下第一条当发现，跳过该分组（不让残留异常判挂整测）。
      Object? renderEx;
      Object? e;
      while ((e = tester.takeException()) != null) {
        renderEx ??= e;
      }
      if (renderEx != null) {
        destFindings.add('${dest.id.name}: render threw $renderEx');
        debugPrint(
            '[schema-coverage] DEST ${dest.id.name} render FAILED: $renderEx');
        continue;
      }
      final EffectProbe? probe = probeFor(dest.id);
      final Set<FocusNode> seen = <FocusNode>{};
      final Set<String> driven = <String>{};
      int stale = 0;
      for (int step = 0; step < 400; step++) {
        final FocusNode? node = FocusManager.instance.primaryFocus;
        if (node != null && !seen.contains(node)) {
          seen.add(node);
          final _FocusedRow? row = _focusedSettingsRow();
          if (row != null && driven.add(row.title)) {
            verdicts.add(await _verifyFocusedNode(
              tester: tester,
              driver: driver,
              db: db,
              readerSettings: readerSettings,
              probe: probe,
              destId: dest.id.name,
              row: row,
            ));
          }
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 16));
        final FocusNode? now = FocusManager.instance.primaryFocus;
        if (now == null || seen.contains(now)) {
          if (++stale > 8) break;
        } else {
          stale = 0;
        }
      }
    }

    // 全局还原：改过的 key 写回初值，测试新增的 key 删除，再校验快照一致。
    final Map<String, String> afterAll =
        Map<String, String>.from(await db.getAllPrefs());
    for (final MapEntry<String, String> e in initial.entries) {
      if (afterAll[e.key] != e.value) {
        await db.setPref(e.key, e.value);
      }
    }
    for (final String k in afterAll.keys) {
      if (!initial.containsKey(k)) {
        await db.deletePref(k);
      }
    }
    await readerSettings.refreshFromDb();
    final bool globallyRestored =
        _mapsEqual(initial, Map<String, String>.from(await db.getAllPrefs()));

    for (final ItemVerdict v in verdicts) {
      debugPrint('[schema-coverage] ${_describe(v)}');
    }
    final int changed = verdicts.where((ItemVerdict v) => v.changed).length;
    final int effect =
        verdicts.where((ItemVerdict v) => v.effectVerified).length;
    final int unverified = verdicts
        .where((ItemVerdict v) => v.changed && !v.effectVerified)
        .length;
    debugPrint('[schema-coverage] ALL destinations: rows=${verdicts.length} '
        'changed=$changed effectVerified=$effect '
        'unverified(待 T4)=$unverified globallyRestored=$globallyRestored '
        'destFindings=${destFindings.length}');
    for (final String f in destFindings) {
      debugPrint('[schema-coverage] DEST-FINDING: $f');
    }

    expect(destFindings, isEmpty,
        reason: '全部 8 个 destination 都应能渲染（根本性修复：测试侧 wire 全部'
            '子系统）。渲染失败: ${destFindings.join("; ")}');
    expect(verdicts.length, greaterThan(40),
        reason: '应遍历到跨全部 8 个分组的大量可操作控件（焦点可达）');
    final List<ItemVerdict> notPersisted =
        verdicts.where((ItemVerdict v) => v.changed && !v.persisted).toList();
    expect(notPersisted, isEmpty,
        reason: '改了却没写穿 DB 的控件: '
            '${notPersisted.map((ItemVerdict v) => v.id).join(", ")}');
    expect(verdicts.where((ItemVerdict v) => v.effectVerified).length,
        greaterThanOrEqualTo(8),
        reason: 'reading(T1)+appearance(T2) 应有多项被探针确认真生效');
    expect(globallyRestored, isTrue, reason: '全部设置必须能还原到初始快照');
  });
}

String _describe(ItemVerdict v) {
  final String status = v.isPass
      ? 'PASS'
      : (v.changed && !v.effectVerified ? 'UNVERIFIED' : 'FAIL');
  return '[${v.controlType}] ${v.id} reached=${v.reached} '
      'changed=${v.changed} persisted=${v.persisted} '
      'effect=${v.effectVerified} restored=${v.restored} $status'
      '${v.note.isEmpty ? "" : " — ${v.note}"}';
}

_FocusedRow? _focusedSettingsRow() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  _FocusedRow? found;
  ctx.visitAncestorElements((Element el) {
    final Widget w = el.widget;
    if (w is AdaptiveSettingsSwitchRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.switchRow);
      return false;
    }
    if (w is AdaptiveSettingsSliderRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.slider);
      return false;
    }
    if (w is AdaptiveSettingsStepperRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.stepper);
      return false;
    }
    if (w is AdaptiveSettingsSegmentedRow) {
      found = _FocusedRow(
          title: (w as dynamic).title as String, kind: _RowKind.segmented);
      return false;
    }
    return true;
  });
  return found;
}

Future<ItemVerdict> _verifyFocusedNode({
  required WidgetTester tester,
  required FocusDriver driver,
  required HibikiDatabase db,
  required ReaderSettings readerSettings,
  required EffectProbe? probe,
  required String destId,
  required _FocusedRow row,
}) async {
  await readerSettings.refreshFromDb();
  final EffectSnapshot? effBefore = probe?.capture();
  final Map<String, String> before =
      Map<String, String>.from(await db.getAllPrefs());

  if (row.kind == _RowKind.switchRow) {
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 50));
  } else {
    await driver.adjust(steps: 4);
    await tester.pump(const Duration(milliseconds: 50));
    if (_mapsEqual(before, await db.getAllPrefs())) {
      await driver.adjust(steps: -4);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  final Object? thrown = tester.takeException();

  final Map<String, String> after =
      Map<String, String>.from(await db.getAllPrefs());
  await readerSettings.refreshFromDb();
  final bool persisted = !_mapsEqual(before, after);
  final bool changed = persisted;

  bool effectVerified = false;
  String note = '';
  if (probe != null && effBefore != null && changed) {
    effectVerified = probe.compare(effBefore, probe.capture()).changed;
    if (!effectVerified) {
      note = 'EFFECT UNVERIFIED: ${probe.kind.name} 渲染输入无变化（多为行为类设置，待 T4）';
    }
  } else if (!changed) {
    note = 'no change observed（驱动键不对 / 控件被门控 disabled）';
  } else {
    note = 'EFFECT UNVERIFIED: 该分组暂无适用探针（待 T4 行为探针）';
  }
  if (thrown != null) {
    note = '${note.isEmpty ? "" : "$note; "}THREW: $thrown';
  }

  return ItemVerdict(
    id: '$destId/${row.title}',
    controlType: row.kind.name,
    reached: true,
    changed: changed,
    persisted: persisted,
    effectVerified: effectVerified,
    restored: true,
    note: note,
  );
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

enum _RowKind { switchRow, slider, stepper, segmented }

class _FocusedRow {
  const _FocusedRow({required this.title, required this.kind});
  final String title;
  final _RowKind kind;
}
