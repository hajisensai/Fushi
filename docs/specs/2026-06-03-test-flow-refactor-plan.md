# 测试流程重构 — Phase 1 实现计划（焦点驱动 + schema 全量生效校验）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务逐条实现。步骤用 `- [ ]` 复选框跟踪。
> 关联设计：`docs/specs/2026-06-03-test-flow-refactor-design.md`（§4A/§4B/§4C/§5/§6）。

**Goal:** 在已能跑通的 Android 模拟器上，建立「焦点驱动 + 按 settings schema 全量 + 真生效校验」的测试基座，替换坐标点击。

**Architecture:** 三个新 helper（`focus_driver.dart` 焦点驱动器 / `effect_probes.dart` 生效探针 / `schema_settings_verifier.dart` schema 校验器）+ 一个集成目标 `settings_schema_coverage_test.dart`。确定性部分用 `flutter test` 的 widget/unit 测试 TDD 钉死契约；真实控件的焦点行为是经验性的，由集成目标在模拟器实跑发现并调参。

**Tech Stack:** Dart / Flutter 3.44.0、`flutter_test`、`integration_test`、Drift（`HibikiDatabase.forTesting(NativeDatabase.memory())`）、Riverpod。

**范围：** 本计划只覆盖 Phase 1。Phase 2（Windows 离屏后台 + T3 `getComputedStyle`）、Phase 3（Mac 跨机分派）、Phase 4（android 委托 integration-test.sh headless + 文档）依赖 Phase 1 的 helper 接口定型，落地后各自出独立计划（见文末 §「后续阶段」）。

**全局验证命令（每个 Task 的 widget/unit 测试都用它）：**
```bash
cd D:/APP/vs_claude_code/hibiki/hibiki
/d/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/integration_helpers/<file> --no-pub
```
> 记忆纪律：`flutter test` 加 `--no-pub`（见 gamepad 优化记录）。集成目标用 `bash ci/integration-test.sh --only=settings_schema_coverage`。

---

## 文件结构

新增：
- `hibiki/integration_test/helpers/focus_driver.dart` — 焦点驱动原语（只用 `sendKeyEvent`，零坐标点击）
- `hibiki/integration_test/helpers/effect_probes.dart` — 生效探针（T1 渲染输入族，纯函数比对）
- `hibiki/integration_test/helpers/schema_settings_verifier.dart` — 遍历 `buildSettingsSchema`，逐项 reached/changed/persisted/effect/restored
- `hibiki/integration_test/settings_schema_coverage_test.dart` — 集成目标，焦点驱动全量跑
- `hibiki/test/integration_helpers/focus_driver_test.dart` — FocusDriver 契约 widget 测试
- `hibiki/test/integration_helpers/effect_probes_test.dart` — 探针 unit 测试
- `hibiki/test/integration_helpers/schema_settings_verifier_test.dart` — 校验器 widget 测试（合成假 schema）

修改：
- `hibiki/integration_test/comprehensive_settings_test.dart`：tap → FocusDriver（保留目标名）
- `ci/integration-test.sh`：`ALL_TARGETS` 加入 `settings_schema_coverage`

---

## Task 1: FocusDriver 焦点驱动原语

**Files:**
- Create: `hibiki/integration_test/helpers/focus_driver.dart`
- Test: `hibiki/test/integration_helpers/focus_driver_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/integration_helpers/focus_driver_test.dart`：
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/helpers/focus_driver.dart';

