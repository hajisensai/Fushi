# All-platform MD3 Default and macOS Single-shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `auto` resolve to MD3 on every supported platform, migrate hidden Apple preferences to `auto`, and prevent the macOS-native window/sidebar from wrapping MD3.

**Architecture:** Keep Cupertino and macos_ui renderers as dormant internal capabilities. Centralize effective design-system behavior in `adaptive_platform.dart`, normalize user-persisted values at the `ThemeNotifier` load/write boundary, and make the app root and `HomePage` share `isMacosPlatform(context)` as their only native-shell gate.

**Tech Stack:** Flutter/Dart, Material 3, macos_ui, Drift preferences, flutter_test, repository bug tracker.

## Global Constraints

- `auto` means MD3 on Android, iOS, macOS, Windows, and Linux.
- The settings UI exposes only `auto` and `material`; Cupertino/macOS implementations remain in source but hidden.
- Persisted `cupertino`, `macos`, and unknown design-system values normalize to and persist as `auto`.
- Explicit `macos` remains safe on non-macOS hosts and only activates macos_ui on macOS.
- Do not touch the unrelated 33 failures in the zero-change upstream full-test baseline.
- Use TDD: every production change follows a failing focused test.

---

### Task 1: Record the verified macOS double-shell bug

**Files:**
- Create: `docs/bugs/BUG-784-md3-macos-double-shell.md` through the bug tool
- Modify: `docs/BUGS.md` through reindexing only

**Interfaces:**
- Consumes: the reproduced latest-build screenshot and the `main.dart`/`home_page.dart` root-cause path
- Produces: `BUG-784`, whose two checkboxes are completed only after code and tests land

- [ ] **Step 1: Create the bug record**

Run from the repository root:

```bash
dart run tool/bug.dart new md3-macos-double-shell "macOS 自动/MD3 仍套原生侧栏形成双壳"
```

Expected: `docs/bugs/BUG-784-md3-macos-double-shell.md`, plus an automatically rebuilt `docs/BUGS.md` index.

- [ ] **Step 2: Replace the skeleton with verified evidence**

Record these facts without checking completion boxes yet:

```markdown
- **报告**：2026-07-13（用户截图并在最新 develop@b177f858b 实机复现）
- **真实性**：✅ 真 bug
- **根因**：`hibiki/lib/main.dart` 按裸 `TargetPlatform.macOS` 无条件创建 `MacosWindow + Sidebar`，绕过 `HibikiDesignSystemTheme`；`HomePage` 同时按设计系统创建 MD3 rail，形成双壳。
- [ ] ① 根因修复
- [ ] ② 自动化测试
- **设备复测**：待修复后重新构建并截图。
```

- [ ] **Step 3: Commit the verified bug record**

```bash
git add docs/bugs/BUG-784-md3-macos-double-shell.md docs/BUGS.md
git commit -m "docs(bug): record macOS MD3 double shell"
```

Expected: only the new bug record and generated index are committed.

---

### Task 2: Make auto resolve to Material on all platforms

**Files:**
- Create: `hibiki/test/utils/adaptive/adaptive_platform_test.dart`
- Modify: `hibiki/lib/src/utils/adaptive/adaptive_platform.dart`

**Interfaces:**
- Consumes: `HibikiDesignSystemTheme`, `isCupertinoPlatform(BuildContext)`, `isMacosPlatform(BuildContext)`
- Produces: `auto`/`material` => neither Apple predicate; explicit Apple enums remain directly injectable

- [ ] **Step 1: Write the failing platform-matrix test**

Create a widget probe that injects the requested platform and design-system extension:

```dart
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';

void main() {
  Future<({bool cupertino, bool macos})> resolve(
    WidgetTester tester, {
    required TargetPlatform platform,
    required HibikiDesignSystem designSystem,
  }) async {
    late ({bool cupertino, bool macos}) result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        platform: platform,
        extensions: <ThemeExtension<dynamic>>[
          HibikiDesignSystemTheme(designSystem),
        ],
      ),
      home: Builder(builder: (BuildContext context) {
        result = (
          cupertino: isCupertinoPlatform(context),
          macos: isMacosPlatform(context),
        );
        return const SizedBox.shrink();
      }),
    ));
    return result;
  }

  testWidgets('auto resolves to MD3 on all five platform families',
      (WidgetTester tester) async {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final result = await resolve(
        tester,
        platform: platform,
        designSystem: HibikiDesignSystem.auto,
      );
      expect(result.cupertino, isFalse, reason: '$platform');
      expect(result.macos, isFalse, reason: '$platform');
    }
  });

  testWidgets('explicit Apple modes remain internally available',
      (WidgetTester tester) async {
    final cupertino = await resolve(
      tester,
      platform: TargetPlatform.iOS,
      designSystem: HibikiDesignSystem.cupertino,
    );
    expect(cupertino.cupertino, isTrue);
    final macos = await resolve(
      tester,
      platform: TargetPlatform.macOS,
      designSystem: HibikiDesignSystem.macos,
    );
    expect(macos.macos, Platform.isMacOS);
  });

  testWidgets('missing design extension follows auto and stays MD3',
      (WidgetTester tester) async {
    late bool cupertino;
    late bool macos;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Builder(builder: (BuildContext context) {
        cupertino = isCupertinoPlatform(context);
        macos = isMacosPlatform(context);
        return const SizedBox.shrink();
      }),
    ));
    expect(cupertino, isFalse);
    expect(macos, isFalse);
  });

  test('context-free adaptive route defaults to Material', () {
    final route = adaptivePageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
    );
    expect(route, isA<MaterialPageRoute<void>>());
  });
}
```

