import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1693 批审计：互联设置面板（`interconnect.part.dart`）四处缺陷的源码守卫。
///
///  ① 「测试连接」拿**全局** token 测所有对端：多对端时全局键被最后配对那台覆写，
///     第一台恒被误报失败；全局键为空时更是整体早退，哪怕各地址行都自带 per-peer
///     token。修法：逐地址 `interconnectTokenFor`（行上凭据优先、回落全局键），
///     与全部真实同步消费点的 BUG-1550 规则一致。顺带拆掉入口那句 `_saveToken()`
///     ——它带着「清全部 per-peer token」的显式覆盖语义，把测试变成凭据改写。
///  ② 「用互联做备份后端」失败弹裸 `e.toString()`：改走 [friendlySyncErrorDetail]
///     （对端全探不到 → SyncPeerUnreachableError → 「无法连接配对设备」）。
///  ③ `_reachable` 结果映射从不清理：删掉再重加同一地址立刻显示上一轮 ✓/✗。
///     修法收口在 `_persistUrls` 单点（所有 URL 变更必经之路）按现存 URL 集合剪。
///  ④ 点 LAN 设备在探测/配对**之前**就 `setInterconnectEnabled(true)` 且失败不
///     回滚。修法：启用挪到配对成功点（v2 `_onPairSuccess` / v1 拿到 token 后）。
///
/// 这四条全是私有 State 的时序/数据流，最强可落地层是对同步设置 schema 合并语料做
/// 源码守卫（同目录 `interconnect_client_panel_guard_test.dart` 的既有范式）。
void main() {
  final String corpus = readSyncSettingsSchemaSource();

  test('① 测试连接逐地址取凭据，不再用全局键一测到底 / 空键早退', () {
    final String body = methodBody(corpus, '  Future<void> _testAll() async');

    expect(
      containsCodeLine(body, 'interconnectTokenFor(u, globalToken)'),
      isTrue,
      reason: '凭据必须按候选取（行上 per-peer token 优先、回落全局键），'
          '否则配对第二台后全局键被覆写，第一台恒被误报失败',
    );
    expect(
      containsCodeLine(body, 'token.isEmpty'),
      isFalse,
      reason: '全局键为空不许整体早退——各地址行可能自带有效的 per-peer token',
    );
    expect(
      containsCodeLine(body, '_saveToken'),
      isFalse,
      reason: '_saveToken 会清掉全部地址行的 per-peer token（BUG-1550 显式覆盖'
          '语义），测试连接不许顺手改写凭据；手动输入路径的 onChanged 已逐次落库',
    );

    final String masked = maskComments(body);
    final int pick = masked.indexOf('interconnectTokenFor(');
    final int probe = masked.indexOf('testConnection(');
    expect(pick, isNonNegative);
    expect(probe, isNonNegative);
    expect(pick, lessThan(probe), reason: '先按候选选凭据，再拿它去探测；顺序反了就是旧的全局键形状');
  });

  test('② 备份后端切换失败走统一友好错误翻译，不弹裸异常', () {
    final String body =
        methodBody(corpus, '  Future<void> _useInterconnectAsBackend() async');
    expect(
      containsCodeLine(body, 'friendlySyncErrorDetail(e)'),
      isTrue,
      reason: '对端全探不到时 SyncPeerUnreachableError 应翻成「无法连接配对设备」',
    );
    expect(
      containsCodeLine(body, 'e.toString()'),
      isFalse,
      reason: '裸 toString 上屏就是把这个 bug 放回来',
    );
  });

  test('③ URL 集合一变就剪掉不再对应任何行的 _reachable 条目', () {
    final String body =
        methodBody(corpus, '  Future<void> _persistUrls() async');
    expect(
      containsCodeLine(body, '_reachable.removeWhere('),
      isTrue,
      reason: '所有 URL 变更（删除/改址/重排）必经 _persistUrls；不在这里剪，'
          '删掉再重加同一地址就会立刻显示上一轮的 ✓/✗',
    );
  });

  test('④ 互联启用只落在配对成功点，点击 LAN 设备不再预写', () {
    final String connect = methodBody(
        corpus, '  Future<void> _connectToDevice(FushiDevice device) async');
    expect(
      containsCodeLine(connect, 'setInterconnectEnabled(true)'),
      isFalse,
      reason: '探测/配对之前就写死「互联已启用」且失败不回滚——启用必须由成功点落',
    );

    // v2 成功点：token 落库之后启用。
    final String v2 = methodBody(corpus, '  Future<String> _onPairSuccess(');
    expect(containsCodeLine(v2, 'setInterconnectEnabled(true)'), isTrue,
        reason: 'v2 配对成功（token 已落库）才代表互联真的投入使用');
    final String v2Masked = maskComments(v2);
    expect(
      v2Masked.indexOf('setFushiClientTokenForUrl('),
      lessThan(v2Masked.indexOf('setInterconnectEnabled(true)')),
      reason: '先落凭据再落启用：启用了却没凭据是半配置状态',
    );

    // v1 回退成功点：同样拿到 token 才启用。
    final String v1 = methodBody(corpus, '  Future<void> _pairLegacyV1(');
    expect(containsCodeLine(v1, 'setInterconnectEnabled(true)'), isTrue,
        reason: 'v1 老路径拿到 token（配对成功）后同样要落启用');
    final String v1Masked = maskComments(v1);
    expect(
      v1Masked.indexOf('setFushiClientTokenForUrl('),
      lessThan(v1Masked.indexOf('setInterconnectEnabled(true)')),
      reason: 'v1 也必须先落凭据再落启用',
    );
  });
}
