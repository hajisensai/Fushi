import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（BUG-920）：沉浸模式下鼠标光标 + 沉浸退出按钮**静止超时**也要隐藏。
///
/// 根因：沉浸态 media_kit 控制条被 IgnorePointer + 门控整体关掉、其 visibilityNotifier
/// 不再翻 → [_applyControlsVisibilityFromMediaKit]（OS 光标隐藏唯一权威）只在进沉浸那一刻
/// 跑一次；真实鼠标移动 [_setCursorHidden]`(false)` 唤回光标后，[_pokeLockButton] 的 2s 定时器
/// **只清 [_lockButtonVisible]**，既不重隐光标、也不释放 hover 保活 [_lockButtonHovered]
/// （keep-alive 顶住 `_lockButtonVisible || _lockButtonHovered` → 按钮永不淡出）。用户报
/// 「沉浸模式鼠标和沉浸按钮都不会隐藏，除非把鼠标移到别处」。
///
/// 修复：[_pokeLockButton] 定时器回调补「空闲重隐」——桌面重跑 [_applyControlsVisibilityFromMediaKit]
/// 按门控 / overlay 重隐光标；光标真被隐藏时（[_cursorHidden]）再释放 [_lockButtonHovered]，
/// 让按钮随光标同步淡出（光标仍可见时不清 hover，保 BUG-294）。media_kit controls 跑不了
/// headless，故锁源码结构不变量（与 [video_immersive_cursor_hide_guard_test] 同理）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  /// 切出 `_pokeLockButton` 方法体（到下一个方法 / extension 结束）。
  String pokeBody() {
    final int start = src.indexOf('void _pokeLockButton() {');
    expect(start, greaterThan(0), reason: '应有 _pokeLockButton 构造器');
    // _pokeLockButton 是 controls_visibility.part 的最后一个方法，其后紧跟 extension 闭合 `}`。
    // 用「下一次出现 `\n  void ` 或 `\n}` 里更近的那个」切尾，稳落方法边界。
    final int nextMethod = src.indexOf('\n  void ', start + 1);
    final int extEnd = src.indexOf('\n}', start + 1);
    int end = extEnd;
    if (nextMethod > start && (extEnd < 0 || nextMethod < extEnd)) {
      end = nextMethod;
    }
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  test('定时器回调静止超时重跑光标策略（空闲重隐光标，沉浸态缺失路径根修）', () {
    final String body = pokeBody();
    // 定时器仍先清自动淡出可见性。
    expect(body.contains('_lockButtonVisible.value = false'), isTrue,
        reason: '定时器到点仍应清 _lockButtonVisible（自然淡出）');
    // 关键：回调内重跑光标隐藏唯一权威 → 沉浸态静止 2s 重隐光标。
    expect(body.contains('_applyControlsVisibilityFromMediaKit()'), isTrue,
        reason:
            'BUG-920：定时器回调必须重跑 _applyControlsVisibilityFromMediaKit，补上沉浸态静止后的光标重隐路径');
  });

  test('光标真隐藏时释放锁按钮 hover 保活（按钮随光标同步淡出），且整块桌面门控', () {
    final String body = pokeBody();
    // 光标真被隐藏时才释放 hover 保活 → 按钮随光标同步淡出（消除 keep-alive 顶死）。
    expect(
      body.contains(
          'if (_cursorHidden.value) _lockButtonHovered.value = false'),
      isTrue,
      reason:
          'BUG-920：光标真被隐藏时应释放 _lockButtonHovered，让沉浸退出按钮随光标一起淡出（keep-alive 前提消失）',
    );
    // 空闲重隐整块桌面门控（移动端无 OS 光标语义，行为不变）。
    expect(body.contains('if (_isDesktopVideoControls) {'), isTrue,
        reason: '空闲重隐光标 / 释放 hover 属桌面 OS 光标语义，必须桌面门控');
  });

  test('保 BUG-294：定时器内每次释放 _lockButtonHovered 都受 _cursorHidden 门控（不无条件清）', () {
    final String body = pokeBody();
    // 反向钉死：不得无条件清 hover（那会在 overlay 打开、光标仍可见时把按钮从光标正下方
    // 凭空收走，回归 BUG-294）。定时器回调里对 _lockButtonHovered 的**每一次**清零都必须
    // 挂在 `if (_cursorHidden.value)` 门控之后。
    final int total =
        '_lockButtonHovered.value = false'.allMatches(body).length;
    final int guarded =
        'if (_cursorHidden.value) _lockButtonHovered.value = false'
            .allMatches(body)
            .length;
    expect(guarded, greaterThan(0),
        reason: '应有受 _cursorHidden 门控的 _lockButtonHovered 释放');
    expect(total, guarded,
        reason:
            'BUG-294：定时器内不得存在未受 _cursorHidden 门控的无条件 _lockButtonHovered 清零');
  });
}