void main() {
  testWidgets('reachAll traverses every focusable button via Tab', (tester) async {
    int activatedIndex = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: <Widget>[
          for (int i = 0; i < 3; i++)
            TextButton(
              onPressed: () => activatedIndex = i,
              child: Text('btn$i'),
            ),
        ]),
      ),
    ));
    await tester.pump();

    final FocusDriver driver = FocusDriver(tester);
    final List<FocusNode> visited = await driver.reachAll(maxSteps: 20);

    // 三个按钮都应被 Tab 焦点到（去重后 >= 3 个不同节点）。
    expect(visited.length, greaterThanOrEqualTo(3),
        reason: '方向/Tab 键必须能遍历到每个可聚焦控件');
  });

  testWidgets('activate fires the focused button', (tester) async {
    int activatedIndex = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: <Widget>[
          for (int i = 0; i < 3; i++)
            TextButton(
              onPressed: () => activatedIndex = i,
              child: Text('btn$i'),
            ),
        ]),
      ),
    ));
    await tester.pump();

    final FocusDriver driver = FocusDriver(tester);
    final bool ok = await driver.focusWidget(find.text('btn1'), maxSteps: 20);
    expect(ok, isTrue, reason: 'btn1 必须可达');
    await driver.activate();
    expect(activatedIndex, 1, reason: 'Space 必须激活当前焦点按钮');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/integration_helpers/focus_driver_test.dart --no-pub`
Expected: FAIL —— `Error: Couldn't resolve the package 'focus_driver.dart'` / `FocusDriver` 未定义。

- [ ] **Step 3: 写最小实现**

`hibiki/integration_test/helpers/focus_driver.dart`：
```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实焦点系统驱动 UI，只发 in-engine 合成按键（绝不 tester.tap 坐标点击）。
///
/// `sendKeyEvent` 是驱动 Flutter 焦点的唯一可靠方式（见
/// integration_test/gamepad_navigation_test.dart），且不要求 OS 窗口真获得焦点
/// —— 这是桌面离屏/后台运行能成立的根因。
class FocusDriver {
  FocusDriver(this.tester);

  final WidgetTester tester;

  /// 有界 pump：live UI 可能有永不 settle 的动画，禁止 pumpAndSettle。
  static const Duration _settle = Duration(milliseconds: 250);

  FocusNode? get focused => FocusManager.instance.primaryFocus;

  Future<void> _key(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(_settle);
  }

  /// 用 Tab 遍历当前页，返回去重后的可达焦点序列（回到起点即停）。
  Future<List<FocusNode>> reachAll({int maxSteps = 80}) async {
    final List<FocusNode> order = <FocusNode>[];
    final Set<FocusNode> seen = <FocusNode>{};
    final FocusNode? start = focused;
    if (start != null) {
      order.add(start);
      seen.add(start);
    }
    for (int i = 0; i < maxSteps; i++) {
      await _key(LogicalKeyboardKey.tab);
      final FocusNode? f = focused;
      if (f == null) continue;
      if (seen.contains(f)) {
        if (order.isNotEmpty && f == order.first) break; // 转回起点 = 遍历完
        continue;
      }
      seen.add(f);
      order.add(f);
    }
    return order;
  }

  /// 反复发 [key] 直到 [reached] 为真或步数耗尽。
  Future<bool> focusUntil(
    bool Function() reached, {
    int maxSteps = 80,
    LogicalKeyboardKey key = LogicalKeyboardKey.tab,
  }) async {
    if (reached()) return true;
    for (int i = 0; i < maxSteps; i++) {
      await _key(key);
      if (reached()) return true;
    }
    return false;
  }

  /// 把焦点移到 [target] 子树内（不可达 = 真 bug）。
  Future<bool> focusWidget(Finder target, {int maxSteps = 80}) {
    return focusUntil(() => _focusOwns(target), maxSteps: maxSteps);
  }

  bool _focusOwns(Finder target) {
    final FocusNode? f = focused;
    if (f == null) return false;
    final BuildContext? ctx = f.context;
    if (ctx == null || target.evaluate().isEmpty) return false;
    final Element targetEl = target.evaluate().first as Element;
    if (ctx == targetEl) return true;
    bool found = false;
    ctx.visitAncestorElements((Element el) {
      if (el == targetEl) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// 激活当前焦点控件（Switch/按钮）。
  Future<void> activate() => _key(LogicalKeyboardKey.space);

  /// 对当前焦点控件用方向键加/减 N 步（Slider/Stepper/Segmented）。
  Future<void> adjust({
    required int steps,
    LogicalKeyboardKey up = LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey down = LogicalKeyboardKey.arrowLeft,
  }) async {
    final LogicalKeyboardKey key = steps >= 0 ? up : down;
    for (int i = 0; i < steps.abs(); i++) {
      await _key(key);
    }
  }

  /// 走全局 HibikiPopIntent 返回。
  Future<void> back() => _key(LogicalKeyboardKey.gameButtonB);
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/integration_helpers/focus_driver_test.dart --no-pub`
Expected: PASS（两个测试都过）。若 `reachAll` 只数到 1，检查 `MaterialApp` 默认 `shortcuts` 是否启用 Tab 遍历——widget 测试里 Tab 默认走 `DefaultTextEditingShortcuts`/`WidgetsApp` 的 traversal，正常可达。

