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

## Round 11: Desktop Lookup Routing

### Scope
- `hibiki/lib/src/models/app_model.dart`
- `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- Current dirty lookup-path changes that route selection/search actions through `openPopupDictionaryLookup()`

### Findings

#### HBK-AUDIT-021
- severity: high
- status: fixed
- files: `hibiki/lib/src/models/app_model.dart`, `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: the current lookup refactor routed all recursive dictionary searches through `openPopupDictionaryLookup()`, but that method unconditionally launched `hibiki://lookup?word=...`. The `hibiki://lookup` intent is only registered in Android manifest for `PopupDictActivity`; Windows has no equivalent protocol registration, so desktop lookup actions could leave the app or fail at the OS URL layer instead of opening Hibiki's dictionary UI.
- impact: Windows CJK lookup from selection menus, creator enhancements, stash/text segmentation search, and other shared lookup actions could stop being an in-app UI flow. Passing screenshots or a green app launch would not prove this path because the failure is in the action routing contract.
- fix: kept Android on the existing native popup intent path, and added a desktop/non-Android branch that opens `PopupDictionaryPage` inside a normal Flutter `Dialog`. `PopupDictionaryPage` now supports an optional in-app close callback and exposes a keyed close button for deterministic widget evidence; it still uses the native `PopupChannel.finishPopup()` when launched as the Android popup entrypoint.
- verification: TDD red check first failed because `PopupDictionaryPage` had no in-app close contract. After the fix, `flutter test test/pages/popup_dictionary_page_test.dart` passed with 2 tests, including a desktop lookup assertion that no `url_launcher` call is made. `dart format .` completed; full `flutter test` passed with 745 tests. The stale Round 10 note about `disableDialogScrim` / `shouldDisablePopupScrim` compile blockers is superseded by current evidence: the present worktree compiles and tests cleanly.

### Next Scope
- Continue auditing desktop lookup UX at the widget/logic level first: popup sizing under small Windows windows, search submission inside the in-app dialog, and nested result popups. Full Windows drive should still wait until it will not steal focus from the user's active desktop session.

## Round 12: Desktop Popup Search Targets

### Scope
- `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- Windows/CJK popup dictionary search targeting without launching a focused desktop runner.

### Findings

#### HBK-AUDIT-022
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: the new in-app desktop lookup dialog exposed a keyed close button, but its search `TextField` and search `IconButton` were still anonymous widgets. Future Windows drive tests would have to fall back to scanning for the first text field or search icon, repeating the same false-targeting problem already fixed for the home dictionary page.
- impact: CJK lookup validation inside the desktop popup could type into or tap the wrong widget if another text field or search icon is present in the same widget tree, producing flaky or false-positive Windows UI evidence.
- fix: added stable `ValueKey<String>` identifiers for `popup_dictionary_search_field` and `popup_dictionary_search_button`.
- verification: TDD red check failed because `popup_dictionary_search_field` was missing. After the fix, `flutter test test/pages/popup_dictionary_page_test.dart` passed with 3 tests. This is a widget-level non-focus-stealing verification path; no Windows runner was launched.

### Next Scope
- Continue desktop popup lookup review with search submission/result evidence and nested popup positioning under constrained Windows dialog sizes.

## Round 13: Desktop Popup Search Submit

### Scope
- `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- Windows/CJK popup dictionary search submission without launching a focused desktop runner.

### Findings

