# Dictionary Manager Action Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 4 bare icon-buttons in the 词典管理 (Dictionary Manager) app bar with a labeled, in-page action bar on Material platforms so import/clear actions read as normal buttons instead of cryptic icons.

**Architecture:** On Material (Android/Windows/Linux) the app-bar `actions` slot is emptied and the four actions (download / import folder / import file / clear-all) become labeled `FilledButton.tonalIcon` buttons in a `Wrap` at the top of the page body — they reflow on narrow widths and never crowd the title bar. Each button is registered as a single gamepad/keyboard focus stop via `HibikiActivatableFocusTarget` + `ExcludeFocus` (the same idiom as `reader_quick_settings_sheet.dart`) so directional-nav reachability is not regressed. Cupertino (iOS/macOS) is left untouched — it keeps its native nav-bar icon actions. Existing i18n keys are reused as labels, so there is zero i18n churn.

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0, Material 3, Riverpod; project widgets `AdaptiveSettingsScaffold`, `HibikiActivatableFocusTarget`, `HibikiFocusRoot`, `HibikiDesignTokens`.

---

## File Structure

- `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart` — the only behavioural change. Add an import, branch `build()` by design system, add `_buildActionBar()` + `_buildActionButton(...)` helper. `_buildMobilePageActions` / `_buildDesktopPageActions` are KEPT (used by the Cupertino path and asserted by the static test).
- `hibiki/test/pages/dictionary_dialog_layout_static_test.dart` — extend with a guard for the new Material action bar.

## Constraints (from existing static test — must stay true)

- Source still contains `_buildMobilePageActions`, `_buildDesktopPageActions`, `MediaQuery.sizeOf(context).width < 480`, `AdaptiveSettingsPickerRow<DictionaryType>`, `_buildDictionaryTypePicker`, `_buildDictionaryVisibilityButton`.
- `build()` body still contains `AdaptiveSettingsScaffold` and not `adaptiveAlertDialog(` / `DictionaryManagerDialogFrame`.
- Source still contains `HibikiDesignTokens.of(context)`.

---

### Task 1: Material in-page labeled action bar

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`

- [ ] **Step 1: Add the focus-controller import**

After the existing `import 'package:hibiki/src/utils/misc/channel_constants.dart';` line, add:

```dart
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
```

- [ ] **Step 2: Branch `build()` by design system**

Replace the current `build()` method:

```dart
  @override
  Widget build(BuildContext context) {
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    return AdaptiveSettingsScaffold(
      title: Text(t.dictionaries),
      actions: compact ? _buildMobilePageActions() : _buildDesktopPageActions(),
      children: [
        compact ? _buildDictionaryTypePicker() : _buildCategorySelector(),
        buildContent(),
      ],
    );
  }
```

with:

```dart
  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    return AdaptiveSettingsScaffold(
      title: Text(t.dictionaries),
      // Cupertino (iOS/macOS) keeps its native nav-bar icon actions. Material
      // (Android/Windows/Linux) empties the app bar and surfaces the same
      // actions as labeled buttons in an in-page action bar so they read as
      // normal buttons instead of bare icons.
      actions: cupertino
          ? (compact ? _buildMobilePageActions() : _buildDesktopPageActions())
          : const <Widget>[],
      children: [
        if (!cupertino) _buildActionBar(),
        compact ? _buildDictionaryTypePicker() : _buildCategorySelector(),
        buildContent(),
      ],
    );
  }