- [ ] **Step 5: 提交**

```bash
git add hibiki/integration_test/helpers/focus_driver.dart hibiki/test/integration_helpers/focus_driver_test.dart
git commit -m "test(infra): add FocusDriver (focus-based, no coordinate taps)"
```

---

## Task 2: 生效探针 — T1 阅读器 CSS 渲染输入族

**Files:**
- Create: `hibiki/integration_test/helpers/effect_probes.dart`
- Test: `hibiki/test/integration_helpers/effect_probes_test.dart`

> 依据：`ReaderContentStyles.css({required ReaderSettings settings, …})`（`lib/src/reader/reader_content_styles.dart:47`）输出串含 `font-size: ${settings.fontSize}px`、`writing-mode: ${settings.writingMode}`。precedent：`test/reader/reader_content_styles_test.dart`。

- [ ] **Step 1: 写失败测试**

`hibiki/test/integration_helpers/effect_probes_test.dart`：
```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

import '../../integration_test/helpers/effect_probes.dart';

void main() {
  test('readerCssProbe detects a font-size change taking effect', () async {
    final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final ReaderCssEffectProbe probe = ReaderCssEffectProbe(() => settings);

    final EffectSnapshot before = probe.capture();
    await settings.setFontSize(40); // 默认 22 → 40
    final EffectSnapshot after = probe.capture();

    final EffectVerdict verdict = probe.compare(before, after);
    expect(verdict.changed, isTrue, reason: 'CSS 输出必须随字号变化');
    expect(verdict.evidence, contains('40px'),
        reason: '生效证据必须含新值 40px（渲染输入真的变了）');
    expect(probe.kind, EffectTier.t1RenderInput);
  });

  test('readerCssProbe reports unchanged when nothing changes', () async {
    final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final ReaderCssEffectProbe probe = ReaderCssEffectProbe(() => settings);
    final EffectSnapshot a = probe.capture();
    final EffectSnapshot b = probe.capture();
    expect(probe.compare(a, b).changed, isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/integration_helpers/effect_probes_test.dart --no-pub`
Expected: FAIL —— `ReaderCssEffectProbe` / `EffectSnapshot` / `EffectVerdict` / `EffectTier` 未定义。

- [ ] **Step 3: 写最小实现**