#### HBK-AUDIT-023
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: Round 12 proved that desktop popup search controls were targetable, but not that either the icon button or keyboard search action actually submitted the user's query into the lookup flow. That left a UI false-state hole: a Windows test could type into a visible field and still never prove the submit contract.
- impact: CJK popup lookup validation could pass on widget presence alone while the real button or Enter/search-key path was disconnected, whitespace-polluted, or untestable without starting a focus-stealing Windows runner.
- fix: extracted the search row into `PopupDictionarySearchBar`, kept the same stable keys, and made both the icon button and `TextInputAction.search` use one typed submit path that trims input and ignores empty queries before delegating to the page search handler.
- verification: TDD red check failed as expected because `PopupDictionarySearchBar` did not exist. After the fix, `flutter test test/pages/popup_dictionary_page_test.dart` passed with 5 tests, including button-submit and keyboard-submit cases. Full `flutter test` passed with 748 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with existing CMake/WebView2/native warnings. This remains a widget-level non-focus-stealing verification path.

### Next Scope
- Continue desktop popup lookup review with nested result popup positioning and constrained Windows dialog sizes; avoid screenshot-only conclusions unless backed by bounds or widget evidence.

## Round 14: Constrained Popup Positioning

### Scope
- `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`
- `hibiki/test/pages/dictionary_popup_layer_test.dart`
- Shared nested popup positioning used by dictionary pages and reader popup surfaces.

### Findings

#### HBK-AUDIT-024
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`, `hibiki/test/pages/dictionary_popup_layer_test.dart`
- root cause: `calcPopupPosition()` used fixed padding as the lower clamp bound even when the available popup surface was smaller than `padding * 2`. In a constrained Windows dialog, tiny transient layout, or test harness surface, `clamp(padding, screen - size - padding)` could receive inverted bounds and throw before any UI could render.
- impact: normal desktop windows may look fine, but constrained popup/dialog layouts could crash or produce no nested result popup. A screenshot from a normal-sized window would miss this because the failure is a geometry precondition bug.
- fix: normalized the usable inset from the actual screen size first, then derived width, height, and left/top clamp bounds from that usable rectangle. This keeps regular desktop dimensions capped by `maxWidth`/`maxHeight` while making tiny surfaces degrade into an in-bounds rectangle instead of throwing.
- verification: TDD red check failed with `Invalid argument(s): 6.0` in `double.clamp`. After the fix, `flutter test test/pages/dictionary_popup_layer_test.dart` passed with 2 tests covering tiny constrained surfaces and normal 800x600 desktop bounds. Full `flutter test` passed with 750 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue review with the rendered popup layer stack under constrained dialog sizes and verify whether result WebView content gets stable height without overflow.

## Round 15: Compact Desktop Popup Dialog

### Scope
- `hibiki/lib/src/models/app_model.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- In-app desktop popup dictionary dialog under compact Windows-sized surfaces.

### Findings

