import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_host.dart';

/// TODO-354 ① 行为守卫：书架/首页（无 reader）开的悬浮字幕点词必须路由进常驻主窗口
/// 查词宿主，而不再被 app 级 no-op handler 吞掉。
///
/// [FloatingLyricLookupNotifier] 是 app 级默认 handler 与 [FloatingLyricLookupHost]
/// 之间的请求总线。这里钉住其纯逻辑：
///  - requestLookup 推请求并 notify；
///  - 空白文本忽略（不 notify、不留挂起请求）；
///  - consume 取出后清空（避免 host 重建重复弹）。
void main() {
  final FloatingLyricLookupNotifier notifier =
      FloatingLyricLookupNotifier.instance;

  setUp(notifier.debugReset);
  tearDown(notifier.debugReset);

  test('requestLookup stores the request and notifies', () {
    int notified = 0;
    void listener() => notified++;
    notifier.addListener(listener);
    addTearDown(() => notifier.removeListener(listener));

    notifier.requestLookup('日本語', 1);

    expect(notified, 1);
    expect(notifier.pending, isNotNull);
    expect(notifier.pending?.text, '日本語');
    expect(notifier.pending?.index, 1);
  });

  test('requestLookup ignores blank text (no notify, no pending)', () {
    int notified = 0;
    void listener() => notified++;
    notifier.addListener(listener);
    addTearDown(() => notifier.removeListener(listener));

    notifier.requestLookup('   ', 0);

    expect(notified, 0, reason: '空白文本不应触发查词');
    expect(notifier.pending, isNull);
  });

  test('consume returns and clears the pending request', () {
    notifier.requestLookup('言葉', 0);
    expect(notifier.pending, isNotNull);

    final FloatingLyricLookupRequest? req = notifier.consume();
    expect(req?.text, '言葉');
    expect(notifier.pending, isNull, reason: 'consume 后应清空，避免重复弹');

    expect(notifier.consume(), isNull, reason: '二次 consume 应返回 null');
  });
}