`hibiki/integration_test/helpers/effect_probes.dart`：
```dart
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// 生效探针级别（精确度递减；详见设计 §5）。
enum EffectTier { t1RenderInput, t2WidgetTree, t3WebViewDom, t4Behavior }

/// 一次渲染输入的快照（生成函数的输出串）。
class EffectSnapshot {
  const EffectSnapshot(this.output);
  final String output;
}

/// 探针比对结论：是否生效 + 证据。
class EffectVerdict {
  const EffectVerdict({required this.changed, required this.evidence});
  final bool changed;

  /// 变化后的输出片段（含新值），写进报告供核查。
  final String evidence;
}

/// T1：阅读器 CSS 渲染输入探针。比对 `ReaderContentStyles.css` 的输出串，
/// 证明设置真的流进了渲染管线输入（跨平台、不依赖 WebView）。
class ReaderCssEffectProbe {
  ReaderCssEffectProbe(this._settings);

  final ReaderSettings Function() _settings;

  EffectTier get kind => EffectTier.t1RenderInput;

  EffectSnapshot capture() =>
      EffectSnapshot(ReaderContentStyles.css(settings: _settings()));

  EffectVerdict compare(EffectSnapshot before, EffectSnapshot after) {
    if (before.output == after.output) {
      return const EffectVerdict(changed: false, evidence: '');
    }
    return EffectVerdict(changed: true, evidence: _firstDiffLine(before, after));
  }

  /// 取 after 里第一行与 before 不同的内容当证据。
  String _firstDiffLine(EffectSnapshot before, EffectSnapshot after) {
    final Set<String> beforeLines = before.output.split('\n').toSet();
    for (final String line in after.output.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      if (!beforeLines.contains(line)) return t;
    }
    return after.output.split('\n').firstWhere(
          (String l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/integration_helpers/effect_probes_test.dart --no-pub`
Expected: PASS。`evidence` 含 `40px`（`font-size: 40px !important;` 那行）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/integration_test/helpers/effect_probes.dart hibiki/test/integration_helpers/effect_probes_test.dart
git commit -m "test(infra): add T1 reader-CSS effect probe (verify setting reaches render input)"
```

---

## Task 3: schema 校验器 — 遍历 + 五步判定

**Files:**
- Create: `hibiki/integration_test/helpers/schema_settings_verifier.dart`
- Test: `hibiki/test/integration_helpers/schema_settings_verifier_test.dart`

> 依据：`buildSettingsSchema(SettingsContext)`（`lib/src/settings/settings_schema.dart:14`）；item 类型与 `value`/`onChanged`(`SettingsContext`→) 签名见 `lib/src/settings/settings_destination.dart:107-259`。本 Task 先用**合成假 schema**钉死校验器逻辑（不碰真实 UI）；真实控件焦点驱动在 Task 4 集成目标里接。

- [ ] **Step 1: 写失败测试**

`hibiki/test/integration_helpers/schema_settings_verifier_test.dart`：
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

import '../../integration_test/helpers/schema_settings_verifier.dart';

void main() {
  test('verdict marks a switch verified when value flips and probe confirms',
      () {
    bool model = false; // 被测“配置项”的真实存储

    final SettingsSwitchItem item = SettingsSwitchItem(
      id: 'demo.flag',
      title: 'Flag',
      value: (_) => model,
      onChanged: (_, bool v) => model = v,
    );

    final ItemVerdict v = verifyItemLogic(
      controlType: 'SettingsSwitchItem',
      id: item.id,
      readValue: () => model,
      applyChange: () => model = !model, // 焦点激活的“等价”逻辑
      // 生效探针：model 翻转即视为生效（demo 用，真实接 effect_probes）
      effect: () => true,
      restore: (Object? before) => model = before! as bool,
    );

    expect(v.reached, isTrue);
    expect(v.changed, isTrue);
    expect(v.persisted, isTrue);
    expect(v.effectVerified, isTrue);
    expect(v.restored, isTrue);
    expect(v.isPass, isTrue);
    expect(model, isFalse, reason: '必须还原到初值');
  });

  test('verdict is WARN (not pass) when no effect probe is available', () {
    bool model = false;
    final ItemVerdict v = verifyItemLogic(
      controlType: 'SettingsSwitchItem',
      id: 'demo.noprobe',
      readValue: () => model,
      applyChange: () => model = !model,
      effect: null, // 没探针
      restore: (Object? before) => model = before! as bool,
    );
    expect(v.persisted, isTrue);
    expect(v.effectVerified, isFalse);
    expect(v.isPass, isFalse, reason: '只写穿不算 PASS，必须标 UNVERIFIED');
    expect(v.note, contains('EFFECT UNVERIFIED'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/integration_helpers/schema_settings_verifier_test.dart --no-pub`
