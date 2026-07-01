import 'package:flutter_test/flutter_test.dart';

import 'sync_settings_schema_source_corpus.dart';

/// TODO-963: 手动输入 IP 的「先探测再配对」闭环源码守卫。
///
/// 用户诉求：直接输入 IP 时应先发探测请求；网段不同 / 公网时 mDNS 发现不到对方，
/// 手动输入的 IP 也必须有 UI 路径发起配对（拿 token，免手粘）。M2 已在
/// `interconnect.part.dart` 落地：`_HibikiServerConfigWidget._addOrEditUrl` 新增地址后
/// 调 `_attemptManualPair`（reachability 探测 + 配对），配对编排 `_runPairingV2` 与
/// mDNS 发现解耦（host-agnostic，只吃 baseUrl/指纹/展示名，不依赖 `HibikiDevice`）。
///
/// 这些是**纯客户端 UI 接线**，没有对应的 widget/unit 测试守着——一旦有人把
/// `_addOrEditUrl` 回退成「只存地址不探测」，或把配对重新耦合回 mDNS 设备行，
/// analyze / 现有 sync 单测都不会红。此守卫在最强可落地层（源码切片）钉住闭环：
/// 手动 add → 探测 → 配对入口存在，且配对编排不吃 mDNS 的 `HibikiDevice`。
void main() {
  late String source;

  setUpAll(() {
    source = readSyncSettingsSchemaSource();
  });

  test('手动新增地址后触发探测 + 配对（_addOrEditUrl → _attemptManualPair）', () {
    // 手动加/编辑地址的入口方法存在。
    expect(
      source.contains('Future<void> _addOrEditUrl({int? index}) async {'),
      isTrue,
      reason: '手动输入 IP 的 add/edit 入口方法丢失',
    );
    // 新增地址后必须调用手动配对编排（探测 + 配对），否则手输 IP 只是死存地址。
    expect(
      source.contains('await _attemptManualPair(result);'),
      isTrue,
      reason: '_addOrEditUrl 新增地址后未触发 _attemptManualPair（探测+配对闭环断裂）',
    );
  });

  test('手动配对先跑 reachability 探测（scope ①：fetchHibikiPing）', () {
    expect(
      source.contains('Future<void> _attemptManualPair(String rawUrl) async {'),
      isTrue,
      reason: '手动 IP 配对编排方法 _attemptManualPair 丢失',
    );
    // 探测走已有的 /api/ping 客户端 fetchHibikiPing——配对前先确认可达 + 是 hibiki。
    expect(
      source.contains('await fetchHibikiPing('),
      isTrue,
      reason: '手动 IP 配对未先跑 reachability 探测（fetchHibikiPing）',
    );
    // 探测失败 / 非 hibiki 必须有 UI 反馈（向后兼容：仍保留地址供手粘 token）。
    expect(
      source.contains('t.sync_pair_not_hibiki'),
      isTrue,
      reason: '探测不可达 / 非 hibiki 时缺少 UI 反馈',
    );
  });

  test('配对编排与 mDNS 发现解耦（scope ②：_runPairingV2 host-agnostic）', () {
    // 共享的配对编排只吃 baseUrl / 指纹 / 展示名，不依赖 mDNS 的 HibikiDevice。
    expect(
      source.contains('Future<void> _runPairingV2({'),
      isTrue,
      reason: '共享配对编排 _runPairingV2 丢失',
    );
    // _attemptManualPair 必须把手动 baseUrl 喂进共享编排（而非只有 mDNS 行能配对）。
    expect(
      source.contains('await _runPairingV2('),
      isTrue,
      reason: '手动 IP 未接入共享配对编排 _runPairingV2',
    );
    // 配对成功后自动落 token（免用户手粘）。
    expect(
      source.contains('await _onPairSuccess(baseUrl, token, fingerprint)'),
      isTrue,
      reason: '配对成功后未自动落 token（_onPairSuccess）',
    );

    // _runPairingV2 的签名区间内不得出现 HibikiDevice —— 保证它 host-agnostic，
    // 手动 IP 与 mDNS 发现走同一条编排而非各写一份 / 只对发现设备开放。
    final int orchestrateStart = source.indexOf('Future<void> _runPairingV2({');
    final int orchestrateEnd = source.indexOf('Future<String> _onPairSuccess(');
    expect(orchestrateStart, greaterThanOrEqualTo(0));
    expect(orchestrateEnd, greaterThan(orchestrateStart));
    final String orchestrate =
        source.substring(orchestrateStart, orchestrateEnd);
    expect(
      orchestrate.contains('HibikiDevice'),
      isFalse,
      reason: '_runPairingV2 依赖了 mDNS 的 HibikiDevice，破坏手动 IP / mDNS 解耦',
    );
  });
}
