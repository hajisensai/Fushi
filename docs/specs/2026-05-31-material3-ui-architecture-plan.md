# Material 3 and Global Focus UI Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Hibiki local rule override:** this plan lives in `docs/specs/` because `AGENTS.md` says requirement/design/implementation documents belong under `docs/specs/*`.

**Goal:** Make Hibiki feel and behave like a real Material Design 3 app by making settings schema, shared tokens, shared components, and a deterministic global focus system the source of truth, then migrating visible page families without breaking persisted preferences, Hoshi reader state, gamepad/keyboard control, or platform behavior.

**Architecture:** Keep Flutter `ThemeData(useMaterial3: true)` as the base, but stop treating the theme flag as the design system. The real system is `HibikiDesignTokens` + shared components + schema-rendered settings + `HibikiFocusRoot`; feature pages compose those primitives and keep only business-specific rendering. Cupertino remains an additive renderer for settings density and native-feeling navigation, not a competing app design. Focus is an app contract, not a page-local side effect.

**Tech Stack:** Flutter/Dart, Riverpod, Slang i18n, Flutter `Focus`/`Actions`/`Shortcuts`, `SettingsDestination` schema, `HibikiDesignTokens`, `HibikiCard`, `HibikiListItem`, `HibikiSearchField`, `AdaptiveSettings*`, `GamepadService`, Hoshi reader WebView path.

---

## Non-Negotiable Constraints

- Current EPUB reader remains Hoshi: `ReaderHibikiPage`, `ReaderHoshiSource`, `reader_pagination_scripts.dart`, `reader_content_styles.dart`, `reader_selection_scripts.dart`, Hoshi resource interception, and `window.hoshiReader`.
- Do not rename persisted `Ttu*`, `reader_ttu`, or `setTtu*` keys/methods unless a migration is explicitly designed and tested. Those names are compatibility boundaries.
- New or removed i18n keys must use `hibiki/tool/i18n_sync.dart`; do not hand-edit 17 Slang JSON files or `strings.g.dart`.
- Settings UI changes must preserve setting values. Moving or deleting a visible row is allowed; deleting persisted state is not allowed unless the plan names the key and migration.
- Ordinary chrome may not invent local visual rules. Feature pages should not directly decide radius, surface color, typography size, or control density unless the file is a shared component, content renderer, chart/preview, or reader content surface.
- Focus must never be absent after the app shell has built its first frame. If a route temporarily has no meaningful control, focus lands on an explicit route/shell fallback node, not on `null`.
- There must be one app-level Flutter focus owner at a time. Hoshi DOM selection/caret state may exist inside the focused reader host, but it must not create a second competing Flutter focus model.
- Focus drives scroll. Directional movement chooses the next focus target first, then scrolls it into view. Manual scroll must not secretly choose focus, and page code must not rely on the nearest `Scrollable` to decide navigation.
- Direct calls to `FocusManager.instance.primaryFocus`, `focusInDirection`, `nextFocus`, `previousFocus`, `requestFocus`, `unfocus`, and `Scrollable.ensureVisible` are migration targets. After the focus layer exists, new direct uses need a local justification or belong in `hibiki/lib/src/focus/`.
- Each implementation task ends with focused verification and a scoped commit. Do not stage unrelated dirty-worktree files.

---

## Current State Summary

The app already has the MD3 base:

- `hibiki/lib/src/models/theme_notifier.dart` builds `ThemeData(useMaterial3: true)`.
- `hibiki/lib/src/utils/components/hibiki_design_tokens.dart` defines token families.
- `hibiki/lib/src/utils/components/hibiki_material_components.dart` contains `HibikiCard`, `HibikiListItem`, `HibikiSearchField`, `HibikiTextField`, `HibikiOverflowMenu`, `HibikiFilePickerRow`, `HibikiLogPanel`, `HibikiPopupSurface`, and related primitives.
- `hibiki/lib/src/settings/settings_schema.dart` already models settings as `SettingsDestination` / `SettingsSection` / `SettingsItem`.
- `hibiki/lib/src/settings/material_settings_renderer.dart` and `cupertino_settings_renderer.dart` render the same schema.
- `hibiki/test/settings/md3_design_system_static_test.dart` guards many already-migrated surfaces.

The remaining problem is architectural: too many special pages and custom rows still bypass the schema/component contract. A page-by-page repaint will keep producing special cases. The fix is to tighten the data structure first, then migrate surfaces by family.

Focus has the same architectural problem:

- `hibiki/lib/src/shortcuts/gamepad_service.dart` dispatches from `FocusManager.instance.primaryFocus?.context ?? navigatorKey.currentContext` and falls back to Flutter traversal with `focusInDirection`, `nextFocus`, and `previousFocus`.
- `hibiki/lib/src/utils/components/hibiki_focus_ring.dart` observes focus and calls `Scrollable.ensureVisible`, but it is a paint/visibility helper, not the owner of the focus graph.
- `hibiki/lib/src/utils/components/hibiki_focusable.dart` makes isolated gesture targets reachable, but it does not register targets, scopes, or scroll ownership.
- `ReaderHibikiPage` still contains page-local focus nodes and hand-written chrome/popup focus jumps.
- Existing tests cover pieces of this behavior, but they do not enforce "primary focus is never null" or "focus move owns scroll".

The bad data structure is the absence of a data structure: focusable targets are implicit widgets scattered through the tree. The MD3 migration must introduce an explicit focus graph before migrating more complex surfaces, otherwise every new MD3 row will inherit the same inconsistent gamepad behavior.

---

## File Structure

### Core Design System

- Modify `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`
  - Owns radius, spacing, density, surface, typography, and component role names.
  - Add named density/layout roles instead of letting pages use `VisualDensity.compact` directly.
