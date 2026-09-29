import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'ffi/fushi_p2p_bindings.dart';
import 'fushi_p2p_library.dart';

/// 原生调用返回 `{"ok":false,"error":...}` 或句柄已关闭。
class FushiP2pException implements Exception {
  const FushiP2pException(this.message);

  final String message;

  @override
  String toString() => 'FushiP2pException: $message';
}

/// 端点自身的信息。
class FushiP2pInfo {
  const FushiP2pInfo({
    required this.nodeId,
    required this.secretKeyHex,
    required this.relayUrl,
    required this.directAddrs,
    this.online,
  });

  factory FushiP2pInfo.fromJson(Map<String, Object?> json) => FushiP2pInfo(
    nodeId: json['nodeId']! as String,
    secretKeyHex: json['secretKeyHex']! as String,
    relayUrl: json['relayUrl'] as String?,
    directAddrs: (json['directAddrs'] as List<Object?>? ?? const <Object?>[])
        .cast<String>(),
    online: json['online'] as bool?,
  );

  /// 64 位小写 hex 的 NodeId（= ed25519 公钥）。
  final String nodeId;

  /// 32 字节私钥 hex。只能存设备本地，绝不能随备份外带（否则两台设备同一 NodeId）。
  final String secretKeyHex;

  /// 当前 home relay；还没连上中继时为 null。
  final String? relayUrl;

  /// 本机可被直连的 `ip:port`（含 LAN / 经 STUN 探得的公网地址）。
  final List<String> directAddrs;

  /// 仅 [FushiP2pEndpoint.waitOnline] 返回时有值。
  final bool? online;
}

/// 到对端连接当前走的路径。
enum FushiP2pPathKind {
  /// 选中的是直连 UDP 路径（打洞成功 / 同 LAN）。
  direct,

  /// 只走中继。桌面开 Clash TUN 之类改写 UDP 源端口时会长期停在这里。
  relay,

  /// 直连与中继路径都开着但还没选定（打洞进行中）。
  mixed,

  /// 没有连接 / 没有路径。
  none,
}

/// `fp2p_conn_status` 的结果。
class FushiP2pConnStatus {
  const FushiP2pConnStatus({
    required this.connected,
    required this.path,
    required this.rttMs,
    required this.directPaths,
    required this.relayPaths,
  });

  factory FushiP2pConnStatus.fromJson(Map<String, Object?> json) {
    final String path = json['path'] as String? ?? 'none';
    return FushiP2pConnStatus(
      connected: json['connected'] as bool? ?? false,
      path: FushiP2pPathKind.values.firstWhere(
        (FushiP2pPathKind k) => k.name == path,
        orElse: () => FushiP2pPathKind.none,
      ),
      rttMs: (json['rttMs'] as num?)?.toDouble(),
      directPaths: (json['directPaths'] as num?)?.toInt() ?? 0,
      relayPaths: (json['relayPaths'] as num?)?.toInt() ?? 0,
    );
  }

  final bool connected;
  final FushiP2pPathKind path;

  /// 选中路径的 RTT（毫秒）；无连接为 null。
  final double? rttMs;
  final int directPaths;
  final int relayPaths;
}

/// 一个 iroh 端点（= 一个 NodeId + 自己的 tokio runtime）。
///
/// 所有方法都是同步 FFI 调用，除 [close] 外都不会在网络上阻塞：拨号发生在
/// 第一条本地 TCP 连进转发口时，在原生线程里进行。
class FushiP2pEndpoint {
  FushiP2pEndpoint._(this._lib, this._handle);

  /// 创建端点。[secretKeyHex] 为 null = 新生成（之后从 [info] 取出持久化）；
  /// [relayUrls] 为空 = iroh 默认 n0 公共中继，否则只用这些自建 iroh-relay。
  ///
  /// 原生库不可用时抛 [StateError]；创建失败抛 [FushiP2pException]。
  static FushiP2pEndpoint create({
    FushiP2p? library,
    String? secretKeyHex,
    List<String> relayUrls = const <String>[],
  }) {
    final FushiP2p? lib = library ?? FushiP2p.instance;
    if (lib == null) {
      throw StateError('fushi_p2p native library is not available');
    }
    final FushiP2pBindings b = lib.bindings;
    final Pointer<Utf8> secret = secretKeyHex == null
        ? nullptr
        : secretKeyHex.toNativeUtf8();
    final Pointer<Utf8> relays = relayUrls.isEmpty
        ? nullptr
        : jsonEncode(relayUrls).toNativeUtf8();
    try {
      final Pointer<Fp2pEndpoint> h = b.fp2p_endpoint_create(
        secret.cast(),
        relays.cast(),
      );
      if (h == nullptr) {
        final String? err = _takeString(b, b.fp2p_last_error());
        throw FushiP2pException(err ?? 'fp2p_endpoint_create failed');
      }
      return FushiP2pEndpoint._(lib, h);
    } finally {
      if (secret != nullptr) malloc.free(secret);
      if (relays != nullptr) malloc.free(relays);
    }
  }

  final FushiP2p _lib;
  Pointer<Fp2pEndpoint> _handle;

  bool get isClosed => _handle == nullptr;

  FushiP2pBindings get _b => _lib.bindings;

  Pointer<Fp2pEndpoint> get _h {
    if (_handle == nullptr) {
      throw const FushiP2pException('endpoint is closed');
    }
    return _handle;
  }

