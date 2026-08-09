import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：确保视频页修复「导入着色器后空格失灵」的接线不被回退。
///
/// 根因：media_kit 的 `Video` 自带 FocusNode + 内置快捷键（空格=播放/暂停）。覆盖层
/// （对话框 / bottom sheet / FilePicker 系统对话框）会夺走窗口键盘焦点，关闭后 Flutter
/// 不会自动把焦点还给 Video → 空格失灵。修复是把焦点节点提到 State 持有、传给 Video，
/// 并在每个覆盖层关闭后归还。
///
/// 归还统一走 [PageFocusOwnership]（`_focusOwnership`）：单一入口 + 按
/// `FocusReclaimCause` 分流的判据（`_canOwnVideoFocus`），取代原先散在各处、每个
/// 自带一套门控的 `_refocusVideo()` / `_reclaimVideoFocusIfOwned()` 手写补丁。本测试
/// 静态扫描这些不变式，因为焦点行为在 widget 测试里难稳定复现（依赖真实焦点遍历 /
/// 平台文件选择器）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('State 持有专用 FocusNode 并在 dispose 释放', () {
    expect(src, contains('FocusNode _videoFocusNode'),
        reason: '应有 State 级别的 _videoFocusNode 供覆盖层关闭后归还焦点');
    expect(src, contains('_videoFocusNode.dispose()'),
        reason: 'FocusNode 必须在 dispose 释放，避免泄漏');
  });

  test('Video widget 接上 _videoFocusNode（替换内置匿名节点）', () {
    expect(src, contains('focusNode: _videoFocusNode'),
        reason: 'Video 必须用本页持有的 FocusNode，否则覆盖层关闭后无法归还焦点');
  });

  test('视频首次 load 完成后主动把焦点交给 Video', () {
    final int applyLoad = src.indexOf('Future<void> _applyLoad({');
    final int persist =
        src.indexOf('Future<void> _persistPosition(', applyLoad);
    expect(applyLoad, greaterThanOrEqualTo(0));
    expect(persist, greaterThan(applyLoad));
    final String body = src.substring(applyLoad, persist);

    expect(
        body,
        contains(
            '_focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady)'),
        reason: '非全屏进入视频页后若没有主动聚焦，空格会冒泡到全局 DoNothingIntent 而不是播放/暂停');
  });

  test('慢路径挂载 Video 后必须补一次焦点回收（BUG-1266）', () {
    // 根因：[_videoFocusNode] 挂在 [Video] 上，而首帧未就绪的首开被 `!_videoReadyToShow`
    // 挡在 `_buildLoadingBody` 分支——此刻 Video 尚未挂载、节点未 attach，`_applyLoad`
    // 结尾那次 contentReady 回收对孤儿节点是静默 no-op（请求直接丢失）。若
    // [_promoteVideoReady] 把 Video 挂上后不补一次回收，焦点会整段滞留在页面之外：
    // 手柄按键不冒泡经过本页，所有手柄绑定失灵，且没人消费的 B 会被 Android 合成成
    // BACK 直接退页（用户报「必须先按一下暂停才能正常上下句」「进视频想回退两句却退回桌面」）。
    final int start = src.indexOf('void _promoteVideoReady() {');
    expect(start, greaterThanOrEqualTo(0),
        reason: '慢路径提升汇聚点 _promoteVideoReady 应存在');
    final int end = src.indexOf('Future<void> _init() async {', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(
        body,
        contains(
            '_focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady)'),
        reason: '慢路径把 Video 挂上后必须补一次焦点回收，否则本页整段没有键盘所有者');
  });

  test('存在统一的焦点所有者与判据', () {
    expect(src, contains('PageFocusOwnership _focusOwnership'),
        reason: '归还焦点必须走单一所有者 _focusOwnership，不再各处手写 requestFocus');
    expect(src, contains('node: _videoFocusNode'),
        reason: '所有者必须持有本页的 _videoFocusNode');
    expect(src, contains('bool _canOwnVideoFocus(FocusReclaimCause cause)'),
        reason: '应有统一的「视频此刻应当持有键盘」判据，按 cause 分流');
  });

  test('页面不得绕过 _focusOwnership 直接抢焦点', () {
    // 一旦有人重新在页面里裸调 requestFocus，判据（播放器就绪 / 查词浮层可见 /
    // 所有者路由 isCurrent）就被绕过——这正是统一前每个补丁互相漂移的老路。
    expect(src, isNot(contains('_videoFocusNode.requestFocus()')),
        reason:
            '焦点请求必须经 _focusOwnership.reclaim/reclaimAfterFrame/guardOverlay');
  });

  test('每个会夺焦的覆盖层关闭后都归还焦点', () {
    // TODO-274：倍速/音轨/字幕源/设置四菜单迁到 side panel，关闭走 [_hideVideoSidePanel]；
    // TODO-638 剧集列表也改 push-aside 侧栏（关闭走 [_closeEpisodeList]），视频页已无
    // modal bottom sheet。统计所有回收点覆盖 side panel / push-aside 列表关闭 + 各
    // 对话框/picker。
    final int reclaimCalls = '_focusOwnership.reclaim'.allMatches(src).length;
    expect(reclaimCalls, greaterThanOrEqualTo(6),
        reason:
            '所有夺焦覆盖层（side panel + push-aside 列表 + 着色器/Jimaku/picker）关闭后都应归还焦点');
    // side panel 关闭汇聚点 [_hideVideoSidePanel] 必须归还键盘焦点。
    final int hideIdx = src.indexOf('void _hideVideoSidePanel() {');
    expect(hideIdx, greaterThanOrEqualTo(0),
        reason: 'side panel 菜单需有统一关闭汇聚点 _hideVideoSidePanel');
    final int hideEnd = src.indexOf('\n  }', hideIdx);
    expect(
        src.substring(hideIdx, hideEnd).contains(
            '_focusOwnership.reclaim(FocusReclaimCause.overlayClosed)'),
        isTrue,
        reason: 'side panel 关闭后必须归还键盘焦点');
    // TODO-638：剧集列表 push-aside 关闭汇聚点 [_closeEpisodeList] 也必须归还键盘焦点
    // （取代旧 modal sheet whenComplete 的 _videoSheetOpen 复位 + refocus 闭包）。
    final int epIdx = src.indexOf('void _closeEpisodeList() {');
    expect(epIdx, greaterThanOrEqualTo(0),
        reason: '剧集列表 push-aside 需有统一关闭汇聚点 _closeEpisodeList');
    final int epEnd = src.indexOf('\n  }', epIdx);
    expect(
        src.substring(epIdx, epEnd).contains(
            '_focusOwnership.reclaim(FocusReclaimCause.overlayClosed)'),
        isTrue,
        reason: '剧集列表 push-aside 关闭后必须归还键盘焦点');
  });

  // ── TODO-040/042：三类「快捷键失灵」的统一修复接线 ────────────────────────

  test('全屏期窗口侧 controls 必须经 VideoControlsFocusGate 卸载（根因修复）', () {
    // 根因：窗口/全屏两套 controls 共用 _videoFocusNode，退全屏时全屏侧 Focus
    // dispose 把节点摘成永久孤儿 → 此后所有归还静默失效（行为复现见
    // video_fullscreen_focus_gate_test.dart）。
    expect(src, contains('VideoControlsFocusGate('),
        reason: 'controls builder 必须包 VideoControlsFocusGate');
    expect(src, contains('fullscreenRouteActive: _videoFullscreenActive'),
        reason: 'gate 必须吃页面级 _videoFullscreenActive 标记');
    expect(src, contains('bool _videoFullscreenActive = false;'),
        reason: '页面必须维护「全屏路由在栈上」标记');
  });

  test('全屏路由关闭走唯一汇聚点：whenComplete 复位标记 + 归还焦点', () {
    expect(src, contains('.whenComplete(_onVideoFullscreenRouteClosed)'),
        reason: 'Esc/F/按钮/双击/系统返回全部经路由 future 完成，必须单点收口');
    final int handler = src.indexOf('void _onVideoFullscreenRouteClosed()');
    expect(handler, greaterThanOrEqualTo(0));
    final String body = src.substring(
        handler, src.indexOf('Future<void> _exitVideoFullscreen', handler));
    expect(body, contains('_videoFullscreenActive = false'),
        reason: '退全屏必须复位标记让窗口侧 controls 重挂（节点重新 attach）');
    // 必须是 post-frame：窗口侧 controls 要先重挂、节点重新 reparent，同步请求会落空。
    expect(
        body,
        contains(
            '_focusOwnership.reclaimAfterFrame(FocusReclaimCause.surfaceRemounted)'),
        reason: '重挂后必须在下一帧归还键盘焦点');
  });

  test('查词浮层栈全空时在关栈汇聚点归还焦点（点遮罩/返回/Esc 全路径）', () {
    final int pop = src.indexOf('void _popNestedPopupAt(int index)');
    expect(pop, greaterThanOrEqualTo(0));
    final String body =
        src.substring(pop, src.indexOf('Widget _buildNestedPopupLayer', pop));
    // TODO-270 E：关栈汇聚点的 stackEmpty 分支扩成块体（清未制卡草稿 + 归还焦点）；
    // 焦点归还仍在同一汇聚点，覆盖点遮罩/返回/Esc/滑动全部关闭路径。
    expect(body, contains('if (stackEmpty) {'),
        reason: '浮层全关后必须在关栈汇聚点处理（清草稿 + 归还焦点）');
    expect(body,
        contains('_focusOwnership.reclaim(FocusReclaimCause.popupDismissed)'),
        reason: '浮层全关后键盘所有权必须回到视频，否则查词一次后空格失灵');
  });

  test('点视频区收回键盘焦点（焦点意外丢失后的恢复路径）', () {
    final int handler = src.indexOf('void _handleVideoPointerUp(');
    expect(handler, greaterThanOrEqualTo(0));
    final String body = src.substring(
        handler, src.indexOf('bool _isVideoChromePointer(', handler));
    expect(body, contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
        reason: '点视频画面必须收回键盘（与原生播放器一致）');
    // 「查词浮层期间除外」现在由 _canOwnVideoFocus 的统一门控保证，不再由调用点手写。
    expect(src, contains('_hasVisiblePopup'), reason: '判据必须仍然考虑查词浮层可见性');
  });

  test('窗口重新激活（切窗返回）时按统一判据收回焦点', () {
    final int lifecycle = src.indexOf('void didChangeAppLifecycleState(');
    expect(lifecycle, greaterThanOrEqualTo(0));
    final String body = src.substring(
        lifecycle, src.indexOf('Future<void> _init()', lifecycle));
    expect(
        body, contains('_focusOwnership.reclaim(FocusReclaimCause.appResumed)'),
        reason: 'resumed 时若键盘所有权属本页必须收回焦点（TODO-040 ①切窗返回）');
    // appResumed 是全局回调，判据里必须有「所有者路由 isCurrent」这一层，
    // 否则会夺走压在本页上方对话框的键盘。
    expect(src, contains('owner.isCurrent'),
        reason: 'appResumed 判据必须确认本页仍是当前路由');
  });
}