- Modify `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - Owns Material cards, list rows, buttons/chips, search, popup surfaces, panels, dialog frames, and page shells.
  - Add missing primitives only when at least two pages need the same behavior.
- Modify `hibiki/lib/src/utils/components/settings_shared.dart`
  - Owns adaptive settings rows and controls used both by schema custom builders and legacy settings subpages while they are being absorbed.

### Global Focus System

- Add `hibiki/lib/src/focus/hibiki_focus_controller.dart`
  - Owns the app focus invariant, active target, route fallback node, directional movement, and focus restoration after route/widget removal.
- Add `hibiki/lib/src/focus/hibiki_focus_scope.dart`
  - Registers ordered, grid, modal, reader-chrome, and reader-content scopes.
- Add `hibiki/lib/src/focus/hibiki_focus_target.dart`
  - Wraps a `FocusNode` with a stable id, geometry role, enabled state, activation role, and optional scroll policy.
- Add `hibiki/lib/src/focus/hibiki_focus_scroll.dart`
  - Centralizes focus-driven scrolling. `HibikiFocusRing` may delegate to it; page code should not call `Scrollable.ensureVisible` for directional focus.
- Add `hibiki/lib/src/focus/hibiki_focus_policy.dart`
  - Contains deterministic target selection. Flutter's default geometric search is a compatibility fallback, not the primary algorithm.
- Modify `hibiki/lib/main.dart`
  - Wrap the app body in `HibikiFocusRoot` before the app-wide focus ring/navigation wrappers.
- Modify `hibiki/lib/src/shortcuts/gamepad_service.dart`
  - Dispatch D-pad/stick movement through `HibikiFocusController.move(...)`; keep the current traversal helper only as an unrooted compatibility fallback during migration.
- Modify `hibiki/lib/src/shortcuts/global_navigation.dart`
  - Resolve focused route and dispatch context through the focus controller instead of treating null primary focus as "not ours".
- Modify `hibiki/lib/src/utils/components/hibiki_focus_ring.dart`
  - Paint only. It observes controller/focus geometry and delegates scroll to `HibikiFocusScroll`.
- Modify `hibiki/lib/src/utils/components/hibiki_focusable.dart`
  - Become a `HibikiFocusTarget` adapter for custom tap targets.

### Settings Data and Renderers

- Modify `hibiki/lib/src/settings/settings_destination.dart`
  - Add schema metadata only if renderer decisions cannot be inferred from item type.
- Modify `hibiki/lib/src/settings/settings_schema.dart`
  - Single source of truth for global settings grouping and row order.
  - Moves settings between destinations and hides/removes visible entries.
- Modify `hibiki/lib/src/sync/sync_settings_schema.dart`
  - Sync/backup remains a nested destination but must follow the same row grammar.
- Modify `hibiki/lib/src/settings/settings_actions.dart`
  - Holds custom row builders while they are still needed; builders must return shared/adaptive primitives.
- Modify `hibiki/lib/src/settings/material_settings_renderer.dart`
  - Material renderer should render schema items through shared MD3 rows.
- Modify `hibiki/lib/src/settings/cupertino_settings_renderer.dart`
  - Cupertino renderer should render the same schema without drifting in behavior.
- Modify `hibiki/lib/src/settings/settings_home_page.dart`
  - Owns wide/narrow settings shell and selected destination behavior.

### High-Exposure Page Families

- Modify `hibiki/lib/src/pages/implementations/home_page.dart`
- Modify `hibiki/lib/src/pages/implementations/home_reader_page.dart`
- Modify `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- Modify `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`
- Modify `hibiki/lib/src/pages/implementations/collections_page.dart`
- Modify `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
- Modify dictionary management and popup files:
  - `dictionary_dialog_page.dart`
  - `dictionary_dialog_import_page.dart`
  - `dictionary_dialog_delete_page.dart`
  - `dictionary_settings_dialog_page.dart`
  - `dictionary_popup_layer.dart`
  - `dictionary_popup_webview.dart`
  - `dictionary_popup_native.dart`
  - `popup_dictionary_page.dart`
  - `floating_dict_page.dart`
- Modify reader and media support files:
  - `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
  - `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`
  - `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
  - `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`

### Tests and Review Docs

- Modify `hibiki/test/settings/md3_design_system_static_test.dart`
- Modify or add focused tests under:
  - `hibiki/test/focus/`
  - `hibiki/test/settings/`
  - `hibiki/test/shortcuts/`
  - `hibiki/test/pages/`
  - `hibiki/test/media/audiobook/`
- Append review findings to `docs/reviews/YYYY-MM-DD-project-review.md` only when implementation finds new risks or verified regressions.
- Update `docs/REGRESSION_BUGS.md` only if a regression is actually reproduced.

---

## Implementation Order

1. Guardrails first: define what "MD3 architecture" and "global focus" mean in tests before changing more UI.
2. Global focus foundation: install `HibikiFocusRoot`, target registration, deterministic movement, and focus-driven scroll.
3. Settings information architecture: move/delete visible configuration entries in schema, not inside renderers.
4. Shared component closure: add missing primitives for repeated page patterns and make them focus participants.
5. Page-family migration: migrate visible families in risk order.
6. Reader/manual verification: only after Hoshi-adjacent UI or focus bridge changes.
7. Review loop: audit the plan and implementation evidence before calling the migration complete.

---

## Focus Task 1: Freeze the Global Focus Contract

**Files:**
- Add: `hibiki/test/focus/global_focus_contract_test.dart`
- Add: `hibiki/test/focus/focus_driven_scroll_test.dart`
- Modify: `hibiki/test/shortcuts/gamepad_focus_nav_test.dart`
- Review: `hibiki/lib/src/shortcuts/gamepad_service.dart`
- Review: `hibiki/lib/src/utils/components/hibiki_focus_ring.dart`
- Review: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

- [x] **Step 1: Add failing contract tests for focus ownership**

The tests should describe the public behavior before implementation:

```dart
testWidgets('HibikiFocusRoot restores focus when the primary node is removed',
    (WidgetTester tester) async {
  final FocusNode first = FocusNode(debugLabel: 'first');
  final FocusNode second = FocusNode(debugLabel: 'second');
  addTearDown(first.dispose);
  addTearDown(second.dispose);

  bool showFirst = true;
  late StateSetter setOuter;
  await tester.pumpWidget(MaterialApp(
    home: HibikiFocusRoot(
      child: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          setOuter = setState;
          return Column(
            children: <Widget>[
              if (showFirst)
                HibikiFocusTarget(
                  id: const HibikiFocusId('first'),
                  focusNode: first,
                  child: const SizedBox(width: 40, height: 40),
                ),
              HibikiFocusTarget(
                id: const HibikiFocusId('second'),
                focusNode: second,
                child: const SizedBox(width: 40, height: 40),
              ),
            ],
          );
        },
      ),
    ),
  ));

  first.requestFocus();
  await tester.pump();
  expect(FocusManager.instance.primaryFocus, same(first));

  setOuter(() => showFirst = false);
  await tester.pump();
  await tester.pump();

  expect(FocusManager.instance.primaryFocus, isNotNull);
  expect(second.hasPrimaryFocus, isTrue);
});
```

Add separate tests for:

- First frame gets a primary focus through the root fallback if no control is ready.
- Removing a dialog restores focus to the invoking target.
- Disabling the focused row moves focus to the next enabled target.
- A route with only passive content focuses the route fallback, not `null`.

- [x] **Step 2: Add failing contract tests for focus-driven scroll**

The test should prove the sequence: move focus first, then reveal that target.

```dart
testWidgets('directional move scrolls the newly focused target into view',
    (WidgetTester tester) async {
  final ScrollController controller = ScrollController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(MaterialApp(
    home: HibikiFocusRoot(
      child: SizedBox(
        height: 120,
        child: ListView.builder(
          controller: controller,
          itemExtent: 48,
          itemCount: 20,
          itemBuilder: (BuildContext context, int index) {
            return HibikiFocusTarget(
              id: HibikiFocusId('row-$index'),
              child: TextButton(
                onPressed: () {},
                child: Text('Row $index'),
              ),
            );
          },
        ),
      ),
    ),
  ));

  final HibikiFocusController focus = HibikiFocusRoot.controllerOf(
    tester.element(find.byType(ListView)),
  );
  focus.requestById(const HibikiFocusId('row-0'));
  await tester.pump();

  for (int i = 0; i < 8; i += 1) {
    focus.move(HibikiFocusDirection.down);
    await tester.pump();
  }
  await tester.pumpAndSettle();

  expect(focus.activeId, const HibikiFocusId('row-8'));
  expect(controller.offset, greaterThan(0));
});
```

Do not accept a test that scrolls first and infers focus from visibility. That is the old broken model.

- [x] **Step 3: Update existing gamepad tests to target the new contract**

Keep `gamepad_focus_nav_test.dart`, but stop treating `gamepadMoveFocusInDirection(...)` as the end-state API. The final tests should cover:

- D-pad and analog stick both call `HibikiFocusController.move(...)`.
- With no app focus, the controller restores fallback/first target before movement.
- A blocked direction uses deterministic scope policy, not raw Flutter geometric search.
- Activation uses the focused target's context, not `navigatorKey.currentContext`.

- [x] **Step 4: Run focused failing tests**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/focus test/shortcuts/gamepad_focus_nav_test.dart
```

This task may commit tests only if they are marked with `skip` and each skipped test names the not-yet-implemented task. Prefer committing the implementation and tests together in Focus Task 2.

Implementation evidence: covered by commits `c975f3ae3`, `1d0c199f8`, `f368d5190`, and `489474495`. Focus tests and shortcut focus tests now exercise the root, fallback, movement, and focus-driven scroll behavior.

---

## Focus Task 2: Implement the Focus Root, Registry, and Invariant

**Files:**
- Add: `hibiki/lib/src/focus/hibiki_focus_controller.dart`
- Add: `hibiki/lib/src/focus/hibiki_focus_target.dart`
- Add: `hibiki/lib/src/focus/hibiki_focus_scope.dart`
- Modify: `hibiki/lib/main.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_focusable.dart`
- Modify: `hibiki/test/focus/global_focus_contract_test.dart`

- [x] **Step 1: Introduce stable focus ids and target registration**

Use explicit ids for repeated rows and route-owned controls. Do not use display text as identity; text is localized and user-editable.

```dart
@immutable
class HibikiFocusId {
  const HibikiFocusId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HibikiFocusId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
```

- [x] **Step 2: Implement `HibikiFocusController` as the single owner**

The controller owns a fallback node and a registry. `FocusManager.primaryFocus` remains Flutter's actual focus source, but the controller repairs invalid states and chooses movement targets.

Required API:

```dart
enum HibikiFocusDirection { up, down, left, right }

class HibikiFocusController extends ChangeNotifier {
  HibikiFocusController();

  FocusNode get fallbackNode;
  BuildContext? get activeContext;
  HibikiFocusId? get activeId;

  void attach(BuildContext rootContext);
  void detach();
  void register(HibikiFocusTargetEntry entry);
  void unregister(HibikiFocusId id, FocusNode node);
  bool requestById(HibikiFocusId id);
  bool move(HibikiFocusDirection direction);
  void ensureFocus();
}
```

Invariant rules:

- `ensureFocus()` runs after the first app frame, after route changes, after target unregister, and after a focused node becomes disabled.
- Repair order is: last active valid target, current route first enabled target, route fallback node.
- The fallback node is `skipTraversal: true` but `canRequestFocus: true`; it exists to make `primaryFocus == null` impossible, not to draw a ring.
- Unregistering the active target must schedule repair; it must not synchronously request focus during widget disposal.
- Text fields and WebView hosts are targets. Native text editing is not overridden while that target owns focus.