- [ ] **Step 2: Run the test to prove the current behavior is wrong**

```bash
cd hibiki
flutter test test/utils/adaptive/adaptive_platform_test.dart
```

Expected: FAIL for iOS/macOS under `auto`.

- [ ] **Step 3: Implement the minimal resolver change**

In `adaptive_platform.dart`:

```dart
case HibikiDesignSystem.auto:
  return false;
```

Apply that result in both Apple predicates; keep explicit `cupertino` and explicit host-safe `macos` branches. Change the context-free default route fallback to:

```dart
bool get isCupertinoDefault => false;
```

- [ ] **Step 4: Run the focused test**

```bash
flutter test test/utils/adaptive/adaptive_platform_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the platform resolver**

```bash
git add lib/src/utils/adaptive/adaptive_platform.dart test/utils/adaptive/adaptive_platform_test.dart
git commit -m "fix(theme): make auto use MD3 on every platform"
```

---

### Task 3: Normalize hidden persisted Apple modes to auto

**Files:**
- Modify: `hibiki/test/models/theme_notifier_test.dart`
- Modify: `hibiki/lib/src/models/theme_notifier.dart`
- Modify: `hibiki/lib/src/settings/settings_actions.dart`
- Modify: `CLAUDE.md`
- Modify: `hibiki/CLAUDE.md`
- Modify: `docs/agent/build.md`

**Interfaces:**
- Consumes: `ThemeNotifier.loadFromPrefsSnapshot`, `refreshFromDb`, `setDesignSystem`, `designSystem`
- Produces: `ThemeNotifier.normalizeDesignSystemPreference(Object?) -> String`; user storage can contain only `auto` or `material`

- [ ] **Step 1: Replace the old Cupertino persistence expectation with failing migration tests**

Add cases equivalent to:

```dart
for (final value in <String>['cupertino', 'macos', 'fluent']) {
  test('hidden design_system=$value snapshot is immediately auto', () {
    notifier.loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode(value),
    });
    expect(notifier.designSystem, 'auto');
    expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
  });

  test('hidden design_system=$value refresh persists auto', () async {
    await db.setPref('design_system', PrefCodec.encode(value));
    await notifier.refreshFromDb();
    expect(notifier.designSystem, 'auto');
    final prefs = await db.getAllPrefs();
    expect(PrefCodec.decode(prefs['design_system']!, ''), 'auto');
  });
}

test('setDesignSystem rejects hidden values by normalizing to auto', () async {
  await notifier.setDesignSystem('macos');
  expect(notifier.designSystem, 'auto');
});
```

Keep the `material` and absent/explicit `auto` tests.

- [ ] **Step 2: Run the focused tests to verify failure**

```bash
flutter test test/models/theme_notifier_test.dart --plain-name "ThemeNotifier.designSystemTheme reflects design_system pref"
```

Expected: FAIL because hidden values currently remain effective.

- [ ] **Step 3: Implement load/write-boundary normalization**

Add a pure normalizer and an in-memory-plus-DB migration helper:

```dart
static String normalizeDesignSystemPreference(Object? value) {
  return value == 'material' ? 'material' : 'auto';
}

