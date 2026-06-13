import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频字幕列表只保留**一条**标题（BUG-245 / TODO-280；TODO-314 改 push-aside 后续守）。
///
/// 根因（BUG-245 原文）：overlay side-panel 系统曾对除 settings 外所有面板套
/// [VideoTranslucentSidePanel]（自带标题栏），而字幕列表的 [VideoSubtitleJumpPanel] 自带
/// 完整 header → 双标题。
///
/// TODO-314：字幕列表已整体改 push-aside（不再走 overlay），由 [_subtitleJumpSidePanel] /
/// [_videoWithSubtitlePanel] 直接渲染 [VideoSubtitleJumpPanel]（自带 header），不再被
/// [VideoTranslucentSidePanel] 套壳。本守卫改为锁 push-aside 面板**直接**渲染
/// VideoSubtitleJumpPanel、不二次套外壳标题栏，延续「单标题」不变量。
///
/// media_kit controls 跑不了 headless，故锁源码结构不变量（与既有 video 守卫范式一致）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  /// 截取 push-aside 字幕面板列构造器 [_subtitleJumpSidePanel] 方法体。
  String pushAsidePanelBody() {
    final int start = src.indexOf('Widget _subtitleJumpSidePanel(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 push-aside 字幕面板列 _subtitleJumpSidePanel');
    // 到下一个顶层方法定义为止（OSD overlay 构造器）。
    final int end = src.indexOf('Widget _buildOsdOverlay() {', start);
    expect(end, greaterThan(start), reason: '_subtitleJumpSidePanel 应正常闭合');
    return src.substring(start, end);
  }

  test('push-aside 字幕面板直接渲染 VideoSubtitleJumpPanel（自带 header，不双标题）', () {
    final String body = pushAsidePanelBody();
    expect(body.contains('VideoSubtitleJumpPanel('), isTrue,
        reason: 'push-aside 面板应直接渲染 VideoSubtitleJumpPanel（自带 header + 关闭）');
    expect(body.contains('VideoTranslucentSidePanel('), isFalse,
        reason: '字幕面板不应再被 VideoTranslucentSidePanel 套一层标题栏（否则双标题，BUG-245）');
  });

  test('字幕列表已无 overlay 路径（不再走 _buildVideoSidePanelContent 的 subtitleList 分支）',
      () {
    // overlay 内容构造器不应再对 subtitleList 单独分支（该 kind 已删）。
    final int start = src.indexOf('Widget _buildVideoSidePanelContent(');
    expect(start, greaterThanOrEqualTo(0));
    final int end =
        src.indexOf('Widget _buildSubtitleSourcesSidePanel(', start);
    expect(end, greaterThan(start));
    final String contentBody = src.substring(start, end);
    expect(
      contentBody.contains('_VideoSidePanelKind.subtitleList'),
      isFalse,
      reason: 'overlay 内容构造器不应再引用 subtitleList（已改 push-aside）',
    );
  });
}
