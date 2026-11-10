import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-4273：互联「已添加的对端」行标题只显示 URL，不显示已存的对端设备名。
/// BUG-4274：「测试连接」连已停用的行也测，停用行亮 ✓ 让人以为它在用。
///
/// 选什么显示 / 测哪些行是纯函数（单测）；面板是私有 State，接线用源码守卫
/// （同目录 `interconnect_settings_bug1693_guard_test.dart` 范式）。
void main() {
  group('BUG-4273 interconnectPeerRowName', () {
    test('uses the row own device name without the brand prefix', () {
      const FushiClientUrl row = FushiClientUrl(
        url: 'https://192.168.1.5:8765',
        deviceName: '  Fushi · Desk PC ',
      );
      expect(
        interconnectPeerRowName(const <FushiClientUrl>[row], row),
        'Desk PC',
      );
    });

    test('learned address without a name borrows it from its host group', () {
      const FushiClientUrl manual = FushiClientUrl(
        url: 'https://192.168.1.5:8765',
        deviceName: 'Desk PC',
        hostId: 'h1',
      );
      const FushiClientUrl learned = FushiClientUrl(
        url: 'https://[fd00::5]:8765',
        hostId: 'h1',
        learned: true,
      );
      const FushiClientUrl other = FushiClientUrl(
        url: 'https://10.0.0.9:8765',
        deviceName: 'Laptop',
        hostId: 'h2',
      );
      expect(
        interconnectPeerRowName(const <FushiClientUrl>[
          other,
          manual,
          learned,
        ], learned),
        'Desk PC',
      );
    });

    test('no name anywhere (or blank) returns null so the URL is shown', () {
      const FushiClientUrl legacy = FushiClientUrl(
        url: 'http://192.168.1.7:8765',
        deviceName: '   ',
      );
      const FushiClientUrl noHost = FushiClientUrl(url: 'http://10.0.0.1:1');
      expect(
        interconnectPeerRowName(const <FushiClientUrl>[legacy, noHost], legacy),
        isNull,
      );
      expect(
        interconnectPeerRowName(const <FushiClientUrl>[legacy, noHost], noHost),
        isNull,
      );
    });
  });

  test('BUG-4274 interconnectUrlsToTest keeps only enabled rows, in order', () {
    const List<FushiClientUrl> urls = <FushiClientUrl>[
      FushiClientUrl(url: 'a'),
      FushiClientUrl(url: 'b', enabled: false),
      FushiClientUrl(url: 'c'),
    ];
    expect(
      interconnectUrlsToTest(urls).map((FushiClientUrl u) => u.url),
      <String>['a', 'c'],
    );
    expect(
      interconnectUrlsToTest(const <FushiClientUrl>[
        FushiClientUrl(url: 'x', enabled: false),
      ]),
      isEmpty,
    );
  });

  group('settings panel wiring (source guard)', () {
    final String corpus = readSyncSettingsSchemaSource();

    test('BUG-4273 row title prefers the peer name over the URL', () {
      final String masked = maskComments(corpus);
      expect(
        masked.contains('interconnectPeerRowName(_urls, u)'),
        isTrue,
        reason: '行标题要取对端设备名（含同 host 组借名）',
      );
      expect(
        masked.contains('peerName ?? u.url'),
        isTrue,
        reason: '有名字显示名字，没名字回落 URL',
      );
      expect(
        masked.contains('address: peerName == null ? null : u.url'),
        isTrue,
        reason: '标题换成名字后 URL 必须仍在副标题里，同 host 多地址靠它区分',
      );
    });

    test('BUG-4274 test-all probes only enabled rows', () {
      final String body = maskComments(
        methodBody(corpus, '  Future<void> _testAll() async'),
      );
      expect(body.contains('interconnectUrlsToTest(_urls)'), isTrue);
      expect(
        body.contains('for (final FushiClientUrl u in _urls)'),
        isFalse,
        reason: '直接遍历 _urls 就会把停用行也测一遍',
      );
      expect(body.contains('t.interconnect_peer_test_none_enabled'), isTrue);
    });

    test('BUG-4274 disabled rows show no stale test result', () {
      final String masked = maskComments(corpus);
      expect(
        masked.contains('u.enabled ? _reachable[u.url] : null'),
        isTrue,
        reason: '停用行不显示上一轮 ✓/✗',
      );
      final String toggle = maskComments(
        methodBody(corpus, '  Future<void> _toggleUrl(int index) async'),
      );
      expect(toggle.contains('_reachable.remove(url)'), isTrue);
    });
  });
}
