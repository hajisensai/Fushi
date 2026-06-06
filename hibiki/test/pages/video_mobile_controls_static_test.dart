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

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
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
      contains('MaterialVideoControlsTheme('),
      reason: '必须包 MaterialVideoControlsTheme（移动端 controls 读取）',
    );
    expect(
      src,
      contains('MaterialDesktopVideoControlsTheme('),
      reason: '必须保留 MaterialDesktopVideoControlsTheme（桌面端 controls 读取）',
    );
    // 移动主题的 normal/fullscreen 都用 _mobileControlsTheme（全屏丢 AppBar 也可达）。
    expect(
      '_mobileControlsTheme(controller)'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: '移动主题 normal 与 fullscreen 都应配 _mobileControlsTheme，保证全屏可达',
    );
  });

  test('移动 controls 主题含字幕/音轨/设置入口', () {
    // 截取 _mobileControlsTheme 方法体，断言三个入口都在其中，避免误把桌面主题的命中算进来。
    final int start = src.indexOf(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: '应能定位 _mobileControlsTheme 方法');
    // 方法体以 'void _showTrackMenu(' 为下界（紧随其后定义）。
    final int end = src.indexOf('void _showTrackMenu(', start);
    expect(end, greaterThan(start), reason: '应能界定 _mobileControlsTheme 方法体范围');
    final String body = src.substring(start, end);

    expect(
      body,
      contains('_showSubtitleSourceMenu(controller)'),
      reason: '移动 controls 应有字幕源入口',
    );
    expect(
      body,
      contains('_showAudioTrackMenu(controller)'),
      reason: '移动 controls 应有音轨切换入口（经共享 _showAudioTrackMenu）',
    );
    expect(
      body,
      contains('onPressed: _showPlayerSettings'),
      reason: '移动端全屏丢 AppBar，设置入口必须进 controls 才可达',
    );
    expect(
      body,
      contains('onPressed: _showEpisodeList'),
      reason: 'playlist 时剧集列表入口也应进 controls（全屏可达）',
    );
    // 用移动版自定义按钮组件 MaterialCustomButton（对应桌面的 MaterialDesktopCustomButton）。
    expect(
      body,
      contains('MaterialCustomButton('),
      reason: '移动端自定义按钮应用 MaterialCustomButton',
    );
  });
}
