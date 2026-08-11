import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1562：互联客户端配置面板（`_FushiServerConfigWidgetState`）三处状态/时序缺口。
///
///  ① 「已连接 ✓」那一行的判据是 token 非空，而 token 活在 `_tokenController` 里；
///     build 直接读 `controller.text` 却从没 addListener，手动填写路径的 `_saveToken`
///     也只落库不 setState —— 用户贴完 token 那一行原地不动，直到别的原因触发重建。
///  ② `_attemptManualPair` 在进 `_runPairingV2`（它才置忙态）之前还有 TOFU 指纹捕获 +
///     `/api/ping` 探测两次秒级网络往返；那段窗口里「添加」和各行「重新配对」按钮都还
///     亮着，多点两下就能并发跑起两条配对流程，两条都走到 `_onPairSuccess` 写 token，
///     后写覆盖先写 → 最终落库的凭据未必是最后成功那台的。
///  ③ `_addOrEditUrl` 的弹窗是个 async gap：期间关掉「启用互联」会让宿主 section 被
///     门控隐藏、widget dispose，返回后那句 setState 直接崩。
///
/// 这三条都是「私有 State 的时序」，最强可落地层是对同步设置 schema 合并语料做源码
/// 守卫（同目录 `interconnect_token_display_guard_test.dart` 的既有范式）。
void main() {
  String clientWidgetSlice(String corpus) {
    final int start = corpus.indexOf('class _FushiServerConfigWidgetState');
    expect(start, greaterThanOrEqualTo(0), reason: '客户端配置 widget 丢失');
    final int end = corpus.indexOf('class _ServerModeWidget', start);
    expect(end, greaterThan(start));
    return corpus.substring(start, end);
  }

  test('① token 文本变化驱动重建：controller 有监听，build 读的是 State 字段', () {
    final String client = clientWidgetSlice(readSyncSettingsSchemaSource());
    expect(
      containsCodeLine(client, '_tokenController.addListener('),
      isTrue,
      reason: '没人监听 token 输入框 → 「已连接 ✓」永远停在上一次重建时的状态',
    );
    expect(
      containsCodeLine(client, '_tokenController.removeListener('),
      isTrue,
      reason: 'dispose 不摘钩 = 用完即崩的悬空监听',
    );
    expect(
      containsCodeLine(client, 'if (_tokenPresent)'),
      isTrue,
      reason: '「已连接 ✓」应由 State 字段驱动；直接读 controller.text 的写法'
          '天生不触发重建',
    );
    expect(
      RegExp(r'if \(_tokenController\.text\.trim\(\)\.isNotEmpty\)')
          .hasMatch(maskComments(client)),
      isFalse,
      reason: 'build 里再直接拿 controller 文本做条件就等于把这个 bug 放回来',
    );
  });

  test('② 手动配对忙态覆盖全程：入口先自查，探测之前就置忙，finally 清', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String attempt =
        methodBody(corpus, '  Future<void> _attemptManualPair(String rawUrl)');

    expect(containsCodeLine(attempt, 'if (_pairingManual) return;'), isTrue,
        reason: '没有入口自查就挡不住第二条配对流程（LAN 路径的 _pairingUrl 是现成范式）');

    final String masked = maskComments(attempt);
    final int busyOn = masked.indexOf('_setPairV2Busy(true)');
    final int probe = masked.indexOf('FushiTofuProbe.captureFingerprint');
    final int ping = masked.indexOf('fetchFushiPing(');
    final int pair = masked.indexOf('_runPairingV2(');
    expect(busyOn, isNonNegative, reason: '手动配对必须自己置忙态，不能只靠内层');
    expect(probe, isNonNegative);
    expect(ping, isNonNegative);
    expect(pair, isNonNegative);
    expect(busyOn, lessThan(probe), reason: 'TOFU 指纹捕获是秒级网络往返，它之前就得进忙态');
    expect(busyOn, lessThan(ping), reason: '/api/ping 探测同样在窗口内，忙态必须先于它');
    expect(busyOn, lessThan(pair));
    expect(containsCodeLine(attempt, '_setPairV2Busy(false)'), isTrue,
        reason: 'finally 不清忙态 = 面板永久卡在「配对中」');
    expect(masked.contains('} finally {'), isTrue,
        reason: '任一 early-return / 抛异常都必须还原忙态，只能靠 finally');
  });

  test('③ 弹窗返回后先查 mounted 再 setState', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String addOrEdit =
        methodBody(corpus, '  Future<void> _addOrEditUrl({int? index})');
    final String masked = maskComments(addOrEdit);
    final int dialog = masked.indexOf('showAppDialog<String>(');
    final int guard = masked.indexOf('if (!mounted) return;');
    final int setStateAt = masked.indexOf('setState(');
    expect(dialog, isNonNegative);
    expect(guard, isNonNegative,
        reason: '弹窗是 async gap，宿主 section 可能已被门控隐藏并 dispose');
    expect(guard, greaterThan(dialog), reason: 'mounted 守卫必须在弹窗之后');
    expect(guard, lessThan(setStateAt),
        reason: 'setState 之前没有守卫 = dispose 后 setState 崩溃');
  });
}
