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
