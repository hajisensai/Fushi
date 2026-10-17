import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-3506：窄条层靠给 `CSS.highlights` 打的钩子得知查词 / 搜索 / 收藏写进了注册表。WebKit 的
/// 注册表包装对象没人引用时会被回收、下次读到新对象，挂在旧对象上的钩子跟着消失——iOS 上查词
/// 写完注册表窄条层不重画，被查的词没有高亮。钩子装上的那个对象必须由一直存活的闭包强引用，
/// 且每次重画前核对一遍（引擎换了对象就给新对象补装）。这种回收只在 WebKit 发生，Chrome 行为
/// 测试复现不了，只能钉源码形状；真机证据见 docs/bugs/BUG-3506-*.md。
void main() {
  final String js = ReaderSelectionScripts.source();

  test('the hooked highlight registry is held by a live closure', () {
    final int start = js.indexOf('var hookRegistry = function()');
    expect(start, greaterThanOrEqualTo(0), reason: 'hookRegistry must exist');
    final String body = js.substring(
      start,
      js.indexOf('hookRegistry();', start),
    );
    expect(body, contains('hookedRegistry = reg;'));
    expect(body, contains('reg === hookedRegistry'));
    expect(js, contains('var hookedRegistry = null;'));
  });

  test('every lane flush re-checks the registry hook before painting', () {
    final int start = js.indexOf('var flush = function()');
    expect(start, greaterThanOrEqualTo(0));
    final String body = js.substring(
      start,
      js.indexOf('var schedule = function', start),
    );
    final int hook = body.indexOf('hookRegistry();');
    expect(
      hook,
      greaterThanOrEqualTo(0),
      reason: 'flush must call hookRegistry()',
    );
    expect(hook, lessThan(body.indexOf('paintGroup(')));
  });

  test('no hook is installed on an unreferenced local registry', () {
    // 旧写法：顶层 `var reg = registry(); if (reg && !reg.__fushiLanesHooked) {...}`，没有闭包引用 reg。
    expect(
      RegExp(
        r'var reg = registry\(\);\s*if \(reg && !reg\.__fushiLanesHooked\)',
      ).hasMatch(js),
      isFalse,
    );
  });
}
