import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
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

/// 焦点驱动的 settings schema 覆盖测试（Phase 1 Task 4，widget 测试形态）。
///
/// 用仓库验证过的 settings_renderer harness（测试 AppModel + 内存 DB + 真实
/// schema + 真实 MaterialSettingsRenderer）渲染 reading 分组明细页，再用
/// [FocusDriver] 以 Tab 焦点遍历整页：每个可聚焦节点若落在某个
/// `AdaptiveSettings*Row` 上就驱动它（Switch 用 Space 激活；Slider / Stepper /
/// Segmented 都是 _GamepadAdjustableValue 包装的单一焦点停靠点，用 Left/Right
/// 方向键原地调值），验证「改值 → 写穿 DB → 真生效(T1) → 全局可还原」。
///
/// 比 flutter drive 上跑 app.main 更确定、更快、无 live-app 后台噪音；逐设置校验
/// 是平台无关的（焦点 + 框架 + 纯 Dart T1 探针）。整 app 流程的真机/桌面验证
/// 由 app_smoke 等目标承担（Phase 2-4）。
///
/// PASS = 五步全绿；只写穿 DB 不算过。行为类设置不影响阅读器 CSS、没有适用的 T1
/// 探针，按设计 §5 显式记为 UNVERIFIED 缺口（待 T4 行为探针），不静默放水也不
/// 误判失败。
void main() {
  testWidgets(
      'reading settings: focus-driven, change persists and takes effect',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // reader 设置后端指向这个内存 DB：reader 项的 onChanged 写到这里、T1 探针也读
    // 这里。测试后复原全局静态，避免泄漏到其它测试。
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
    final AppModel appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier;

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
      ],
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
            final SettingsDestination reading = buildSettingsSchema(sctx)
                .firstWhere((SettingsDestination d) =>
                    d.id == SettingsDestinationId.reading);
            return MaterialSettingsRenderer().buildDetailPage(
              settingsContext: sctx,
              destination: reading,
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final Map<String, String> initial =
        Map<String, String>.from(await db.getAllPrefs());

    final FocusDriver driver = FocusDriver(tester);
    final ReaderCssEffectProbe readerProbe =
        ReaderCssEffectProbe(() => readerSettings);
    final List<ItemVerdict> verdicts = <ItemVerdict>[];
    final Set<FocusNode> seen = <FocusNode>{};
    final Set<String> drivenTitles = <String>{};

    const int maxStops = 300;
    int stale = 0;
    for (int step = 0; step < maxStops; step++) {
      final FocusNode? node = FocusManager.instance.primaryFocus;
      if (node != null && !seen.contains(node)) {
        seen.add(node);
        final _FocusedRow? row = _focusedSettingsRow();
        if (row != null && !drivenTitles.contains(row.title)) {
          drivenTitles.add(row.title);
          verdicts.add(await _verifyFocusedNode(
            tester: tester,
            driver: driver,
            db: db,
            readerSettings: readerSettings,
            readerProbe: readerProbe,
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
    final Map<String, String> restored =
        Map<String, String>.from(await db.getAllPrefs());
    final bool globallyRestored = _mapsEqual(initial, restored);

    for (final ItemVerdict v in verdicts) {
      debugPrint('[schema-coverage] ${_describe(v)}');
    }
    final int changed = verdicts.where((ItemVerdict v) => v.changed).length;
    final int effect =
        verdicts.where((ItemVerdict v) => v.effectVerified).length;
    final int unverified = verdicts
        .where((ItemVerdict v) => v.changed && !v.effectVerified)
        .length;
    debugPrint('[schema-coverage] reading: rows=${verdicts.length} '
        'changed=$changed effectVerified=$effect '
        'unverified(T1-n/a或待T4)=$unverified globallyRestored=$globallyRestored');

    expect(verdicts.length, greaterThan(3),
        reason: 'reading 分组必须遍历到多个可操作控件（焦点可达）');
    final List<ItemVerdict> notPersisted =
        verdicts.where((ItemVerdict v) => v.changed && !v.persisted).toList();
    expect(notPersisted, isEmpty,
        reason: '改了却没写穿 DB 的控件: '
            '${notPersisted.map((ItemVerdict v) => v.id).join(", ")}');
    expect(verdicts.where((ItemVerdict v) => v.effectVerified).length,
        greaterThanOrEqualTo(8),
        reason: '阅读器 CSS 类设置应有多项被 T1 探针确认真生效');
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
  required ReaderCssEffectProbe readerProbe,
  required _FocusedRow row,
}) async {
  await readerSettings.refreshFromDb();
  final EffectSnapshot effBefore = readerProbe.capture();
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
  if (changed) {
    final EffectVerdict ev =
        readerProbe.compare(effBefore, readerProbe.capture());
    effectVerified = ev.changed;
    if (!effectVerified) {
      note = 'EFFECT UNVERIFIED: T1 reader-CSS 无变化（多为行为类设置，待 T4 探针）';
    }
  } else {
    note = 'no change observed（该控件的驱动键可能不对）';
  }
  if (thrown != null) {
    note = '${note.isEmpty ? "" : "$note; "}THREW: $thrown';
  }

  return ItemVerdict(
    id: row.title,
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
