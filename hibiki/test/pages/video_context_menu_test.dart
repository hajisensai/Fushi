import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：桌面右键上下文菜单（TODO-048c）。整页 widget 测试依赖真实 libmpv
/// player（测试宿主无 libmpv，`load()` / `Player` 构造即抛），故按既有视频守卫范式
/// （见 video_player_keyboard_static_test.dart）在源码层钉死结构不变量。
void main() {
  // TODO-590 batch16: 右键触发点 onSecondaryTapUp 在 _buildVideoControlsInner、
  // 截断锚点 _buildVideoBody 都已搬到 video_hibiki/layout.part.dart，故改读「主壳 + 全部
  // part」合并语料；_handleSecondaryTap / _buildVideoContextMenuItems 仍在主壳，切片照旧。
  final String page = readVideoHibikiSource();

  group('右键菜单触发与门控', () {
    test('视频控制层挂 onSecondaryTapUp（右键触发）', () {
      expect(page.contains('onSecondaryTapUp:'), isTrue,
          reason: '桌面右键须经 GestureDetector.onSecondaryTapUp 进入菜单');
      expect(
          page.contains('_handleSecondaryTap(details.globalPosition)'), isTrue,
          reason: '右键松手处的 globalPosition 作 showMenu 锚点');
    });

    test('右键菜单仅桌面（移动端门控 no-op）', () {
      // _handleSecondaryTap 第一行必是桌面门控，移动端不弹菜单。
      final int idx = page.indexOf('void _handleSecondaryTap(');
      expect(idx, greaterThan(0), reason: '必须有 _handleSecondaryTap 入口');
      final String body = page.substring(idx, idx + 400);
      expect(body.contains('if (!_isDesktopVideoControls) return;'), isTrue,
          reason: '移动端无右键，须 _isDesktopVideoControls 门控双保险');
    });

    test('菜单锚定 _videoControlsContext（全屏路由内可弹）', () {
      final int idx = page.indexOf('void _handleSecondaryTap(');
      final String body = page.substring(idx, idx + 1800);
      expect(body.contains('_videoControlsContext'), isTrue,
          reason: 'showMenu 须用 controls 子树 context，全屏路由复用同一 builder 才能弹出');
      expect(body.contains('showMenu<VoidCallback>('), isTrue,
          reason: '用 showMenu 弹 PopupMenu，自带锚点定位');
      expect(body.contains('RelativeRect.fromLTRB('), isTrue,
          reason: '右键位置须转成 RelativeRect 作菜单锚点');
    });

    // BUG-260：界面缩放（appUiScale ≠ 1）下右键菜单落点必须与鼠标对齐。
    //
    // 根因：视频页整页被 [HibikiAppUiScaleNeutralizer] 中和回净缩放=1 的真实视口空间，
    // 故 controls 盒子在真实屏幕坐标系；而 showMenu 的 RelativeRect 解读为路由 Overlay
    // 坐标系（在全局 HibikiAppUiScale 的 FittedBox 缩放画布内）。两套坐标差 factor=scale。
    // 修复：用 `localToGlobal(..., ancestor: overlay)` 把右键点沿真实渲染变换链映射到
    // showMenu 所用 Overlay 的 RenderBox 坐标系——FittedBox 缩放被 ancestor 变换自动吸收，
    // 与查词浮层 charRect 走同一「锚点跟随真实渲染几何」范式，对任意 scale 自洽无残差。
    test('菜单锚点用 Overlay 相对变换吃掉界面缩放残差（BUG-260）', () {
      final int idx = page.indexOf('void _handleSecondaryTap(');
      expect(idx, greaterThan(0));
      final String body = page.substring(idx, idx + 1800);
      // 取 showMenu 实际使用的 Navigator(rootNavigator:false) 的 Overlay RenderBox。
      expect(
          body.contains('Overlay.of(ctx).context.findRenderObject()'), isTrue,
          reason: '锚点须落在 showMenu 所用 Overlay 的坐标系，故取该 Overlay 的 RenderBox');
      // 用 ancestor 变换把右键点映射到 Overlay 空间，沿真实渲染链吸收 FittedBox 缩放。
      expect(body.contains('ancestor: overlayObject'), isTrue,
          reason: 'localToGlobal(..., ancestor: overlay) 让锚点与菜单宿主同坐标系（吃掉缩放残差）');
      // RelativeRect 须基于 Overlay 尺寸 + 映射后的 anchor，而非中和后真实视口的尺寸/local。
      expect(body.contains('overlaySize.width - anchor.dx'), isTrue,
          reason: 'right/bottom 须以 Overlay 尺寸算（缩放画布空间），与 anchor 同系');
      // 不得回退到旧的「直接拿 controls 盒子真实 local 当锚点」写法（那正是 BUG-260 偏移源）。
      expect(body.contains('renderObject.size.width - local.dx'), isFalse,
          reason: '旧的真实空间 local 锚点会偏离鼠标 factor≈scale，必须已替换');
    });

    test('菜单关闭后归还键盘焦点', () {
      final int idx = page.indexOf('void _handleSecondaryTap(');
      final String body = page.substring(idx, idx + 2000);
      expect(body.contains('_refocusVideo()'), isTrue,
          reason: '覆盖层夺焦后不会自动归还，菜单关闭须 _refocusVideo');
    });
  });

  group('菜单项复用既有动作（不重造）', () {
    // 取 _buildVideoContextMenuItems 方法体断言各项动作都接到既有 helper。
    final int idx = page.indexOf(
      'List<PopupMenuEntry<VoidCallback>> _buildVideoContextMenuItems(',
    );
    late final String items;
    setUpAll(() {
      expect(idx, greaterThan(0), reason: '必须有 _buildVideoContextMenuItems');
      // TODO-590 batch16: _buildVideoContextMenuItems 现是主壳最末个方法（其后的
      // _buildVideoBody 已搬到 layout.part，在合并语料里反而排在它之后），故改用方法自身
      // 的 2 空格闭合作截断终点（菜单项列表内的 `}` 都缩进更深，不会误命中），仍覆盖整个
      // 菜单项列表、不被新增菜单项 / 注释挤出（TODO-389）。
      final int end = page.indexOf('\n  }', idx);
      expect(end, greaterThan(idx),
          reason: '_buildVideoContextMenuItems 须有 2 空格闭合作截断终点');
      items = page.substring(idx, end);
    });

    test('含播放/暂停', () {
      expect(items.contains('t.video_menu_play_pause'), isTrue);
      expect(items.contains('controller.playOrPause()'), isTrue);
    });

    test('含全屏切换', () {
      expect(items.contains('t.video_menu_fullscreen'), isTrue);
      expect(items.contains('_toggleVideoFullscreen('), isTrue);
    });

    test('含播放速度', () {
      expect(items.contains('t.video_setting_speed'), isTrue);
      expect(items.contains('_showSpeedMenu'), isTrue);
    });

    test('含字幕轨切换', () {
      expect(items.contains('t.video_menu_subtitle_track'), isTrue);
      expect(items.contains('_showSubtitleSourceMenu(controller)'), isTrue);
    });

    test('含字幕列表（TODO-069）', () {
      expect(items.contains('t.video_subtitle_list'), isTrue);
      expect(items.contains('_toggleSubtitleJumpList'), isTrue);
    });

    test('含音轨切换', () {
      expect(items.contains('t.video_audio_track'), isTrue);
      expect(items.contains('_showAudioTrackMenu(controller)'), isTrue);
    });

    test('含截图', () {
      expect(items.contains('t.video_screenshot'), isTrue);
      expect(items.contains('_saveScreenshot'), isTrue);
    });

    test('含片段导出且紧挨截图，文案保持源片段语义', () {
      final int screenshotIdx = items.indexOf('t.video_screenshot');
      final int clipIdx = items.indexOf('t.video_clip_export');
      final String formerPixelCaptureTerm =
          String.fromCharCodes(<int>[0x5f55, 0x5c4f]);
      final String formerEnglishTerm =
          <String>['screen', 'recording'].join(' ');
      expect(screenshotIdx, greaterThanOrEqualTo(0), reason: '菜单应含截图');
      expect(clipIdx, greaterThanOrEqualTo(0), reason: '菜单应含片段导出');
      expect(clipIdx, greaterThan(screenshotIdx),
          reason: '片段导出应放在截图之后，和截图入口相邻');
      expect(items.contains('_toggleClipExport'), isTrue,
          reason: '右键菜单须复用页面片段导出状态机');
      expect(items.contains(formerPixelCaptureTerm), isFalse,
          reason: 'TODO-434 菜单文案应保持源片段导出语义');
      expect(items.contains(formerEnglishTerm), isFalse,
          reason: 'TODO-434 menu copy should keep source clip semantics');
    });

    test('含锁定 / 沉浸模式（TODO-101）', () {
      expect(items.contains('t.video_menu_lock'), isTrue);
      expect(items.contains('_toggleImmersiveLock'), isTrue);
    });

    // TODO-389：右键菜单补「设置」项，打开视频设置侧栏（与右侧 rail 的
    // VideoControlButton.settings 走同一个 _showPlayerSettings）。
    test('含设置（TODO-389，打开视频设置侧栏）', () {
      expect(items.contains('t.video_settings_title'), isTrue,
          reason: '设置项标签复用既有 video_settings_title（与侧栏标题同 key）');
      expect(items.contains('_showPlayerSettings'), isTrue,
          reason: '设置项须接入既有 _showPlayerSettings 入口（不重造打开逻辑）');
      expect(items.contains('Icons.tune'), isTrue,
          reason: '图标用 Icons.tune，与 VideoControlButton.settings 控制按钮保持一致');
    });

    // BUG-261: 着色器「对比原画」项已从右键菜单移除（用户要求），改只走 `C` 快捷键 /
    // 设置页进入。原「对比仅在启用着色器时出现」用例随之删除，由下面的不变量守住
    // 「右键菜单不再含对比项」。
    test('不再含着色器对比项（BUG-261，改走 C 快捷键 / 设置）', () {
      expect(items.contains('Icons.compare'), isFalse,
          reason: '右键菜单已移除「对比原画」项（BUG-261）');
      expect(items.contains('t.video_shader_compare'), isFalse,
          reason: '右键菜单不再引用 video_shader_compare（i18n key 已随项移除）');
    });
  });
}
