import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-284）：视频右 / 左浮动学习按钮 rail 在鼠标 hover 时不闪烁。
///
/// 根因：rail 按钮是 opaque [IconButton]，叠在 media_kit 桌面控制条那个全画面
/// hover-tracking [MouseRegion] 之上。鼠标移到 rail 按钮上 → media_kit 的
/// `MouseRegion.onExit` 立即把 `visible` 置 false → [_videoControlsVisible] 派生 false →
/// rail [SizedBox.shrink] 消失 → 鼠标位置下方重新是 media_kit region → onEnter 把
/// visible 拉回 true → rail 重现 → 鼠标又落按钮上 → 每帧级别快速闪烁。
///
/// 修复（消除特殊情况）：rail 显隐判据 = `_videoControlsVisible || 鼠标悬在 rail 上`，并在
/// 按钮列上挂 `MouseRegion(opaque:false)` keep-alive（进 rail 置 _railHovered=true +
/// _pokeControlsVisible 续命；出 rail 置 false）。media_kit controls 跑不了 headless，故锁
/// 源码结构不变量。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('存在 rail hover 单一真相源 _railHovered（ValueNotifier）并在 dispose 释放', () {
    expect(
      src.contains('final ValueNotifier<bool> _railHovered'),
      isTrue,
      reason: '应有 _railHovered 单一真相源 ValueNotifier（BUG-284）',
    );
    expect(
      src.contains('_railHovered.dispose()'),
      isTrue,
      reason: '_railHovered 应在 dispose 释放',
    );
  });

  test('rail 显隐判据含「控制条可见 OR 鼠标悬在 rail 上」（hover 期间不被收走）', () {
    expect(
      src.contains('if (!controlsVisible && !railHovered)'),
      isTrue,
      reason: 'rail 隐藏判据应为「控制条不可见 且 不在 hover」，hover 期间永不收走（BUG-284）',
    );
    final int railStart = src.indexOf('Widget _buildVideoSideActionRail(');
    expect(railStart, greaterThanOrEqualTo(0));
    final int mergeStart =
        src.indexOf('Listenable.merge(<Listenable>[', railStart);
    expect(mergeStart, greaterThanOrEqualTo(0));
    final int mergeEnd = src.indexOf('])', mergeStart);
    expect(mergeEnd, greaterThan(mergeStart));
    final String merge = src.substring(mergeStart, mergeEnd);
    expect(merge.contains('_videoControlsVisible'), isTrue);
    expect(merge.contains('_railHovered'), isTrue);
  });

  test('rail 按钮列挂 keep-alive MouseRegion（opaque:false + 进 rail 续命）', () {
    final int start = src.indexOf('Widget _railHoverKeepAlive(');
    expect(start, greaterThan(0), reason: '应有 _railHoverKeepAlive 构造器');
    final int end = src.indexOf('Widget _buildVideoSideActionRail(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('opaque: false'), isTrue,
        reason: 'keep-alive 不阻断指针下探（按钮点击 / 画面 hover 不受影响，沿 BUG-198 纪律）');
    expect(body.contains('_railHovered.value = true'), isTrue,
        reason: '进 rail 置 _railHovered=true，顶住 rail 显示');
    expect(body.contains('_pokeControlsVisible()'), isTrue,
        reason: '进 rail 续命 media_kit 控制条（其自身设计的续命路径）');
    expect(body.contains('_railHovered.value = false'), isTrue,
        reason: '出 rail 置 false，可见性回落到 _videoControlsVisible');
  });

  test('hover keep-alive 真正包住按钮列（不是整片 Positioned.fill）', () {
    final int railForIdx = src.indexOf('Widget _buildVideoSideRailFor(');
    expect(railForIdx, greaterThan(0));
    final int next = src.indexOf('Widget _videoWithSubtitlePanel(', railForIdx);
    expect(next, greaterThan(railForIdx));
    final String railFor = src.substring(railForIdx, next);
    expect(railFor.contains('_railHoverKeepAlive('), isTrue,
        reason: 'keep-alive 应包在单条 rail 的按钮列上（非整片 fill）');
  });

  test('字幕盒 hover 唤回光标 + 续命控制条（_handleSubtitleHover，BUG-284）', () {
    expect(src.contains('void _handleSubtitleHover(bool hovering)'), isTrue,
        reason: '应有字幕盒 hover 处理 _handleSubtitleHover');
    final int start = src.indexOf('void _handleSubtitleHover(bool hovering)');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(body.contains('_setCursorHidden(false)'), isTrue,
        reason: 'hover 字幕盒应唤回光标（顶层 _cursorHidden 胜出层让位）');
    expect(body.contains('_pokeControlsVisible()'), isTrue,
        reason: 'hover 字幕盒应续命控制条（避免 media_kit mount=false 自隐光标）');
    expect(src.contains('onHoverChanged: _handleSubtitleHover'), isTrue,
        reason: 'VideoSubtitleOverlay 应接 onHoverChanged: _handleSubtitleHover');
  });
}
