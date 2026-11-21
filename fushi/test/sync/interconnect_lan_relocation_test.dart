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
  build(
    List<BonsoirService> advertised, {
    DateTime Function()? now,
    Future<void>? initializeGate,
    Future<void>? stopGate,
  }) {
    final List<_FakeDiscovery> made = <_FakeDiscovery>[];
    final List<String> log = <String>[];
    final InterconnectLanRelocator relocator = InterconnectLanRelocator(
      ownDeviceId: () async => 'SELF',
      discoveryFactory: (String own) => LanDiscoveryService(
        deviceId: own,
        discoveryFactory: (String type) {
          final _FakeDiscovery d = _FakeDiscovery(
            type,
            advertised,
            initializeGate: initializeGate,
            stopGate: stopGate,
          );
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
    // 停 browser 在后台做（不在选路的等待链上）。
    await pumpEventQueue();
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
    expect(r.made, hasLength(1), reason: '并发请求合进一轮');
    // 那一轮因 H、G 都出现而提前结束，对 MISSING 没有定论：重新浏览一轮（跑满）。
    expect(await r.relocator.urlsFor('MISSING'), isEmpty);
    expect(r.made, hasLength(2));
    // 跑满的一轮对所有 host 有定论：30 秒窗口内不再浏览。
    expect(await r.relocator.urlsFor('MISSING'), isEmpty);
    expect(await r.relocator.urlsFor('H'), <String>['https://192.0.2.7:38765']);
    expect(r.made, hasLength(2), reason: '30 秒窗口内只浏览一次');

    clock = clock.add(const Duration(seconds: 31));
    await r.relocator.urlsFor('H');
    expect(r.made, hasLength(3));
  });

  test('提前结束的一轮不拿来回答别的 host：后来要找的 G 重新浏览并找到', () async {
    // H 先被解析出来，只找 H 的那一轮在 G 出现前就结束了。
    final r = build(<BonsoirService>[
      resolved(id: 'H'),
      resolved(id: 'G', host: '192.0.2.8', name: 'Laptop'),
    ]);
    expect(await r.relocator.urlsFor('H'), <String>['https://192.0.2.7:38765']);
    expect(r.made, hasLength(1));
    expect(await r.relocator.urlsFor('G'), <String>['https://192.0.2.8:38765']);
    expect(r.made, hasLength(2));
  });

  test('原生 browser 起不来也停不掉（method channel 不归）：到点照样返回', () async {
    final Completer<void> never = Completer<void>();
    final r = build(<BonsoirService>[
      resolved(id: 'H'),
    ], initializeGate: never.future);
    expect(
      await r.relocator.urlsFor('H').timeout(const Duration(seconds: 3)),
      isEmpty,
    );
    // 窗口内复用这一轮的结论，不再起一个卡住的 browser。
    expect(await r.relocator.urlsFor('H'), isEmpty);
    expect(r.made, hasLength(1));

    final r2 = build(<BonsoirService>[
      resolved(id: 'H'),
    ], stopGate: never.future);
    expect(
      await r2.relocator.urlsFor('H').timeout(const Duration(seconds: 3)),
      <String>['https://192.0.2.7:38765'],
    );
    await pumpEventQueue();
    expect(r2.log, <String>['start'], reason: '停完之前留在退出清理集合里');
  });

  test('IPv6 地址按 URI 规则加方括号', () async {
    final r = build(<BonsoirService>[resolved(id: 'H', host: 'fd00::7')]);
    expect(await r.relocator.urlsFor('H'), <String>['https://[fd00::7]:38765']);
  });
}

/// 起浏览后立即把 [advertised] 作为已解析服务派发出去。
class _FakeDiscovery implements BonsoirDiscovery {
  _FakeDiscovery(
    this.type,
    this.advertised, {
    this.initializeGate,
    this.stopGate,
  });

  @override
  final String type;
  final List<BonsoirService> advertised;
  final Future<void>? initializeGate;
  final Future<void>? stopGate;
  final StreamController<BonsoirDiscoveryEvent> _events =
      StreamController<BonsoirDiscoveryEvent>.broadcast();
  bool stopped = false;

  @override
  Future<void> initialize() async => initializeGate;

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
    await stopGate;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
