import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sync_settings_schema_source_corpus.dart';

/// TODO-1330 ④ 源码守卫：互联「访问令牌」两端显示的语义区分不被回退。
///
/// 根因是 UI 呈现困惑，不是功能 bug：host 端显示的是共享服务器令牌
/// (getServerPassword / sync_server_password)；client 端令牌框显示的是配对时 host 按
/// 设备铸造的 per-peer token (getHibikiClientToken，见 hibiki_sync_server
/// _issuePeerToken)。二者天生不同、且 _validateAuth 同时受理——用户见「明明用互联
/// 连接了、两端访问令牌不一样」而困惑。修复只加独立标签 + 说明文案，不改任何令牌取值
/// 或鉴权。本守卫钉住：
///  (1) client 令牌框用独立标签 sync_client_token（不再复用 sync_server_token），带说明
///      sync_client_token_hint；
///  (2) server 令牌显示保留 sync_server_token 并带说明 sync_server_token_self_hint；
///  (3) 令牌取值来源不被对调：client 读 getHibikiClientToken、server 读 getServerPassword；
///  (4) server _validateAuth 仍「共享令牌 + 任一 per-peer token」双接受（澄清 UI 不得
///      连带砍掉双接受，Never break userspace）。
void main() {
  String clientWidgetSlice(String corpus) {
    final int start = corpus.indexOf('class _HibikiServerConfigWidgetState');
    expect(start, greaterThanOrEqualTo(0), reason: '客户端配置 widget 丢失');
    final int end = corpus.indexOf('class _ServerModeWidget', start);
    expect(end, greaterThan(start));
    return corpus.substring(start, end);
  }

  String serverWidgetSlice(String corpus) {
    final int start = corpus.indexOf('class _ServerModeWidgetState');
    expect(start, greaterThanOrEqualTo(0), reason: '服务器模式 widget 丢失');
    final int end = corpus.indexOf('class _LanDiscoveryWidget', start);
    expect(end, greaterThan(start));
    return corpus.substring(start, end);
  }

  test('client 令牌框用独立标签 sync_client_token + 说明，不复用 sync_server_token', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String client = clientWidgetSlice(corpus);
    expect(client.contains('labelText: t.sync_client_token'), isTrue,
        reason: 'client 令牌框未用独立标签——回退到 sync_server_token 会让两端同名而困惑。');
    expect(client.contains('t.sync_client_token_hint'), isTrue,
        reason: 'client 令牌框缺说明文案（per-peer token 与对端共享令牌不同）。');
    expect(client.contains('labelText: t.sync_server_token'), isFalse,
        reason: 'client 令牌框不得再用 sync_server_token 标签（与 host 端同名即回退）。');
  });

  test('server 令牌显示保留 sync_server_token + 独立说明 sync_server_token_self_hint',
      () {
    final String corpus = readSyncSettingsSchemaSource();
    final String server = serverWidgetSlice(corpus);
    expect(server.contains('Text(t.sync_server_token'), isTrue,
        reason: 'server 共享令牌显示标签丢失。');
    expect(server.contains('t.sync_server_token_self_hint'), isTrue,
        reason: 'server 令牌缺「本设备共享令牌」说明。');
  });

  test('令牌取值来源不被对调：client 读 getHibikiClientToken、server 读 getServerPassword',
      () {
    final String corpus = readSyncSettingsSchemaSource();
    final String client = clientWidgetSlice(corpus);
    final String server = serverWidgetSlice(corpus);
    expect(client.contains('getHibikiClientToken()'), isTrue,
        reason: 'client 必须显示 per-peer 客户端令牌（getHibikiClientToken）。');
    expect(client.contains('getServerPassword()'), isFalse,
        reason: 'client 不得显示 host 共享令牌（会把两端令牌显示成相同）。');
    expect(server.contains('getServerPassword()'), isTrue,
        reason: 'server 必须显示共享服务器令牌（getServerPassword）。');
    expect(server.contains('getHibikiClientToken()'), isFalse,
        reason: 'server 不得显示客户端 per-peer 令牌。');
  });

  test('server _validateAuth 仍双接受：共享 _token + 任一 per-peer token', () {
    final String s = File('lib/src/sync/hibiki_sync_server.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int start =
        s.indexOf('Future<bool> _validateAuth(String header) async {');
    expect(start, greaterThanOrEqualTo(0), reason: '_validateAuth 丢失');
    final int end = s.indexOf('Future<Set<String>> _peerTokens()', start);
    expect(end, greaterThan(start));
    final String body = s.substring(start, end);
    expect(body.contains('utf8.encode(_token)'), isTrue,
        reason: '_validateAuth 丢了共享令牌兼容路径（Never break userspace）。');
    expect(body.contains('_peerTokens()'), isTrue,
        reason: '_validateAuth 丢了 per-peer token 受理——UI 澄清不得连带砍掉双接受。');
  });
}
