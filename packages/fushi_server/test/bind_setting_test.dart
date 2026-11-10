import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:test/test.dart';

/// 无头 `bind` → [FushiListenScope] 的兼容表（BUG：bind 配成具体地址或 ::1 仍监听全部
/// 网卡）。`0.0.0.0` / `::` / 空 / `localhost` / `127.0.0.1` 与升级前逐字相同。
void main() {
  FushiListenScope scopeOf(String bind) => parseBindSetting(bind).scope;

  test('全网卡写法 → lan()，无警告', () {
    for (final String bind in <String>['', '0.0.0.0', '::', ' 0.0.0.0 ']) {
      final ({FushiListenScope scope, String? warning}) r = parseBindSetting(
        bind,
      );
      expect(r.scope, isA<FushiListenLan>(), reason: bind);
      expect(r.warning, isNull, reason: bind);
    }
  });

  test('localhost / 127.0.0.1 → loopbackV4()（localhost 不交给系统解析）', () {
    expect(scopeOf('localhost'), isA<FushiListenLoopbackV4>());
    expect(scopeOf('LOCALHOST'), isA<FushiListenLoopbackV4>());
    expect(scopeOf('127.0.0.1'), isA<FushiListenLoopbackV4>());
  });

  test('其他 IP 字面量 → exact(该地址)', () {
    for (final String bind in <String>[
      '::1',
      '127.0.0.2',
      '192.168.1.5',
      '2408:8207::1',
    ]) {
      final FushiListenScope s = scopeOf(bind);
      expect(s, isA<FushiListenExact>(), reason: bind);
      expect(
        (s as FushiListenExact).address,
        InternetAddress(bind),
        reason: bind,
      );
    }
    expect(scopeOf('::1').isLoopbackOnly, isTrue);
    expect(scopeOf('127.0.0.2').isLoopbackOnly, isTrue);
    expect(scopeOf('192.168.1.5').isLoopbackOnly, isFalse);
  });

  test('主机名 → lan() 并给警告', () {
    final ({FushiListenScope scope, String? warning}) r = parseBindSetting(
      'nas.local',
    );
    expect(r.scope, isA<FushiListenLan>());
    expect(r.warning, contains('nas.local'));
  });

  test('ServerAnkiConnectConfig.isLoopback 与监听判据同一份', () {
    expect(ServerAnkiConnectConfig.isLoopback('::1'), isTrue);
    expect(ServerAnkiConnectConfig.isLoopback('127.0.0.2'), isTrue);
    expect(ServerAnkiConnectConfig.isLoopback('localhost'), isTrue);
    expect(ServerAnkiConnectConfig.isLoopback('127.0.0.1'), isTrue);
    expect(ServerAnkiConnectConfig.isLoopback('0.0.0.0'), isFalse);
    expect(ServerAnkiConnectConfig.isLoopback('192.168.1.5'), isFalse);
  });
}
