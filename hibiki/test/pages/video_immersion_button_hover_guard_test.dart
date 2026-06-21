import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（TODO-388 / BUG-295）：视频侧边锁 / 解锁（沉浸）按钮在鼠标 hover 时不消失。
///
/// 根因：锁按钮可见性走 [_lockButtonVisible] + [_pokeLockButton] 的 2s 自动淡出定时器，
/// 唤起只发生在「鼠标在视频区移动」时（[_videoControlsHoverWrap] 的 onHover）。鼠标**静止
/// 悬停在按钮本身**上时不再有 hover 事件续命，2s 后按钮在光标正下方淡出消失。
///
/// 修复（消除特殊情况，对齐屏幕右侧 rail 按钮）：新增 [_lockButtonHovered] + hover keep-alive
/// MouseRegion（进按钮置 true 顶住 + [_pokeLockButton] 续命；出按钮置 false 回落自然淡出），
/// 可见性判据改为 `_lockButtonVisible.value || _lockButtonHovered.value`。media_kit controls
/// 跑不了 headless，故锁源码结构不变量（与 [video_rail_hover_flicker_guard_test] 同理）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('存在 _lockButtonHovered 单一真相源（ValueNotifier）并在 dispose 释放', () {
    expect(
      src.contains('final ValueNotifier<bool> _lockButtonHovered'),
      isTrue,
      reason: '应有 _lockButtonHovered 单一真相源（BUG-295）',
    );
    expect(
      src.contains('_lockButtonHovered.dispose()'),
      isTrue,
      reason: '_lockButtonHovered 应在 dispose 释放',
    );
  });

  test('锁按钮可见性判据含「自动淡出可见 OR 鼠标悬在按钮上」（hover 期间不被收走）', () {
    expect(
      src.contains('_lockButtonVisible.value || _lockButtonHovered.value'),
      isTrue,
      reason: '锁按钮可见性应为 _lockButtonVisible OR _lockButtonHovered（BUG-295）',
    );
    expect(
      src.contains(
          'Listenable.merge(<Listenable>[\n                  _lockButtonVisible,\n                  _lockButtonHovered,\n                ])'),
      isTrue,
      reason: '锁按钮应同时监听 _lockButtonVisible 与 _lockButtonHovered',
    );
  });

  test('锁按钮挂 keep-alive MouseRegion（opaque:false + 进按钮续命 + 出按钮置 false）', () {
    final int start = src.indexOf('Widget _lockButtonHoverKeepAlive(');
    expect(start, greaterThan(0), reason: '应有 _lockButtonHoverKeepAlive 构造器');
    final int end = src.indexOf('Widget _buildVideoSideActionRail(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('opaque: false'), isTrue,
        reason: 'keep-alive 不阻断指针下探（按钮点击 / 画面 hover 不受影响）');
    expect(body.contains('_lockButtonHovered.value = true'), isTrue,
        reason: '进按钮置 _lockButtonHovered=true，顶住锁按钮显示');
    expect(body.contains('_pokeLockButton()'), isTrue, reason: '进按钮续命自动淡出定时器');
    expect(body.contains('_lockButtonHovered.value = false'), isTrue,
        reason: '出按钮置 false，可见性回落到 _lockButtonVisible 的自然淡出');
  });

  test('keep-alive 真正包住锁按钮本体（_buildSideLockButton 内调用）', () {
    final int start = src.indexOf('Widget _buildSideLockButton()');
    expect(start, greaterThan(0));
    final int end = src.indexOf('onPressed: _toggleImmersiveLock,', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('_lockButtonHoverKeepAlive('), isTrue,
        reason: 'keep-alive 应包在锁按钮本体上');
  });
}
