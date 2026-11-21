import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_lan_relocation.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';

/// BUG-5068（反馈 MDzxg3SNQc）：选路在存量直连地址全不通时，靠 [InterconnectLanRelocator]
/// 做一次限时 mDNS 浏览，按 TXT `id`（= hostId）找到已配对 host 的新地址。
void main() {
  BonsoirService resolved({
    required String id,
    String host = '192.0.2.7',
    int port = 38765,
    bool tls = true,
    String name = 'Desk PC',
  }) => BonsoirService.ignoreNorms(
    name: name,
    type: LanDiscoveryService.serviceType,
    port: port,
    hostAddresses: <String>[host],
    attributes: <String, String>{'id': id, if (tls) 'tls': '1'},
  );

  ({
    InterconnectLanRelocator relocator,
    List<_FakeDiscovery> made,
    List<String> log,
  })
  build(List<BonsoirService> advertised, {DateTime Function()? now}) {
    final List<_FakeDiscovery> made = <_FakeDiscovery>[];
    final List<String> log = <String>[];
    final InterconnectLanRelocator relocator = InterconnectLanRelocator(
      ownDeviceId: () async => 'SELF',
      discoveryFactory: (String own) => LanDiscoveryService(
        deviceId: own,
        discoveryFactory: (String type) {
          final _FakeDiscovery d = _FakeDiscovery(type, advertised);
          made.add(d);
          return d;
        },
        mdnsFallbackEnabled: false,
      ),
      onBrowseStart: (LanDiscoveryService _) => log.add('start'),
      onBrowseEnd: (LanDiscoveryService _) => log.add('end'),
      browseTimeout: const Duration(milliseconds: 300),
      now: now ?? DateTime.now,
    );
    return (relocator: relocator, made: made, log: log);
  }

  test('按 TXT id 找到 hostId 那台 host 的 https 地址，浏览完即停', () async {
    final r = build(<BonsoirService>[
      resolved(id: 'OTHER', host: '192.0.2.9', name: 'Other PC'),
      resolved(id: 'H'),
    ]);
    expect(await r.relocator.urlsFor('H'), <String>['https://192.0.2.7:38765']);
    expect(r.log, <String>['start', 'end'], reason: '浏览期间登记进退出清理集合');
    expect(r.made.single.stopped, isTrue, reason: '浏览完必须停掉原生 browser');
  });

  test('明文 host（TXT 不带 tls=1）不给地址；找不到 → 空', () async {
    final r = build(<BonsoirService>[resolved(id: 'H', tls: false)]);
    expect(await r.relocator.urlsFor('H'), isEmpty);
    expect(await r.relocator.urlsFor('MISSING'), isEmpty);
  });

  test('窗口内复用同一轮浏览结果；并发请求合进一轮；过期后重新浏览', () async {
    DateTime clock = DateTime(2026, 11, 21);
    final r = build(<BonsoirService>[
      resolved(id: 'H'),
      resolved(id: 'G', host: '192.0.2.8', name: 'Laptop'),
    ], now: () => clock);
    final List<List<String>> both = await Future.wait(<Future<List<String>>>[
      r.relocator.urlsFor('H'),
      r.relocator.urlsFor('G'),
    ]);
    expect(both, <List<String>>[
      <String>['https://192.0.2.7:38765'],
      <String>['https://192.0.2.8:38765'],
    ]);
    expect(await r.relocator.urlsFor('MISSING'), isEmpty);
    expect(r.made, hasLength(1), reason: '30 秒窗口内只浏览一次');

    clock = clock.add(const Duration(seconds: 31));
    await r.relocator.urlsFor('H');
    expect(r.made, hasLength(2));
  });

  test('IPv6 地址按 URI 规则加方括号', () async {
    final r = build(<BonsoirService>[resolved(id: 'H', host: 'fd00::7')]);
    expect(await r.relocator.urlsFor('H'), <String>['https://[fd00::7]:38765']);
  });
}

/// 起浏览后立即把 [advertised] 作为已解析服务派发出去。
class _FakeDiscovery implements BonsoirDiscovery {
  _FakeDiscovery(this.type, this.advertised);

  @override
  final String type;
  final List<BonsoirService> advertised;
  final StreamController<BonsoirDiscoveryEvent> _events =
      StreamController<BonsoirDiscoveryEvent>.broadcast();
  bool stopped = false;

  @override
  Future<void> initialize() async {}

  @override
  Stream<BonsoirDiscoveryEvent>? get eventStream => _events.stream;

  @override
  Future<void> start() async {
    scheduleMicrotask(() {
      for (final BonsoirService s in advertised) {
        _events.add(BonsoirDiscoveryServiceResolvedEvent(service: s));
      }
    });
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
