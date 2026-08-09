import 'package:flutter_test/flutter_test.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

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

  // TODO-831：退出即停的时机从 dispose 提前到 onSourcePagePop（pop 动画开始前
  // 调用），让书架 NowListeningMiniBar 从首帧就见空会话、不闪播放条。
  //
  // BUG-1273 契约变更：这里从「await stop」改成「unawaited(stop())」。TODO-831 要的
  // 「首帧见空会话」由 `_stopInternal` 的首段（第一个 await 前清空
  // _reader/_controller/_book + notifyListeners）保证——只隔一个微任务，远早于 pop
  // 动画首帧，与调用方是否 await 无关；而 await 它会把「排队 + 停 native 播放器 +
  // 销毁解码器」这段**只有播放态才真正干活**的不可控耗时挂进用户的返回路径（外层
  // 还有 _popInProgress 单飞门 → 播放中返回被静默吞掉，直到音频真停下来才 pop）。
  // 行为层证据见 `reader_back_not_blocked_by_stop_test.dart`。
  test('onSourcePagePop fires the guarded stop without awaiting (BUG-1273)',
      () {
    final RegExpMatch? body = RegExp(
      r'Future<void> onSourcePagePop\(\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 onSourcePagePop 方法体');
    final String pop = body!.group(1)!;
    expect(
      RegExp(
        r'if\s*\(\s*!appModel\.audiobookBackgroundPlay\s*\)\s*\{[\s\S]*?'
        r'unawaited\(\s*appModel\.audiobookSession\.stop\(\)',
      ).hasMatch(pop),
      isTrue,
      reason: '退出即停必须在 onSourcePagePop 里按 !audiobookBackgroundPlay '
          '门控调 stop（pop 前止声 + 清会话，消除迷你条闪播放条）',
    );
    // 负向：绝不能退回 await——那正是 BUG-1273 的根因（播放中返回被吞到音频停下）。
    expect(
      RegExp(r'await\s+appModel\.audiobookSession\.stop\(\)').hasMatch(pop),
      isFalse,
      reason: 'BUG-1273：退出路径不得 await stop（native 释放耗时不可控且只在播放态'
          '发生，会把用户的返回挂到音频真停下来那一刻）',
    );
  });

  // W1（TODO-831 复核 → BUG-1273 收口）：stop 在释放 native 解码器时可能抛平台异常。
  // 旧实现 await + try/catch 防它逃逸阻断 nav.pop()；改 fire-and-forget 后，异常不再
  // 经过退出路径，但仍必须就地 catchError 记到 ErrorLogService（否则成未捕获异步
  // 错误），与 dispose 路径的 unawaited(stop().catchError(...)) 惯例一致。
  test('onSourcePagePop stop() is guarded by catchError + ErrorLogService (W1)',
      () {
    final RegExpMatch? body = RegExp(
      r'Future<void> onSourcePagePop\(\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 onSourcePagePop 方法体');
    final String pop = body!.group(1)!;
    expect(
      RegExp(
        r'unawaited\(\s*[\s\S]*?appModel\.audiobookSession\.stop\(\)'
        r'\s*\.catchError\([\s\S]*?ErrorLogService\.instance\.log\(',
      ).hasMatch(pop),
      isTrue,
      reason: 'onSourcePagePop 的 fire-and-forget stop 必须 .catchError 记到 '
          'ErrorLogService，不得留下未捕获异步错误（W1）',
    );
  });
}
