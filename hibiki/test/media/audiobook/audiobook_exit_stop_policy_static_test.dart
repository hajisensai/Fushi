import 'package:flutter_test/flutter_test.dart';

import '../../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-702 源码守卫：有声书「退出即停（默认）/ 后台续播（可选）」。
///
/// 行为层 [AudiobookSession.detachReader] / [AudiobookSession.stop] 的语义已由
/// `audiobook_session_test.dart`（detach 不 dispose 控制器、stop dispose 控制器并
/// 清会话）+ `audiobook_dispose_stop_test.dart`（stopPlayback 真释放 native 解码器）
/// 钉死。本守卫钉死阅读器 dispose 把「按偏好分流」接对：
///  - 两条分支都先 [detachReader]（卸回调、不 dispose 控制器）；
///  - 默认（`!appModel.audiobookBackgroundPlay`）追加 `unawaited(stop())` 真止声；
///  - 不得无条件 stop（那会破坏 TODO-291 阶段2 的后台续播）。
///
/// dispose 路径需要完整 WebView reader 栈，host 测试环境跑不起来，故落在源码守卫层
/// （最强可落地层），与 `audio_lifecycle_flush_wiring_static_test.dart` 同范式。
void main() {
  final String src = readReaderPageSource();

  RegExpMatch? disposeBody() => RegExp(
        r'  @override\n  void dispose\(\) \{(.*?)\n    super\.dispose\(\);\n  \}',
        dotAll: true,
      ).firstMatch(src);

  test(
      'reader dispose still detaches the audiobook reader (no controller dispose)',
      () {
    final RegExpMatch? body = disposeBody();
    expect(body, isNotNull, reason: '找不到阅读器 dispose 方法体');
    expect(
      body!.group(1),
      contains('appModel.audiobookSession.detachReader(this);'),
      reason: '退书必须先 detachReader（卸 WebView 侧回调，不 dispose 控制器）',
    );
  });

  test('default (background-play OFF) stops the session on exit (TODO-702)',
      () {
    final RegExpMatch? body = disposeBody();
    expect(body, isNotNull);
    final String dispose = body!.group(1)!;
    // 默认退出即停：按 !audiobookBackgroundPlay 分流，追加 unawaited(stop())。
    expect(
      RegExp(
        // `{` 与 unawaited 之间允许注释；stop() 后允许 .catchError 收口（与本文件
        // 其它 unawaited future 惯例对齐），故不强求紧跟 `);`。
        r'if\s*\(\s*!appModel\.audiobookBackgroundPlay\s*\)\s*\{[\s\S]*?'
        r'unawaited\(\s*appModel\.audiobookSession\.stop\(\)',
      ).hasMatch(dispose),
      isTrue,
      reason: '默认（后台续播关）退出阅读页必须 stop 会话真正止声（TODO-702）',
    );
  });

  test('exit-stop is guarded by the pref, not unconditional (keeps TODO-291)',
      () {
    final RegExpMatch? body = disposeBody();
    expect(body, isNotNull);
    final String dispose = body!.group(1)!;
    // stop 必须落在偏好门控内：不得有无条件（顶层、非 if 内）的 stop 调用，
    // 否则后台续播开关失效（破坏 TODO-291 阶段2 的后台续播）。
    final int stopIdx = dispose.indexOf('audiobookSession.stop()');
    expect(stopIdx, greaterThanOrEqualTo(0));
    final String beforeStop = dispose.substring(0, stopIdx);
    expect(
      beforeStop.contains('!appModel.audiobookBackgroundPlay'),
      isTrue,
      reason: 'stop 必须在 !audiobookBackgroundPlay 门控内，'
          '不能无条件 stop（开启后台续播时应保留会话继续播）',
    );
  });

  // TODO-831：退出即停的时机从 dispose 提前到 onSourcePagePop（被 onWillPop
  // await，pop 动画开始前完成），让书架 NowListeningMiniBar 从首帧就见空会话、
  // 不闪播放条。这里钉住该提前的 await stop 在偏好门控内存在；dispose 的兜底
  // unawaited(stop()) 由上面三条守卫继续钉。
  test('onSourcePagePop awaits a guarded stop on exit (TODO-831)', () {
    final RegExpMatch? body = RegExp(
      r'Future<void> onSourcePagePop\(\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 onSourcePagePop 方法体');
    final String pop = body!.group(1)!;
    expect(
      RegExp(
        r'if\s*\(\s*!appModel\.audiobookBackgroundPlay\s*\)\s*\{[\s\S]*?'
        r'await\s+appModel\.audiobookSession\.stop\(\)',
      ).hasMatch(pop),
      isTrue,
      reason: '退出即停必须在 onSourcePagePop 里按 !audiobookBackgroundPlay '
          '门控 await stop（pop 动画前止声，消除迷你条闪播放条）',
    );
  });

  // W1（TODO-831 复核）：onSourcePagePop 被 onWillPop await，若 stop 在桌面释放
  // native 解码器时抛平台异常，异常会沿 onWillPop → onPopInvokedWithResult 逃逸，
  // 导致 nav.pop() 不执行（用户退不出阅读器）。这里钉住 await stop 被 try/catch
  // 包裹、异常记到 ErrorLogService、catch 后照常退出（与 dispose 路径 catchError
  // 对齐）；防止未来重构把这层错误守卫去掉。
  test('onSourcePagePop guards stop() with try/catch + ErrorLogService (W1)',
      () {
    final RegExpMatch? body = RegExp(
      r'Future<void> onSourcePagePop\(\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 onSourcePagePop 方法体');
    final String pop = body!.group(1)!;
    expect(
      RegExp(
        r'try\s*\{[\s\S]*?'
        r'await\s+appModel\.audiobookSession\.stop\(\)[\s\S]*?'
        r'\}\s*catch\s*\([^)]*\)\s*\{[\s\S]*?'
        r'ErrorLogService\.instance\.log\(',
      ).hasMatch(pop),
      isTrue,
      reason: 'onSourcePagePop 的 await stop 必须被 try/catch 包裹、异常记到 '
          'ErrorLogService，stop 抛异常时不得逃逸阻断 nav.pop()（W1）',
    );
  });
}
