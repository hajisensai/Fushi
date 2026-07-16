import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-839 守卫：全屏下连播/换集不得漏栈旧集页（否则 ESC 需逐层退）。
///
/// 根因：全屏播放时 app 全屏路由被推到 **root navigator**（`fullscreen.part.dart` 的
/// `_pushNeutralizedVideoFullscreen`，`rootNavigator: true`），压在剧集页之上。本地换集
/// 走 `navigator.pushReplacement`——它替换的是该 navigator 的**栈顶路由**。若换集前不先退
/// 全屏路由，`pushReplacement` 会替换掉栈顶的全屏路由、把本集页漏在栈里，每连播一集残留
/// 一层 → 按 ESC 一层层回退而非退出。
///
/// 修复不变量：
/// ① `_switchEpisode` 本地分支在 `pushReplacement` **之前**先 `_exitVideoFullscreen`
///    退全屏路由，让剧集页回到栈顶，pushReplacement 正确替换本集（栈恒平、ESC 一次退出）；
///    并把换集前是否全屏（`wasFullscreen`）透传给新页 `initialFullscreen`。
/// ② `VideoHibikiPage` / `neutralized` 承载 `initialFullscreen` 字段；新页首帧就绪后经
///    `_scheduleInitialFullscreenIfNeeded` 重进全屏（快/慢两条就绪路径都触发），保持连播
///    全屏沉浸。
///
/// 撤掉任一环（去掉换集前退全屏、把 exit 挪到 push 之后、断开 initialFullscreen 透传/重进）
/// 即转红。行为级复现需 media_kit + 全屏路由 + 真 navigator 栈，故守在最强可落地的源码层。
void main() {
  final File episodePart =
      File('lib/src/pages/implementations/video_hibiki/episode.part.dart');
  final File fullscreenPart =
      File('lib/src/pages/implementations/video_hibiki/fullscreen.part.dart');
  final File pageFile =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String switchBody;
  late String fullscreenSrc;
  late String pageSrc;

  setUpAll(() {
    for (final File f in <File>[episodePart, fullscreenPart, pageFile]) {
      expect(f.existsSync(), isTrue, reason: '缺文件 ${f.path}');
    }
    final String episodeSrc =
        episodePart.readAsStringSync().replaceAll('\r\n', '\n');
    final int start = episodeSrc.indexOf('Future<void> _switchEpisode(');
    expect(start, isNonNegative, reason: '找不到 _switchEpisode 方法');
    // 方法体终点锚：下一个 `\n  /// ` 文档注释（_showEpisodeList 前）。
    final int end = episodeSrc.indexOf('\n  /// ', start);
    expect(end, greaterThan(start), reason: '找不到 _switchEpisode 方法体终点');
    switchBody = episodeSrc.substring(start, end);

    fullscreenSrc = fullscreenPart.readAsStringSync().replaceAll('\r\n', '\n');
    pageSrc = pageFile.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('换集本地分支：pushReplacement 前先退全屏路由', () {
    final int exitIdx = switchBody.indexOf('_exitVideoFullscreen(');
    final int pushIdx = switchBody.indexOf('navigator.pushReplacement');
    expect(pushIdx, isNonNegative, reason: '本地换集应走 pushReplacement');
    expect(exitIdx, isNonNegative,
        reason: '换集前必须先 _exitVideoFullscreen 退全屏路由（BUG-839）');
    expect(exitIdx, lessThan(pushIdx),
        reason: '退全屏必须在 pushReplacement 之前，否则会误替换栈顶全屏路由、漏栈旧集页');
  });

  test('退全屏只作用于本地分支（在远端早退之后）', () {
    final int remoteReturnIdx =
        switchBody.indexOf('_loadRemoteEpisode(index, startIntent: intent)');
    final int exitIdx = switchBody.indexOf('_exitVideoFullscreen(');
    expect(remoteReturnIdx, isNonNegative, reason: '远端分支应走 _loadRemoteEpisode');
    expect(exitIdx, greaterThan(remoteReturnIdx),
        reason: '退全屏必须在远端早退之后，只作用于本地换集分支（远端原地换流不压栈）');
  });

  test('换集把换集前全屏态透传给新页 initialFullscreen', () {
    expect(switchBody.contains('wasFullscreen'), isTrue,
        reason: '换集应捕获换集前是否全屏（wasFullscreen）');
    expect(switchBody.contains('initialFullscreen: wasFullscreen'), isTrue,
        reason: '新页 neutralized 必须收到 initialFullscreen: wasFullscreen，才能重进全屏');
  });

  test('VideoHibikiPage / neutralized 承载 initialFullscreen 字段并透传', () {
    expect(pageSrc.contains('final bool initialFullscreen;'), isTrue,
        reason: 'VideoHibikiPage 应有 initialFullscreen 字段');
    expect(pageSrc.contains('this.initialFullscreen = false'), isTrue,
        reason: '默认构造器应默认 initialFullscreen=false（首开不自动全屏）');
    // neutralized 工厂必须把入参透传给构造器，否则换集标志到不了新页 State。
    expect(pageSrc.contains('bool initialFullscreen = false'), isTrue,
        reason: 'neutralized 工厂应有 initialFullscreen 形参');
    expect(pageSrc.contains('initialFullscreen: initialFullscreen'), isTrue,
        reason: 'neutralized 必须把 initialFullscreen 透传给 VideoHibikiPage');
  });

  test('新页首帧就绪的两条路径都触发重进全屏', () {
    // 慢路径 [_promoteVideoReady] 与快路径（isInitialVideoOpen 直接翻真）都必须调
    // _scheduleInitialFullscreenIfNeeded，否则本地文件（快路径）换集不会重进全屏。
    final int scheduleCalls =
        '_scheduleInitialFullscreenIfNeeded()'.allMatches(pageSrc).length;
    expect(scheduleCalls, greaterThanOrEqualTo(2),
        reason: '快/慢两条就绪路径都要触发重进全屏（至少 2 处调用）');
  });

  test('重进全屏方法存在且一次性、带上限防死循环', () {
    expect(fullscreenSrc.contains('void _scheduleInitialFullscreenIfNeeded()'),
        isTrue,
        reason: '应在 fullscreen 域定义 _scheduleInitialFullscreenIfNeeded');
    expect(fullscreenSrc.contains('_didInitialFullscreen'), isTrue,
        reason: '重进全屏必须一次性（_didInitialFullscreen 闸门）');
    expect(fullscreenSrc.contains('_initialFullscreenRetries'), isTrue,
        reason: 'controls 未就绪时的重试必须有上限（_initialFullscreenRetries），杜绝死循环');
    expect(fullscreenSrc.contains('_pushNeutralizedVideoFullscreen('), isTrue,
        reason: '就绪后应经 _pushNeutralizedVideoFullscreen 重进全屏路由');
  });
}
