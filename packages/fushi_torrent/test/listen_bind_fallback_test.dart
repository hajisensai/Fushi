// BUG-2023 回归：监听端口被拒（access_denied）时 libtorrent 必须回退，不能整条
// listen socket 丢掉。
//
// 根因（native/fushi_torrent/vcpkg-ports/libtorrent/
// listen-bind-access-denied-fallback.patch）：setup_listener 先 bind TCP，再把
// uTP 的 UDP socket bind 到**同一个端口**；只有 address_in_use 会重试/回退，
// 其它错误一律丢掉整条 listen socket（连同已经 bind 好的 TCP）。Windows 上 TCP
// 可用、UDP 却回 WSAEACCES(10013) 的端口很常见：Hyper-V/WinNAT 的 UDP 排除段、
// 被系统服务独占的 UDP 端口（mDNS 5353）。于是 `127.0.0.1:0` 拿到这样一个
// TCP 端口时 listen_port()==0，而且没有 listen socket 就连不出去
// （`[sock_bind] not supported`）——做种端就是 CI 上的
// `timeout waiting for seeder listen port`，下载端就是 ip_filter 用例的
// `timeout waiting for metadata after clearing ip_filter`。
//
// 两条用例按平台各自确定性地造出「被拒」的端口；机器上造不出来就 skip 并写明
// 原因，不假绿。库路径同其它用例：FUSHI_TORRENT_LIB 指向 DLL/.so，缺库整组 skip。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:fushi_torrent/testing.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

Future<void> _pollUntil(
  bool Function() done, {
  required Duration timeout,
  required String what,
  void Function()? onTick,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) fail('timeout waiting for $what');
    onTick?.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

const int _wsaeacces = 10013;
const int _eacces = 13;

/// 一个回环端口：TCP 能 bind，UDP 的普通 bind（不带任何复用选项，与
/// libtorrent 的 uTP socket 相同）被拒并回 WSAEACCES。候选取本机 UDP 排除段
/// 的每段首个端口，外加 mDNS 的 5353。找不到返回 null。
Future<int?> _findUdpRefusedTcpBindablePort() async {
  final List<int> candidates = <int>[5353];
  try {
    final ProcessResult r = await Process.run('netsh', <String>[
      'int',
      'ipv4',
      'show',
      'excludedportrange',
      'protocol=udp',
    ]);
    for (final RegExpMatch m in RegExp(
      r'^\s*(\d+)\s+(\d+)',
      multiLine: true,
    ).allMatches('${r.stdout}')) {
      candidates.add(int.parse(m.group(1)!));
    }
  } on ProcessException {
    // 没有 netsh 就只剩 5353 这一个候选。
  }
  for (final int port in candidates) {
    try {
      final RawDatagramSocket udp = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        reuseAddress: false,
      );
      udp.close();
      continue; // UDP 能 bind，不是要找的端口。
    } on SocketException catch (e) {
      if (e.osError?.errorCode != _wsaeacces) continue;
    }
    try {
      final ServerSocket tcp = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await tcp.close();
      return port;
    } on SocketException {
      continue; // TCP 也被拒/被占：libtorrent 会走 TCP 侧的回退，不是本用例的形状。
    }
  }
  return null;
}

/// 一个 TCP bind 回 EACCES 的回环端口（POSIX 非 root 下的特权端口）。
Future<int?> _findTcpAccessDeniedPort() async {
  const int port = 80;
  try {
    final ServerSocket tcp = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    await tcp.close();
    return null; // root 或放开了 ip_unprivileged_port_start：造不出 EACCES。
  } on SocketException catch (e) {
    return e.osError?.errorCode == _eacces ? port : null;
  }
}

void main() {
  final String? explicit = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    try {
      return EmbeddedTorrentEngine.open(libraryPath: explicit);
    } on ArgumentError {
      return null;
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();
  final String? skip =
      engine == null ? 'fushi_torrent_ffi native lib not built' : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_listen_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'UDP bind refused with WSAEACCES: session keeps listening and connects out',
    () async {
      if (!Platform.isWindows) {
        markTestSkipped('WSAEACCES on a TCP-bindable port is a Windows shape');
        return;
      }
      final int? port = await _findUdpRefusedTcpBindablePort();
      if (port == null) {
        markTestSkipped(
          'no loopback port here is TCP-bindable but UDP-refused (WSAEACCES)',
        );
        return;
      }

      final LocalSeedRig rig = await LocalSeedRig.start(
        engine: engine!,
        workDir: tempDir,
        contentBytes: 256 * 1024,
      );
      addTearDown(rig.dispose);

      final EmbeddedTorrentSession? leecher = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:$port',
      );
      expect(leecher, isNotNull);
      addTearDown(leecher!.close);

      // 修复前：uTP bind 回 10013，整条 listen socket 被丢，端口恒为 0。
      // 修复后：TCP 留在请求的端口上，uTP 退到别的端口。
      await _pollUntil(
        () => leecher.listenPort > 0,
        timeout: const Duration(seconds: 10),
        what: 'a listen port although UDP $port is refused with WSAEACCES and '
            'TCP accepts it (libtorrent dropped the whole listen socket '
            'instead of falling back on the UDP side, BUG-2023)',
      );
      expect(leecher.listenPort, port);

      // 没有 listen socket 时出站连接直接 `[sock_bind] not supported`——这才是
      // 用户可见的症状，所以还要真的连出去拿到元数据。
      final FtAddResult added = leecher.addMagnet(
        rig.magnetUri,
        savePath: '${tempDir.path}/dl',
      );
      expect(added.ok, isTrue, reason: 'addMagnet: ${added.error}');
      await _pollUntil(
        () => leecher.listTorrents().any(
              (FtTorrentStatus t) => t.id == rig.infoHash && t.hasMetadata,
            ),
        timeout: const Duration(seconds: 30),
        what: 'metadata over a session whose uTP port was refused',
        onTick: () =>
            leecher.connectPeer(rig.infoHash, '127.0.0.1', rig.seederPort),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'TCP bind refused with EACCES: session falls back to an OS-assigned port',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('Windows has no privileged ports');
        return;
      }
      final int? port = await _findTcpAccessDeniedPort();
      if (port == null) {
        markTestSkipped('binding a privileged port is allowed here (root?)');
        return;
      }

      final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
        engine!,
        listenInterfaces: '127.0.0.1:$port',
      );
      expect(session, isNotNull);
      addTearDown(session!.close);

      // 修复前：TCP bind 回 EACCES，不重试不回退，listen_port()==0。
      await _pollUntil(
        () => session.listenPort > 0,
        timeout: const Duration(seconds: 10),
        what: 'a listen port although $port is refused with EACCES '
            '(listen_system_port_fallback must let the OS pick one, BUG-2023)',
      );
      expect(session.listenPort, isNot(port));
    },
    skip: skip,
  );
}
