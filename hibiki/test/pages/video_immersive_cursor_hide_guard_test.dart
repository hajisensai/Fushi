import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：沉浸/锁屏 + 控制条淡出时 OS 光标在所有 chrome 上统一隐藏（TODO-318 / BUG-258）。
///
/// 根因：media_kit 用 `MouseRegion(cursor: none)`（hideMouseOnControlsRemoval）隐藏光标，但
/// hibiki 把 overlay chrome（锁按钮 rail / OSD / 字幕面板）叠在其上 → 最前层 MouseRegion 的
/// cursor 胜出 → 鼠标放到 chrome 上光标重现；沉浸锁态 IgnorePointer 又剥了 media_kit region。
///
/// 修复：单一真相源 [_cursorHidden]（镜像 controls 隐藏 2s 计时 + 沉浸锁态），在 controls
/// Stack 最顶层 [_buildCursorOverlay] 包一个 MouseRegion(cursor:none) 统一胜出；真实鼠标
/// 移动经 [_handleVideoControlsHover] 唤回。不 per-overlay 加 opaque MouseRegion（防 BUG-198）。
///
/// media_kit controls 跑不了 headless，故锁源码结构不变量。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('存在 OS 光标隐藏单一真相源 _cursorHidden（ValueNotifier）', () {
    expect(
      src.contains('final ValueNotifier<bool> _cursorHidden'),
      isTrue,
      reason: '应有 _cursorHidden 单一真相源 ValueNotifier',
    );
    expect(
      src.contains('void _setCursorHidden(bool hidden)'),
      isTrue,
      reason: '应有统一翻转 helper _setCursorHidden（桌面门控）',
    );
    expect(
      src.contains('_cursorHidden.dispose()'),
      isTrue,
      reason: '_cursorHidden 应在 dispose 释放',
    );
  });

  test('controls Stack 最顶层有 cursor:none 统一胜出层（_buildCursorOverlay）', () {
    expect(src.contains('Widget _buildCursorOverlay()'), isTrue,
        reason: '应有光标隐藏统一胜出层构造器');
    final int start = src.indexOf('Widget _buildCursorOverlay()');
    final int end = src.indexOf('Widget _buildVideoSideActionRail(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('valueListenable: _cursorHidden'), isTrue,
        reason: '胜出层由 _cursorHidden 驱动');
    expect(body.contains('SystemMouseCursors.none'), isTrue,
        reason: '隐藏时用 cursor: none');
    expect(body.contains('opaque: false'), isTrue,
        reason: 'opaque:false 不阻断指针下探（防 BUG-198 hover 穿透）');

    // 胜出层挂在 controls Stack 内，且排在右侧 rail / 侧栏 overlay 之后（front-most）。
    // 注意 _buildCursorOverlay 定义在文件靠前，这里专门匹配 Stack 子节点挂载形态
    // （`if (_isDesktopVideoControls) _buildCursorOverlay()`）以测真实绘制顺序。
    final int railIdx = src.indexOf('_buildVideoSideActionRail(controller),');
    final int panelIdx =
        src.indexOf('_buildVideoSidePanelOverlay(controller),');
    final int overlayIdx =
        src.indexOf('if (_isDesktopVideoControls) _buildCursorOverlay()');
    expect(overlayIdx, greaterThan(railIdx),
        reason: '光标胜出层应在 action rail 之后（更靠 Stack 顶）');
    expect(overlayIdx, greaterThan(panelIdx),
        reason: '光标胜出层应在侧栏 overlay 之后（最顶层，cursor 解析才胜出）');
  });

  test('沉浸锁 / 控制条淡出隐藏光标；真实鼠标移动唤回；解锁立即唤回', () {
    // TODO-364：光标隐藏逻辑从 _markControlsVisible 收敛进唯一派生函数
    // _applyControlsVisibilityFromMediaKit（控制条不可见且无 overlay 即隐藏光标，
    // 镜像 media_kit 的 hideMouseOnControlsRemoval，2s 由 media_kit 自己的 Timer 触发并推送）。
    final int markIdx =
        src.indexOf('void _applyControlsVisibilityFromMediaKit() {');
    final int markEnd =
        src.indexOf('void _markControlsVisible(bool visible) {', markIdx);
    final String mark = src.substring(markIdx, markEnd);
    expect(mark.contains('_setCursorHidden(!visible && !_hasVideoOverlay)'),
        isTrue,
        reason: '控制条不可见且无 overlay（纯沉浸 / 自动淡出）时隐藏光标');

    // 真实鼠标移动唤回光标（合成 poke 不强制显示）。
    final int hoverIdx =
        src.indexOf('void _handleVideoControlsHover(PointerEvent event) {');
    final int hoverEnd = src.indexOf(
        'void _handleVideoControlsHoverExit(PointerEvent event) {', hoverIdx);
    final String hover = src.substring(hoverIdx, hoverEnd);
    expect(hover.contains('_setCursorHidden(false)'), isTrue,
        reason: '真实鼠标移动应唤回光标');
    expect(hover.contains('if (!_isSyntheticControlsHover(event)) {'), isTrue,
        reason: '只有非合成（真实）移动才唤回光标');

    // 解锁沉浸时立即唤回光标。
    final int lockIdx = src.indexOf('void _toggleImmersiveLock() {');
    final int lockEnd =
        src.indexOf('VideoImmersiveMode get _videoImmersiveMode', lockIdx);
    final String lock = src.substring(lockIdx, lockEnd);
    expect(lock.contains('_setCursorHidden(false)'), isTrue,
        reason: '解锁沉浸应立即唤回光标（即时反馈）');
  });

  test('字幕列表打开时光标纳入「有 overlay 即可见」门控（光标语义，BUG-371）', () {
    // 光标语义按 _hasVideoOverlay 分叉（有 overlay 即可见，纯沉浸才隐藏，保 BUG-258）。
    // BUG-371：字幕列表是 push-aside 侧栏，不再纳入控制条可见性派生门控 gated
    // （控制条在被挤窄的画面上仍可用），但**光标**仍要在字幕列表打开时保持可见——靠
    // _hasVideoOverlay（含 _subtitleListVisible）+ 前置胜出层光标覆盖，而非靠 gated。
    final int markIdx =
        src.indexOf('void _applyControlsVisibilityFromMediaKit() {');
    final int markEnd =
        src.indexOf('void _markControlsVisible(bool visible) {', markIdx);
    final String mark = src.substring(markIdx, markEnd);
    expect(mark.contains('_setCursorHidden(!visible && !_hasVideoOverlay)'),
        isTrue,
        reason: '有 overlay（侧栏 / 字幕列表）时光标可见，纯沉浸锁才隐藏（保 BUG-258）');

    // _hasVideoOverlay getter 把侧栏与字幕列表统一为「有 overlay」单一判据——
    // 字幕列表打开时光标仍由它保活（即使控制条门控 gated 已不含字幕列表，BUG-371）。
    expect(
      RegExp(r'bool get _hasVideoOverlay =>[\s\S]*?_videoSidePanel\.value '
              r'!= null \|\|[\s\S]*?_subtitleListVisible\.value')
          .hasMatch(src),
      isTrue,
      reason: '_hasVideoOverlay 应同时覆盖侧栏与字幕列表（光标保活，BUG-371 保留）',
    );
  });

  test('字幕列表打开时 IgnorePointer 不再 gate media_kit 控制条（BUG-371）', () {
    // BUG-371：字幕列表是 push-aside 侧栏（画面挤窄、不遮控制条），开列表时 media_kit
    // 顶 / 底栏按钮应继续可点（左侧按钮可用），故 IgnorePointer **不**绑 _subtitleListVisible。
    // 字幕列表打开时画面光标仍可见——靠前置胜出层光标覆盖 + _hasVideoOverlay（上一个 test），
    // 不再靠把 media_kit 整层 IgnorePointer 掉。
    final int start = src.indexOf('return ListenableBuilder(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 media_kit controls 的 ListenableBuilder');
    final int end = src.indexOf('child: AdaptiveVideoControls(state),', start);
    expect(end, greaterThan(start),
        reason: 'IgnorePointer 块应闭合到 AdaptiveVideoControls');
    final String block = src.substring(start, end);
    expect(block.contains('_subtitleListVisible'), isFalse,
        reason:
            'BUG-371：IgnorePointer 不应再绑 _subtitleListVisible（字幕列表 push-aside 不遮控制条）');
  });

  test('不 per-overlay 加 opaque MouseRegion（防 BUG-198 hover 穿透）', () {
    // 锁按钮 rail / OSD 等 overlay 不应自己叠 opaque:true 的 MouseRegion 抢光标。
    // 统一胜出层是唯一的光标控制点（opaque:false）。
    expect(
      'cursor: SystemMouseCursors.none'.allMatches(src).length,
      1,
      reason: '光标隐藏只在单一胜出层做，不散落到各 overlay',
    );
  });
}
