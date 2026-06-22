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
}
