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

  test('查词页不重复画大标题，路由与历史动作并入搜索行', () {
    final String src =
        File('lib/src/pages/implementations/home_dictionary_page.dart')
            .readAsStringSync();
    final String buildSection = src.substring(
      src.indexOf('Widget build(BuildContext context)'),
      src.indexOf('void _handleDictionaryHomeDrop'),
    );
    final String searchHeaderSection = src.substring(
      src.indexOf('Widget _buildSearchHeader()'),
      src.indexOf('Widget _buildBody()'),
    );
    expect(buildSection.contains('FushiPageHeader'), isFalse,
        reason: '窗口标题栏 / 主导航已标明查词，内容区不得再占一整行重复标题');
    expect(buildSection.contains('DesktopContentLayout('), isTrue,
        reason: '查词正文仍应保留 dictionary 档的文字流留白');
    expect(searchHeaderSection, contains('home-dictionary-route-back'),
        reason: '砍掉页头不能丢掉隐藏 tab 独立路由的返回入口');
    expect(searchHeaderSection, contains('clear_dictionary_title'),
        reason: '清空查词历史动作应随搜索框留在首屏');
  });

  test('下载保留中心分区页头，浏览器扩展不重复画标题', () {
    final String downloads = File(
      'lib/src/pages/implementations/downloads_page.dart',
    ).readAsStringSync();
    final String browser = File(
      'lib/src/pages/implementations/browser_extension_page.dart',
    ).readAsStringSync();
    expect(downloads, contains('FushiPageHeader.customTitle('));
    expect(browser, isNot(contains('FushiPageHeader(')));
    expect(downloads, isNot(contains('appBar:')));
    expect(browser, isNot(contains('appBar:')));
  });
}