#### HBK-AUDIT-025
- severity: low
- status: verified-pass
- files: `hibiki/lib/src/models/app_model.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: no production defect found in this round. The risk was that the non-Android popup dictionary path wraps `PopupDictionaryPage` in `Dialog(insetPadding: EdgeInsets.all(24))` plus `ConstrainedBox(maxWidth: 520, maxHeight: 640)`, and a compact desktop window might overflow or render outside the viewport.
- impact: if this had failed, Windows lookup validation could show a normal screenshot at large size while compact windows clipped or hid the popup. The widget check did not reproduce that failure.
- fix: no layout code change. Added a non-focus-stealing widget regression test that opens the desktop popup in a 320x240 test window and asserts no Flutter exception plus an in-bounds dialog rectangle.
- verification: `flutter test test/pages/popup_dictionary_page_test.dart --plain-name "desktop popup dialog renders inside a compact window"` passed. Full `flutter test` passed with 751 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning. This is recorded as verified-pass, not fixed.

### Next Scope
- Continue review with popup result WebView content sizing and empty/loading states under compact popup surfaces.

## Round 16: Compact Popup Empty State

### Scope
- `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`
- `hibiki/lib/src/utils/components/jidoujisho_placeholder_message.dart`
- `hibiki/test/pages/dictionary_popup_layer_test.dart`
- `hibiki/test/widgets/jidoujisho_placeholder_message_test.dart`
- Empty/loading dictionary popup content under compact desktop popup surfaces.

### Findings

#### HBK-AUDIT-026
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`, `hibiki/lib/src/utils/components/jidoujisho_placeholder_message.dart`, `hibiki/test/pages/dictionary_popup_layer_test.dart`, `hibiki/test/widgets/jidoujisho_placeholder_message_test.dart`
- root cause: `DictionaryPopupLayer` reused the generic page-level `JidoujishoPlaceholderMessage` for no-result popup content. That component defaults to a large icon plus title-sized text, and its `iconSize` parameter was declared but ignored, so the popup could not request a compact placeholder. In a small popup surface this produced a `RenderFlex overflowed` exception.
- impact: desktop lookup could render fine in a normal window while compact dialog surfaces, constrained nested popups, or test harness sizes overflowed in the no-result state. This is a real UI layout bug, not a screenshot artifact.
- fix: made `JidoujishoPlaceholderMessage.iconSize` actually control the icon size, and changed the popup no-result state to use a compact, scrollable placeholder with smaller icon/text and padding.
- verification: TDD red check failed with `A RenderFlex overflowed by 210 pixels on the bottom` for an 80x48 popup surface. A second red check proved `iconSize` was ignored (`expected 18`, actual `28.0`). After the fix, `flutter test test/pages/dictionary_popup_layer_test.dart` passed with 3 tests, `flutter test test/widgets/jidoujisho_placeholder_message_test.dart` passed with 4 tests, full `flutter test` passed with 754 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue review with popup WebView result content sizing and nested popup stack behavior after result links/selections.

## Round 17: Reader Popup Bottom Reserve Bounds

### Scope
- `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`
- `hibiki/test/pages/dictionary_popup_layer_test.dart`
- Current dirty reader popup bottom-reserve path in `BaseSourcePage` / `ReaderHoshiPage`.

### Findings

#### HBK-AUDIT-027
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`, `hibiki/test/pages/dictionary_popup_layer_test.dart`
- root cause: the current reader popup bottom-reserve path subtracts bottom chrome height from the available popup surface, but `calcPopupPosition()` treated the reserve as always smaller than the surface. If a compact Windows window, transient layout, or oversized bottom chrome made `bottomReserve >= screen.height`, the vertical clamp bounds inverted and threw `Invalid argument(s): 6.0`.
- impact: the normal reader screenshot can look correct, while compact windows or chrome-heavy layouts can crash or hide lookup popups when the reader tries to avoid the bottom controls.
- fix: clamp `bottomReserve` to the screen height and derive horizontal and vertical insets separately. Vertical sizing now uses the effective area above the reserved bottom chrome, so the function preserves the bottom-avoidance behavior without letting impossible reserves break popup placement.
- verification: TDD red check failed with `Invalid argument(s): 6.0` when `bottomReserve` exceeded a compact surface. After the fix, `flutter test test/pages/dictionary_popup_layer_test.dart` passed with 5 tests, full `flutter test` passed with 755 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue review with popup WebView result content sizing and nested popup stack behavior after result links/selections.

## Round 18: Popup WebView Metadata Merge

### Scope
- `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`
- `hibiki/test/pages/dictionary_popup_webview_test.dart`
- Dictionary popup WebView JSON contract used by Windows desktop popup results.

### Findings

#### HBK-AUDIT-028
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`, `hibiki/test/pages/dictionary_popup_webview_test.dart`
- root cause: `buildLookupEntriesJson()` groups entries by `word + reading`, but initialized `matched`, `deinflectionTrace`, `frequencies`, and `pitches` only from the first entry in each group. When the first glossary entry had no metadata and a later grouped entry carried frequency or pitch data, the WebView received empty metadata arrays.
- impact: the visible popup could look fine on a normal screenshot while still omitting frequency or pitch sections depending on dictionary ordering. That is a real data-contract bug in the Windows popup result path, not a visual-only artifact.
- fix: decode each entry's `extra` once, then merge metadata into the grouped result across the whole group. Frequency and pitch payloads are deduplicated by their encoded JSON value so repeated glossary entries from the same Hoshi term do not duplicate metadata blocks.
- verification: TDD red check failed because a later grouped entry's `frequencies` and `pitches` were dropped. After the fix, `flutter test test/pages/dictionary_popup_webview_test.dart` passed, full `flutter test` passed with 756 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue review with nested popup stack behavior after result links/selections, especially link-click geometry and recursive lookup result state.

