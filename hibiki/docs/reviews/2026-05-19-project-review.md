# 2026-05-19 Project Review

## Round 1: Windows Home Layout

### Scope
- `hibiki/lib/src/utils/misc/platform_utils.dart`
- `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- `hibiki/lib/src/pages/implementations/hoshi_settings_page.dart`
- `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- `hibiki/lib/src/pages/implementations/history_reader_page.dart`
- `hibiki/test/utils/misc/platform_layout_test.dart`

### Findings

#### HBK-AUDIT-010
- severity: medium
- status: fixed
- files: `hibiki/lib/src/utils/misc/platform_utils.dart`, `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`, `hibiki/lib/src/pages/implementations/hoshi_settings_page.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`, `hibiki/lib/src/pages/implementations/history_reader_page.dart`
- root cause: Windows/desktop home layout had a `NavigationRail`, but each content surface owned its own width and grid rules. Dictionary used a local 960px cap, settings used a too-narrow 640px cap, and reader history duplicated shelf-card breakpoints.
- impact: the default Windows window could still feel like a stretched phone layout, and future desktop UI changes would drift because the layout policy was scattered across page implementations.
- fix: introduced shared desktop layout metrics and `DesktopContentLayout`; reader shelf, dictionary, and settings now share the same content-width and padding policy, and shelf card extents are computed from one function.
- verification: `flutter test test/utils/misc/platform_layout_test.dart` passed, then `flutter test` passed with 730 tests. `flutter build windows --debug` also completed and produced `build/windows/x64/runner/Debug/hibiki.exe`; the build emitted existing CMake/WebView2/native conversion warnings but no errors. This is a code-path/layout-policy and Windows compile verification; full Windows runtime screenshot review is still a separate manual QA step.

### Next Scope
- If time permits, launch the Windows build and capture screenshots of Books, Dictionaries, and Settings at the default `1280x720` runner size.

## Round 2: Windows UI Verification Path

### Scope
- `hibiki/integration_test/app_smoke_test.dart`
- Windows desktop UI interaction verification for the home navigation rail.

### Findings

#### HBK-AUDIT-011
- severity: medium
- status: fixed
- files: `hibiki/integration_test/app_smoke_test.dart`
- root cause: the app smoke integration test only looked for `BottomNavigationBar` and Material `NavigationBar`. On Windows the home page uses `NavigationRail`, so the test could start the app but skip the actual desktop tab-switching path.
- impact: Windows Books -> Dictionaries -> Books navigation could regress without this smoke test noticing. Manual screenshots are also a weak source of truth here because external window capture can lie about the real Flutter layout under DPI, occlusion, or compositor state.
- fix: the smoke test now resolves primary navigation targets from `NavigationRail`, `BottomNavigationBar`, or `NavigationBar`, then taps the Flutter widgets through the integration test framework.
- verification: `flutter drive -d windows --driver=test_driver/integration_test.dart --target=integration_test/app_smoke_test.dart` passed from `hibiki/`. This uses Flutter test interaction, not host mouse input. The earlier external `PrintWindow` screenshot was treated as invalid evidence after local visual disagreement and was not used as a basis for UI changes.

### Next Scope
- Continue Windows UI review with `flutter drive` coverage for CJK dictionary search and Hoshi reader interactions, using fixtures where required.

## Round 3: Windows Integration Test Targeting

### Scope
- `hibiki/integration_test/app_smoke_test.dart`
- `hibiki/integration_test/user_path_test.dart`
- `hibiki/integration_test/reader_dictionary_test.dart`
- `hibiki/integration_test/regression_test.dart`
- `hibiki/integration_test/test_helpers.dart`
- `hibiki/test/integration/navigation_helpers_test.dart`

### Findings

#### HBK-AUDIT-012
- severity: medium
- status: fixed
- files: `hibiki/integration_test/test_helpers.dart`, `hibiki/integration_test/app_smoke_test.dart`, `hibiki/integration_test/user_path_test.dart`, `hibiki/integration_test/reader_dictionary_test.dart`, `hibiki/test/integration/navigation_helpers_test.dart`
- root cause: integration tests selected navigation tabs by scanning the whole widget tree for icons such as `Icons.search`. On Windows the content area can contain the same icons as the navigation rail, so the tests could tap a content icon instead of the navigation target.
- impact: Windows UI drive tests could become flaky or silently exercise the wrong path, especially around Dictionary and Settings navigation.
- fix: introduced a shared `findPrimaryNavigationTargets()` helper that scopes icon lookup to `NavigationRail`, `BottomNavigationBar`, or `NavigationBar`; app smoke, user path, and reader/dictionary integration tests now use that helper.
- verification: `flutter test test/integration/navigation_helpers_test.dart` passed and validates that content-area search icons are ignored when a `NavigationRail` is present. `flutter test` also passed with 731 tests, and `flutter drive -d windows --driver=test_driver/integration_test.dart --target=integration_test/app_smoke_test.dart` passed after the helper was shared.