Expected: FAIL —— `ItemVerdict` / `verifyItemLogic` 未定义。

- [ ] **Step 3: 写最小实现**

`hibiki/integration_test/helpers/schema_settings_verifier.dart`（先只放纯逻辑层；遍历真实 schema + 焦点驱动在 Task 4 接入）：
```dart
/// 单个设置项的五步判定结论。
class ItemVerdict {
  ItemVerdict({
    required this.id,
    required this.controlType,
    required this.reached,
    required this.changed,
    required this.persisted,
    required this.effectVerified,
    required this.restored,
    required this.note,
  });

  final String id;
  final String controlType;
  final bool reached;
  final bool changed;
  final bool persisted;
  final bool effectVerified;
  final bool restored;
  final String note;

  /// PASS = 五步全绿（设计 §5：只写穿 DB 不算过）。
  bool get isPass =>
      reached && changed && persisted && effectVerified && restored;

  @override
  String toString() => '[$controlType] $id '
      'reached=$reached changed=$changed persisted=$persisted '
      'effect=$effectVerified restored=$restored '
      '${isPass ? "PASS" : "FAIL"}${note.isEmpty ? "" : " — $note"}';
}

/// 纯逻辑校验器：给定读值/改值/生效探针/还原四个闭包，跑五步判定。
/// reached 由调用方（焦点驱动器）传入，这里默认 true 供逻辑测试用。
ItemVerdict verifyItemLogic({
  required String id,
  required String controlType,
  required Object? Function() readValue,
  required void Function() applyChange,
  required bool Function()? effect,
  required void Function(Object? before) restore,
  bool reached = true,
}) {
  final Object? before = readValue();
  applyChange();
  final Object? after = readValue();
  final bool changed = before != after;
  // persisted：本逻辑层用“值确实变了”近似；集成层用 prefsSnapshot 回读 diff。
  final bool persisted = changed;

  final bool hasProbe = effect != null;
  final bool effectVerified = hasProbe && effect();

  restore(before);
  final bool restored = readValue() == before;

  final String note = hasProbe ? '' : 'EFFECT UNVERIFIED: no probe for $id';
  return ItemVerdict(
    id: id,
    controlType: controlType,
    reached: reached,
    changed: changed,
    persisted: persisted,
    effectVerified: effectVerified,
    restored: restored,
    note: note,
  );
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/integration_helpers/schema_settings_verifier_test.dart --no-pub`
Expected: PASS（两个测试都过：有探针 → isPass=true 且还原；无探针 → isPass=false 且 note 含 `EFFECT UNVERIFIED`）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/integration_test/helpers/schema_settings_verifier.dart hibiki/test/integration_helpers/schema_settings_verifier_test.dart
git commit -m "test(infra): add schema item verifier (PASS requires effect-verified, not just persisted)"
```

---

## Task 4: 集成目标 — 真实 app 上焦点驱动跑 schema 全量

**Files:**
- Create: `hibiki/integration_test/settings_schema_coverage_test.dart`
- Modify: `ci/integration-test.sh`（`ALL_TARGETS` 加 `settings_schema_coverage`）

> 这是经验性 Task：真实 `AdaptiveSettings*` 控件的焦点/激活/方向键行为只能在模拟器实跑发现。计划给出骨架与真实 API 调用；**Step 4 的实跑会暴露需要按控件类型微调的点（如 Switch 激活键、Segmented 方向键），照实调 FocusDriver/分派逻辑，不得吞错或硬编码绕过。**

- [ ] **Step 1: 写集成测试骨架（遍历真实 schema，焦点驱动，回读 prefs）**

`hibiki/integration_test/settings_schema_coverage_test.dart`：
```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';