```

- [ ] **Step 3: Add the action bar + gamepad-focusable button helper**

Insert directly after the closing brace of the new `build()` method (before `_buildDesktopPageActions`):

```dart
  /// Material in-page action bar: labeled import/clear buttons that wrap on
  /// narrow widths. Replaces the bare app-bar icon buttons on Material.
  Widget _buildActionBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          _buildActionButton(
            focusPrefix: 'dict-action-download',
            icon: Icons.cloud_download_outlined,
            label: t.dict_download_browse,
            onTap: _showDownloadSelectionDialog,
          ),
          if (!Platform.isIOS)
            _buildActionButton(
              focusPrefix: 'dict-action-folder',
              icon: Icons.drive_folder_upload_outlined,
              label: t.dialog_import_folder,
              onTap: _importDictionaryFolder,
            ),
          _buildActionButton(
            focusPrefix: 'dict-action-file',
            icon: Icons.upload_file_outlined,
            label: t.dialog_import_dictionary,
            onTap: _importDictionaryFiles,
          ),
          _buildActionButton(
            focusPrefix: 'dict-action-clear',
            icon: Icons.delete_sweep_outlined,
            label: t.dialog_clear_all_dictionaries,
            onTap: showDictionaryClearDialog,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// A labeled action button that is mouse/touch tappable and, under a
  /// [HibikiFocusRoot], a single gamepad/keyboard focus stop (A/Enter fires
  /// [onTap]). Same idiom as the reader quick-settings action strip: the
  /// underlying button is removed from focus traversal so it does not grab a
  /// competing, unregistered focus node.
  Widget _buildActionButton({
    required String focusPrefix,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    ButtonStyle? style,
  }) {
    final Widget button = FilledButton.tonalIcon(
      onPressed: onTap,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    if (HibikiFocusRoot.maybeControllerOf(context) == null) {
      return button;
    }
    return HibikiActivatableFocusTarget(
      focusIdPrefix: focusPrefix,
      onTap: onTap,
      child: ExcludeFocus(child: button),
    );
  }
```

- [ ] **Step 4: Format + analyze**

Run: `dart format lib/src/pages/implementations/dictionary_dialog_page.dart`
Run: `flutter analyze lib/src/pages/implementations/dictionary_dialog_page.dart`
Expected: no new analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart
git commit -m "feat(dict): labeled in-page action bar for dictionary manager (Material)"
```

---

### Task 2: Static-layout guard for the new action bar

**Files:**
- Modify: `hibiki/test/pages/dictionary_dialog_layout_static_test.dart`

- [ ] **Step 1: Add the failing guard test**

Append before the final closing `}` of `main()`:

```dart
  test('dictionary manager surfaces a labeled Material action bar', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    // Material path empties the app bar and renders an in-page action bar.
    expect(source, contains('_buildActionBar'));
    expect(source, contains('if (!cupertino) _buildActionBar()'));
    expect(source, contains('actions: cupertino'));

    // The four actions are labeled buttons reusing the existing i18n keys.
    for (final String label in <String>[
      't.dict_download_browse',
      't.dialog_import_folder',
      't.dialog_import_dictionary',
      't.dialog_clear_all_dictionaries',
    ]) {
      expect(source, contains(label), reason: 'missing label $label');
    }
    expect(source, contains('FilledButton.tonalIcon'));

    // Buttons stay reachable by gamepad/keyboard (single focus stop each).
    expect(source, contains('HibikiActivatableFocusTarget'));
  });
```

- [ ] **Step 2: Run the test file**

Run: `flutter test test/pages/dictionary_dialog_layout_static_test.dart --no-pub`
Expected: all tests PASS (including the pre-existing ones, which still find `_buildMobilePageActions` / `_buildDesktopPageActions` / the `< 480` breakpoint).

- [ ] **Step 3: Commit**

```bash
git add hibiki/test/pages/dictionary_dialog_layout_static_test.dart
git commit -m "test(dict): guard labeled Material action bar in dictionary manager"
```

---

## Verification

- `dart format .` clean.
- `flutter test test/pages/dictionary_dialog_layout_static_test.dart --no-pub` green.
- Broader sanity: `flutter test test/pages --no-pub` green (no other page test regressed).
- Device/visual recheck (Android, per CLAUDE.md reader/import/layout rule): open Settings → 词典管理, confirm 4 labeled buttons appear, each performs its action, the clear button is error-colored, and the layout wraps without crowding on a phone width. (Pending real-device confirmation by the user.)

## Notes / risks

- Cupertino (iOS/macOS) is deliberately unchanged — lowest risk, native convention. The `Platform.isIOS` guard inside `_buildActionBar` is defensive (the bar only renders on Material, where `Platform.isIOS` is already false).
- No new i18n keys → no `i18n_sync.dart` / `slang` run required.
- `FilledButton.tonalIcon` is wrapped in `ExcludeFocus` only under a `HibikiFocusRoot`; in plain widget tests (no root) it returns the bare button, so standard Flutter focus/taps still work.
