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
