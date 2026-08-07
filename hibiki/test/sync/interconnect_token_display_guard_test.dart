import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sync_settings_schema_source_corpus.dart';

/// TODO-1330 ④ 源码守卫：互联「访问令牌」两端显示不再摆出两个对不上的数字。
///
/// 根因是 UI 呈现困惑，不是功能 bug：host 端显示的是共享服务器令牌
/// (getServerPassword / sync_server_password)；client 端存的是配对时 host 按设备铸造的
/// per-peer token (getFushiClientToken)。二者天生不同、且 _validateAuth 同时受理——过去
/// 把 client 令牌当成一个显眼数字摆出来 + 加说明解释「为何两端不一样」，反而更困惑。
///
/// 现在的修复：client 令牌配对后自动填入，已连接就只显示「已连接」状态，原始令牌收进
/// 「手动填写」折叠项（ExpansionTile），不再和 host 端令牌摆成两个数字。两条解释性说明
/// (sync_client_token_hint / sync_server_token_self_hint) 一并删除。令牌取值来源与后端
/// 鉴权双接受一概不动（Never break userspace）。本守卫钉住：
///  (1) client 令牌框收进「手动填写」折叠 (ExpansionTile + sync_client_token_manual)，
///      已连接显示 sync_client_connected 状态，且不再带 sync_client_token_hint 说明；
///  (2) server 令牌显示保留 sync_server_token，且不再带 sync_server_token_self_hint 说明；
///  (3) 令牌取值来源不被对调：client 读 getFushiClientToken、server 读 getServerPassword；
///  (4) server _validateAuth 仍「共享令牌 + 任一 per-peer token」双接受（澄清 UI 不得
///      连带砍掉双接受，Never break userspace）。
void main() {
  String clientWidgetSlice(String corpus) {
    final int start = corpus.indexOf('class _FushiServerConfigWidgetState');
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

  test('client 令牌收进「手动填写」折叠 + 已连接只显示状态，不再带 per-peer 说明文案', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String client = clientWidgetSlice(corpus);
    // 令牌输入框仍在（手动粘贴对端令牌的回退路径），但收进 ExpansionTile 折叠项。
    expect(client.contains('ExpansionTile('), isTrue,
        reason: 'client 令牌框未收进折叠项——原始令牌又被摆成显眼数字会重现困惑。');
    expect(client.contains('t.sync_client_token_manual'), isTrue,
        reason: '「手动填写令牌」折叠标题丢失。');
    expect(client.contains('t.sync_client_connected'), isTrue,
        reason: '已连接状态提示丢失——应以状态代替摆出原始令牌数字。');
    expect(client.contains('labelText: t.sync_client_token'), isTrue,
        reason: '折叠项内的令牌输入框标签丢失（手填回退路径必须保留）。');
    // 解释「两端为何不一样」的说明已删除——改用隐藏令牌而非加说明。
    expect(client.contains('t.sync_client_token_hint'), isFalse,
        reason: 'client 不应再带解释性说明——隐藏令牌后无需解释差异。');
    expect(client.contains('labelText: t.sync_server_token'), isFalse,
        reason: 'client 令牌框不得用 sync_server_token 标签。');
  });

  test('server 令牌显示保留 sync_server_token，且不再带 sync_server_token_self_hint 说明',
      () {
    final String corpus = readSyncSettingsSchemaSource();
    final String server = serverWidgetSlice(corpus);
    expect(server.contains('Text(t.sync_server_token'), isTrue,
        reason: 'server 共享令牌显示标签丢失。');
    expect(server.contains('t.sync_server_token_self_hint'), isFalse,
        reason: 'server 令牌不应再带解释性说明——隐藏 client 令牌后无需解释差异。');
  });

  test('令牌取值来源不被对调：client 读 getFushiClientToken、server 读 getServerPassword',
      () {
    final String corpus = readSyncSettingsSchemaSource();
    final String client = clientWidgetSlice(corpus);
    final String server = serverWidgetSlice(corpus);
    expect(client.contains('getFushiClientToken()'), isTrue,
        reason: 'client 必须读 per-peer 客户端令牌（getFushiClientToken）。');
    expect(client.contains('getServerPassword()'), isFalse,
        reason: 'client 不得读 host 共享令牌。');
    expect(server.contains('getServerPassword()'), isTrue,
        reason: 'server 必须显示共享服务器令牌（getServerPassword）。');
    expect(server.contains('getFushiClientToken()'), isFalse,
        reason: 'server 不得显示客户端 per-peer 令牌。');
  });

  test('server _validateAuth 仍双接受：共享 _token + 任一 per-peer token', () {
    final String s = File('lib/src/sync/fushi_sync_server.dart')
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
