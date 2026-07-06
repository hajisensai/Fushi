import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（BUG-463）：视频内顶栏（media_kit 控制条 [topButtonBar]）必须避让系统
/// 状态栏 / 刘海，否则顶栏左右按钮被遮挡、点不到（用户报「视频顶栏的按钮会被挡住」）。
///
/// 根因：fork 的 [MaterialVideoControls] 只在**全屏**分支给顶栏 Column 套
/// `MediaQuery.padding` 顶部内缩（`isFullscreen ? MediaQuery.padding : EdgeInsets.zero`），
/// 窗口分支外层 padding 恒 `EdgeInsets.zero`；而移动端视频**永不进 media_kit 全屏路由**
/// （BUG-221，`_toggleVideoFullscreen` 移动端 no-op）→ 顶栏始终落窗口分支、顶部 inset 从
/// 不生效，按钮永远贴 `y=0` 被状态栏 / 刘海盖住。修复：移动 theme 显式把系统顶部 / 左 /
/// 右 inset 折进 `topButtonBarMargin`（纯函数 [videoTopBarMargin]），与底栏
/// `bottomButtonBarMargin` 的 `_videoBottomSystemInset` 对称。
///
/// media_kit 控制条几何依赖私有 State + 真实系统栏可见性，widget 测试难稳定复现，故用
/// 源码扫描守卫接线不被回退；margin 折算的纯函数行为由
/// `test/media/video/video_subtitle_style_test.dart` 的 `videoTopBarMargin` 组验证。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('移动控制主题把 topButtonBarMargin 接到 _videoTopBarMargin()（不回退默认无顶部 inset）',
      () {
    // 撤回成 media_kit 默认（不设 topButtonBarMargin，或写死无 top）→ 本条红、bug 复发。
    expect(src, contains('topButtonBarMargin: _videoTopBarMargin()'),
        reason: '移动 theme 必须把顶栏 margin 接到系统安全区折算的 _videoTopBarMargin()');
  });

  test('_videoTopBarMargin 读 padding/viewPadding，并用系统栏可见性门控顶部 inset', () {
    final int fn = src.indexOf('EdgeInsets _videoTopBarMargin()');
    expect(fn, greaterThanOrEqualTo(0),
        reason: '应有 _videoTopBarMargin 计算顶栏 margin');
    final int fnEnd = src.indexOf(';', fn);
    final String body = src.substring(fn, fnEnd);
    // BUG-556：top 不可再直接等于 padding.top。iOS 横竖屏切换 / 系统栏临时显隐时，
    // padding.top 可能带着过渡态安全区值；顶部避让要像底栏一样由系统栏真实可见性门控。
    expect(body, contains('MediaQuery.of(context).padding'),
        reason: '顶栏折算仍需读取 padding，避免键盘/系统 inset 概念混淆');
    expect(body, contains('MediaQuery.of(context).viewPadding'),
        reason: '横屏 cutout 左右避让应读取 viewPadding，避免状态栏显隐影响左右安全区');
    expect(body, contains('_systemBarsVisible'),
        reason: '顶部 inset 必须由系统栏真实可见性门控，隐栏时不吃过渡态 padding.top');
    expect(body, contains('videoTopBarMargin('),
        reason: 'margin 折算应经纯函数 videoTopBarMargin（页面/测试同源）');
  });

  test('反退回：移动 theme topButtonBarMargin 不写死成无系统 inset 的常量', () {
    // 旧实现根本不设 topButtonBarMargin（media_kit 默认 = horizontal:16、top:0）。本守卫
    // 钉「必须有动态接线」即足以挡回退；这里再额外确保没人把它写死回纯常量 margin。
    expect(
      src,
      isNot(
          contains('topButtonBarMargin: EdgeInsets.symmetric(horizontal: 16)')),
      reason: '顶栏 margin 不应写死成 media_kit 默认无顶部 inset 的常量（顶栏会被状态栏遮挡）',
    );
  });
}