#### HBK-AUDIT-013
- severity: low
- status: fixed
- files: `hibiki/integration_test/test_helpers.dart`, `hibiki/integration_test/user_path_test.dart`, `hibiki/integration_test/reader_dictionary_test.dart`, `hibiki/integration_test/regression_test.dart`
- root cause: Windows desktop `flutter drive` reports `MissingPluginException` for `integration_test` screenshot capture, but the tests still required at least one screenshot.
- impact: completed Windows widget interactions could fail only because screenshot capture is unsupported in this drive path.
- fix: screenshot evidence remains required on platforms that support it, but Windows drive tests now use widget assertions and drive exit status as the authoritative evidence.
- verification: `flutter drive -d windows --driver=test_driver/integration_test.dart --target=integration_test/user_path_test.dart` reached all tab navigation steps and skipped screenshots correctly; a later run was interrupted by a Flutter Windows `RawKeyboard` assertion caused by a host `Meta Left` key event while the user was actively using the machine, so this test remains environment-sensitive rather than a product UI failure. The non-focus-stealing validation path is covered by `flutter test test/integration/navigation_helpers_test.dart` and the passing Windows `app_smoke_test` drive run above.

### Next Scope
- Continue with non-focus-stealing Windows checks first. For full `user_path_test` and reader/dictionary drive validation, run when the desktop keyboard focus is not being used, or move those flows to widget-level tests where possible.

## Round 4: Reader Shelf Grid Width