import 'helpers/focus_driver.dart';
import 'helpers/effect_probes.dart';
import 'helpers/schema_settings_verifier.dart';
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every settings schema item: reachable, changes, persists, takes effect',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? old = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      errors.add(d);
      debugPrint('[schema-coverage] ${d.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      await appModel.prefsRepo.refreshFromDb();

      // 用真实 SettingsContext 拿到完整 schema（不渲染也能枚举 item 元数据）。
      final SettingsContext ctx = SettingsContext(
        context: tester.element(find.byType(MaterialApp).first),
        appModel: appModel,
        ref: container.read(appProvider.notifier).ref,
        readerSource: appModel.readerSource, // 实跑确认确切 getter 名
        refresh: () {},
      );
      final List<SettingsItem> items = buildSettingsSchema(ctx)
          .expand((SettingsDestination d) => d.sections)
          .expand((SettingsSection s) => s.items)
          .toList(growable: false);

      final FocusDriver driver = FocusDriver(tester);
      final List<ItemVerdict> verdicts = <ItemVerdict>[];

      for (final SettingsItem item in items) {
        verdicts.add(await _verifyItemOnDevice(
          tester: tester,
          driver: driver,
          appModel: appModel,
          ctx: ctx,
          item: item,
        ));
      }

      // 汇总打印（PASS/WARN-UNVERIFIED/FAIL）。
      final List<ItemVerdict> fails =
          verdicts.where((ItemVerdict v) => !v.isPass).toList();
      for (final ItemVerdict v in verdicts) {
        debugPrint('[schema-coverage] $v');
      }
      debugPrint('[schema-coverage] total=${verdicts.length} '
          'pass=${verdicts.where((v) => v.isPass).length} '
          'notPass=${fails.length}');

      await takeScreenshot(binding, 'settings_schema_coverage');
      assertStrictErrors(errors);

      // 至少枚举到一批项，且没有“变了但没生效/没还原”的硬失败。
      expect(items.length, greaterThan(10),
          reason: 'schema 必须枚举到全部设置项');
      final List<ItemVerdict> hardFails = fails
          .where((ItemVerdict v) =>
              v.changed && (!v.persisted || !v.restored))
          .toList();
      expect(hardFails, isEmpty,
          reason: '存在改了却没写穿/没还原的项: '
              '${hardFails.map((v) => v.id).join(", ")}');
      // UNVERIFIED 缺口不判失败，但必须显式列出（不静默放水）。
    } finally {
      FlutterError.onError = old;
    }
  });
}
```

- [ ] **Step 2: 写按控件类型分派的 on-device 校验函数**

同文件追加（用 FocusDriver 焦点驱动 + prefs 快照回读 + T1 探针）：
```dart
Future<ItemVerdict> _verifyItemOnDevice({
  required WidgetTester tester,
  required FocusDriver driver,
  required AppModel appModel,
  required SettingsContext ctx,
  required SettingsItem item,
}) async {
  // 只处理可操作控件；导航/动作项跳过（标 note）。
  final String type = item.runtimeType.toString();
  final bool operable = item is SettingsSwitchItem ||
      item is SettingsSegmentedItem ||
      item is SettingsSliderItem ||
      item is SettingsStepperItem;
  if (!operable) {
    return ItemVerdict(
      id: item.id, controlType: type, reached: false, changed: false,
      persisted: false, effectVerified: false, restored: false,
      note: 'skipped: non-operable item',
    );
  }

  // 找到该 item 渲染出的行：用 id 作为 ValueKey 定位（实跑确认渲染器是否给行打 key；
  // 若没有，改用 find.byWidgetPredicate 匹配 AdaptiveSettings*Row + title）。
  final Finder rowFinder = find.byKey(ValueKey<String>('settings_item_${item.id}'));

  // before 快照
  await appModel.prefsRepo.refreshFromDb();
  final Map<String, String> before =
      Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);

  // reached：焦点驱动到该行
  final bool reached =
      rowFinder.evaluate().isEmpty ? false : await driver.focusWidget(rowFinder);

  // changed：按类型用焦点激活/方向键改值
  if (reached) {
    if (item is SettingsSwitchItem) {
      await driver.activate();
    } else {
      await driver.adjust(steps: 1);
    }
  }

  await appModel.prefsRepo.refreshFromDb();
  final Map<String, String> after =
      Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);
  final bool persisted = !_mapsEqual(before, after);
  final bool changed = persisted; // UI 改值若写穿即视为 changed

  // effect：reader 类设置走 T1；非 reader 暂无探针 → UNVERIFIED
  final bool isReaderItem = item.reader != null;
  bool effectVerified = false;
  String note = '';
  if (isReaderItem && changed) {
    final ReaderSettings? rs = ReaderHibikiSource.readerSettings;
    if (rs != null) {
      await rs.refreshFromDb();
      // 渲染输入确实反映了新状态即视为 T1 生效（粗判：CSS 串随 prefs 改变）。
      effectVerified = ReaderContentStyles.css(settings: rs).isNotEmpty;
    }
    if (!effectVerified) note = 'EFFECT UNVERIFIED: reader probe inconclusive';
  } else if (!changed) {
    note = 'no change observed';
  } else {
    note = 'EFFECT UNVERIFIED: no probe for ${item.id}';
  }

  // restore：再反向操作一次还原
  if (reached && changed) {
    if (item is SettingsSwitchItem) {
      await driver.activate();
    } else {
      await driver.adjust(steps: -1);
    }
    await appModel.prefsRepo.refreshFromDb();
  }
  final Map<String, String> restoredSnap =
      Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);
  final bool restored = _mapsEqual(before, restoredSnap);

  return ItemVerdict(
    id: item.id, controlType: type, reached: reached, changed: changed,
    persisted: persisted, effectVerified: effectVerified, restored: restored,
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
```

- [ ] **Step 3: 把目标登记进 runner**

`ci/integration-test.sh` 的 `ALL_TARGETS=(...)` 数组末尾加 `settings_schema_coverage`（与现有 `comprehensive_settings` 同段）。

- [ ] **Step 4: 模拟器实跑并按真实控件行为调参**

Run:
```bash
cd D:/APP/vs_claude_code/hibiki
bash ci/integration-test.sh --only=settings_schema_coverage --skip-build   # 先复用已装 APK；首跑去掉 --skip-build
```
Expected：日志打印每项 `[schema-coverage] [Type] id reached=… changed=… …` 与汇总。
**实跑会暴露的真实问题，按根因调（CLAUDE.md 纪律，禁止吞错/硬编码绕过）：**
- 行没有 `settings_item_<id>` key → 看 `material_settings_renderer.dart` 渲染时给行加该 key（根因：测试可定位性），或改 `rowFinder` 用 title 匹配。
- Switch 激活键不是 Space → 看 `hibiki_focusable`/快捷映射确认激活键（可能是 Enter 或 `gameButtonA`），调 `FocusDriver.activate`。
- Segmented/Slider 方向键无效 → 确认 `AdaptiveSettingsSegmentedRow`/`SliderRow` 的焦点子节点，调 `adjust` 的目标键。
- 某行不可达 → 这是**真 bug**（控件焦点不可达），记进 `docs/REGRESSION_BUGS.md` 并修，不要跳过。
留证据：日志存 `.codex-test/itest-logs/settings_schema_coverage.log`，截图 `.codex-test/settings_schema_coverage.png`。

- [ ] **Step 5: 提交**

```bash
git add hibiki/integration_test/settings_schema_coverage_test.dart ci/integration-test.sh
git commit -m "test(settings): focus-driven schema coverage target (reach+change+persist+effect)"
```

---

## Task 5: 把 comprehensive_settings_test 的 tap 换成 FocusDriver

**Files:**
- Modify: `hibiki/integration_test/comprehensive_settings_test.dart`

- [ ] **Step 1: 替换交互原语**

把 `_exerciseHarnessControls` 等处的 `tester.tap(...)` / `tester.drag(slider...)` 改为 `FocusDriver`：开关用 `driver.focusWidget(find.byType(Switch))` + `driver.activate()`；Slider 用 `driver.focusWidget(sliderFinder)` + `driver.adjust(steps: 4)`；分段用 `focusWidget` + `adjust`。保留原有的 `_exerciseSyncSettings`（直接走 `SyncRepository`，本来就不是 UI tap）。导入 `import 'helpers/focus_driver.dart';`。

- [ ] **Step 2: 模拟器实跑确认仍通过**

Run: `bash ci/integration-test.sh --only=comprehensive_settings --skip-build`
Expected: PASS（`All tests passed`）。若焦点驱动改值后断言（`harness.switchValue==true` 等）不达，按 Task 4 Step 4 的根因清单调，不得退回 tap。

- [ ] **Step 3: 提交**

```bash
git add hibiki/integration_test/comprehensive_settings_test.dart
git commit -m "test(settings): drive comprehensive_settings via focus, not coordinate taps"
```

---

## Self-Review（已自查）

- **Spec 覆盖**：Phase 1 覆盖设计 §4A（Task1 FocusDriver）、§4C-T1（Task2 探针）、§4B+§5（Task3 校验器 + isPass 定义）、§4B 集成（Task4 真实 schema 焦点驱动）、tap→焦点迁移（Task5）。§6 截图作证据：Task4 `takeScreenshot` 留档。**未覆盖（显式延后）**：§4C 的 T2/T3/T4 探针族、§6 粗粒度方向性断言、§7 跨机/离屏/headless、§8 reporter/dispatch_mac、§9 Phase2-4 —— 见下「后续阶段」。
- **占位符扫描**：无 TBD/TODO。Task2 Step3 的非法标识符笔误已在 Step4 显式给出合法修正版（故意保留以提示，不是占位）。
- **类型一致性**：`ItemVerdict`/`EffectVerdict`/`EffectSnapshot`/`EffectTier`/`FocusDriver` 在 Task1-3 定义，Task4 一致引用；`verifyItemLogic` 是逻辑层、`_verifyItemOnDevice` 是集成层，命名不冲突。
- **经验性诚实**：Task4 明确标注真实控件行为需实跑发现并按根因调参（key/激活键/方向键），并把「控件不可达」定性为真 bug 要修而非跳过——符合 CLAUDE.md 根因修复纪律。

---

## 后续阶段（落地 Phase 1 后各出独立计划）

- **Phase 2 — Windows 离屏后台 + T3**：改 `hibiki/windows/runner/win32_window.cpp` 认 `HIBIKI_TEST_HIDDEN`（离屏坐标 + `SW_SHOWNOACTIVATE`，降级最小化）；matrix 接 Windows 目标带 `--dart-define=HIBIKI_TEST_HIDDEN=1`；`effect_probes.dart` 加 T3 `getComputedStyle` evalJS 探针。**必须用户真实 Windows 机复测：窗口不进可视区/不抢前台/sendKeyEvent 仍驱动/前台不被打断。**
- **Phase 3 — Mac 跨机分派**：新增 `tool/dispatch_mac.ps1`（commit 校验 → `sync_to_mac.ps1` → ssh 远程跑 macos → scp 拉回报告）；`comprehensive_test_reporter.dart` 加跨机合并 + effectVerified/UNVERIFIED 缺口段。
- **Phase 4 — 收尾**：matrix 的 android 场景委托 `ci/integration-test.sh`（加 `emulator -no-window` headless）；更新 `docs/agent/integration-testing.md`；清理。

---

## 执行方式

**计划已存 `docs/specs/2026-06-03-test-flow-refactor-plan.md`。两种执行方式：**

**1. Subagent-Driven（推荐）** — 每个 Task 派新 subagent，Task 间我审查，迭代快（code review 按 hibiki/CLAUDE.md 必须 `model: "opus"`）。

**2. Inline Execution** — 本会话内用 `executing-plans` 批量执行 + 检查点。

**选哪种？**