## Round 19: Popup Tap-Outside Wiring

### Scope
- `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- Independent desktop/Android popup dictionary base result layer close behavior.

### Findings

#### HBK-AUDIT-029
- severity: low
- status: fixed
- files: `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: `DictionaryPopupWebView` emits `tapOutside` when the user clicks blank popup content, and nested popup layers plus reader popups already wire that callback to dismiss. The independent `PopupDictionaryPage` base layer did not pass `onTapOutside`, so the JavaScript handler was installed but had no page action.
- impact: in the Windows in-app popup and Android popup activity, clicking blank result content could look like a valid outside-dismiss gesture but do nothing. A screenshot would not catch this because the visible layout is fine; the callback contract was missing.
- fix: passed `_close` as `onTapOutside` for the base popup layer, matching the existing close button and nested-layer behavior.
- verification: TDD red check failed with `DictionaryPopupLayer.onTapOutside == null` for the base layer. After the fix, `flutter test test/pages/popup_dictionary_page_test.dart` passed with 7 tests, full `flutter test` passed with 757 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with existing third-party/native warnings only.

### Next Scope
- Continue review with popup result content layout under long expressions, large structured content, and image/table-heavy dictionary entries.

## Round 20: Popup Structured Content Layout

### Scope
- `hibiki/assets/popup/popup.css`
- `hibiki/assets/popup/popup.js`
- `hibiki/test/utils/misc/popup_asset_behavior_test.js`
- Long expressions, large images, and structured table content inside Windows popup result WebView.

### Findings

#### HBK-AUDIT-030
- severity: low
- status: verified-pass
- files: `hibiki/assets/popup/popup.css`, `hibiki/assets/popup/popup.js`, `hibiki/test/utils/misc/popup_asset_behavior_test.js`
- root cause: no production defect found in this round. The risk was that long terms, image-heavy entries, or wide structured-content tables could overflow a compact Windows popup result surface even when ordinary screenshots looked fine.
- impact: if this regressed, CJK lookup results with large dictionary media or wide tables would clip horizontally or force the popup content outside its intended bounds.
- fix: no production code change. Added an asset-level regression test proving structured-content tables render inside `.gloss-sc-table-container`, matching the existing CSS horizontal-scroll guard. Existing asset tests already cover oversized image scroll wrappers and natural image sizing.
- verification: `node test/utils/misc/popup_asset_behavior_test.js` passed after extending the fake DOM with `hasAttribute()`. `flutter test test/pages/dictionary_popup_webview_test.dart` passed, `flutter test test/pages/popup_dictionary_page_test.dart` passed with 7 tests, full `flutter test` passed with 757 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue review with remaining Windows popup host paths, especially Android popup activity parity versus in-app desktop popup behavior and any unverified generated/dirty UI changes.

## Round 21: Reader Highlight Popup Geometry

### Scope
- `hibiki/lib/src/reader/reader_selection_scripts.dart`
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- `hibiki/lib/src/pages/base_source_page.dart`
- `hibiki/assets/popup/selection.js`
- `hibiki/test/reader/reader_selection_scripts_test.dart`
- `hibiki/test/utils/misc/popup_asset_behavior_test.js`
- Hoshi reader lookup popup geometry after dictionary result highlighting on Windows-sized layouts.

### Findings

