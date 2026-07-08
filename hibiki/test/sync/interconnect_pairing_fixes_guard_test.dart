import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sync_settings_schema_source_corpus.dart';

/// TODO-1330 源码守卫：互联配对三处修复的接线锚点，防被无意回退。
///
/// - BUG-616：互联「测试连接」必须带上该地址钉扎的证书指纹（否则对默认开 TLS 的
///   已配对 https host 恒失败）。
/// - BUG-617：pinRequired 会话 host 点「允许」后弹窗不关、常驻显示 PIN，直到 client
///   提交 confirm（onPairSessionResolved）/ 手动 / TTL 才收起。
/// - #3：失败后「重新配对」入口复用 _attemptManualPair，不必删地址重加。
///
/// 这几处是纯客户端 UI / 控制器接线，没有可低成本落地的 widget 测试守着；行为测试
/// （interconnect_test_connection_tls_test / hibiki_sync_server_pair_v2_test）守住服务端
/// 与后端契约，本文件在源码切片层钉住 UI 侧接线不被删。
void main() {
  test('BUG-616：_testAll 把地址钉扎指纹传进 testConnection', () {
    final String source = readSyncSettingsSchemaSource();
    final int start = source.indexOf('Future<void> _testAll() async {');
    expect(start, greaterThanOrEqualTo(0), reason: '_testAll 丢失');
    final int end =
        source.indexOf('Widget build(BuildContext context) {', start);
    expect(end, greaterThan(start));
    final String testAll = source.substring(start, end);
    expect(
      testAll.contains('fingerprint: u.fingerprintSha256'),
      isTrue,
      reason: '测试连接漏传钉扎指纹——对默认开 TLS 的已配对 https host 会恒失败（BUG-616）。',
    );
  });

  test('#3：客户端地址行有「重新配对」入口，复用 _attemptManualPair', () {
    final String source = readSyncSettingsSchemaSource();
    expect(
      source.contains('t.sync_pair_repair'),
      isTrue,
      reason: '缺失「重新配对」入口——失败后只能删地址重加（TODO-1330 #3）。',
    );
    expect(
      source.contains('_attemptManualPair(u.url)'),
      isTrue,
      reason: '「重新配对」未复用现有 v2 配对编排 _attemptManualPair。',
    );
  });

  test('BUG-617：控制器审批弹窗对 pinRequired 会话常驻显示 PIN 到 confirm', () {
    final String controller = File('lib/src/sync/hibiki_server_controller.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    // server 的 confirm 到达信号接进控制器（收起常驻 PIN 弹窗）。
    expect(
      controller
          .contains('..onPairSessionResolved = _dismissPendingPairPinDialog'),
      isTrue,
      reason: 'onPairSessionResolved 未接线——client 提交 confirm 后无法收起 host PIN 弹窗。',
    );
    // 常驻弹窗收起句柄存在（点允许后不立刻 pop）。
    expect(
      controller.contains('_pendingPairPinDismiss'),
      isTrue,
      reason: '缺常驻 PIN 弹窗收起句柄——退回「点允许即关窗」会重现 BUG-617。',
    );
    // 「等对方输入此 PIN」等待态文案。
    expect(
      controller.contains('t.sync_pair_pin_waiting'),
      isTrue,
      reason: '缺「等待对方输入 PIN」等待态——host 点允许后无常驻提示。',
    );
  });
}
