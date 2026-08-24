import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 门头统一守卫（2026-08-13 用户定案）：下载页此前是全 app 唯一还在用
/// `AppBar + 居中 TabBar` 门头的顶层 tab，与书 / 漫画 / 视频 / 游戏库页的
/// `FushiPageHeader.customTitle`（左对齐分区导航 + FushiIconButton 动作）不一致。
/// 本守卫钉死统一后的形态不被回退。
///
/// 2026-08-24：库页顶栏改走 MD3 tabs（[LibrarySectionTabs]），本页跟着换，钉死的
/// 「同范式」随之从分段条变成该共享组件。本页有 [TabBarView]，用
/// `LibrarySectionTabs.controlled` 与之共用同一个 [TabController]——不是回退到旧
/// 形态：旧形态是 **AppBar 内嵌居中 TabBar**，下面第四条仍然钉着它。
///
/// 注释与三引号语料先经 [maskCommentsAndScriptLines] 掩掉：源文件的说明注释里
/// 会提到旧 AppBar 与新范式的名字，裸 contains 会两个方向都误判。
void main() {
  test('下载页门头走 FushiPageHeader.customTitle + 共享分区导航，不再用 AppBar', () {
    final File f = File('lib/src/pages/implementations/downloads_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 downloads_page.dart（路径变了要同步本守卫）');
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    expect(code, contains('FushiPageHeader.customTitle'),
        reason: '下载页门头必须与其余顶层库页同范式（分段条作页头主位）');
    expect(code, contains('LibrarySectionTabs<int>.controlled'),
        reason: '子页导航必须走库页共享的 LibrarySectionTabs；本页有 TabBarView，'
            '须用 controlled 形态与它共用同一个 TabController（镜像出第二份选中态会让'
            '横滑时指示器只能跳、不跟手）');
    expect(code, isNot(contains('FushiSegmentedStrip<')),
        reason: 'MD3：分段按钮是 section 级单选控件，不得替代导航 tabs');
    expect(code, isNot(contains('appBar: AppBar(')),
        reason: '不得回退到独有的 AppBar 门头（与其它库页不一致）');
    expect(code, isNot(contains('bottom: TabBar(')),
        reason: '不得回退到 AppBar 内嵌居中 TabBar 的旧形态');
  });
}