#### HBK-AUDIT-031
- severity: medium
- status: fixed
- files: `hibiki/lib/src/reader/reader_selection_scripts.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/lib/src/pages/base_source_page.dart`, `hibiki/assets/popup/selection.js`, `hibiki/test/reader/reader_selection_scripts_test.dart`, `hibiki/test/utils/misc/popup_asset_behavior_test.js`
- root cause: the selection highlight code was moving from a fire-and-forget contract to a geometry-returning contract, but the contract needed to be explicit and tested. Without using the returned highlighted-range bounds, the reader popup could stay anchored to the original tap/selection rectangle even after the dictionary result highlighted a shorter matched expression.
- impact: a normal screenshot can look fine when the original selection and matched expression overlap closely, while Windows reader lookup popups can drift or feel badly placed for longer selected sentences, deinflected matches, or compact reader chrome layouts.
- fix: made `highlightSelection()` return explicit bounds in both the Hoshi reader selection script and popup asset script, JSON-stringified the reader invocation, added a typed Dart parser for bridge results, and updated `ReaderHoshiPage` to reposition the active popup from the real highlighted bounds when available. Invalid or missing bounds now fall back to the existing popup position instead of crashing.
- verification: `flutter test test/reader/reader_selection_scripts_test.dart` passed with 27 tests. `node test/utils/misc/popup_asset_behavior_test.js` passed and now checks the popup asset highlight bounds contract. `dart format .` changed 0 files. Full `flutter test` passed with 761 tests. `flutter build windows --debug` was attempted, but MSBuild could not copy `WebView2Loader.dll` because the running process `Hibiki (191208)` had the existing debug DLL locked; no app process was killed because the user is actively using the computer.

### Next Scope
- Continue review with remaining dirty Windows popup host paths that do not require stealing focus, especially `PopupDictActivity` window flags and the current popup swipe-dismiss/desktop search-field deltas.

## Round 22: Popup Host Swipe And Deferred Display

### Scope
- `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`
- `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java`
- `hibiki/test/pages/dictionary_popup_layer_test.dart`
- `hibiki/test/pages/popup_dictionary_page_test.dart`
- Remaining Windows/desktop popup host UI deltas that do not require stealing focus.

### Findings

#### HBK-AUDIT-032
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`, `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`, `hibiki/test/pages/dictionary_popup_layer_test.dart`, `hibiki/test/pages/popup_dictionary_page_test.dart`
- root cause: `DictionaryPopupLayer` always wrapped content in `SwipeDismissWrapper`. That behavior is useful for floating reader/nested popups, but it is wrong for the full-size popup dictionary host: a horizontal drag inside the dedicated popup window can dismiss the whole host while the user is scrolling, selecting text, or interacting with result content.
- impact: Windows in-app popup and Android popup activity content could disappear from an ordinary content gesture. A screenshot would look correct because the layout is fine; the bug is in the gesture contract.
- fix: added an explicit `swipeDismissible` flag to `DictionaryPopupLayer`, defaulting to the previous behavior, and disabled it only for the base `PopupDictionaryPage` host layer. The popup page also keeps the search/header boundary visually separate with a divider and removes TextField outline variants so the host chrome is not double-bordered.
- verification: added widget coverage proving `swipeDismissible: false` leaves the layer unwrapped and proving the base popup host layer passes `swipeDismissible == false`. `flutter test test/pages/dictionary_popup_layer_test.dart test/pages/popup_dictionary_page_test.dart test/reader/reader_selection_scripts_test.dart` passed with 41 tests. Full `flutter test` passed with 763 tests. `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing third-party `flutter_inappwebview_windows` CMake dev warning.

