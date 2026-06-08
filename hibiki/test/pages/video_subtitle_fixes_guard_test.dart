import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for the 2026-06-08 video subtitle fix batch. media_kit cannot
/// run headless and OS-level drag/focus can't be widget-tested, so each fix
/// locks its call-site invariant in `video_hibiki_page.dart` rather than driving
/// a real player.
///
/// - BUG-130: 点击画面不暂停（media_kit 桌面 `playAndPauseOnTap` 默认 false）。
/// - BUG-131: 导入字幕后键盘失灵（加载遮罩夺焦后未归还）。
/// - BUG-132: 退出后导入字幕丢（播放列表恢复不按路径加载 app 文档目录里的导入文件）。
/// - BUG-133: 视频画面拖入字幕无反应（窗口模式缺页级拖放目标）。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('BUG-130: 桌面控制条启用单击播放/暂停', () {
    final String body = region(
      'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(src.contains('playAndPauseOnTap: true'), isTrue,
        reason: '桌面单击画面必须播放/暂停，否则点画面毫无反应（BUG-130）');
    expect(body.contains('playAndPauseOnTap: true'), isTrue,
        reason: 'playAndPauseOnTap 必须设在桌面控制主题里');
  });

  test('BUG-131: 关闭字幕加载遮罩后归还焦点给视频', () {
    final String body = region(
      'void _hideSubtitleLoadingOverlay() {',
      'Future<bool> _selectSubtitleSource(',
    );
    expect(body.contains('_refocusVideo()'), isTrue,
        reason: '加载遮罩是模态对话框、会夺焦；关闭后必须主动把焦点还给 Video，'
            '否则空格等快捷键失灵（BUG-131）');
    expect(body.contains('addPostFrameCallback'), isTrue,
        reason: '应在下一帧归还焦点（让 pop 自身焦点变更先落定）');
  });

  test('BUG-132: 恢复字幕源时对导入的外挂文件按路径直接加载', () {
    final String body = region(
      'Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>',
      'SubtitleSource? _firstMatching(',
    );
    expect(body.contains('isImportedExternalSubtitlePath('), isTrue,
        reason: 'app 文档目录里的导入字幕不在剧集目录、listAllSubtitleSources 扫不到，'
            '必须按持久化的绝对路径直接加载（BUG-132）');
    expect(body.contains('File(persisted).existsSync()'), isTrue,
        reason: '按路径加载前要确认文件仍在磁盘上');
    // 该捷径必须排在同目录枚举之前。
    final int shortcut = body.indexOf('isImportedExternalSubtitlePath(');
    final int enumerate = body.indexOf('listAllSubtitleSources(');
    expect(shortcut, lessThan(enumerate),
        reason: '按路径直接加载应先于 listAllSubtitleSources 同目录枚举');
  });

  test('BUG-133: 视频页有页级拖放目标 + 导入去重防护', () {
    // 页级拖放目标（窗口模式可靠收拖放；内层那个供全屏用）。
    expect(src.contains('Widget _pageDropTarget('), isTrue,
        reason: '窗口模式需在页面顶层挂拖放目标，内层 media_kit controls 里的实测无反应（BUG-133）');
    final String pageDrop = region(
      'Widget _pageDropTarget(',
      'Widget _buildVideoBody(',
    );
    expect(pageDrop.contains('HibikiFileDropTarget('), isTrue);
    expect(pageDrop.contains('_importExternalSubtitle('), isTrue);

    // 去重防护：页级 + 内层两个目标可能对同一次拖放都触发。
    final String importOuter = region(
      'Future<void> _importExternalSubtitle(',
      'Future<void> _importExternalSubtitleInner(',
    );
    expect(importOuter.contains('_subtitleImportsInFlight'), isTrue,
        reason: '同一 srcPath 在途时必须忽略二次调用，避免重复导入/重复提示（BUG-133）');
  });

  test('视频通知走 mpv 式角标 OSD，不再用 Material SnackBar', () {
    expect(src.contains('void _showOsd('), isTrue,
        reason: '视频内通知应走左上角 OSD（_showOsd），取代从底部弹出遮挡控制条的 SnackBar');
    expect(src.contains('showSnackBar('), isFalse,
        reason: '视频页不应再有 showSnackBar(...) 调用——通知统一走 _showOsd（mpv 式角标）');
    final int osdStart = src.indexOf('Widget _buildOsdOverlay() {');
    expect(osdStart, greaterThanOrEqualTo(0),
        reason: 'OSD 层 _buildOsdOverlay 必须存在并挂进 controls overlay');
    final String osd = src.substring(osdStart);
    expect(osd.contains('IgnorePointer'), isTrue,
        reason: 'OSD 必须 IgnorePointer 包裹，绝不拦截点击（单击暂停/拖放/字幕查词）');
    expect(osd.contains('_osdNotifier'), isTrue,
        reason: 'OSD 监听 _osdNotifier 渲染当前消息');
  });
}