- [x] **Step 3: Add `HibikiFocusRoot` to the app shell**

Wrap the app once, near the existing focus ring/navigation wrappers:

```dart
return HibikiFocusRoot(
  child: HibikiFocusRing(
    child: wrapWithGlobalNavigation(
      navigatorKey: navigatorKey,
      child: child,
    ),
  ),
);
```

Keep the actual nesting consistent with `main.dart`; the point is that navigation, focus ring, shortcuts, and gamepad dispatch can all resolve the same controller.

- [x] **Step 4: Convert `HibikiFocusable` into a target adapter**

`HibikiFocusable` should still work for existing callers, but internally it registers a `HibikiFocusTarget`. This preserves old call sites while moving the data model into the new layer.

- [x] **Step 5: Verify**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/focus lib/src/utils/components/hibiki_focusable.dart test/focus
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/focus/global_focus_contract_test.dart test/widgets/hibiki_focusable_test.dart
git status --short
git add -- lib/src/focus lib/main.dart lib/src/utils/components/hibiki_focusable.dart test/focus test/widgets/hibiki_focusable_test.dart
git diff --cached --check
git commit -m "feat(focus): add global focus root"
```

---

## Focus Task 3: Move Gamepad and Keyboard Navigation Onto the Focus Controller

**Files:**
- Modify: `hibiki/lib/src/shortcuts/gamepad_service.dart`
- Modify: `hibiki/lib/src/shortcuts/global_navigation.dart`
- Modify: `hibiki/test/shortcuts/gamepad_focus_nav_test.dart`
- Modify: `hibiki/test/shortcuts/gamepad_navigation_flow_test.dart`
- Modify: `hibiki/test/shortcuts/shortcut_focus_dispatch_test.dart`

- [x] **Step 1: Replace directional fallback as the primary path**

`GamepadService` should dispatch D-pad and analog-stick movement through the app controller:

```dart
final HibikiFocusController? focus =
    HibikiFocusRoot.maybeControllerOf(ctx);
if (focus != null &&
    dir != null &&
    focus.move(hibikiFocusDirectionFromTraversal(dir))) {
  return;
}
```

Add the conversion helper in the focus layer so shortcut code does not define its own direction vocabulary.

Keep `gamepadMoveFocusInDirection(...)` temporarily only for unrooted tests or screens not yet wrapped by `HibikiFocusRoot`. Mark it deprecated after all app surfaces are rooted.

- [x] **Step 2: Make activation use active focus context**

Activation, long-press, and B/back dispatch should resolve context from `HibikiFocusController.activeContext`. `navigatorKey.currentContext` is only a last-resort shell fallback, never the normal action context.

- [x] **Step 3: Make Escape/back repair focus after pop**

After `Navigator.maybePop()`, schedule `focus.ensureFocus()`. Closing a dialog must restore focus to the invoking target or nearest valid route target.

- [x] **Step 4: Verify**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/shortcuts test/shortcuts
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/shortcuts/gamepad_focus_nav_test.dart test/shortcuts/gamepad_navigation_flow_test.dart test/shortcuts/shortcut_focus_dispatch_test.dart
git status --short
git add -- lib/src/shortcuts test/shortcuts
git diff --cached --check
git commit -m "fix(focus): route gamepad movement through focus controller"
```

---

## Focus Task 4: Centralize Focus-Driven Scroll

**Files:**
- Add: `hibiki/lib/src/focus/hibiki_focus_scroll.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_focus_ring.dart`
- Modify: `hibiki/test/focus/focus_driven_scroll_test.dart`
- Modify: `hibiki/test/widgets/hibiki_focus_ring_test.dart`

- [x] **Step 1: Move scroll reveal out of the ring**

`HibikiFocusRing` should paint and track geometry. It should not own scroll policy. Move the existing "only scroll if hidden" logic into `HibikiFocusScroll`.

Required behavior:

- Reveal happens after target focus changes, not after arbitrary scroll notifications.
- Nested scrollables are supported by calling Flutter's reveal logic from the target context after the controller has chosen the target.
- If the target is already fully visible, do nothing.
- Manual scroll never changes app focus.
- Touch highlight mode may suppress the visible ring, but it must not invalidate focus ownership.

- [x] **Step 2: Make the controller call scroll reveal**

After `move(...)` or `requestById(...)` succeeds, schedule `HibikiFocusScroll.ensureVisible(...)` for the target. Keep this post-frame; disposal and layout changes must settle before geometry reads.

- [x] **Step 3: Add static guard for forbidden scroll ownership**

Add a focused static test that allows `Scrollable.ensureVisible` only in:

- `lib/src/focus/hibiki_focus_scroll.dart`
- Temporary allowlisted legacy files with a removal comment

- [x] **Step 4: Verify**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/focus lib/src/utils/components/hibiki_focus_ring.dart test/focus test/widgets/hibiki_focus_ring_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/focus/focus_driven_scroll_test.dart test/widgets/hibiki_focus_ring_test.dart
git status --short
git add -- lib/src/focus lib/src/utils/components/hibiki_focus_ring.dart test/focus test/widgets/hibiki_focus_ring_test.dart
git diff --cached --check
git commit -m "fix(focus): centralize focus-driven scrolling"
```

Implementation evidence: scroll ownership is centralized in `HibikiFocusScroll`, and `focus_architecture_static_test.dart` guards `Scrollable.ensureVisible` placement. Verified in commit `489474495`.

---

## Focus Task 5: Define Scope Policies for Lists, Grids, Dialogs, Charts, and Reader Chrome

**Files:**
- Add: `hibiki/lib/src/focus/hibiki_focus_policy.dart`
- Modify: `hibiki/lib/src/focus/hibiki_focus_scope.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart`
- Modify: `hibiki/lib/src/utils/components/settings_shared.dart`
- Add/modify tests under `hibiki/test/focus/`, `hibiki/test/settings/`, and `hibiki/test/pages/`

- [ ] **Step 1: Implement deterministic policies**

Start with four policies. Do not invent more until a real surface needs one.

- `ordered`: rows, settings sections, menus, vertical dialogs.
- `grid`: shelves, cover grids, dictionary cards.
- `modal`: dialogs/sheets trap focus and restore the invoker on close.
- `proxy`: charts, previews, and non-interactive panels expose one focus target with explicit actions instead of pretending every painted label is focusable.

- [ ] **Step 2: Make shared MD3 primitives register targets**

`HibikiListItem`, `HibikiCard` when tappable, `HibikiSearchField`, overflow menus, file picker rows, adaptive settings rows, segmented controls, sliders, and switches should opt into focus target registration at the component layer.

This is the important MD3 merge point: a page migrated to shared MD3 primitives gets deterministic keyboard/gamepad focus for free.

Progress: `HibikiListItem`, `HibikiCard`, `HibikiDropdown`, `HibikiSearchField`, `HibikiTextField`, `HibikiSelectableChip`, `HibikiActionChip`, and `HibikiIconButton` now register focus targets when given a `focusId`. Remaining work: overflow menus, file picker rows, adaptive settings rows, segmented controls, sliders, switches, and any page-owned proxy targets.

- [ ] **Step 3: Remove page-local traversal hacks while migrating components**

Any direct `nextFocus`, `previousFocus`, or `focusInDirection` outside `lib/src/focus/` should either disappear or be listed in a temporary allowlist with owner and removal task.

- [ ] **Step 4: Verify**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/focus lib/src/utils/components test/focus test/settings test/pages
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/focus test/settings/settings_renderer_test.dart test/widgets/settings_focus_traversal_test.dart
git status --short
git add -- lib/src/focus lib/src/utils/components test/focus test/settings test/widgets/settings_focus_traversal_test.dart
git diff --cached --check
git commit -m "feat(focus): add deterministic focus scopes"
```

---