#### HBK-AUDIT-033
- severity: high
- status: fixed
- files: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- root cause: the reader lookup popup flow was partly migrated from immediate display plus later repositioning to deferred display after highlight bounds were known. The helper was renamed to `_highlightAndShowPopup()`, but stale calls to `_highlightAndReposition()` remained in the text-selection path during the dirty state, making related Flutter tests fail to compile.
- impact: this is not a visual nit. Any test or build that includes `ReaderHoshiPage` can fail at compile time, blocking Windows UI verification entirely.
- fix: use one flow for both lyrics and normal reader selections: call `searchDictionaryResult(..., deferDisplay: true)`, evaluate the highlight bounds, and then show the deferred popup once with the final rectangle.
- verification: the compile failure was reproduced while running `flutter test test/pages/popup_dictionary_page_test.dart --plain-name "base popup layer disables swipe dismiss inside popup host"`. After the fix, that test passed, the combined targeted popup/selection tests passed with 41 tests, full `flutter test` passed with 763 tests, and `flutter build windows --debug` succeeded.

#### HBK-AUDIT-034
- severity: low
- status: verified-pass
- files: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java`
- root cause: the dirty native popup activity changes were reviewed for Windows-facing popup parity. They ignore blank `hibiki://lookup?word=` inputs and clear window dimming for the transparent popup activity.
- impact: blank lookup intents no longer open an empty popup, and the Android popup behaves more like the desktop in-app popup by avoiding an extra dimmed background behind the small dictionary surface.
- fix: no additional production edit in this round beyond preserving the existing dirty native change for later Android-specific validation.
- verification: static code review only. No Android activity instrumentation was run in this Windows-focused pass.

### Next Scope
- Continue review with remaining dirty generated/i18n and lyrics overlay files only if they are actually Windows UI related; otherwise leave them out of the Windows popup/layout fix stream.

## Round 23: Lyrics Mode Selection Contract

### Scope
- `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`
- `hibiki/test/media/audiobook/lyrics_mode_html_test.dart`
- Remaining dirty lyrics-mode WebView HTML changes, with attention to desktop/Windows pointer and text-selection behavior.

### Findings

#### HBK-AUDIT-035
- severity: medium
- status: fixed
- files: `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`, `hibiki/test/media/audiobook/lyrics_mode_html_test.dart`
- root cause: lyrics mode carried a hand-rolled long-press recognizer and disabled text selection on every cue. That duplicated the Hoshi selection script already injected into the page and made pointer behavior fragile on desktop-class environments: click, long press, drag selection, and cue navigation competed in the same HTML layer.
- impact: Windows/WebView pointer input could feel inconsistent: the current cue is supposed to open lookup on click, while native text selection should remain available. Disabling selection plus a custom long-press gate is the wrong data flow.
- fix: remove the cue-level `user-select: none` rules and the custom long-press handlers. The current cue click now directly calls `window.hoshiSelection.selectText(...)`; non-current cue clicks continue to call `onLyricsCueTap` for playback jump.
- verification: added `lyrics_mode_html_test.dart` coverage proving the generated HTML keeps current-cue click lookup, does not disable native selection, and does not include the old long-press event hooks. `flutter test test/media/audiobook/lyrics_mode_html_test.dart` passed with 2 tests.

#### HBK-AUDIT-036
- severity: low
- status: open
- files: `hibiki/lib/i18n/strings*.i18n.json`, `hibiki/lib/i18n/strings.g.dart`
- root cause: the remaining i18n dirty diff removes the now-unreferenced `disable_dialog_scrim` key, but the working tree version also adds UTF-8 BOM markers to locale JSON files and rewrites `strings.g.dart` with huge formatting churn.
- impact: deleting a dead key is probably fine, but committing the current dirty i18n diff would bury a one-key cleanup under generated-file noise and possible encoding drift.
- fix: do not commit the current i18n dirty state in this Windows UI round. A later cleanup should regenerate or edit the locale files in a clean UTF-8/no-BOM pass and stage only the intended key removal.
- verification: `rg -n "disable_dialog_scrim|disableDialogScrim|dialog scrim|scrim" hibiki/lib hibiki/test hibiki/android hibiki/ios` found no runtime references. No i18n files were staged in this round.

