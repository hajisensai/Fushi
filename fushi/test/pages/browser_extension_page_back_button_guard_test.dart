import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1741 守卫：`BrowserExtensionPage` 是**双身份页**——既是桌面顶层导航 tab
/// （`HomeTab.browserExtension`，侧栏在旁边，不该出返回箭头），又被
/// `settings_schema_lookup.dart` 的 `SettingsNavigationItem` 裸 push 成全屏
/// `MaterialPageRoute`（此时侧栏被整个盖住）。BUG-1658 把顶层 tab 页头统一成
/// `FushiPageHeader` 大标题时只写了前一半，于是从设置进来的用户没有任何返回控件。
///
/// 同仓 `DownloadsPage` 是完全同构的双身份页，它按 `Navigator.canPop()` 分流。
/// 本守卫钉死「扩展页也必须按 canPop 分流给 leading」这个不变式。
///
/// 注释里会提到 leading、canPop、AppBar 这些词，裸 contains 会两个方向都
/// 误判，故先经 [maskCommentsAndScriptLines] 掩掉注释与三引号语料。
void main() {
  test('BUG-1741：扩展页页头按 canPop 分流给返回键（顶层 tab 身份下仍不出箭头）', () {
    final File f =
        File('lib/src/pages/implementations/browser_extension_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 browser_extension_page.dart（路径变了要同步本守卫）');
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    final int headerAt = code.indexOf('FushiPageHeader(');
    expect(headerAt, greaterThanOrEqualTo(0),
        reason: '页头必须仍是 FushiPageHeader（BUG-1658 的统一大标题几何）');

    // 断言字面量：'leading: Navigator.of(context).canPop()'
    // 必须是条件分流而不是无条件给 leading——作顶层 tab 时侧栏就在旁边，
    // 无条件出箭头会让 tab 页头凭空多一个不能用的返回键。
    final int leadingAt =
        code.indexOf('leading: Navigator.of(context).canPop()', headerAt);
    expect(leadingAt, greaterThan(headerAt),
        reason: '被设置 push 成全屏路由时侧栏被盖住，页头必须承接返回键；'
            '且必须按 canPop 分流，顶层 tab 身份下不出箭头');

    // 断言字面量：'maybePop()'——真正能退出去，而不是只画一个箭头。
    expect(code.substring(leadingAt, leadingAt + 400), contains('maybePop()'),
        reason: '返回键必须真的 pop 路由');

    // 未选用的替代方案（改用 AdaptiveSettingsScaffold/FushiToolScaffold 拿自动
    // leading）会把顶层 tab 的页头几何换成小标题工具栏，正是 BUG-1658 修掉的
    // 东西，属回归。这里钉死不得回退到 AppBar 门头。
    expect(code, isNot(contains('appBar: AppBar(')),
        reason: '不得回退到旧 AppBar 门头（BUG-1658）');
  });
}
