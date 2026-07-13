import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：**hover 触发**的音量/倍速轻浮层不得关闭 push-aside 字幕列表（BUG-791）。
///
/// 根因：桌面默认控制布局把 volume + speed 放进 `bottomRight` 槽紧挨 fullscreen；
/// `_controlPopoverAnchor` 给这些按钮包了 `MouseRegion`，**hover（onEnter）** 即调
/// `_showControlPopover`。而 `_showControlPopover` 曾沿用 `_showVideoSidePanel` 的
/// 「开任何浮层就关 push-aside 字幕列表」互斥假设，无条件 `_subtitleListVisible.value = false`。
/// 但轻浮层落点被 `resolveVideoControlPopoverPlacement` clamp 在 `playerBounds`（字幕列表
/// 推开后已窄化的视频列）内，几何上不与右侧字幕栏重叠——鼠标划过右下角图标去够全屏时
/// 就把字幕列表误关了。
///
/// 修复：`_showControlPopover` 移除对 `_subtitleListVisible` 的强制关闭（与 BUG-371 对
/// 三处控制条门控的处理一致）。真正遮挡右栏、需互斥关字幕列表的是**点击**触发的 overlay
/// 面板 `_showVideoSidePanel`（保留）。本守卫锁死二者语义差异不被回改。
///
/// media_kit 在 headless test 跑不起真视频 widget，故断言源码层的互斥路由。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  /// 切 `_showControlPopover` 的**方法定义体**（signature 到下一个方法 `_hideControlPopover`）。
  /// 用 `void _showControlPopover(` 精确锚定定义，避开调用点 `_showControlPopover(kind`。
  String showControlPopoverBody() {
    final int start = src.indexOf('void _showControlPopover(');
    expect(start, greaterThan(-1), reason: '应有 _showControlPopover 方法定义');
    final int end = src.indexOf('void _hideControlPopover()', start);
    expect(end, greaterThan(start), reason: '需有 _hideControlPopover 作为方法体终点');
    return src.substring(start, end);
  }

  test('BUG-791：_showControlPopover 不得关闭 push-aside 字幕列表（hover 触发的轻浮层与字幕列表共存）',
      () {
    final String body = showControlPopoverBody();
    expect(
      body.contains('_subtitleListVisible.value = false'),
      isFalse,
      reason: 'hover 触发的音量/倍速轻浮层几何上不遮挡右侧字幕栏，'
          '不得把 push-aside 字幕列表弄没（BUG-791）',
    );
  });

  test('对照锚定：点击触发的 overlay 面板 _showVideoSidePanel 仍互斥关闭字幕列表（遮挡右栏合理）', () {
    final int showStart = src.indexOf('void _showVideoSidePanel(');
    expect(showStart, greaterThan(-1), reason: '应有 _showVideoSidePanel 方法');
    final int showEnd =
        src.indexOf('\n  void _hideVideoSidePanel()', showStart);
    expect(showEnd, greaterThan(showStart));
    final String showBody = src.substring(showStart, showEnd);
    expect(
      showBody.contains('_subtitleListVisible.value = false'),
      isTrue,
      reason: 'overlay 面板 centerRight 遮挡右栏，开它时关字幕列表合理——'
          '此对照确保 BUG-791 的修复只针对轻浮层、未误删 overlay 面板的互斥',
    );
  });

  test(
      '回归锚定：轻浮层由 _controlPopoverAnchor 的 MouseRegion.onEnter（hover）触发 _showControlPopover',
      () {
    final int anchorStart = src.indexOf('Widget _controlPopoverAnchor({');
    expect(anchorStart, greaterThan(-1),
        reason: '应有 _controlPopoverAnchor helper');
    final int anchorEnd =
        src.indexOf('\n  ', src.indexOf('child: anchored,', anchorStart));
    final String anchorBody = src.substring(anchorStart, anchorEnd);
    expect(anchorBody.contains('MouseRegion('), isTrue,
        reason: '桌面 hover 由 MouseRegion 打开轻浮层');
    expect(anchorBody.contains('onEnter:'), isTrue,
        reason: 'onEnter（hover 进入）即触发——这正是 BUG-791 的意外行为来源');
    expect(
      RegExp(r'onEnter:.*?_showControlPopover\(', dotAll: true)
          .hasMatch(anchorBody),
      isTrue,
      reason: 'onEnter 调 _showControlPopover：证明轻浮层是 hover 触发，'
          '故 _showControlPopover 不得含关字幕列表的副作用',
    );
  });
}