### Next Scope
- Continue only with clean, directly Windows/UI-related review items; leave i18n key cleanup for a separate encoding-safe pass.

## Round 24: Dead Popup Scrim Locale Key Cleanup

### Scope
- `hibiki/lib/i18n/strings*.i18n.json`
- `hibiki/lib/i18n/strings.g.dart`
- The remaining dirty locale cleanup for the removed popup scrim setting.

### Findings

#### HBK-AUDIT-036
- severity: low
- status: fixed
- files: `hibiki/lib/i18n/strings*.i18n.json`, `hibiki/lib/i18n/strings.g.dart`
- root cause: `disable_dialog_scrim` was left behind in all Slang locale sources and the generated dispatch file after the popup scrim setting path was removed. The first dirty working-tree state also introduced UTF-8 BOM markers and huge generated-file formatting churn, which would have made a simple cleanup unsafe to commit.
- impact: the stale key did not currently affect runtime UI, but keeping it confused the Windows popup cleanup by implying a scrim setting still existed. Committing the BOM/churn version would also make future i18n reviews noisy and brittle.
- fix: regenerate Slang from the existing locale sources, remove only the dead `disable_dialog_scrim` key from each locale JSON, rewrite locale JSON as UTF-8 without BOM, and regenerate `strings.g.dart` so only the corresponding getters and flat-map branches disappear.
- verification: `rg -n "disable_dialog_scrim|disableDialogScrim|dialog scrim|scrim" hibiki/lib hibiki/test hibiki/android hibiki/ios` produced no matches. A PowerShell `ConvertFrom-Json` pass over every `*.i18n.json` succeeded and confirmed the key is absent. Byte-prefix checks confirmed locale JSON starts with `{` (`7B 0D 0A`), not BOM (`EF BB BF`). `dart run slang` succeeded after the cleanup.

### Next Scope
- Remaining uncommitted files are local iOS Flutter environment files and `.codex-test/screenshots/`; neither is a Windows UI source change. Continue broad Windows UI review from committed source and tests rather than staging local environment noise.

## Round 25: Blur Overlay Default Desktop Position

### Scope
- `hibiki/lib/src/utils/player/blur_options.dart`
- `hibiki/test/utils/player/blur_options_test.dart`
- Default blur overlay placement on Windows-shaped player surfaces.

### Findings

#### HBK-AUDIT-037
- severity: medium
- status: fixed
- files: `hibiki/lib/src/utils/player/blur_options.dart`, `hibiki/test/utils/player/blur_options_test.dart`
- root cause: `ResizeableWidget` initialized its default horizontal position from `MediaQuery.size.height` instead of `MediaQuery.size.width`. The vertical default and horizontal default were both derived from height, so wide Windows windows placed the blur overlay too far left even though the saved-position path could look normal after manual adjustment.
- impact: first-use blur overlay placement was wrong on desktop-shaped windows. A screenshot of an already-saved layout could look fine, but new users or reset state would get a mispositioned overlay.
- fix: extract the default rectangle calculation into `defaultBlurRect(Size screen)` and compute `left` from `screen.width` while preserving the existing vertical quarter-screen placement and default 150x150 size.
- verification: added a failing-first widget-independent test for a `1200x600` window, where the old height-based calculation would produce `left == 225` instead of the expected centered `left == 525`. After the fix, `flutter test test/utils/player/blur_options_test.dart` passed. `dart format lib/src/utils/player/blur_options.dart test/utils/player/blur_options_test.dart` formatted the touched Dart files. Full `flutter test` passed with 765 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing third-party `flutter_inappwebview_windows` CMake dev warning. The fixed repository-wide `dart format .` command is still blocked by a transient generated `build/flutter_inappwebview_android/.transforms/.../headless_in_app_webview/*` missing-path error, so it is not counted as passed.

