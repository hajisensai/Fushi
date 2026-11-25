import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:test/test.dart';

/// BUG：无头服务端 `bind` 配成具体地址或 `::1` 仍监听全部网卡。
///
/// 引擎此前只收一个 `allowLan` 布尔，非回环一律 anyIPv4 / 双栈 anyIPv6；现在收
/// 类型化的 [FushiListenScope]，`exact` 精确绑定那一个地址。
Future<bool> _hostHasIPv6Loopback() async {
  try {
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv6,
      0,
    );
    await probe.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// 本机第一个非回环 v4 网卡地址；取不到（沙箱 / 无网卡）时 null。
Future<InternetAddress?> _firstNonLoopbackV4() async {
  try {
    final List<NetworkInterface> nics = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final NetworkInterface nic in nics) {
      for (final InternetAddress a in nic.addresses) {
        if (!a.isLoopback) return InternetAddress(a.address);
      }
    }
  } on SocketException {
    return null;
  }
  return null;
}

Future<bool> _canConnect(InternetAddress host, int port) async {
  try {
    final Socket s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 2),
    );
    s.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> main() async {
  final bool hasIPv6Loopback = await _hostHasIPv6Loopback();
  final InternetAddress? lanV4 = await _firstNonLoopbackV4();

  late Directory tempDir;
  FushiSyncServer? server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_listen_scope_test');
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<FushiSyncServer> start(
    FushiListenScope scope, {
    SecurityContext? securityContext,
  }) async {
    final FushiSyncServer s = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'listen-scope-token',
      listenScope: scope,
      securityContext: securityContext,
    );
    server = s;
    await s.start();
    return s;
  }

  test('isLoopbackOnly：loopbackV4 / lan / exact 各按地址判', () {
    expect(const FushiListenScope.loopbackV4().isLoopbackOnly, isTrue);
    expect(const FushiListenScope.lan().isLoopbackOnly, isFalse);
    expect(
      FushiListenScope.exact(InternetAddress.loopbackIPv6).isLoopbackOnly,
      isTrue,
    );
    expect(
      FushiListenScope.exact(InternetAddress('127.0.0.2')).isLoopbackOnly,
      isTrue,
    );
    expect(
      FushiListenScope.exact(InternetAddress('192.168.1.5')).isLoopbackOnly,
      isFalse,
    );
  });

  test('exact(127.0.0.1)：只听回环', () async {
    final FushiSyncServer s = await start(
      FushiListenScope.exact(InternetAddress.loopbackIPv4),
    );
    expect(s.boundAddress?.isLoopback, isTrue);
    expect(s.listensBeyondLoopback, isFalse);
    expect(await _canConnect(InternetAddress.loopbackIPv4, s.port), isTrue);
  });

  test('exact(::1)：只听 v6 回环', () async {
    final FushiSyncServer s = await start(
      FushiListenScope.exact(InternetAddress.loopbackIPv6),
    );
    expect(s.boundAddress?.isLoopback, isTrue);
    expect(s.boundAddress?.type, InternetAddressType.IPv6);
    expect(s.listensBeyondLoopback, isFalse);
    expect(await _canConnect(InternetAddress.loopbackIPv6, s.port), isTrue);
    // 不能再像升级前那样落到 anyIPv4 全网卡。
    expect(await _canConnect(InternetAddress.loopbackIPv4, s.port), isFalse);
  }, skip: hasIPv6Loopback ? false : '本机没有 IPv6 回环，无从验证 ::1 监听');

  test('exact(网卡地址)：只听该地址，127.0.0.1 连不上', () async {
    final FushiSyncServer s = await start(FushiListenScope.exact(lanV4!));
    expect(s.boundAddress?.address, lanV4.address);
    expect(s.listensBeyondLoopback, isTrue);
    expect(await _canConnect(lanV4, s.port), isTrue);
    expect(await _canConnect(InternetAddress.loopbackIPv4, s.port), isFalse);
  }, skip: lanV4 == null ? '本机没有非回环 IPv4 网卡地址' : false);

  test('exact(网卡地址) + TLS：配对链接只公布这一条网卡地址', () async {
    final FushiTlsIdentity id = await FushiTlsIdentityStore(
      dataDir: tempDir.path,
    ).loadOrCreate();
    final SecurityContext ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(id.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
    final FushiSyncServer s = await start(
      FushiListenScope.exact(lanV4!),
      securityContext: ctx,
    );
    s
      ..hostId = 'host-listen-scope'
      ..interfaceLister = () async => <NetworkInterface>[
        _FakeNic('eth0', <InternetAddress>[lanV4]),
        _FakeNic('eth1', <InternetAddress>[InternetAddress('10.99.99.99')]),
      ];
    final FushiPairLink link = await s.buildPairLink();
    final List<String> urls = <String>[
      for (final InterconnectHostAddress a in link.addresses) a.url,
    ];
    expect(urls, contains('https://${lanV4.address}:${s.port}'));
    expect(urls.where((String u) => u.contains('10.99.99.99')), isEmpty);
  }, skip: lanV4 == null ? '本机没有非回环 IPv4 网卡地址' : false);

  test('lan() 明文：仍只听 anyIPv4（不回归）', () async {
    final FushiSyncServer s = await start(const FushiListenScope.lan());
    expect(s.boundAddress, InternetAddress.anyIPv4);
    expect(s.listensBeyondLoopback, isTrue);
  });

  test('loopbackV4()：只听 127.0.0.1（不回归）', () async {
    final FushiSyncServer s = await start(const FushiListenScope.loopbackV4());
    expect(s.boundAddress, InternetAddress.loopbackIPv4);
    expect(s.listensBeyondLoopback, isFalse);
  });

  test('不给 listenScope 时由 allowLan 推出', () async {
    final FushiSyncServer s = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'listen-scope-token',
      allowLan: true,
    );
    server = s;
    await s.start();
    expect(s.boundAddress, InternetAddress.anyIPv4);
    expect(s.listensBeyondLoopback, isTrue);
  });
}

class _FakeNic implements NetworkInterface {
  _FakeNic(this.name, List<InternetAddress> addresses)
    : addresses = <InterfaceAddress>[
        for (final InternetAddress a in addresses) _FakeInterfaceAddress(a),
      ];

  @override
  final String name;

  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 0;
}

class _FakeInterfaceAddress implements InterfaceAddress {
  _FakeInterfaceAddress(this._address);

  final InternetAddress _address;

  @override
  int get prefixLength => _address.type == InternetAddressType.IPv4 ? 24 : 64;

  @override
  InternetAddress? get broadcast => null;

  @override
  InternetAddressType get type => _address.type;

  @override
  String get address => _address.address;

  @override
  String get host => _address.host;

  @override
  Uint8List get rawAddress => _address.rawAddress;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  bool get isMulticast => _address.isMulticast;

  @override
  Future<InternetAddress> reverse() => _address.reverse();
}
