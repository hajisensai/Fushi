import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频字幕列表侧栏只保留**一条**标题（BUG-245 / TODO-280）。
///
/// 根因：[_buildVideoSidePanelOverlay] 曾对除 settings 外所有 `_VideoSidePanelKind`
/// 一律套 [VideoTranslucentSidePanel]（自带「标题 + 关闭」标题栏），但字幕列表用的
/// [VideoSubtitleJumpPanel] 自带完整 header（标题 + 字号步进 + 自动滚动 + 关闭）——
/// 外壳标题 + 面板标题叠成两条。修复让 subtitleList 走 bypass 分支（像 settings 那样）：
/// 不套 [VideoTranslucentSidePanel]，直接返回 [_buildSubtitleListSidePanel]，只补外层
/// [Align]/[SafeArea]/[Padding] 保留右贴边/安全区定位。
///
/// media_kit controls 跑不了 headless，按平台分流的真实侧栏渲染难稳定复现，故锁源码
/// 结构不变量（与既有 video 守卫范式一致）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  /// 截取 [_buildVideoSidePanelOverlay] 方法体（到下一个 `_buildSubtitleListSidePanel`
  /// 定义为止，足够覆盖整个 builder）。
  String overlayBody() {
    final int start = src.indexOf(
      'Widget _buildVideoSidePanelOverlay(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有 _buildVideoSidePanelOverlay 方法');
    final int end = src.indexOf(
      'Widget _buildSubtitleListSidePanel(',
      start,
    );
    expect(end, greaterThan(start),
        reason: '需有 _buildSubtitleListSidePanel 作为 overlay 段终点');
    return src.substring(start, end);
  }

  test('overlay 对 subtitleList 走 bypass 分支（不套 VideoTranslucentSidePanel）', () {
    final String body = overlayBody();
    final int branchIdx =
        body.indexOf('if (kind == _VideoSidePanelKind.subtitleList) {');
    expect(branchIdx, greaterThanOrEqualTo(0),
        reason: 'overlay 应对 subtitleList 单独分支（像 settings 那样 bypass 外壳标题栏）');
    final int translucentIdx = body.indexOf('VideoTranslucentSidePanel(');
    expect(translucentIdx, greaterThan(branchIdx),
        reason: 'subtitleList 分支必须在 VideoTranslucentSidePanel 构造之前早返回，'
            '不能再被它套一层标题栏');
    // subtitleList 分支体内（到分支闭合前）不得出现 VideoTranslucentSidePanel。
    final String branchToTranslucent =
        body.substring(branchIdx, translucentIdx);
    expect(branchToTranslucent.contains('VideoTranslucentSidePanel'), isFalse,
        reason: 'subtitleList 分支不应套 VideoTranslucentSidePanel（否则双标题）');
  });

  test('subtitleList 分支直接返回 _buildSubtitleListSidePanel（面板自带标题/关闭）', () {
    final String body = overlayBody();
    final int branchIdx =
        body.indexOf('if (kind == _VideoSidePanelKind.subtitleList) {');
    final int translucentIdx = body.indexOf('VideoTranslucentSidePanel(');
    final String branch = body.substring(branchIdx, translucentIdx);
    expect(branch.contains('_buildSubtitleListSidePanel(controller)'), isTrue,
        reason:
            'subtitleList 分支应直接返回 _buildSubtitleListSidePanel（自带 header + 关闭）');
  });
}