String? _normalizeHiddenDesignSystemInMemory() {
  final Object? raw = _get('design_system', defaultValue: 'auto');
  final String normalized = normalizeDesignSystemPreference(raw);
  if (raw == normalized) return null;
  _prefs['design_system'] = PrefCodec.encode(normalized);
  return normalized;
}
```

Call the helper after loading a snapshot and persist with `unawaited(_db.setPref(...))`; in `refreshFromDb` await the DB write before notifying. Normalize `setDesignSystem` input before `_set`. Make `designSystem` return the normalized value. Do not add side effects to theme getters.

Update `settings_actions.dart` comments to state that Apple choices and legacy values are hidden and normalized; retain exactly `['auto', 'material']` as visible values.

Update the three standing-rule documents so they no longer claim that public
iOS defaults to Cupertino: all five platforms use MD3 under `auto`; Apple
renderers remain hidden internal capabilities. Do not rewrite historical specs.

- [ ] **Step 4: Run ThemeNotifier and settings tests**

```bash
flutter test test/models/theme_notifier_test.dart test/settings/settings_renderer_test.dart test/settings/settings_schema_coverage_test.dart
```

Expected: PASS (schema coverage may retain its documented UNVERIFIED diagnostics but exits 0).

- [ ] **Step 5: Commit migration behavior**

```bash
git add ../CLAUDE.md CLAUDE.md ../docs/agent/build.md lib/src/models/theme_notifier.dart lib/src/settings/settings_actions.dart test/models/theme_notifier_test.dart
git commit -m "fix(theme): migrate hidden Apple modes to auto"
```

---

### Task 4: Gate the macOS root shell by the effective design system

**Files:**
- Modify: `hibiki/test/macos/macos_shell_static_test.dart`
- Modify: `hibiki/integration_test/macos_shell_screenshot_test.dart`
- Modify: `hibiki/integration_test/macos_reader_screenshot_test.dart`
- Modify: `hibiki/integration_test/macos_todo1375_reader_fullscreen_relayout_test.dart`
- Modify: `hibiki/integration_test/macos_todo1375_shell_reader_fullscreen_test.dart`
- Modify: `hibiki/lib/main.dart`

**Interfaces:**
- Consumes: `isMacosPlatform(BuildContext)` from Task 2
- Produces: root `MacosWindow + Sidebar` and page `MacosScaffold` activate from the same predicate

- [ ] **Step 1: Strengthen the source guard and make it fail**

Add assertions:

```dart
expect(main, contains('if (isMacosPlatform(context))'));
expect(
  main,
  isNot(contains(
    'if (Theme.of(context).platform == TargetPlatform.macOS)',
  )),
);
```

Keep positive assertions that explicit macOS mode still contains `MacosWindow`, shared sidebar, and `HomePage` native layout.

Update the default-auto macOS screenshot integration test to wait for
`hibikiMaterialNavKey`, assert `find.byType(MacosWindow)` is empty, and capture
the MD3 home/settings shell. Make the reader screenshot and fullscreen relayout
tests wait for the same MD3 home key instead of `MacosWindow`. Mark the
TODO-1375 native-sidebar/back-button integration test skipped with an explicit
reason until an internal explicit-macos injection harness exists; it must not
time out while Apple modes are publicly hidden.

- [ ] **Step 2: Run the guard and verify red**

```bash
flutter test test/macos/macos_shell_static_test.dart
```

Expected: FAIL because `main.dart` still uses the raw physical-platform branch.

- [ ] **Step 3: Replace the root condition**

In `main.dart` use:

```dart
if (isMacosPlatform(context)) {
  navigation = MacosTheme(
    // existing MacosWindow/sidebar body unchanged
  );
}
```

Do not duplicate the shell or change HomeTab/sidebar contents.

- [ ] **Step 4: Run the shell and platform tests**

```bash
flutter test test/macos/macos_shell_static_test.dart test/utils/adaptive/adaptive_platform_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the single-shell fix**

```bash
git add lib/main.dart test/macos/macos_shell_static_test.dart integration_test/macos_shell_screenshot_test.dart integration_test/macos_reader_screenshot_test.dart integration_test/macos_todo1375_reader_fullscreen_relayout_test.dart integration_test/macos_todo1375_shell_reader_fullscreen_test.dart
git commit -m "fix(macos): respect MD3 before creating native shell"
```

---

### Task 5: Complete regression checks, bug record, and visible macOS proof

**Files:**
- Modify: `docs/bugs/BUG-784-md3-macos-double-shell.md`
- Modify: `docs/BUGS.md` through `tool/bug.dart reindex`
- Create evidence outside git: `/tmp/hibiki-md3-single-shell-20260713.png`

**Interfaces:**
- Consumes: Tasks 1-4 commits and the latest macOS build
- Produces: checked bug record, test evidence, and a visibly single MD3 shell

- [ ] **Step 1: Format and run relevant regression tests**

```bash
cd hibiki
dart format .
flutter test test/utils/adaptive/adaptive_platform_test.dart test/models/theme_notifier_test.dart test/macos/macos_shell_static_test.dart test/settings/settings_renderer_test.dart
```

Expected: PASS.

- [ ] **Step 2: Build and launch the current macOS app**

```bash
flutter run -d macos
```

Expected: build succeeds, initialization reaches `[Hibiki] init: DONE`, and the window contains only the MD3 app navigation under the migrated/default `auto` preference.

- [ ] **Step 3: Capture visible evidence**

```bash
screencapture -x /tmp/hibiki-md3-single-shell-20260713.png
```

Inspect the image and require that the extra far-left macos_ui sidebar/border is absent.

- [ ] **Step 4: Complete and reindex the bug record**

Mark both boxes `[x]`, record the actual implementation commit hashes and test files, add the screenshot path as device evidence, then run:

```bash
dart run tool/bug.dart reindex
```

- [ ] **Step 5: Commit the completed bug record**

```bash
git add docs/bugs/BUG-784-md3-macos-double-shell.md docs/BUGS.md
git commit -m "docs(bug): close macOS MD3 double shell"
```
