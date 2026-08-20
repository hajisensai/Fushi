import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// TODO-961：互联 TLS 用户入口 + 发现配对 v2 化的源码守卫。
///
/// 这些是纯客户端 UI 接线（schema part 文件里的私有 widget），没有可低成本落地的
/// widget 测试守着——一旦有人删掉 TLS 开关、把 `_toggleUrl` 回退成裸构造（丢
/// TOFU 指纹）、或把发现列表配对退回 v1 明文直连，analyze / 现有 sync 单测都不会
/// 红。此守卫在最强可落地层（源码切片）钉住三条接线。
void main() {
  late String source;

  setUpAll(() {
    source = readSyncSettingsSchemaSource();
  });

  test('设置页存在互联加密（HTTPS/TLS）开关且接 setServerTlsEnabled', () {
    expect(
      source.contains('t.sync_server_tls_enable'),
      isTrue,
      reason: '互联加密开关的 i18n 标题丢失（TLS 又变回无入口死代码）',
    );
    expect(
      source.contains('.setServerTlsEnabled(v)'),
      isTrue,
      reason: 'TLS 开关未接 SyncRepository.setServerTlsEnabled',
    );
    // 切换必须提示「已配对设备需重新配对」（scheme 变了存量 URL/指纹不再匹配）。
    expect(
      source.contains('t.sync_server_tls_repair_hint'),
      isTrue,
      reason: 'TLS 切换缺少「需重新配对」提示',
    );
    // 运行中切换要重启 host socket 才真生效（含 mDNS TXT tls 标志更新）。
    // BUG-1563 之后重启结果要被消费（失败上屏 + 开关回落），所以判据只钉「在
    // _setTlsEnabled 里、以 isRunning 为条件、真的调了 restart()」这个不变式，
    // 不再逐字匹配那一行的写法。
    final String tls =
        methodBody(source, '  Future<void> _setTlsEnabled(bool v)');
    expect(
      containsCodeLine(tls, '_serverController.isRunning'),
      isTrue,
      reason: 'TLS 切换未按 host 是否在跑分流',
    );
    expect(
      containsIdentifierCall(tls, '_serverController.restart'),
      isTrue,
      reason: 'TLS 切换未重启运行中的 host（开关变成下次启动才生效的哑开关）',
    );
  });

  test('B 段：首次启用 hosting 走 applyFirstHostingTlsDefault（存量零破坏）', () {
    expect(
      source.contains('.applyFirstHostingTlsDefault()'),
      isTrue,
      reason: '首次 hosting 的 TLS 默认值接线丢失',
    );
  });

  test('gap②：_toggleUrl 用 copyWith 保留 TOFU 指纹/展示名', () {
    final int start =
        source.indexOf('Future<void> _toggleUrl(int index) async {');
    expect(start, greaterThanOrEqualTo(0), reason: '_toggleUrl 丢失');
    final int end =
        source.indexOf('Future<void> _deleteUrl(int index) async {');
    expect(end, greaterThan(start));
    final String toggle = source.substring(start, end);
    expect(
      toggle.contains('u.copyWith(enabled: !u.enabled)'),
      isTrue,
      reason: '_toggleUrl 未用 copyWith（裸构造会静默清掉已钉扎的 fingerprintSha256）',
    );
    expect(
      toggle.contains('FushiClientUrl(url:'),
      isFalse,
      reason: '_toggleUrl 出现裸构造重建条目，会丢 fingerprintSha256/deviceName',
    );
  });

  test('发现列表配对走 v2：探测 scheme → 共享 _runPairingV2，老 host 回落 v1', () {
    final int start = source
        .indexOf('Future<void> _connectToDevice(FushiDevice device) async {');
    expect(start, greaterThanOrEqualTo(0), reason: '_connectToDevice 丢失');
    final int end = source.indexOf('String _pairDeniedMessage(String body) {');
    expect(end, greaterThan(start));
    final String connect = source.substring(start, end);
    // scheme 选择 + 探测（TXT tls 标志 + /api/ping 定案）。
    expect(
      connect.contains('await probeDiscoveredPairingEndpointDetailed('),
      isTrue,
      reason: '发现配对未先探测 scheme（probeDiscoveredPairingEndpointDetailed）',
    );
    // BUG-1741：必须消费探测带回的失败原因与 TLS 确证，否则又会把 TLS host
    // 推进 v1 明文死路，并把真实原因换成一句「配对失败」。
    expect(
      connect.contains('outcome.peerSpeaksTls'),
      isTrue,
      reason: '发现配对未消费 peerSpeaksTls，TLS host 会被回落进 v1 明文死路',
    );
    expect(
      connect.contains('_pingFailureMessage(outcome.failure)'),
      isTrue,
      reason: '发现配对丢弃了探测失败原因，UI 只能给出误导文案',
    );
    // v1 必须用探明的 baseUrl，不能再盲信硬编码 http 的 device.webDavUrl。
    expect(
      connect.contains('probe?.baseUrl ?? device.webDavUrl'),
      isTrue,
      reason: 'v1 回落未使用探明 scheme 的 baseUrl（会把错的 http:// 永久写进列表）',
    );
    expect(
      connect.contains('tlsAdvertised: device.tlsEnabled'),
      isTrue,
      reason: '发现配对未消费 mDNS TXT 的 tls 标志',
    );
    // v2 host 走与手动 IP 共享的编排（TOFU→PIN→token+指纹落库）。
    expect(
      connect.contains('await _runPairingV2('),
      isTrue,
      reason: '发现配对未接入共享 v2 编排 _runPairingV2',
    );
    // 旧版 host 回落 v1 明文（Never break userspace）。
    expect(
      connect.contains('await _pairLegacyV1('),
      isTrue,
      reason: '发现配对丢了 v1 明文回落（旧版 host 将无法配对）',
    );
  });
}