### Scope
- `hibiki/lib/src/utils/misc/platform_utils.dart`
- `hibiki/lib/src/pages/implementations/history_reader_page.dart`
- `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- `hibiki/test/utils/misc/platform_layout_test.dart`

### Findings

#### HBK-AUDIT-014
- severity: medium
- status: fixed
- files: `hibiki/lib/src/utils/misc/platform_utils.dart`, `hibiki/lib/src/pages/implementations/history_reader_page.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`, `hibiki/test/utils/misc/platform_layout_test.dart`
- root cause: reader shelf grid card extents were computed from `MediaQuery.sizeOf(context).width`, i.e. the whole app/window width. On Windows the shelf is inside `DesktopContentLayout`, so the grid's real content width can be much narrower than the full window.
- impact: on wide Windows layouts the shelf could pick a wider card breakpoint than the constrained grid actually has, causing inconsistent columns and spacing drift between EPUB and SRT sections.
- fix: added `readerShelfGridExtentForLayout()` and changed the base reader shelf plus Hoshi EPUB/SRT grids to compute extents from `LayoutBuilder` constraints, falling back to media width only when no content constraint is available.
- verification: `flutter test test/utils/misc/platform_layout_test.dart` passed and now covers constrained content width (`mediaWidth: 1600`, `contentWidth: 760` -> `180`).

### Next Scope
- Continue auditing Windows-specific focus/keyboard behavior without using host mouse input; current remaining blocker is full drive validation while the desktop keyboard is actively in use.

## Round 5: Non-Focus-Stealing Navigation Evidence

### Scope
- `hibiki/lib/src/pages/implementations/home_page.dart`
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- `hibiki/integration_test/test_helpers.dart`
- `hibiki/test/integration/navigation_helpers_test.dart`

### Findings

#### HBK-AUDIT-015
- severity: low
- status: fixed
- files: `hibiki/test/integration/navigation_helpers_test.dart`
- root cause: full Windows `flutter drive` can receive host keyboard messages while the user is actively using the same desktop. The observed failure happened in Flutter's Windows `RawKeyboard` platform message path for a host `Meta Left` key event before Hibiki's `HomePage._handleKeyEvent` or `ReaderHoshiPage._handleKeyEvent` business logic could decide anything.
- impact: a valid Windows UI interaction test can fail because the test window briefly owns focus while unrelated host keyboard input is present. Re-running this while the user is working would violate the no-mouse/no-focus-stealing constraint and still give noisy evidence.
- fix: expanded the no-window widget coverage for the shared integration helper. The test now proves that desktop `NavigationRail` order is stable (`Books`, `Dictionary`, `Settings`), content-area icons are ignored, mobile bottom navigation remains supported, and Windows drive screenshot capture is optional.
- verification: `flutter test test/integration/navigation_helpers_test.dart` passed with 4 tests. This does not replace full reader/dictionary drive validation, but it removes the focus-stealing dependency from the navigation/screenshot portions of the Windows UI evidence.

### Next Scope
- Continue moving reader/dictionary interaction checks toward widget or lower-level Hoshi JS/CSS tests where possible. Full Windows drive should only run when the desktop is idle enough that host keyboard events will not contaminate Flutter's platform input stream.

## Round 6: Desktop Layout Constraint Evidence

### Scope
- `hibiki/lib/src/utils/misc/platform_utils.dart`
- `hibiki/test/utils/misc/platform_layout_test.dart`
- Windows layout evidence path after the user reported the external screenshot did not match the live app.

### Findings

#### HBK-AUDIT-016
- severity: low
- status: fixed
- files: `hibiki/test/utils/misc/platform_layout_test.dart`
- root cause: the previous external screenshot path was not reliable enough to judge the Windows UI. It could disagree with the user's live view, so it should not be treated as product evidence. The shared desktop layout policy also only had pure metric tests, not a widget-level check that Flutter's real constraint tree produced the intended content width.
- impact: a false screenshot could waste review time, and a future change to `DesktopContentLayout` could silently remove the desktop width cap or compact full-width behavior without failing tests.
- fix: added widget tests for `DesktopContentLayout` that run without opening a desktop window. The tests verify expanded dictionary content is capped to the 1040px desktop policy minus 24px side padding, and compact content remains full-width without desktop padding.
- verification: `flutter test test/utils/misc/platform_layout_test.dart` passed with 9 tests. `dart format .` completed with 0 changed files. `flutter test` passed with 737 tests. No Windows runner was launched, so this round did not take desktop focus from the user.

### Next Scope
- Continue non-focus-stealing review of Hoshi reader and dictionary interaction contracts. Treat external screenshots as supporting artifacts only when they agree with widget/DOM/bounds evidence.

## Round 7: Reader Keyboard Navigation Contract

### Scope
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- `hibiki/lib/src/reader/reader_pagination_scripts.dart`
- `hibiki/test/reader/reader_pagination_scripts_test.dart`

### Findings

#### HBK-AUDIT-017
- severity: low
- status: fixed
- files: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/lib/src/reader/reader_pagination_scripts.dart`, `hibiki/test/reader/reader_pagination_scripts_test.dart`
- root cause: Windows/desktop reader keyboard navigation was only encoded inside the private `ReaderHoshiPage._handleKeyEvent()` method. Proving PageDown/arrow-key behavior therefore required launching the full reader/WebView path, which is focus-sensitive on Windows and unsuitable while the user is actively using the desktop.
- impact: reader keyboard paging could regress silently, or review could fall back to noisy full-window drive runs that may be contaminated by host keyboard events.
- fix: extracted the key-to-`ReaderNavigationDirection` mapping into `ReaderPaginationScripts.navigationDirectionForKey()`. `ReaderHoshiPage._handleKeyEvent()` now delegates to the shared mapping, and unit tests cover forward keys, backward keys, and ignored non-navigation keys.
- verification: TDD red check failed as expected because `ReaderPaginationScripts.navigationDirectionForKey` did not exist. After the extraction, `flutter test test/reader/reader_pagination_scripts_test.dart` passed with 28 tests. `dart format .` formatted the two changed Dart files. `flutter test` passed with 740 tests. No Windows runner was launched, so this round did not take desktop focus from the user.

### Next Scope
- Continue checking reader/dictionary interaction contracts that can be moved out of full Windows drive runs. Prioritize pure functions or widget tests for focus-sensitive paths.

## Round 8: Dictionary Search Field Targeting

