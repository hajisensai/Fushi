import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：视频**真 overlay 侧栏**（设置 / 音轨 / 倍速 / 收藏句 / 字幕源，经
/// `_videoSidePanel`）打开时，背景的 media_kit 控制条与右侧操作 rail 不再冒出来盖在面板
/// 后面（BUG-253 / TODO-300）。
///
/// 根因：控制条显隐镜像 `_videoControlsVisible` 与 media_kit 自己的控制条此前只被
/// `_immersiveLocked` 抑制、从不看 `_videoSidePanel`。修复把「面板开则抑制」扩展到
/// 控制条显隐 / hover / rail 可见性 / media_kit 指针全部路径，与沉浸锁同源门控。
///
/// BUG-371：字幕跳转列表（`_subtitleListVisible`）是 **push-aside** 侧栏
/// （`_videoWithSubtitlePanel` 的 `Row[Expanded(video), 面板列]`，TODO-314），把画面挤窄到
/// 左侧、**不遮挡**叠在画面上的控制条 / rail。故它**不应**再纳入这些抑制门控——开字幕列表时
/// 左右控制按钮应继续可见可用（用户：「字幕列表只是侧边栏，左边的按钮应该还可以换出」）。
/// 本守卫据此反向断言：抑制门控里**只有** `_videoSidePanel`（+ 沉浸锁 / 编辑态），
/// **没有** `_subtitleListVisible`。
///
/// media_kit controls + hover 时序跑不了 headless，故锁源码结构不变量（与既有
/// video_mouse_autohide_guard_test / video_settings_panel_no_fullscreen_guard_test 同范式）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  /// 截取从 [signature] 起到下一个顶层方法 / 闭合为止的方法体（粗粒度，足够锚定门控）。
  String methodBody(String signature, String endMarker) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '需有 $signature');
    final int end = src.indexOf(endMarker, start + signature.length);
    expect(end, greaterThan(start), reason: '需有 $endMarker 作为 $signature 的段终点');
    return src.substring(start, end);
  }

  test('_pokeControlsVisible 在面板打开时早返回', () {
    final String body = methodBody(
      'void _pokeControlsVisible() {',
      'void _clearRailHover()',
    );
    expect(body.contains('if (_videoSidePanel.value != null) return;'), isTrue,
        reason: '_pokeControlsVisible 必须在 _videoSidePanel 非空时早返回，不唤起背景控制条');
  });

  test(
      '控制条可见性派生（_applyControlsVisibilityFromMediaKit）门控沉浸锁 / 真 overlay 侧栏，但不含字幕列表',
      () {
    // TODO-364：可见性收敛到唯一派生函数，门控成立时强制不可见（旧 _markControlsVisible
    // 强制隐藏分支已并入此处）。BUG-371：字幕列表是 push-aside 不遮控制条，**不在**门控里。
    final String body = methodBody(
      'void _applyControlsVisibilityFromMediaKit() {',
      'void _markControlsVisible(bool visible) {',
    );
    final String flat = body.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat.contains('final bool gated ='), isTrue,
        reason: '派生函数内必须有统一 gated 门控');
    for (final String token in <String>[
      '_immersiveLocked.value',
      '_videoSidePanel.value != null',
      '_videoControlEditMode.value',
    ]) {
      expect(flat.contains(token), isTrue, reason: '派生的门控 gated 必须含 $token');
    }
    expect(flat.contains('_subtitleListVisible.value'), isFalse,
        reason: 'BUG-371：字幕列表 push-aside 不遮控制条，门控**不应含** _subtitleListVisible');
    expect(flat.contains('!gated && _mediaKitControlsVisible.value'), isTrue,
        reason: '门控成立强制不可见、否则等于 media_kit 真实可见性（单一真相源）');
  });

  test('右侧操作 rail 强压制门控含真 overlay 侧栏，但不含字幕列表（BUG-371）', () {
    // 强压制 getter 定义在主文件别处，这里锁其表达式不含字幕列表。
    final String getterBody = methodBody(
      'bool get _videoSideActionRailStronglySuppressed =>',
      'bool get _isDesktopVideoControls {',
    );
    expect(getterBody.contains('_videoSidePanel.value != null'), isTrue,
        reason: 'rail 强压制应含真 overlay 侧栏门控（面板盖控制条则不显示 rail）');
    expect(getterBody.contains('_videoControlEditMode.value'), isTrue,
        reason: 'rail 强压制应含编辑态门控');
    expect(getterBody.contains('_subtitleListVisible.value'), isFalse,
        reason:
            'BUG-371：字幕列表 push-aside 不遮 rail，强压制**不应含** _subtitleListVisible');

    final String body = methodBody(
      'Widget _buildVideoSideActionRail(',
      'Widget _buildSideLockButton(',
    );
    // gate 一行可能被 dart format 折行，故只断言并列条件都在 gate 块里出现。
    // BUG-284：rail 显隐判据从 `!controlsVisible` 收紧为 `(!controlsVisible &&
    // !railHovered)`（hover 期间不被收走防闪烁），沉浸锁分支仍并列在内。
    final int gateIdx = body.indexOf('if (!controlsVisible && !railHovered)');
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'rail 应有 (!controlsVisible && !railHovered) gate（BUG-284）');
    final int braceIdx =
        body.indexOf('return const SizedBox.shrink();', gateIdx);
    expect(braceIdx, greaterThan(gateIdx), reason: 'gate 块应闭合到 shrink');
    expect(body.contains('if (_immersiveLocked.value)'), isTrue,
        reason: 'rail 应保留沉浸锁分支');
  });

  test('media_kit controls 的 IgnorePointer 绑真 overlay 侧栏门控，但不拦字幕列表（BUG-371）',
      () {
    // IgnorePointer 块从签名锚到 AdaptiveVideoControls(state) 结束，避免误命中文件别处同名
    // notifier（如 rail / 可见性派生）。BUG-371：字幕列表 push-aside 不遮控制条，开列表时
    // media_kit 顶 / 底栏按钮应继续可点，故 IgnorePointer **不**绑 _subtitleListVisible。
    // BUG-391 r4（提交 1fc54c75a）在 IgnorePointer 之外又加了一层
    // `return ListenableBuilder(`（控制条 theme builder，合法地 merge 了
    // _subtitleListVisible / _episodeListVisible 以驱动 hideMouseOnControlsRemoval）；
    // 它在合并语料里排在 IgnorePointer 那层之前。改为先定位 IgnorePointer 闭合处
    // (AdaptiveVideoControls) 再向前找最近的 `return ListenableBuilder(`，精确锚定
    // IgnorePointer 自己那层（否则会误把 theme builder 切进来、误命中 _subtitleListVisible）。
    final int end = src.indexOf('child: AdaptiveVideoControls(state),');
    expect(end, greaterThanOrEqualTo(0),
        reason: 'IgnorePointer 块应闭合到 AdaptiveVideoControls');
    final int start = src.lastIndexOf('return ListenableBuilder(', end);
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 media_kit controls 的 IgnorePointer ListenableBuilder');
    final String block = src.substring(start, end);
    for (final String token in <String>[
      '_immersiveLocked',
      '_videoSidePanel',
      '_episodeListVisible',
      '_videoControlEditMode',
    ]) {
      expect(block.contains(token), isTrue,
          reason: 'media_kit controls 的 IgnorePointer 必须监听 / 拦截 $token');
    }
    expect(block.contains('_subtitleListVisible'), isFalse,
        reason:
            'BUG-371：字幕列表 push-aside 不遮控制条，IgnorePointer **不应**绑 _subtitleListVisible');
  });

  test('_showVideoSidePanel 不再唤起控制条、_hideVideoSidePanel 关闭后唤回', () {
    final String show = methodBody(
      'void _showVideoSidePanel(',
      'void _hideVideoSidePanel()',
    );
    // 打开面板时不再 poke（会点亮背景控制条），改为显式收起镜像。
    expect(show.contains('_pokeControlsVisible();'), isFalse,
        reason: '_showVideoSidePanel 打开面板时不应再 _pokeControlsVisible（否则点亮背景控制条）');
    expect(show.contains('_markControlsVisible(false);'), isTrue,
        reason: '_showVideoSidePanel 应显式把已显示的控制条镜像收起');

    final String hide = methodBody(
      'void _hideVideoSidePanel() {',
      'String _videoSidePanelTitle(',
    );
    expect(hide.contains('_pokeControlsVisible();'), isTrue,
        reason: '_hideVideoSidePanel 关闭面板后应 _pokeControlsVisible 唤回控制条');
  });
}