  /// 端点信息（NodeId / 私钥 / 当前中继 / 直连地址）。
  FushiP2pInfo info() =>
      FushiP2pInfo.fromJson(_call(_b.fp2p_endpoint_info(_h)));

  /// 等到连上 home relay 或超时。以短间隔轮询原生状态，不阻塞 isolate。
  Future<FushiP2pInfo> waitOnline(
    Duration timeout, {
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (true) {
      final FushiP2pInfo info = FushiP2pInfo.fromJson(
        _call(_b.fp2p_endpoint_online(_h, 0)),
      );
      if (info.online == true || !DateTime.now().isBefore(deadline)) {
        return info;
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// 作为主机：进来的每条流 → `127.0.0.1:forwardPort`。重复调用即改目标端口。
  void hostListen(int forwardPort) {
    _checkPort(forwardPort, allowZero: false);
    _call(_b.fp2p_host_listen(_h, forwardPort));
  }

  /// 停止接受入站隧道（已建立的流不受影响）。
  void hostStop() {
    _call(_b.fp2p_host_listen(_h, 0));
  }

  /// 作为客户端：在 `127.0.0.1:<返回值>` 开本地转发口，每条连接 → [nodeId]。
  ///
  /// [directAddrs]（`ip:port`）/ [relayUrl] 是可选地址提示：给了就直接按它拨，
  /// 不必等 n0 DNS / DHT 发现（离线 LAN、或主机地址集里已带直连地址时）。
  int clientForward(
    String nodeId, {
    List<String> directAddrs = const <String>[],
    String? relayUrl,
  }) {
    final bool hasHint = directAddrs.isNotEmpty || relayUrl != null;
    final Pointer<Utf8> node = nodeId.toNativeUtf8();
    final Pointer<Utf8> hint = hasHint
        ? jsonEncode(<String, Object?>{
            'directAddrs': directAddrs,
            'relayUrl': relayUrl,
          }).toNativeUtf8()
        : nullptr;
    try {
      final Map<String, Object?> r = _call(
        _b.fp2p_client_forward(_h, node.cast(), hint.cast()),
      );
      return (r['port']! as num).toInt();
    } finally {
      malloc.free(node);
      if (hint != nullptr) malloc.free(hint);
    }
  }

  /// 关掉 [clientForward] 开的本地转发口。返回该口是否存在。
  bool stopForward(int port) {
    _checkPort(port, allowZero: false);
    return _call(_b.fp2p_client_forward_stop(_h, port))['stopped'] == true;
  }

  /// 到 [nodeId] 的连接状态（出站优先，其次入站）。
  FushiP2pConnStatus status(String nodeId) {
    final Pointer<Utf8> node = nodeId.toNativeUtf8();
    try {
      return FushiP2pConnStatus.fromJson(
        _call(_b.fp2p_conn_status(_h, node.cast())),
      );
    } finally {
      malloc.free(node);
    }
  }

  /// 主机侧：本地 HTTP 服务器看到的对端端口 [remotePort]（= 隧道转发连接的本地
  /// 源端口）属于哪个隧道对端。不是隧道连接、或流已结束 → null。端点已关闭也返回
  /// null：关闭后隧道里不会再有新请求，已在途的按「身份未知」处理。
  String? hostPeer(int remotePort) {
    if (_handle == nullptr) return null;
    _checkPort(remotePort, allowZero: false);
    final Object? id = _call(_b.fp2p_host_peer(_h, remotePort))['nodeId'];
    return id is String ? id : null;
  }

  /// 关闭端点并释放原生资源（同步）。可重复调用。
  ///
  /// iroh 会等对端确认连接关闭：有过连接时实测 0.8~2 秒、上限约 4 秒，
  /// 期间阻塞当前 isolate。UI isolate 上请用 [closeAsync]。
  void close() {
    if (_handle == nullptr) return;
    final Pointer<Fp2pEndpoint> h = _handle;
    _handle = nullptr;
    _b.fp2p_endpoint_close(h);
  }

  /// 同 [close]，但原生关闭在一个临时 isolate 里执行，不阻塞调用方。
  /// 句柄在调用时立即失效。
  Future<void> closeAsync() async {
    if (_handle == nullptr) return;
    final int address = _handle.address;
    _handle = nullptr;
    final String? path = _lib.libraryPath;
    await Isolate.run(() {
      // 同一路径再 open 拿到的是同一个已加载模块，句柄地址在其中仍然有效。
      final DynamicLibrary dl = path == null
          ? DynamicLibrary.process()
          : DynamicLibrary.open(path);
      FushiP2pBindings(
        dl,
      ).fp2p_endpoint_close(Pointer<Fp2pEndpoint>.fromAddress(address));
    });
  }

  Map<String, Object?> _call(Pointer<Char> raw) {
    final String? text = _takeString(_b, raw);
    if (text == null) {
      throw const FushiP2pException('native call returned NULL');
    }
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw FushiP2pException('unexpected native payload: $text');
    }
    if (decoded['ok'] != true) {
      throw FushiP2pException(
        decoded['error'] as String? ?? 'unknown native error',
      );
    }
    return decoded;
  }

  static String? _takeString(FushiP2pBindings b, Pointer<Char> raw) {
    if (raw == nullptr) return null;
    try {
      return raw.cast<Utf8>().toDartString();
    } finally {
      b.fp2p_string_free(raw);
    }
  }

  static void _checkPort(int port, {required bool allowZero}) {
    if (port < (allowZero ? 0 : 1) || port > 65535) {
      throw ArgumentError.value(port, 'port', 'out of range');
    }
  }
}