### Scope
- `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- `hibiki/integration_test/test_helpers.dart`
- `hibiki/test/integration/navigation_helpers_test.dart`
- Windows/CJK dictionary search drive-test targeting.

### Findings

#### HBK-AUDIT-018
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`, `hibiki/integration_test/test_helpers.dart`, `hibiki/test/integration/navigation_helpers_test.dart`
- root cause: `findSearchField()` selected the first `TextField`/`TextFormField` in the entire widget tree. On Windows desktop layouts the dictionary tab can coexist with other content or overlay input fields, so the CJK dictionary drive test could type into an unrelated field instead of the real home dictionary search field.
- impact: Windows CJK search validation could become flaky or silently verify the wrong input target, leaving the actual dictionary search path untested.
- fix: gave the home dictionary search `TextField` a stable `ValueKey<String>('home_dictionary_search_field')`, and changed `findSearchField()` to prefer that keyed field before falling back to the old generic field lookup for compatibility.
- verification: TDD red check failed as expected because `findSearchField()` picked `unrelated_search_field`. After the fix, `flutter test test/integration/navigation_helpers_test.dart` passed with 5 tests. `dart format .` formatted the changed dictionary page. `flutter test` passed with 741 tests. No Windows runner was launched, so this round did not take desktop focus from the user.

### Next Scope
- Continue reducing full Windows drive dependency by giving reader/dictionary interaction targets stable keys and lower-level tests where possible.

## Round 9: Dictionary Result Evidence

### Scope
- `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
- `hibiki/integration_test/test_helpers.dart`
- `hibiki/integration_test/reader_dictionary_test.dart`
- `hibiki/test/integration/navigation_helpers_test.dart`
- Windows/CJK dictionary search result verification.

### Findings

#### HBK-AUDIT-019
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`, `hibiki/integration_test/test_helpers.dart`, `hibiki/integration_test/reader_dictionary_test.dart`, `hibiki/test/integration/navigation_helpers_test.dart`
- root cause: `reader_dictionary_test` treated any `Card`, `ListTile`, or `ExpansionTile` in the full widget tree as dictionary search result evidence. On desktop layouts this is too broad: unrelated settings rows, history cards, or overlay widgets can satisfy the count without proving that the CJK dictionary result view actually appeared.
- impact: Windows CJK dictionary search drive validation could produce a false pass while the actual result pane failed to render.
- fix: added a stable `ValueKey<String>('home_dictionary_result_evidence')` inside the home dictionary result view, exposed `findDictionaryResultEvidence()`, and changed `reader_dictionary_test` to assert that keyed evidence instead of counting unrelated generic widgets.
- verification: TDD red check failed as expected because `findDictionaryResultEvidence()` did not exist. After the fix, `flutter test test/integration/navigation_helpers_test.dart` passed with 6 tests. `dart format .` formatted the changed dictionary page. `flutter test` passed with 742 tests. No Windows runner was launched, so this round did not take desktop focus from the user.

### Next Scope
- Continue hardening Windows reader/dictionary drive assertions so every check proves a specific app surface instead of relying on generic widget counts.

## Round 10: Home Readiness Targeting

### Scope
- `hibiki/integration_test/test_helpers.dart`
- `hibiki/integration_test/user_path_test.dart`
- `hibiki/test/integration/navigation_helpers_test.dart`
- Windows drive startup readiness checks.

### Findings

#### HBK-AUDIT-020
- severity: medium
- status: fixed
- files: `hibiki/integration_test/test_helpers.dart`, `hibiki/integration_test/user_path_test.dart`, `hibiki/test/integration/navigation_helpers_test.dart`
- root cause: Windows integration tests treated any `Icons.menu_book` in the widget tree as proof that the home page was ready. That icon can appear in unrelated content, so the tests could start navigation before the primary home navigation had actually rendered.
- impact: Windows drive runs could fail or become noisy by tapping navigation targets before the app reached the home shell, especially when startup timing is slow or another page/surface includes a book icon.
- fix: added `isHomeReady()` based on the shared primary navigation target resolver and changed both home wait paths to use it. The new widget test proves an unrelated book icon no longer marks the home shell ready.
- verification: TDD red check failed as expected because `isHomeReady()` did not exist. After the fix, `flutter test test/integration/navigation_helpers_test.dart` passed with 7 tests. `dart format .` completed with 0 changed files. Full `flutter test` is currently blocked by unrelated dirty-worktree compile errors in `reader_hoshi_page.dart`, `hoshi_settings_page.dart`, and `app_model.dart` around `shouldDisablePopupScrim` / `disableDialogScrim` symbols; those files already have non-round changes and were not included in this fix.

### Next Scope
- Continue replacing broad Windows drive probes with assertions tied to the actual navigation shell, reader surface, and dictionary result surface.
