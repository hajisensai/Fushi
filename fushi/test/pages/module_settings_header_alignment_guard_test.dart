import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1658 守卫：模块壳（视频/书架/漫画/游戏）的「设置」分区与兄弟分区共享同一个
/// 分段导航页头，页头必须逐像素对齐——其余分区都是 readerShelf 全出血、页头只有
/// FushiPageHeader 自身的 spacing.page 内边距。ModuleSettingsView 一旦再把整页
/// （页头在内）包进 DesktopContentLayout 的 settings 档（16/24px 侧向留白 + 宽屏
/// 960 居中限宽），切到「设置」时顶栏选择条就会整体偏移、宽度包络也变（用户实报
/// 「设置和其他页面的左右边距不同、每个子页的顶栏选择组件宽度不同」）。
///
/// 正文的横向缩进由 renderer 的 detailHorizontalInsets 自持；全局设置主页
/// （settings_home_page.dart）的 DesktopContentKind.settings 用法不在本守卫范围。
void main() {
  test('BUG-1658: ModuleSettingsView 不得用 DesktopContentLayout 包住共享页头', () {
    final String src =
        File('lib/src/pages/implementations/module_settings_view.dart')
            .readAsStringSync();
    // 剥掉行注释再扫：注释里允许提及这些名字（解释为什么不能用），只有真实代码
    // 引用才算违规。
    final String code = src
        .split('\n')
        .map((String line) => line.replaceFirst(RegExp(r'//.*$'), ''))
        .join('\n');
    expect(code.contains('DesktopContentLayout'), isFalse,
        reason: '设置分区的页头必须与兄弟分区（readerShelf 全出血）同构对齐，'
            '不得再叠 DesktopContentLayout 的侧向留白/限宽（BUG-1658）');
    expect(code.contains('DesktopContentKind'), isFalse,
        reason: 'ModuleSettingsView 不应引用任何 DesktopContentKind 档位（BUG-1658）');
    expect(code.contains('FushiPageHeader.customTitle'), isTrue,
        reason: '分段导航页头必须仍经 FushiPageHeader.customTitle 渲染，'
            '与兄弟分区同一页头组件');
  });

  test('BUG-1658: 查词页页头必须在 DesktopContentLayout(dictionary) 之外', () {
    final String src =
        File('lib/src/pages/implementations/home_dictionary_page.dart')
            .readAsStringSync();
    final int header = src.indexOf('_buildPageHeader()');
    final int layout = src.indexOf('DesktopContentLayout(');
    expect(header, greaterThanOrEqualTo(0), reason: '查词页应有大标题页头');
    expect(layout, greaterThanOrEqualTo(0),
        reason: '查词正文仍应保留 dictionary 档的文字流留白');
    // 代码顺序 = widget 树顺序：页头调用必须先于（即位于）DesktopContentLayout
    // 之外，否则 dictionary 档的 16/24px 侧向留白会把页头挤得比库页窄（BUG-1658）。
    expect(header, lessThan(layout),
        reason: '查词页页头被包进 DesktopContentLayout，会与书架/视频/游戏页头错位');
  });

  test('BUG-1658: 下载页 / 浏览器扩展页不得回退旧 AppBar 小标题页头', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/downloads_page.dart',
      'lib/src/pages/implementations/browser_extension_page.dart',
    ]) {
      final String code = File(path)
          .readAsStringSync()
          .split('\n')
          .map((String line) => line.replaceFirst(RegExp(r'//.*$'), ''))
          .join('\n');
      expect(code.contains('appBar:'), isFalse,
          reason: '$path 页头已统一为 FushiPageHeader 大标题（BUG-1658），'
              '不得回退 Scaffold.appBar 小标题工具栏');
      expect(code.contains('FushiPageHeader('), isTrue,
          reason: '$path 必须用 FushiPageHeader 渲染大标题页头（BUG-1658）');
    }
  });
}
