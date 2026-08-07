import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-823 守卫：本地换集前必须先 pause 旧 controller，杜绝过渡期双音轨。
///
/// 本地播放列表换集走 `pushReplacement` 到兄弟集单视频页。Flutter 语义下旧路由要等
/// 新页入场过渡动画结束才被移除并 `dispose`（旧页 dispose 里才 `_controller?.dispose()`
/// 停播）。过渡窗口内旧页 controller 仍在放音，而新页 `_init` 已新建 player 并 autoPlay
/// 起播 → 两条音轨短暂同响（观感：切集时上一个视频还在播）。
///
/// 修复：本地分支在 `pushReplacement` 前 `await _controller?.pause()`，音轨即刻静音，
/// 不再依赖延迟 dispose。远端换集复用同一 player + open() 顶替，天然不双开，故只本地
/// 分支处理。撤掉这个 pause 或把它挪到 pushReplacement 之后即转红。
void main() {
  final File episodePart =
      File('lib/src/pages/implementations/video_fushi/episode.part.dart');

  late String switchBody;

  setUpAll(() {
    expect(episodePart.existsSync(), isTrue);
    final String src = episodePart.readAsStringSync().replaceAll('\r\n', '\n');
    final int start = src.indexOf('Future<void> _switchEpisode(');
    expect(start, isNonNegative, reason: '找不到 _switchEpisode 方法');
    // 方法体终点锚：下一个 `\n  /// ` 文档注释（_showEpisodeList 前）。
    final int end = src.indexOf('\n  /// ', start);
    expect(end, greaterThan(start), reason: '找不到 _switchEpisode 方法体终点');
    switchBody = src.substring(start, end);
  });

  test('local episode switch pauses old controller before pushReplacement', () {
    final int pauseIdx = switchBody.indexOf('await _controller?.pause();');
    final int pushIdx = switchBody.indexOf('navigator.pushReplacement');
    expect(pushIdx, isNonNegative, reason: '本地换集应走 pushReplacement');
    expect(pauseIdx, isNonNegative,
        reason: '换集前必须 await _controller?.pause() 停旧音轨（BUG-823）');
    expect(pauseIdx, lessThan(pushIdx),
        reason: 'pause 必须在 pushReplacement 之前，否则过渡期旧音轨仍在放');
  });

  test('pause sits in the local branch, after the remote early return', () {
    // 远端分支复用同一 player，靠 open() 顶替天然不双开；pause 只属本地分支，必须落在
    // `_loadRemoteEpisode(... return;` 之后，避免误伤远端换流路径。
    final int remoteReturnIdx =
        switchBody.indexOf('_loadRemoteEpisode(index, startIntent: intent)');
    final int pauseIdx = switchBody.indexOf('await _controller?.pause();');
    expect(remoteReturnIdx, isNonNegative, reason: '远端分支应走 _loadRemoteEpisode');
    expect(pauseIdx, greaterThan(remoteReturnIdx),
        reason: 'pause 必须在远端早退之后，只作用于本地换集分支');
  });
}