## Focus Task 6: Bridge Hoshi Reader Focus Without Breaking Reading State

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`
- Modify: reader-related focus tests under `hibiki/test/pages/` or `hibiki/test/media/audiobook/`

- [ ] **Step 1: Treat the reader content area as one Flutter focus target**

The Hoshi WebView/content host owns Flutter focus while reading content. DOM selection, popup lookup state, and text selection are internal reader state below that target. Do not create a second Flutter focus model for DOM caret movement.

- [ ] **Step 2: Move reader chrome and popup focus into named scopes**

Reader content, top chrome, audiobook play bar, quick settings, popup header, and popup results should be explicit scopes. Existing `_focusNode`, `_chromeFocusScope`, and `_popupHeaderScope` behavior must be preserved, but the selection policy moves into the focus layer.

The current page-local pattern:

- request full-page reader focus
- request chrome scope focus
- call `nextFocus()`
- if it fails, request reader focus again

should become one controller operation with a deterministic fallback target.

- [ ] **Step 3: Preserve page-turn and lookup behavior**

D-pad/page-turn shortcuts in the reader must keep winning when the reader content scope handles them. Only unhandled directional input should move app focus to chrome/popup controls.

Regression coverage:

- Reader content focused, D-pad right/left still pages when bound.
- Opening quick settings traps focus inside the sheet.
- Closing quick settings restores reader content or invoking chrome button.
- Popup lookup header/results can be traversed without focus falling back to the whole page.
- Audiobook play bar controls are reachable and do not let body text run underneath them.

- [ ] **Step 4: Verify with tests and emulator evidence**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/src/pages/implementations/reader_hibiki_page.dart lib/src/media/audiobook test/pages test/media/audiobook
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/pages test/media/audiobook
```

If this task changes Hoshi reader chrome or audiobook layout, run real emulator verification and save evidence under `.codex-test/`:

- screenshot of reader content focus
- screenshot of quick settings focus trap
- screenshot/UI XML or bounds evidence for audiobook play bar
- logcat excerpt if renderer/focus crashes occur

Then commit only the related files:

```powershell
git status --short
git add -- lib/src/pages/implementations/reader_hibiki_page.dart lib/src/media/audiobook test/pages test/media/audiobook .codex-test docs/REGRESSION_BUGS.md
git diff --cached --check
git commit -m "fix(reader): integrate reader focus scopes"
```

Only stage `.codex-test` and `docs/REGRESSION_BUGS.md` when this task actually produced evidence or reproduced a bug.

---

## Focus Task 7: Add Static Focus Audit Before Page-Family MD3 Migration

**Files:**
- Modify: `hibiki/test/settings/md3_design_system_static_test.dart`
- Add or modify: `hibiki/test/focus/focus_static_audit_test.dart`
- Review all matches from:
  - `rg -n "primaryFocus|focusInDirection|nextFocus|previousFocus|requestFocus|unfocus|Scrollable.ensureVisible" hibiki/lib/src hibiki/lib/main.dart -g "*.dart"`

- [ ] **Step 1: Create an allowlist with reasons**

The allowlist is not a dumping ground. Each direct focus call outside `lib/src/focus/` must include:

- file path
- reason it cannot use the focus layer yet
- owner task that will remove it
- whether it is reader compatibility, text input behavior, or route fallback

- [ ] **Step 2: Fail new raw focus traversal by default**

The static test should reject new raw `focusInDirection`, `nextFocus`, `previousFocus`, and `Scrollable.ensureVisible` uses outside the focus module. `requestFocus` and `unfocus` need a narrower rule because text input and route transitions may have legitimate uses, but they still require allowlist review.

- [ ] **Step 3: Wire this into the MD3 guardrail**

`md3_design_system_static_test.dart` should make the connection explicit: shared MD3 components are also focus participants. A new ordinary interactive component that is not focus-aware is a design-system violation, not merely an accessibility bug.

- [ ] **Step 4: Verify**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format test/focus test/settings/md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/focus/focus_static_audit_test.dart test/settings/md3_design_system_static_test.dart
git status --short
git add -- test/focus/focus_static_audit_test.dart test/settings/md3_design_system_static_test.dart
git diff --cached --check
git commit -m "test(focus): guard global focus architecture"
```

---

## Task 1: Freeze the MD3 Architecture Contract

**Files:**
- Modify: `hibiki/test/settings/md3_design_system_static_test.dart`
- Review: `docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md`
- Review: `docs/reviews/2026-05-26-project-review.md`
- Review: `docs/reviews/2026-05-27-project-review.md`

- [ ] **Step 1: Add a static test for forbidden page-local ordinary chrome**

Add a test near the other static MD3 tests. Keep allowlists explicit so future exceptions are reviewed instead of silently accepted.

```dart
  test('ordinary page chrome does not reopen local MD3 decisions', () {
    const Set<String> allowedFiles = <String>{
      'lib/src/utils/components/hibiki_design_tokens.dart',
      'lib/src/utils/components/hibiki_material_components.dart',
      'lib/src/utils/components/settings_shared.dart',
      'lib/src/pages/implementations/custom_theme_page.dart',
      'lib/src/pages/implementations/reading_statistics_page.dart',
      'lib/src/pages/implementations/reader_hibiki_page.dart',
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
    };
    const List<String> forbidden = <String>[
      'BorderRadius.circular(',
      'VisualDensity.compact',
      'surfaceContainerLow',
      'surfaceContainerHigh',
      'surfaceContainerHighest',
      'fontSize:',
      'Card(',
      'ListTile(',
      'SwitchListTile(',
      'CheckboxListTile(',
      'PopupMenuButton(',
    ];
    final Directory lib = Directory('lib/src');
    final List<File> dartFiles = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))
        .toList(growable: false);
    for (final File file in dartFiles) {
      final String path = file.path.replaceAll(r'\', '/');
      if (allowedFiles.any(path.endsWith)) continue;
      final String source = file.readAsStringSync();
      for (final String token in forbidden) {
        expect(
          source.contains(token),
          isFalse,
          reason: '$path must route $token through shared MD3 components',
        );
      }
    }
  });
```

- [ ] **Step 2: Run the test to prove the guard currently fails**

Run from `hibiki/`:

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart --reporter expanded
```

Expected: FAIL listing current files that still use old ordinary chrome directly. This is intentional; copy the failing file list into the next step's migration inventory.

- [ ] **Step 3: Narrow the allowlist to true content exceptions**

The first failing list will include false positives. Keep only these exception classes:

- Shared component implementations.
- Theme preview or color/chart previews where `fontSize` or `surfaceContainer*` is the content being previewed.
- Reader content/chrome where the value is user-configured reading content, not ordinary app chrome.
- Test files.

Do not allow an exception because "this page is annoying to migrate." That is garbage architecture.

- [ ] **Step 4: Commit the guard only after the allowlist makes it pass for current accepted exceptions**

Run:

```powershell
git add -- hibiki/test/settings/md3_design_system_static_test.dart
git diff --cached --check
git commit -m "test(ui): define MD3 architecture guard"
```

If the guard is too broad to be useful, do not commit it. Instead split it into smaller focused tests per family in Tasks 3-8. Do not commit a permanently failing test.

---

