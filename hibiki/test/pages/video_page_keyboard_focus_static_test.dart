import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：确保视频页修复「导入着色器后空格失灵」的接线不被回退。
///
/// 根因：media_kit 的 `Video` 自带 FocusNode + 内置快捷键（空格=播放/暂停）。覆盖层
/// （对话框 / bottom sheet / FilePicker 系统对话框）会夺走窗口键盘焦点，关闭后 Flutter
/// 不会自动把焦点还给 Video → 空格失灵。修复是把焦点节点提到 State 持有、传给 Video，
/// 并在每个覆盖层关闭后 [requestFocus]（_refocusVideo）。本测试静态扫描这些不变式，
/// 因为焦点行为在 widget 测试里难稳定复现（依赖真实焦点遍历 / 平台文件选择器）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
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

    expect(body, contains('WidgetsBinding.instance.addPostFrameCallback'));
    expect(body, contains('_refocusVideo();'),
        reason: '非全屏进入视频页后若没有主动聚焦，空格会冒泡到全局 DoNothingIntent 而不是播放/暂停');
  });

  test('存在 _refocusVideo 归还焦点的 helper', () {
    expect(src, contains('void _refocusVideo()'),
        reason: '应有统一的 _refocusVideo() 在覆盖层关闭后归还焦点');
    expect(src, contains('_videoFocusNode.requestFocus()'),
        reason: '_refocusVideo 必须 requestFocus');
  });

  test('每个会夺焦的覆盖层关闭后都归还焦点', () {
    // TODO-274：倍速/音轨/字幕源/设置四菜单迁到 side panel，关闭走 [_hideVideoSidePanel]
    // （内含 _refocusVideo()）；TODO-638 剧集列表也改 push-aside 侧栏（关闭走
    // [_closeEpisodeList]，内含 _refocusVideo()），视频页已无 modal bottom sheet。
    // 统计所有 _refocusVideo() 调用点覆盖 side panel / push-aside 列表关闭 + 各对话框/picker。
    final int refocusCalls = '_refocusVideo();'.allMatches(src).length;
    expect(refocusCalls, greaterThanOrEqualTo(6),
        reason:
            '所有夺焦覆盖层（side panel + push-aside 列表 + 着色器/Jimaku/picker）关闭后都应 _refocusVideo()');
    // side panel 关闭汇聚点 [_hideVideoSidePanel] 必须归还键盘焦点。
    final int hideIdx = src.indexOf('void _hideVideoSidePanel() {');
    expect(hideIdx, greaterThanOrEqualTo(0),
        reason: 'side panel 菜单需有统一关闭汇聚点 _hideVideoSidePanel');
    final int hideEnd = src.indexOf('\n  }', hideIdx);
    expect(src.substring(hideIdx, hideEnd).contains('_refocusVideo()'), isTrue,
        reason: 'side panel 关闭后必须归还键盘焦点');
    // TODO-638：剧集列表 push-aside 关闭汇聚点 [_closeEpisodeList] 也必须归还键盘焦点
    // （取代旧 modal sheet whenComplete 的 _videoSheetOpen 复位 + refocus 闭包）。
    final int epIdx = src.indexOf('void _closeEpisodeList() {');
    expect(epIdx, greaterThanOrEqualTo(0),
        reason: '剧集列表 push-aside 需有统一关闭汇聚点 _closeEpisodeList');
    final int epEnd = src.indexOf('\n  }', epIdx);
    expect(src.substring(epIdx, epEnd).contains('_refocusVideo()'), isTrue,
        reason: '剧集列表 push-aside 关闭后必须归还键盘焦点');
  });

  // ── TODO-040/042：三类「快捷键失灵」的统一修复接线 ────────────────────────

  test('全屏期窗口侧 controls 必须经 VideoControlsFocusGate 卸载（根因修复）', () {
    // 根因：窗口/全屏两套 controls 共用 _videoFocusNode，退全屏时全屏侧 Focus
    // dispose 把节点摘成永久孤儿 → 此后所有 _refocusVideo() 静默失效（行为复现见
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
    expect(body, contains('_refocusVideo()'), reason: '重挂后必须归还键盘焦点');
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
    expect(body, contains('_refocusVideo();'),
        reason: '浮层全关后键盘所有权必须回到视频，否则查词一次后空格失灵');
  });

  test('点视频区收回键盘焦点（焦点意外丢失后的恢复路径）', () {
    final int handler = src.indexOf('void _handleVideoPointerUp(');
    expect(handler, greaterThanOrEqualTo(0));
    final String body = src.substring(
        handler, src.indexOf('bool _isVideoChromePointer(', handler));
    expect(body, contains('if (!_hasVisiblePopup) _refocusVideo();'),
        reason: '点视频画面必须收回键盘（与原生播放器一致），查词浮层期间除外');
  });

  test('窗口重新激活（切窗返回）时按统一判据收回焦点', () {
    expect(src, contains('void _reclaimVideoFocusIfOwned()'),
        reason: '应有统一的「视频应当持有键盘」回收判据');
    final int lifecycle = src.indexOf('void didChangeAppLifecycleState(');
    expect(lifecycle, greaterThanOrEqualTo(0));
    final String body = src.substring(
        lifecycle, src.indexOf('Future<void> _init()', lifecycle));
    expect(body, contains('_reclaimVideoFocusIfOwned();'),
        reason: 'resumed 时若键盘所有权属本页必须收回焦点（TODO-040 ①切窗返回）');
  });
}
