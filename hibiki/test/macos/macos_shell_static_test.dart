import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for the macOS-native (macos_ui) shell wiring (Approach B:
/// the MacosWindow + Sidebar live at the app root in main.dart's builder; here
/// HomePage only renders its tab content in a MacosScaffold). HomePage can't be
/// pumped in isolation (needs the full AppModel/provider boot), so — like the
/// other home_page `*_static_test`s — this asserts the structural contract; the
/// live look is verified by the Mac offscreen `flutter drive` screenshot test.
///
/// Approach C note: this shell is layered onto develop's [HomeTab] enum tab
/// model (dynamic active-tab list with video/texthooker toggles), NOT the mac
/// branch's original int-index model. So the sidebar is built from the dynamic
/// active-tab list and selection flows through a `ValueNotifier<HomeTab>`.
void main() {
  final String home = File(
    'lib/src/pages/implementations/home_page.dart',
  ).readAsStringSync();
  final String main = File('lib/main.dart').readAsStringSync();

  test('macOS routes through the native shell before the size-class switch',
      () {
    final int macosBranch = home.indexOf('isMacosPlatform(context)');
    final int sizeClass = home.indexOf('windowSizeClassReal(');
    expect(macosBranch, isNonNegative,
        reason: 'build() must branch to the macos shell.');
    expect(sizeClass, isNonNegative);
    expect(macosBranch, lessThan(sizeClass),
        reason: 'the macOS branch must come before the mobile/desktop '
            'size-class split.');
    expect(home, contains('return _buildMacosLayout();'));
  });

  test('root MacosWindow + Sidebar wrap the navigator (Approach B)', () {
    // The window/sidebar are at the app root so pushed routes inherit a
    // MacosWindowScope (native ToolBars everywhere).
    expect(main, contains('MacosWindow('),
        reason: 'main.dart builder must wrap the navigator in MacosWindow.');
    expect(main, contains('buildHibikiMacosSidebar('),
        reason: 'root MacosWindow must use the shared sidebar builder.');
    expect(home, contains('Sidebar buildHibikiMacosSidebar('));
    expect(home, contains('SidebarItems('));
    expect(home, contains('homeShellTabNotifier'),
        reason: 'sidebar selection is shared with HomePage via the notifier.');
  });

  test('sidebar is built from the dynamic HomeTab active-tab list', () {
    // Approach C: the sidebar destinations must come from the same dynamic
    // active-tab list HomePage's rail uses (homeActiveTabs), so video/texthooker
    // toggles add/remove sidebar items in lock-step — never a hardcoded 3-item
    // books/dictionaries/settings list (which would drop the video tab).
    expect(main, contains('homeActiveTabs('),
        reason: 'root sidebar must derive its destinations from the dynamic '
            'HomeTab active-tab list, not a hardcoded set.');
    expect(home, contains('required List<HomeTab> activeTabs'),
        reason: 'buildHibikiMacosSidebar takes the dynamic active-tab list.');
    expect(home, contains('homeNavItemFor('),
        reason: 'sidebar/rail/bottom-bar share one HomeTab->nav-item map.');
  });

  test('_buildMacosLayout hosts content in a MacosScaffold + native ToolBar',
      () {
    final int layoutStart = home.indexOf('Widget _buildMacosLayout()');
    final int layoutEnd = home.indexOf('Widget _buildDesktopLayout(');
    expect(layoutStart, isNonNegative);
    expect(layoutEnd, greaterThan(layoutStart));
    final String body = home.substring(layoutStart, layoutEnd);
    expect(body, contains('MacosScaffold('),
        reason: 'content sits in a MacosScaffold for the native ToolBar.');
    expect(body, contains('ToolBar('),
        reason: 'native ToolBar titled with the current destination.');
    expect(body, contains('hibikiMacosNavKey'),
        reason: 'content subtree must carry the test hook key.');
    expect(body, contains('MaterialType.transparency'),
        reason: 'macOS content needs a transparent Material ancestor so the '
            'page bodies\' InkWell-based widgets have an ink surface.');
    expect(body, isNot(contains('MacosWindow(')),
        reason: 'MacosWindow moved to the root (main.dart); HomePage must not '
            'nest a second one.');
  });

  test('tab selection is unified through homeShellTabNotifier (HomeTab)', () {
    expect(home, contains('ValueNotifier<HomeTab> homeShellTabNotifier'),
        reason: 'the shared shell selection is a HomeTab notifier, not an int '
            'index (Approach C: enum identity survives conditional tabs).');
    expect(home,
        contains('homeShellTabNotifier.addListener(_onShellTabRequested)'),
        reason: 'HomePage listens so the root sidebar routes selection through '
            'the same _selectTab path (preserving _previousTab / focus reset).');
    expect(home, contains('homeShellTabNotifier.value = tab'),
        reason: '_selectTab writes back so the root sidebar reflects the '
            'current tab whatever entry point switched it.');
  });
}
