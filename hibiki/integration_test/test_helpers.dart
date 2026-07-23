import 'package:flutter/cupertino.dart' show CupertinoTabBar;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart'
    show HomeTab, homeNavItemFor;
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';
import 'package:integration_test/integration_test.dart';

bool get screenshotsAreRequired =>
    !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;

Future<bool> waitForHome(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (isHomeReady()) {
      debugPrint('[test] Home ready at iteration $i (${i * 500}ms)');
      await tester.pump(const Duration(seconds: 1));
      return true;
    }
    if (i > 0 && i % 20 == 0) {
      debugPrint('[test] Still waiting for home... iteration $i');
    }
  }
  return false;
}

bool isHomeReady() {
  return findPrimaryNavigationTargets().length >= 2;
}

Future<int> takeScreenshot(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[test] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[test] Screenshot skipped ($name): $e');
    return 0;
  }
}

void assertStrictErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    // Ignore only network-layer failures (e.g. the offline GitHub update
    // check). A bare "timeout" is NOT filtered, so a stuck WebView/render
    // timeout stays fatal.
    if (msg.contains('socketexception')) return false;
    if (msg.contains('handshakeexception') || msg.contains('tlsexception')) {
      return false;
    }
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Errors (including WebView/renderer) are fatal: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}

Finder findBookEntries() {
  return find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    if (k is ValueKey<String>) {
      return k.value.startsWith('book_entry_') ||
          k.value.startsWith('srt_entry_');
    }
    return false;
  });
}

Finder findSearchField() {
  final Finder homeDictionarySearch =
      find.byKey(const ValueKey<String>('home_dictionary_search_field'));
  if (homeDictionarySearch.evaluate().isNotEmpty) {
    return homeDictionarySearch.first;
  }
  if (find.byType(TextField).evaluate().isNotEmpty) {
    return find.byType(TextField).first;
  }
  if (find.byType(TextFormField).evaluate().isNotEmpty) {
    return find.byType(TextFormField).first;
  }
  final Finder searchBar = find.byType(SearchBar);
  expect(searchBar, findsWidgets,
      reason: 'No TextField, TextFormField, or SearchBar found');
  return searchBar.first;
}

Finder findDictionaryResultEvidence() {
  return find.byKey(
    const ValueKey<String>('home_dictionary_result_evidence'),
  );
}

List<Finder> findPrimaryNavigationTargets() {
  final Finder? root = _primaryNavigationRoot();
  if (root == null) return const <Finder>[];
  return _navigationIconsInside(root);
}

/// 主导航里指定 [HomeTab] 的图标 target（选中/未选中两态都匹配）。
///
/// 顶层 tab 顺序是条件化的（video / downloads / games / browserExtension 按开关
/// 插入，见 home_page.dart 的 `homeActiveTabs`），按位置索引取 `navTargets[i]`
/// 会随开关漂移（曾把 books 当成 dictionaries 驱动）；按 tab 身份取图标才稳定。
/// 图标真值直接来自生产端 `homeNavItemFor`，不在测试里复制常量。
Finder findNavTargetForTab(HomeTab tab) {
  final AdaptiveNavItem item = homeNavItemFor(tab);
  final Finder? root = _primaryNavigationRoot();
  final Finder icon = find.byWidgetPredicate(
    (Widget w) =>
        w is Icon &&
        w.icon != null &&
        (w.icon == item.icon || w.icon == item.selectedIcon),
  );
  if (root == null) {
    // 导航根还没挂载：返回一个此刻必空的 finder（调用方按「不可达」处理）。
    return find.descendant(
        of: find.byKey(hibikiMaterialNavKey), matching: icon);
  }
  return find.descendant(of: root, matching: icon);
}

Finder? _primaryNavigationRoot() {
  // Material now self-draws the bottom bar / side rail (per-item gamepad focus),
  // tagged with [hibikiMaterialNavKey] instead of the stock NavigationBar/Rail.
  final Finder materialNav = find.byKey(hibikiMaterialNavKey);
  if (materialNav.evaluate().isNotEmpty) return materialNav;

  final Finder rail = find.byType(NavigationRail);
  if (rail.evaluate().isNotEmpty) return rail;

  final Finder bottomNav = find.byType(BottomNavigationBar);
  if (bottomNav.evaluate().isNotEmpty) return bottomNav;

  final Finder navigationBar = find.byType(NavigationBar);
  if (navigationBar.evaluate().isNotEmpty) return navigationBar;

  // iOS draws a CupertinoTabBar (see adaptive_navigation.dart); without this
  // branch isHomeReady() never fires on iOS and every waitForHome() test hangs.
  final Finder cupertinoTabBar = find.byType(CupertinoTabBar);
  if (cupertinoTabBar.evaluate().isNotEmpty) return cupertinoTabBar;

  return null;
}

List<Finder> _navigationIconsInside(Finder navigationRoot) {
  final Finder icons = find.descendant(
    of: navigationRoot,
    matching: find.byType(Icon),
  );
  return List<Finder>.generate(
    icons.evaluate().length,
    (int index) => icons.at(index),
  );
}
