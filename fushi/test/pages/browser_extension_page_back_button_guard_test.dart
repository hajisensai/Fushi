import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1748 守卫：`BrowserExtensionPage` 是**双身份页**——既是桌面顶层导航 tab
/// （`HomeTab.browserExtension`，侧栏在旁边，不该出返回箭头），又被
/// `settings_schema_lookup.dart` 的 `SettingsNavigationItem` 裸 push 成全屏
/// `MaterialPageRoute`（此时侧栏被整个盖住）。顶层导航和窗口标题已经说明
/// 「浏览器扩展」，内容区不应重复绘制大标题；被设置 push 时的返回键并入首行。
/// 判定必须读当前 PageRoute，不得被下拉框的 PopupRoute 扰动。
///
/// 注释里会提到 leading、canPop、AppBar 这些词，裸 contains 会两个方向都
/// 误判，故先经 [maskCommentsAndScriptLines] 掩掉注释与三引号语料。
void main() {
  test('BUG-1748/1924：扩展页首行按当前 PageRoute 分流返回键', () {
    final File f =
        File('lib/src/pages/implementations/browser_extension_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 browser_extension_page.dart（路径变了要同步本守卫）');
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    expect(code, isNot(contains('FushiPageHeader(')),
        reason: '内容区不得重复绘制「浏览器扩展」大标题');
    final int leadingAt =
        code.indexOf('ModalRoute.of(context)?.isFirst == false');
    expect(leadingAt, greaterThanOrEqualTo(0),
        reason: '返回键必须绑定当前 PageRoute，不能读会被 PopupRoute 扰动的 canPop');

    // 断言字面量：'maybePop()'——真正能退出去，而不是只画一个箭头。
    final int maybePopAt = code.indexOf('maybePop()', leadingAt);
    expect(maybePopAt, greaterThan(leadingAt),
        reason: '返回键必须真的 pop 路由');

    expect(code, isNot(contains('appBar: AppBar(')),
        reason: '不得回退到旧 AppBar 门头（BUG-1658）');
  });
}