### Next Scope
- Continue Windows UI review with remaining media/dialog surfaces that still calculate widths from raw `MediaQuery` values, especially legacy player dialogs and settings dialogs that can overflow compact desktop windows.

## Round 26: Compact Desktop Dialog Field Widths

### Scope
- `hibiki/lib/src/utils/misc/platform_utils.dart`
- `hibiki/lib/src/pages/implementations/lyrics_dialog_page.dart`
- `hibiki/lib/src/pages/implementations/websocket_dialog_page.dart`
- `hibiki/lib/src/pages/implementations/blur_options_dialog_page.dart`
- `hibiki/test/utils/misc/platform_layout_test.dart`
- Legacy media/player dialogs using raw `MediaQuery.size.width * fraction` content widths.

### Findings

#### HBK-AUDIT-038
- severity: medium
- status: fixed
- files: `hibiki/lib/src/utils/misc/platform_utils.dart`, `hibiki/lib/src/pages/implementations/lyrics_dialog_page.dart`, `hibiki/lib/src/pages/implementations/websocket_dialog_page.dart`, `hibiki/lib/src/pages/implementations/blur_options_dialog_page.dart`, `hibiki/test/utils/misc/platform_layout_test.dart`
- root cause: the lyrics and websocket dialogs sized their input content to one third of the full window width, while the blur options dialog used three quarters. On a compact Windows window such as 320px wide, the one-third rule produces about 106px of content width, which is not a usable desktop text field. The same feature class had three independent width formulas instead of one dialog-width rule.
- impact: compact desktop windows could render media/player dialogs with cramped input fields even though large-window screenshots looked fine. The bug is deterministic from the layout math and does not require screenshot evidence.
- fix: add `desktopDialogContentWidth(double availableWidth)` to the existing platform layout helpers and use it in the lyrics, websocket, and blur options dialogs. The rule keeps compact windows at a usable 256px content width and caps large desktop dialogs at 420px so they do not sprawl.
- verification: the failing-first `platform_layout_test.dart` case initially failed because `desktopDialogContentWidth` did not exist. After the fix, `flutter test test/utils/misc/platform_layout_test.dart` passed with 10 tests, full `flutter test` passed with 766 tests, and `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing third-party `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue Windows UI review with remaining dialog surfaces that still use raw `MediaQuery` sizing or unconstrained `AlertDialog` content, then audit whether any remaining `verified-pass` items need stronger widget/runtime evidence.

## Round 27: AlertDialog Inset Evidence For Compact Width Rule

### Scope
- `hibiki/test/utils/misc/platform_layout_test.dart`
- The `desktopDialogContentWidth()` rule introduced in Round 26, checked against real Flutter `AlertDialog` insets on a compact 320x240 desktop-shaped surface.

### Findings

#### HBK-AUDIT-039
- severity: low
- status: verified-pass
- files: `hibiki/test/utils/misc/platform_layout_test.dart`
- root cause: no production defect found in this round. The risk was that the new 256px compact dialog content floor from Round 26 might still be too wide after `AlertDialog` applies its own default inset padding, which would turn a math-only fix into a real compact-window overflow.
- impact: if this had failed, the shared dialog width helper would need to account for dialog insets rather than only raw window width. That would mean Round 26 had improved text-field usability but not actually proven compact-window safety.
- fix: no production code change. Added a widget test that renders `AlertDialog(content: SizedBox(width: desktopDialogContentWidth(320)))` in a 320x240 test viewport and asserts the content rect stays inside the screen with no Flutter exception.
- verification: `flutter test test/utils/misc/platform_layout_test.dart` passed with 11 tests. `flutter build windows --debug` built `build\windows\x64\runner\Debug\hibiki.exe` with the existing third-party `flutter_inappwebview_windows` CMake dev warning.

### Next Scope
- Continue Windows UI review with other dialogs and sheets that still lack compact-window widget evidence, prioritizing surfaces that collect text input or host scrollable content.
