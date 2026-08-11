import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;

/// BUG-1555：旧 `/api/pair`（v1）整个绕开 v2 的 PIN + HMAC 双确认——它只要 host 点一下
/// 「允许」就把**权限最大、不可逐台吊销**的共享 token 发出去。同一条入站链路上，攻击者
/// 只需改发 v1 就把「公网入站强制 PIN」这条策略废掉，host 屏上弹的还是一个看不出区别的
/// 普通「某设备请求配对」框，误点一次即永久失守。
///
/// 修复：v1 用与 v2 **同一个判据**（`FushiPairingProtocol.computePinRequired`）前置拦截，
/// 本会话必须 PIN 时直接 403 `upgrade_required`，连审批框都不弹。
///
/// 兼容性：LAN 内且 host 未开「LAN 也要 PIN」（默认）时 v1 行为逐字不变。
void main() {
  late Directory tempDir;
  late FushiSyncServer server;

  Future<void> startServer({required bool lanRequiresPin}) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_v1_pin_test');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'shared-token',
      allowLan: true,
    )..lanRequiresPinProvider = (() async => lanRequiresPin);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uri pairUri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair');

  test('host 要求 PIN 时 v1 配对被拒（upgrade_required），且不弹审批框', () async {
    await startServer(lanRequiresPin: true);
    int prompts = 0;
    server.onPairRequest = (FushiPairRequest _) async {
      prompts++;
      return true; // 就算 host 会点「允许」，也不该走到这一步。
    };

    final http.Response resp = await http.post(
      pairUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'name': 'Legacy phone'}),
    );

    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'upgrade_required',
      reason: 'BUG-1555：必须给出可分型的原因，client 才能说「对方需要升级」而非「对方拒绝」',
    );
    expect(resp.body.contains('shared-token'), isFalse,
        reason: '任何情况下都不得在拒绝响应里泄漏共享 token');
    expect(prompts, 0, reason: 'BUG-1555：必须在弹审批框之前拦下——弹了框就等于给了用户一次误点失守的机会');
  });

  test('LAN 免 PIN（默认）时 v1 配对仍照常发 token（向后兼容不破）', () async {
    await startServer(lanRequiresPin: false);
    int prompts = 0;
    server.onPairRequest = (FushiPairRequest _) async {
      prompts++;
      return true;
    };

    final http.Response resp = await http.post(
      pairUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'name': 'Legacy phone'}),
    );

    expect(resp.statusCode, 200);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['token'],
      'shared-token',
    );
    expect(prompts, 1, reason: '免 PIN 的 LAN 会话仍旧走 host 人工审批，行为零变化');
  });

  test('lanRequiresPinProvider 未接线时按免 PIN 处理（headless / 老配置）', () async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_v1_pin_test2');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'shared-token',
      allowLan: true,
    )..onPairRequest = ((FushiPairRequest _) async => true);
    await server.start();

    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 200,
        reason: '未接 lanRequiresPin 供给器时不得把 LAN 会话误判成要 PIN（会砸掉既有配对）');
  });
}