## Task 2: Rebuild Settings Information Architecture Around the Schema

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema.dart`
- Modify: `hibiki/lib/src/settings/settings_destination.dart` if metadata is needed
- Modify: `hibiki/lib/src/settings/settings_actions.dart`
- Modify: `hibiki/lib/src/settings/settings_home_page.dart`
- Test: `hibiki/test/settings/settings_renderer_test.dart`
- Test: `hibiki/test/settings/settings_migration_static_test.dart`
- Test: `hibiki/test/settings/settings_redesign_static_test.dart`

- [ ] **Step 1: Write a schema shape test**

Add assertions to `settings_renderer_test.dart` using its existing `_harness(...)` pattern, or create `settings_schema_architecture_test.dart` with the same in-memory `HibikiDatabase` + `ProviderScope` setup. Do not invent a null `SettingsContext`; `buildSettingsSchema()` reads real `AppModel` and `ReaderHibikiSource` state.

```dart
testWidgets('settings destinations keep the MD3 information architecture', (
  WidgetTester tester,
) async {
  await tester.pumpWidget(
    _harness(
      platform: TargetPlatform.android,
      builder: (SettingsContext settingsContext) {
        final List<SettingsDestinationId> order = buildSettingsSchema(
          settingsContext,
        ).map((SettingsDestination destination) => destination.id).toList();
    expect(order, <SettingsDestinationId>[
      SettingsDestinationId.appearance,
      SettingsDestinationId.profiles,
      SettingsDestinationId.readingDisplay,
      SettingsDestinationId.readingControls,
      SettingsDestinationId.lookup,
      SettingsDestinationId.cardCreation,
      SettingsDestinationId.listening,
      SettingsDestinationId.syncBackup,
      SettingsDestinationId.system,
      SettingsDestinationId.diagnostics,
    ]);
        return const SizedBox.shrink();
      },
    ),
  );
});
```

Use the existing imports from `settings_renderer_test.dart`: `TargetPlatform`, `SettingsContext`, `SettingsDestination`, `SettingsDestinationId`, and `buildSettingsSchema`.

- [ ] **Step 2: Move configuration entries by semantic owner**

In `settings_schema.dart`, keep these destinations and move rows there:

```dart
List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _profilesDestination(),
    _readingDisplayDestination(),
    _readingControlsDestination(),
    _lookupDestination(),
    _cardCreationDestination(),
    _listeningDestination(),
    buildSyncBackupDestination(),
    _systemDestination(),
    _diagnosticsDestination(),
  ];
}
```

Expected ownership:

- Appearance: design system, theme, brightness, language, app icon, navigation bar order.
- Profiles: current profile, profile management.
- Reading display: typography, fonts, book CSS, reader theme preview links.
- Reading controls: tap, swipe, volume, keyboard/shortcut behavior, keep screen awake.
- Lookup: dictionaries, dictionary CSS, audio sources, popup behavior, result display, local audio databases.
- Card creation: Anki and mining-related toggles.
- Listening: media notification, floating lyric, audiobook sentence navigation.
- Sync/backup: sync backend, backup import/export, per-content sync switches.
- System: update channel, low memory mode, GitHub.
- Diagnostics: error log, debug log, debug log toggle.

- [ ] **Step 3: Delete or hide visible rows that are not real settings**

Use one of these patterns:

```dart
SettingsNavigationItem(
  id: 'reading_display.book_css',
  title: t.book_css_editor_title,
  icon: Icons.code_outlined,
  visible: (_) => false,
  builder: (_) => const BookCssEditorPage(extractDir: ''),
)
```

or delete the `SettingsItem` if it only opens a dead/incomplete workflow. Do not delete underlying prefs unless the task explicitly lists a key migration.

- [ ] **Step 4: Keep every visible row iconed**

For every visible `SettingsItem`, set `icon`. Use outlined Material icons by default:

```dart
SettingsSwitchItem(
  id: 'lookup.auto_read_on_lookup',
  title: t.auto_read_on_lookup,
  icon: Icons.volume_up_outlined,
  value: (SettingsContext settingsContext) =>
      settingsContext.readerSource.autoReadOnLookup,
  onChanged: (SettingsContext settingsContext, bool value) {
    settingsContext.readerSource.toggleAutoReadOnLookup();
    notifyReaderSettingsChanged(settingsContext);
  },
)
```

- [ ] **Step 5: Run settings tests**

Run from `hibiki/`:

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\settings_renderer_test.dart test\settings\settings_migration_static_test.dart test\settings\settings_redesign_static_test.dart --reporter expanded
```

Expected: PASS after schema moves. If tests fail because visible row expectations changed, update assertions to the new schema order only after checking the moved rows still preserve value getters and setters.

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/settings/settings_schema.dart hibiki/lib/src/settings/settings_destination.dart hibiki/lib/src/settings/settings_actions.dart hibiki/lib/src/settings/settings_home_page.dart hibiki/test/settings/settings_renderer_test.dart hibiki/test/settings/settings_migration_static_test.dart hibiki/test/settings/settings_redesign_static_test.dart
git diff --cached --check
git commit -m "refactor(settings): align schema with MD3 information architecture"
```

---

## Task 3: Close Shared Component Gaps Before More Page Migration

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart`
- Modify: `hibiki/lib/src/utils/components/settings_shared.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Add explicit density tokens**

Add named density/height roles instead of page-local `VisualDensity.compact`:

```dart
class HibikiDensityTokens {
  const HibikiDensityTokens({
    this.listMinHeight = 56,
    this.compactListMinHeight = 44,
    this.controlHeight = 48,
    this.compactControlHeight = 36,
  });

  final double listMinHeight;
  final double compactListMinHeight;
  final double controlHeight;
  final double compactControlHeight;
}
```

Add it to `HibikiDesignTokens`:

```dart
const HibikiDesignTokens({
  required this.radii,
  required this.surfaces,
  required this.type,
  required this.spacing,
  required this.density,
});

final HibikiDensityTokens density;
```

and initialize it in `HibikiDesignTokens.of`:

```dart
density: const HibikiDensityTokens(),
```

- [ ] **Step 2: Add shared row variants instead of local layout forks**

Add optional density to `HibikiListItem`:

```dart
enum HibikiListDensity { standard, compact }
```

```dart
final HibikiListDensity density;
```

Use it to pick `minHeight` when a caller does not pass an explicit height:

```dart
final double resolvedMinHeight = minHeight ??
    switch (density) {
      HibikiListDensity.standard => tokens.density.listMinHeight,
      HibikiListDensity.compact => tokens.density.compactListMinHeight,
    };
```

Change `minHeight` from `double` to `double?` and update existing calls that depend on a hard value.

- [ ] **Step 3: Add a shared settings navigation row if renderers duplicate logic**

If both Material and Cupertino renderers still construct similar navigation rows, add:

```dart
class AdaptiveSettingsNavigationRow extends StatelessWidget {
  const AdaptiveSettingsNavigationRow({
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      trailing: Icon(
        isCupertinoPlatform(context)
            ? CupertinoIcons.chevron_forward
            : Icons.chevron_right,
      ),
      onTap: onTap,
    );
  }
}
```

- [ ] **Step 4: Extend static component tests**

In `md3_design_system_static_test.dart`, require the new tokens:

```dart
'lib/src/utils/components/hibiki_design_tokens.dart': <String>[
  'class HibikiDesignTokens',
  'class HibikiDensityTokens',
  'final HibikiDensityTokens density',
],
```

and require row density support:

```dart
'lib/src/utils/components/hibiki_material_components.dart': <String>[
  'enum HibikiListDensity',
  'HibikiListDensity.compact',
],
```

- [ ] **Step 5: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\utils\components\hibiki_design_tokens.dart lib\src\utils\components\hibiki_material_components.dart lib\src\utils\components\settings_shared.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart --reporter expanded
```

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/utils/components/hibiki_design_tokens.dart hibiki/lib/src/utils/components/hibiki_material_components.dart hibiki/lib/src/utils/components/settings_shared.dart hibiki/test/settings/md3_design_system_static_test.dart
git diff --cached --check
git commit -m "feat(ui): add MD3 density tokens and row variants"
```

---

## Task 4: Make Settings Renderers Pure Schema Renderers

**Files:**
- Modify: `hibiki/lib/src/settings/material_settings_renderer.dart`
- Modify: `hibiki/lib/src/settings/cupertino_settings_renderer.dart`
- Modify: `hibiki/lib/src/settings/settings_actions.dart`
- Test: `hibiki/test/settings/settings_renderer_test.dart`
- Test: `hibiki/test/pages/hibiki_settings_dialog_page_test.dart`
- Test: `hibiki/test/pages/hibiki_settings_dialog_md3_static_test.dart`

- [ ] **Step 1: Add renderer tests for every item type**

Make sure the renderer test builds one item of each type:

```dart
SettingsSection(
  title: 'Controls',
  items: <SettingsItem>[
    SettingsNavigationItem(
      id: 'test.nav',
      title: 'Navigation',
      icon: Icons.chevron_right_outlined,
      builder: (_) => const SizedBox.shrink(),
    ),
    SettingsActionItem(
      id: 'test.action',
      title: 'Action',
      icon: Icons.play_arrow_outlined,
      onTap: (_) {},
    ),
    SettingsSwitchItem(
      id: 'test.switch',
      title: 'Switch',
      icon: Icons.toggle_on_outlined,
      value: (_) => true,
      onChanged: (_, bool value) {},
    ),
    SettingsSegmentedItem<String>(
      id: 'test.segmented',
      title: 'Segmented',
      icon: Icons.view_week_outlined,
      options: const <SettingsSegmentOption<String>>[
        SettingsSegmentOption<String>(value: 'a', label: 'A'),
        SettingsSegmentOption<String>(value: 'b', label: 'B'),
      ],
      selected: (_) => 'a',
      onChanged: (_, String value) {},
    ),
  ],
)
```

- [ ] **Step 2: Remove renderer-specific visual decisions**

In both renderers:

- Use `HibikiListItem` or `AdaptiveSettingsRow`, not raw `ListTile`.
- Use `HibikiCard` or `AdaptiveSettingsSection`, not raw `Card`.
- Use token spacing, not numeric page-local padding except constructor defaults inside shared components.
- Do not cast typed callbacks to `Function`; call the `SettingsValueChanged<T>` callback directly.

- [ ] **Step 3: Keep custom builders contained**

For `SettingsCustomItem`, the renderer may call:

```dart
SettingsCustomItem custom => custom.builder(settingsContext),
```

but every custom builder in `settings_actions.dart`, `settings_schema.dart`, and `sync_settings_schema.dart` must return `AdaptiveSettingsRow`, `AdaptiveSettingsSection`, `HibikiTextField`, `HibikiCard`, or another shared primitive.

- [ ] **Step 4: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\settings\material_settings_renderer.dart lib\src\settings\cupertino_settings_renderer.dart lib\src\settings\settings_actions.dart test\settings\settings_renderer_test.dart test\pages\hibiki_settings_dialog_page_test.dart test\pages\hibiki_settings_dialog_md3_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\settings_renderer_test.dart test\pages\hibiki_settings_dialog_page_test.dart test\pages\hibiki_settings_dialog_md3_static_test.dart --reporter expanded
```

