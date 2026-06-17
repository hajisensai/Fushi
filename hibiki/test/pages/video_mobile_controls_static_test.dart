import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：确保「移动端视频播放页有字幕/音轨/设置（剧集）按钮」的接线不被回退。
///
/// 根因：字幕/音轨切换按钮原本只配在 [MaterialDesktopVideoControlsThemeData] 的
/// topButtonBar（桌面专属）。media_kit 的 [AdaptiveVideoControls] 按平台**互斥**择一
/// 渲染——桌面读 Desktop 主题，移动（Android/iOS）渲染 [MaterialVideoControls] 读
/// [MaterialVideoControlsThemeData]。移动端从未配置后者 → 用默认控制条，没有字幕/音轨
/// 入口；且移动端全屏走 media_kit 独立 root 路由、丢掉 Scaffold AppBar，连设置/剧集
/// 也不可达。修复是新增 [_mobileControlsTheme] 把这些按钮放进移动 controls 的
/// topButtonBar，并让 [_buildVideoBody] 同时嵌套两套主题。
///
/// 用静态扫描守卫，因为按平台分流的真实 controls 渲染在 widget 测试里依赖 host 平台、
/// 难稳定复现移动分支。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final File themePair = File(
    'lib/src/media/video/video_controls_theme_pair.dart',
  );

  late String src;
  late String themePairSrc;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    expect(themePair.existsSync(), isTrue,
        reason: '视频 controls 主题配对 helper 应存在');
    src = page.readAsStringSync();
    themePairSrc = themePair.readAsStringSync();
  });

  test('存在移动端控制主题 _mobileControlsTheme', () {
    expect(
      src,
      contains('MaterialVideoControlsThemeData _mobileControlsTheme('),
      reason: '应有移动端 controls 主题，否则 AdaptiveVideoControls 在移动端用默认无按钮控制条',
    );
  });

  test('_buildVideoBody 同时嵌套移动与桌面两套 controls 主题', () {
    // 两套主题互斥被对应平台读取，必须都包上才能桌面/移动/全屏全覆盖。
    expect(
      src,
      contains('VideoControlsThemePair('),
      reason: '页面必须通过 VideoControlsThemePair 同时接入移动与桌面 controls 主题',
    );
    expect(
      themePairSrc,
      contains('MaterialVideoControlsTheme('),
      reason: 'helper 必须包 MaterialVideoControlsTheme（移动端 controls 读取）',
    );
    expect(
      themePairSrc,
      contains('MaterialDesktopVideoControlsTheme('),
      reason: 'helper 必须保留 MaterialDesktopVideoControlsTheme（桌面端 controls 读取）',
    );
    // 移动主题的 normal/fullscreen 都用 _mobileControlsTheme（全屏丢 AppBar 也可达）。
    expect(src, contains('_currentVideoControlsTheme('),
        reason: '页面应通过同一个 helper 产出移动/桌面 controls 主题');
    expect(
      src,
      contains('mobile: controlsTheme.mobile'),
      reason: '页面应把当前 layout 产出的 mobile controls 主题传给 VideoControlsThemePair',
    );
    expect(
      src,
      contains('desktop: controlsTheme.desktop'),
      reason: '页面应把当前 layout 产出的 desktop controls 主题传给 VideoControlsThemePair',
    );
    expect(
      themePairSrc,
      contains('fullscreen: mobile'),
      reason: '移动主题 normal/fullscreen 必须同源，保证全屏可达',
    );
  });

  test('移动 controls 主题含字幕/音轨入口；设置经可配置右侧 rail', () {
    // 截取 _mobileControlsTheme 方法体，断言入口都在其中，避免误把桌面主题命中算进来。
    final int start = src.indexOf(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: '应能定位 _mobileControlsTheme 方法');
    final int end = src.indexOf(
      'List<VideoControlItem> _slotChipItems(',
      start,
    );
    expect(end, greaterThan(start), reason: '应能界定 _mobileControlsTheme 方法体范围');
    final String body = src.substring(start, end);

    expect(
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topLeft[\s\S]*?desktop:\s*false')
          .hasMatch(body),
      isTrue,
      reason: '移动 controls 应使用真实 topLeft slot 渲染顶栏按钮',
    );
    expect(
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight[\s\S]*?desktop:\s*false')
          .hasMatch(body),
      isTrue,
      reason: '移动 controls 应使用真实 topRight slot 渲染字幕/音轨/截图等入口',
    );
    expect(body, contains('desktop: false'),
        reason: '移动主题调用 slot renderer 时必须走 mobile 按钮分支');
    expect(src.contains('case VideoControlItem.subtitleTrack:'), isTrue,
        reason: '字幕轨入口应由数据化 VideoControlItem 承载');
    expect(src.contains('_showSubtitleSourceMenu(controller)'), isTrue,
        reason: '字幕轨入口激活后仍应打开字幕菜单');
    expect(src.contains('case VideoControlItem.audioTrack:'), isTrue,
        reason: '音轨入口应由数据化 VideoControlItem 承载');
    expect(src.contains('_showAudioTrackMenu(controller)'), isTrue,
        reason: '音轨入口激活后仍应打开音轨菜单');
    expect(src.contains('case VideoControlItem.episodeList:'), isTrue,
        reason: '剧集入口应由数据化 VideoControlItem 承载');
    expect(src.contains('_showEpisodeList();'), isTrue,
        reason: '剧集入口激活后仍应打开剧集列表');
    // BUG-248B / TODO-274：设置（tune）已从 topButtonBar 移出（与桌面一致），改由可配置
    // 的右侧 rail settings 按钮（VideoControlButton.settings → _activateVideoControlButton
    // → _showPlayerSettings）承载，全屏复用同一 builder 故仍可达。故此处不再断言
    // topButtonBar 含设置按钮，而验证设置走数据化按钮模型。
    expect(
      src,
      contains('case VideoControlButton.settings:'),
      reason: '设置入口经可配置 VideoControlButton.settings 承载',
    );
    expect(
      src,
      contains('_showPlayerSettings(sourceSlot: sourceSlot)'),
      reason: '可配置 settings 按钮激活时仍打开 _showPlayerSettings',
    );
    expect(src.contains('MaterialCustomButton('), isTrue,
        reason: '移动端 slot 自定义按钮应用 MaterialCustomButton');
    expect(body, contains('bottomButtonBar: <Widget>['),
        reason: '移动 controls 应继续提供共享底栏');
  });
}
