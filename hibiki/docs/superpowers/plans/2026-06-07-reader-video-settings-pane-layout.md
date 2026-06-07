# Reader And Video Settings Pane Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the reader and video wide settings dialogs a narrower shared navigation pane, symmetric detail-pane insets, and a reliably visible video category menu.

**Architecture:** Extend `MaterialSupportingPaneLayout` with an optional explicit supporting width while preserving its current responsive default. Reader and video modal sheets pass one shared modal width and move horizontal padding from the wrapper into each pane, leaving the full-page Settings layout and narrow push layouts unchanged.

**Tech Stack:** Flutter, Dart, Material 3, flutter_test.

---

### Task 1: Add An Explicit Supporting-Pane Width

**Files:**
- Modify: `hibiki/lib/src/utils/misc/platform_utils.dart`
- Test: `hibiki/test/utils/misc/platform_layout_test.dart`

- [x] **Step 1: Write the failing test**

Add a widget test that pumps `MaterialSupportingPaneLayout` at 900px and passes
`supportingWidth: 248`. Assert that the supporting child is exactly 248px wide
and the primary child still fills the remaining width.

```dart
testWidgets('uses an explicit supporting pane width when provided', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 900,
        height: 500,
        child: MaterialSupportingPaneLayout(
          minSplitWidth: 640,
          supportingWidth: 248,
          supporting: const ColoredBox(
            key: ValueKey<String>('supporting'),
            color: Colors.red,
          ),
          primary: const ColoredBox(
            key: ValueKey<String>('primary'),
            color: Colors.blue,
          ),
        ),
      ),
    ),
  );

  expect(tester.getSize(find.byKey(const ValueKey('supporting'))).width, 248);
});
```

- [x] **Step 2: Run the test to verify it fails**

Run:

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/utils/misc/platform_layout_test.dart --reporter expanded
```

Expected: compilation fails because `supportingWidth` is not a constructor
parameter.

- [x] **Step 3: Implement the optional width**

Add `double? supportingWidth` to `MaterialSupportingPaneLayout`. Resolve the
fixed width with:

```dart
final double resolvedSupportingWidth =
    supportingWidth ?? supportingPaneWidthForLayout(constraints.maxWidth);
```

Use `resolvedSupportingWidth` for the supporting `SizedBox`. Do not change
`supportingPaneWidthForLayout`.

- [x] **Step 4: Run the shared layout test**

Run the command from Step 2.

Expected: all `platform_layout_test.dart` tests pass.

### Task 2: Apply The Modal Pane Geometry

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `hibiki/lib/src/media/video/video_quick_settings_sheet.dart`
- Test: `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
- Test: `hibiki/test/pages/video_player_settings_master_detail_guard_test.dart`
- Test: `hibiki/test/pages/video_quick_settings_sheet_test.dart`

- [x] **Step 1: Write failing layout guards**

Add guards for a shared `248` modal supporting width and symmetric detail
padding. The widget test should verify that the video's four category labels
remain visible in the wide layout.

```dart
expect(source, contains('supportingWidth: 248'));
expect(source, contains('padding: widePrimaryPadding'));
expect(source, contains('padding: wideSupportingPadding'));
```

Keep the existing checks for `playback`, `shaders`, `mpv`, and `subtitle`.

- [x] **Step 2: Run the focused tests to verify they fail**

Run:

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/media/audiobook/reader_quick_settings_sheet_static_test.dart test/pages/video_player_settings_master_detail_guard_test.dart test/pages/video_quick_settings_sheet_test.dart --reporter expanded
```

Expected: the new source guards fail because neither sheet passes an explicit
width or pane-specific padding.

- [x] **Step 3: Implement pane-specific padding**

In both sheets:

- keep the `640` breakpoint;
- keep the current narrow `bodyPadding`;
- set the wide `MaterialSupportingPaneLayout` to `supportingWidth: 248`;
- remove the wide wrapper padding around the whole layout;
- wrap the supporting scroll view with start/end padding;
- wrap the primary scroll view with equal start/end padding;
- retain the existing bottom inset and independent scrolling.

Use token-derived values equivalent to 20 logical pixels for both primary
horizontal sides:

```dart
final double wideHorizontalInset =
    tokens.spacing.page + tokens.spacing.gap / 2;
final EdgeInsets widePrimaryPadding = EdgeInsets.fromLTRB(
  wideHorizontalInset,
  tokens.spacing.gap / 2,
  wideHorizontalInset,
  tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
);
```

Use the same divider-side inset for the supporting pane while preserving its
outer spacing.

- [x] **Step 4: Run focused reader/video tests**

Run the command from Step 2.

Expected: all focused tests pass.

- [x] **Step 5: Format and run the complete focused verification set**

Run:

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/utils/misc/platform_utils.dart lib/src/media/audiobook/reader_quick_settings_sheet.dart lib/src/media/video/video_quick_settings_sheet.dart test/utils/misc/platform_layout_test.dart test/media/audiobook/reader_quick_settings_sheet_static_test.dart test/pages/video_player_settings_master_detail_guard_test.dart test/pages/video_quick_settings_sheet_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/utils/misc/platform_layout_test.dart test/media/audiobook/reader_quick_settings_sheet_static_test.dart test/pages/video_player_settings_master_detail_guard_test.dart test/pages/video_quick_settings_sheet_test.dart --reporter expanded
git diff --check
```

Expected: formatting succeeds, all focused tests pass, and `git diff --check`
reports no whitespace errors.

- [x] **Step 6: Commit**

Stage only the plan, production files, and focused tests:

```powershell
git add -- hibiki/docs/superpowers/plans/2026-06-07-reader-video-settings-pane-layout.md hibiki/lib/src/utils/misc/platform_utils.dart hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart hibiki/lib/src/media/video/video_quick_settings_sheet.dart hibiki/test/utils/misc/platform_layout_test.dart hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart hibiki/test/pages/video_player_settings_master_detail_guard_test.dart hibiki/test/pages/video_quick_settings_sheet_test.dart
git diff --cached --check
git commit -m "fix(media): balance settings pane layout"
```