- [ ] **Step 5: Commit**

```powershell
git add -- hibiki/lib/src/settings/material_settings_renderer.dart hibiki/lib/src/settings/cupertino_settings_renderer.dart hibiki/lib/src/settings/settings_actions.dart hibiki/test/settings/settings_renderer_test.dart hibiki/test/pages/hibiki_settings_dialog_page_test.dart hibiki/test/pages/hibiki_settings_dialog_md3_static_test.dart
git diff --cached --check
git commit -m "refactor(settings): render schema through shared MD3 rows"
```

---

## Task 5: Migrate Appearance and Reader Customization Settings

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/display_settings_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/custom_fonts_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/custom_theme_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/book_css_editor_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/blur_options_dialog_page.dart`
- Test: `hibiki/test/pages/custom_fonts_dialog_page_test.dart`
- Test: `hibiki/test/pages/book_css_editor_page_test.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Decide which pages remain full pages**

Keep full pages only when they have real workflows:

- `custom_theme_page.dart`: keep as preview studio.
- `custom_fonts_page.dart`: keep as font management workflow.
- `book_css_editor_page.dart`: keep as editor workflow.
- `display_settings_page.dart`: migrate simple toggles/sliders into `settings_schema.dart` where possible.
- `blur_options_dialog_page.dart`: keep only if it has a visual preview; otherwise fold rows into reading display.

- [ ] **Step 2: Move simple rows into `settings_schema.dart`**

For each moved row, use schema item types instead of page-local rows:

```dart
SettingsSliderItem(
  id: 'reading_display.font_size',
  title: t.ttu_font_size,
  icon: Icons.format_size_outlined,
  min: 10,
  max: 40,
  divisions: 30,
  value: (SettingsContext settingsContext) =>
      settingsContext.readerSource.ttuFontSize,
  label: (double value) => value.round().toString(),
  onChanged: (SettingsContext settingsContext, double value) {
    settingsContext.readerSource.setTtuFontSize(value);
    notifyReaderSettingsChanged(settingsContext);
  },
)
```

Use the existing setter names even if they contain `Ttu`; they are compatibility names.

- [ ] **Step 3: Replace local preview chrome with shared primitives**

In the remaining full pages:

- Use `HibikiCard` for preview blocks.
- Use `HibikiColorSwatch` for color chips.
- Use `HibikiPreviewSwitch` for preview toggles.
- Use `HibikiTextField` or `AdaptiveSettingsTextField` for inputs.
- Keep literal `fontSize` only inside actual reader/font preview content.

- [ ] **Step 4: Strengthen static tests**

Add or extend checks that these files use the shared primitives and do not render old framework settings rows:

```dart
expect(source, contains('HibikiCard'));
expect(source, isNot(contains('SwitchListTile(')));
expect(source, isNot(contains('CheckboxListTile(')));
```

- [ ] **Step 5: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\pages\implementations\display_settings_page.dart lib\src\pages\implementations\custom_fonts_page.dart lib\src\pages\implementations\custom_theme_page.dart lib\src\pages\implementations\book_css_editor_page.dart lib\src\pages\implementations\blur_options_dialog_page.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\pages\custom_fonts_dialog_page_test.dart test\pages\book_css_editor_page_test.dart --reporter expanded
```

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/pages/implementations/display_settings_page.dart hibiki/lib/src/pages/implementations/custom_fonts_page.dart hibiki/lib/src/pages/implementations/custom_theme_page.dart hibiki/lib/src/pages/implementations/book_css_editor_page.dart hibiki/lib/src/pages/implementations/blur_options_dialog_page.dart hibiki/test/settings/md3_design_system_static_test.dart hibiki/test/pages/custom_fonts_dialog_page_test.dart hibiki/test/pages/book_css_editor_page_test.dart
git diff --cached --check
git commit -m "refactor(ui): fold reader appearance settings into MD3 schema"
```

---

## Task 6: Migrate Lookup and Dictionary Management Surfaces

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_dialog_import_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_dialog_delete_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_popup_native.dart`
- Modify: `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`
- Modify: `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/floating_dict_page.dart`
- Test: `hibiki/test/pages/dictionary_dialog_layout_static_test.dart`
- Test: `hibiki/test/pages/dictionary_progress_dialog_page_test.dart`
- Test: `hibiki/test/pages/audio_sources_dialog_page_test.dart`
- Test: `hibiki/test/pages/popup_dictionary_page_test.dart`
- Test: `hibiki/test/pages/floating_dict_page_static_test.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Preserve dictionary behavior before UI changes**

Search for behavior gates:

```powershell
rg -n "collapseDictionaries|showExpressionTags|deduplicatePitchAccents|harmonicFrequency|localAudio|audioSources|DictionaryPopup|HibikiPopupSurface|HibikiCompactSearchRow" lib\src\pages\implementations lib\src\settings
```

Write down which rows are settings and which are management actions. Settings belong in `settings_schema.dart`; management actions stay in dictionary management pages.

- [ ] **Step 2: Convert management lists to shared grouped cards**

Use `HibikiCard` for category/group shells and `HibikiListItem` for rows:

```dart
HibikiCard(
  padding: EdgeInsets.zero,
  child: Column(
    children: dictionaries.map((DictionaryMeta dictionary) {
      return HibikiListItem(
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(dictionary.name),
        subtitle: Text(dictionary.revision),
        trailing: Checkbox(
          value: selectedIds.contains(dictionary.id),
          onChanged: (bool? value) => toggleDictionary(dictionary.id),
        ),
        onTap: () => toggleDictionary(dictionary.id),
      );
    }).toList(growable: false),
  ),
)
```

- [ ] **Step 3: Keep dictionary content typography out of ordinary chrome bans**

Dictionary entry HTML/native content can have content-specific typography. Ordinary shell elements cannot. Put exceptions in static tests by file/section, not broad file allowlists.

- [ ] **Step 4: Keep popup lookup shells shared**

All popup/floating shells should use:

- `HibikiPopupSurface`
- `HibikiCompactSearchRow`
- `HibikiOverlayScaffold`
- `HibikiTagChip` for small dictionary/source tags

Do not reintroduce raw `TextField`, local `DecoratedBox`, or local `BorderRadius.circular`.

- [ ] **Step 5: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\pages\implementations\home_dictionary_page.dart lib\src\pages\implementations\dictionary_dialog_page.dart lib\src\pages\implementations\dictionary_dialog_import_page.dart lib\src\pages\implementations\dictionary_dialog_delete_page.dart lib\src\pages\implementations\dictionary_settings_dialog_page.dart lib\src\pages\implementations\dictionary_popup_webview.dart lib\src\pages\implementations\dictionary_popup_native.dart lib\src\pages\implementations\dictionary_popup_layer.dart lib\src\pages\implementations\popup_dictionary_page.dart lib\src\pages\implementations\floating_dict_page.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\pages\dictionary_dialog_layout_static_test.dart test\pages\dictionary_progress_dialog_page_test.dart test\pages\audio_sources_dialog_page_test.dart test\pages\popup_dictionary_page_test.dart test\pages\floating_dict_page_static_test.dart --reporter expanded
```

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/pages/implementations/home_dictionary_page.dart hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart hibiki/lib/src/pages/implementations/dictionary_dialog_import_page.dart hibiki/lib/src/pages/implementations/dictionary_dialog_delete_page.dart hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart hibiki/lib/src/pages/implementations/dictionary_popup_native.dart hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart hibiki/lib/src/pages/implementations/popup_dictionary_page.dart hibiki/lib/src/pages/implementations/floating_dict_page.dart hibiki/test/settings/md3_design_system_static_test.dart hibiki/test/pages/dictionary_dialog_layout_static_test.dart hibiki/test/pages/dictionary_progress_dialog_page_test.dart hibiki/test/pages/audio_sources_dialog_page_test.dart hibiki/test/pages/popup_dictionary_page_test.dart hibiki/test/pages/floating_dict_page_static_test.dart
git diff --cached --check
git commit -m "refactor(dictionary): use shared MD3 lookup and management chrome"
```

---

## Task 7: Migrate Reader Shelf, Collections, Tags, and Statistics

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_reader_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/history_reader_page.dart`
- Modify: `hibiki/lib/src/pages/base_history_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/collections_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_management_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_picker_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/tag_filter_sheet.dart`
- Modify: `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
- Test: `hibiki/test/pages/book_profile_dialog_page_test.dart`
- Test: `hibiki/test/pages/reader_history_delete_dialog_test.dart`
- Test: `hibiki/test/pages/history_reader_page_static_test.dart`
- Test: `hibiki/test/pages/tag_picker_page_static_test.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Preserve shelf behavior**

Before changing UI, search for interactions that must survive:

```powershell
rg -n "onLongPress|Reorderable|Selection|Tag|Bookmark|_bookCardShell|_hasAudio|_playItemAudio|_findCueForItem" lib\src\pages\implementations\reader_hibiki_history_page.dart lib\src\pages\implementations\collections_page.dart lib\src\pages\implementations\tag_management_page.dart
```

Do not lose long-press, selection, tag drop, reorder, import, delete, or audio playback affordances.

- [ ] **Step 2: Route all cards through shared shells**

Use:

- `HibikiCard` for book/card shells.
- `HibikiListItem` for list rows.
- `HibikiTagChip` for tags.
- `HibikiBadge` for small status markers.
- `HibikiColorSwatch` for tag colors.
- `HibikiPlaceholderMessage` for empty states.

- [ ] **Step 3: Keep chart drawing exceptions local to chart painters**

`reading_statistics_page.dart` may use direct colors inside chart painters. Ordinary page sections around charts should use `HibikiCard` and tokens.

- [ ] **Step 4: Strengthen static tests**

For migrated shelf/list files, assert shared components exist and old rows do not:

```dart
expect(source, contains('HibikiCard'));
expect(source, contains('HibikiListItem'));
expect(source, isNot(contains('CheckboxListTile(')));
expect(source, isNot(contains('SwitchListTile(')));
```

- [ ] **Step 5: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\pages\implementations\home_reader_page.dart lib\src\pages\implementations\reader_hibiki_history_page.dart lib\src\pages\implementations\history_reader_page.dart lib\src\pages\base_history_page.dart lib\src\pages\implementations\collections_page.dart lib\src\pages\implementations\tag_management_page.dart lib\src\pages\implementations\tag_picker_page.dart lib\src\pages\implementations\tag_filter_sheet.dart lib\src\pages\implementations\reading_statistics_page.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\pages\book_profile_dialog_page_test.dart test\pages\reader_history_delete_dialog_test.dart test\pages\history_reader_page_static_test.dart test\pages\tag_picker_page_static_test.dart --reporter expanded
```

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/pages/implementations/home_reader_page.dart hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart hibiki/lib/src/pages/implementations/history_reader_page.dart hibiki/lib/src/pages/base_history_page.dart hibiki/lib/src/pages/implementations/collections_page.dart hibiki/lib/src/pages/implementations/tag_management_page.dart hibiki/lib/src/pages/implementations/tag_picker_page.dart hibiki/lib/src/pages/implementations/tag_filter_sheet.dart hibiki/lib/src/pages/implementations/reading_statistics_page.dart hibiki/test/settings/md3_design_system_static_test.dart hibiki/test/pages/book_profile_dialog_page_test.dart hibiki/test/pages/reader_history_delete_dialog_test.dart hibiki/test/pages/history_reader_page_static_test.dart hibiki/test/pages/tag_picker_page_static_test.dart
git diff --cached --check
git commit -m "refactor(ui): migrate shelf and collection chrome to MD3 primitives"
```

---

## Task 8: Migrate Reader Quick Settings and Audiobook Chrome

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
- Modify: `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
- Test: `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Keep reader settings data flow intact**

Do not rename compatibility setters. Use existing reader source calls:

```dart
settingsContext.readerSource.setTtuFontSize(value);
settingsContext.readerSource.setTtuLineHeight(value);
settingsContext.readerSource.setTtuTheme(value);
settingsContext.readerSource.setTtuViewMode(value);
```

- [ ] **Step 2: Keep quick settings as a sheet, not a second global settings app**

The first screen should expose only high-frequency controls:

- font size
- line height
- theme
- paginated/continuous
- current location/status
- subpage links for appearance, layout, behavior, location, audiobook

Low-frequency rows move to global settings schema or subpages.

- [ ] **Step 3: Replace local controls with shared/adaptive controls**

Use:

- `HibikiModalSheetFrame`
- `AdaptiveSettingsSection`
- `AdaptiveSettingsRow`
- `AdaptiveSettingsSegmentedRow`
- `HibikiSelectableChip`
- `HibikiTextField`

Do not add local `Container` card shells.

- [ ] **Step 4: Preserve audiobook bar layout boundaries**

Any change to `audiobook_play_bar.dart` or reader bottom chrome must verify that WebView/body content does not extend under the play bar. If implementation touches layout insets, add a manual verification note in the final implementation report.

- [ ] **Step 5: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\media\audiobook\reader_quick_settings_sheet.dart lib\src\media\audiobook\audiobook_play_bar.dart lib\src\pages\implementations\reader_hibiki_page.dart test\media\audiobook\reader_quick_settings_sheet_static_test.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\media\audiobook\reader_quick_settings_sheet_static_test.dart test\settings\md3_design_system_static_test.dart --reporter expanded
```

- [ ] **Step 6: Commit**

```powershell
git add -- hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart hibiki/lib/src/media/audiobook/audiobook_play_bar.dart hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart hibiki/test/settings/md3_design_system_static_test.dart
git diff --cached --check
git commit -m "refactor(reader): align quick settings and audiobook chrome with MD3"
```

---

## Task 9: Migrate Import, Media, Anki, and Utility Dialogs

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
- Modify: `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`
- Modify: `hibiki/lib/src/pages/implementations/media_item_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/media_source_picker_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/example_sentences_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/open_stash_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/audio_recorder_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/anki_settings_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/text_segmentation_dialog_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/crop_image_dialog_page.dart`
- Test: `hibiki/test/media/audiobook/book_import_dialog_test.dart`
- Test: `hibiki/test/pages/media_item_dialog_page_test.dart`
- Test: `hibiki/test/pages/media_item_edit_dialog_page_test.dart`
- Test: `hibiki/test/pages/anki_settings_page_test.dart`
- Test: `hibiki/test/settings/md3_design_system_static_test.dart`

- [ ] **Step 1: Keep workflow semantics**

For import dialogs, preserve:

- DocumentsUI/file picker flow.
- Authorized `content://` import behavior.
- Existing matching options.
- Existing progress and error states.

For Anki, preserve:

- AnkiConnect and AnkiDroid routing.
- deck/model fetch behavior.
- mapping labels and persisted mappings.

- [ ] **Step 2: Use step-based/import primitives**

Use existing primitives first:

- `HibikiFilePickerRow`
- `AdaptiveSettingsSection`
- `AdaptiveSettingsSwitchRow`
- `HibikiTextField`
- `HibikiDialogFrame`
- `HibikiModalSheetFrame`
- `HibikiPlaceholderMessage`

Only add a new primitive if at least two dialogs duplicate the same layout.

- [ ] **Step 3: Run focused tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\media\audiobook\book_import_dialog.dart lib\src\media\audiobook\audiobook_import_dialog.dart lib\src\pages\implementations\media_item_dialog_page.dart lib\src\pages\implementations\media_item_edit_dialog_page.dart lib\src\pages\implementations\media_source_picker_dialog_page.dart lib\src\pages\implementations\example_sentences_dialog_page.dart lib\src\pages\implementations\open_stash_dialog_page.dart lib\src\pages\implementations\audio_recorder_page.dart lib\src\pages\implementations\anki_settings_page.dart lib\src\pages\implementations\text_segmentation_dialog_page.dart lib\src\pages\implementations\crop_image_dialog_page.dart test\settings\md3_design_system_static_test.dart
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\media\audiobook\book_import_dialog_test.dart test\pages\media_item_dialog_page_test.dart test\pages\media_item_edit_dialog_page_test.dart test\pages\anki_settings_page_test.dart --reporter expanded
```

- [ ] **Step 4: Commit**

```powershell
git add -- hibiki/lib/src/media/audiobook/book_import_dialog.dart hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart hibiki/lib/src/pages/implementations/media_item_dialog_page.dart hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart hibiki/lib/src/pages/implementations/media_source_picker_dialog_page.dart hibiki/lib/src/pages/implementations/example_sentences_dialog_page.dart hibiki/lib/src/pages/implementations/open_stash_dialog_page.dart hibiki/lib/src/pages/implementations/audio_recorder_page.dart hibiki/lib/src/pages/implementations/anki_settings_page.dart hibiki/lib/src/pages/implementations/text_segmentation_dialog_page.dart hibiki/lib/src/pages/implementations/crop_image_dialog_page.dart hibiki/test/settings/md3_design_system_static_test.dart hibiki/test/media/audiobook/book_import_dialog_test.dart hibiki/test/pages/media_item_dialog_page_test.dart hibiki/test/pages/media_item_edit_dialog_page_test.dart hibiki/test/pages/anki_settings_page_test.dart
git diff --cached --check
git commit -m "refactor(ui): align import and creator dialogs with MD3 primitives"
```

---

## Task 10: Final Static Audit and Manual Visual Verification

**Files:**
- Modify: `hibiki/test/settings/md3_design_system_static_test.dart`
- Append if needed: `docs/reviews/YYYY-MM-DD-project-review.md`
- Update only if reproduced: `docs/REGRESSION_BUGS.md`

- [ ] **Step 1: Run static searches for remaining old chrome**

Run from `hibiki/`:

```powershell
rg -n "\b(Card|ListTile|SwitchListTile|CheckboxListTile|ExpansionTile|PopupMenuButton|TextField|TextFormField|DropdownButton|DropdownButtonFormField)\s*\(" lib\src -g "*.dart"
rg -n "fontSize\s*:|BorderRadius\.circular|surfaceContainer|VisualDensity\.compact|dense\s*:" lib\src -g "*.dart"
```

For each hit, classify it as:

- shared component implementation
- content renderer or preview
- chart/custom painter
- Hoshi reader content/user setting
- remaining ordinary chrome defect

Every remaining ordinary chrome defect must become a new static test or be fixed before completion.

- [ ] **Step 2: Run design-system tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart --reporter expanded
```

Expected: PASS.

- [ ] **Step 3: Run focused page families**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\settings_renderer_test.dart test\pages\hibiki_settings_dialog_page_test.dart test\media\audiobook\book_import_dialog_test.dart test\pages\dictionary_dialog_layout_static_test.dart test\pages\popup_dictionary_page_test.dart test\pages\book_profile_dialog_page_test.dart test\pages\reader_history_delete_dialog_test.dart --reporter expanded
```

Expected: PASS.

- [ ] **Step 4: Run full Flutter tests**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
```

Expected: PASS. If full test is blocked by pre-existing environment/tooling failures, record the exact command, exit code, and first relevant error in the review note and final response.

- [ ] **Step 5: Manual Android Material path smoke**

Use the installed debug/release APK appropriate for the device ABI. Do not clear app data unless testing first-run UI is the goal.

Capture:

- home Books/Dictionaries/Settings tabs
- settings home and one detail page
- dictionary search and popup lookup
- reader shelf selection/long press
- reader quick settings sheet
- audiobook bar if a book with audio is available

Store evidence under `.codex-test/`, for example:

```text
.codex-test/md3-home.png
.codex-test/md3-settings.xml
.codex-test/md3-reader-quick-settings.png
.codex-test/md3-logcat.txt
```

For reader/audiobook layout, also capture bounds:

- WebView bounds
- body text/image bounds
- audiobook bar bounds

- [ ] **Step 6: Review report**

Append to `docs/reviews/YYYY-MM-DD-project-review.md`:

```markdown
## Round N - Material 3 architecture completion audit

### Scope

- Files and tests checked in this round.

### Findings

#### HBK-AUDIT-XXX - [title]

- severity: LOW|MEDIUM|HIGH
- status: resolved|open|blocked
- files/lines:
- root cause:
- impact:
- fix:
- verification:

### Next Scope

- None for ordinary app chrome, or list remaining specialized/content-rendering surfaces.
```

Do not claim manual verification passed without screenshots/UI XML/log evidence.

- [ ] **Step 7: Final commit**

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
git status --short
git add -- docs/reviews/YYYY-MM-DD-project-review.md docs/REGRESSION_BUGS.md hibiki/test/settings/md3_design_system_static_test.dart
git diff --cached --check
git commit -m "docs(ui): audit Material 3 architecture migration"
git status --short
```

Only stage `docs/REGRESSION_BUGS.md` if it was actually updated for a reproduced regression.

---

## Completion Criteria

The MD3 and global focus architecture migration is not complete until all of these are true:

- `HibikiFocusRoot` is installed once at the app shell and owns focus repair, movement, active context, and route fallback.
- After the first app frame, `FocusManager.instance.primaryFocus` does not become `null`; route transitions, dialog close, target removal, and disabled focused rows repair focus through the controller.
- Directional gamepad/keyboard movement goes through deterministic focus scope policies. Raw `focusInDirection`, `nextFocus`, and `previousFocus` are not the primary app navigation model.
- Focus drives scroll: controller movement chooses the target first, then `HibikiFocusScroll` reveals it. Page code does not use scroll position as the source of focus truth.
- Lists, grids, dialogs, charts/previews, settings rows, popup results, and reader chrome expose explicit focus targets or proxy targets.
- Hoshi reader content remains the current reader path and has a single Flutter focus owner while DOM selection remains internal reader state.
- `buildSettingsSchema()` is the source of truth for global settings grouping and visible row order.
- Every visible schema row has a semantic owner and icon.
- Simple setting rows are not stranded in one-off settings pages.
- Shared tokens include radius, spacing, surface, typography, and density roles.
- Ordinary page chrome uses shared primitives rather than raw `Card`, `ListTile`, local `TextField`, local menu shell, local radius, local surface role, local typography size, or page-local focus traversal.
- Remaining local visual constants are documented exceptions for content rendering, previews, charts, or reader user preferences.
- `md3_design_system_static_test.dart` and focus static tests guard the migrated architecture instead of only checking historical surface names.
- Focused focus/settings/page tests pass.
- Full `flutter test` passes or any blocker is documented as blocker evidence, not success.
- Hoshi reader UI changes have emulator/device evidence when reader chrome or audiobook layout is touched.
- Review report distinguishes code-audit risks, reproduced bugs, and verified fixes.

---

## Self-Review

### Requirement Coverage

- Material 3 base: covered by Tasks 1, 3, and 10.
- Global focus root and "focus never lost": covered by Focus Tasks 1, 2, 3, and 7.
- Focus Driven Scroll: covered by Focus Tasks 1 and 4.
- Gamepad/keyboard consistency: covered by Focus Tasks 3, 5, and 6.
- Lists/dialogs/charts/reader chrome focus consistency: covered by Focus Tasks 5 and 6.
- Settings movement/deletion: covered by Task 2 and Task 5.
- Shared token/component-first architecture: covered by Tasks 1, 3, 4, and 10.
- Shared component focus participation: covered by Focus Task 5 and MD3 Task 3.
- Page family migration: covered by Tasks 5-9.
- Hoshi reader compatibility: covered by constraints, Focus Task 6, and Task 8.
- Verification and review loop: covered by Task 10.

### Risk Review

- Biggest compatibility risk: accidentally deleting or renaming persisted reader/settings keys while moving UI rows. Mitigation: move visible rows through `settings_schema.dart`, keep existing getters/setters, and do not delete prefs without a named migration.
- Biggest focus risk: creating a second focus model beside Flutter's `FocusManager`. Mitigation: `HibikiFocusController` repairs and chooses targets, but Flutter `primaryFocus` remains the single focus owner.
- Biggest reader risk: treating Hoshi DOM selection as ordinary Flutter focus. Mitigation: reader content is one registered Flutter target; DOM caret/selection stays internal to the reader host.
- Biggest UI risk: broad static bans that block legitimate content rendering. Mitigation: allowlist by reason and section, not by convenience.
- Biggest testing risk: treating `flutter analyze` timeout or narrow static tests as proof of visual correctness. Mitigation: focused widget/static tests plus emulator evidence for touched reader surfaces.

### No-Placeholder Scan

No placeholder markers remain in the plan body. Follow-up work is represented as explicit tasks with files, commands, and expected evidence.

### Review Fix Log

- Replaced the initial schema-test sketch with a real widget-test pattern that reuses `settings_renderer_test.dart`'s `_harness(...)` setup.
- Corrected the guardrail task wording so implementers do not commit a permanently failing static test.
- Confirmed the plan has one task section for each implementation family and a separate completion audit.
- Merged the gamepad/keyboard global focus refactor into the MD3 architecture plan instead of leaving it as a separate UI-cleanup note.
- Added an explicit focus data model, focus-driven scroll contract, reader bridge, static focus audit, and completion criteria for "primary focus is never null".
