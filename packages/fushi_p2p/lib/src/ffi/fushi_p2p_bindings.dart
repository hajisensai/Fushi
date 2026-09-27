// 手写 FFI 绑定：native/fushi_p2p/src/lib.rs 导出的 C ABI（`fp2p_*`）。
//
// 返回 `char*` 的函数（除 fp2p_version 外）一律由调用方 fp2p_string_free 释放；
// 高层封装见 ../fushi_p2p_endpoint.dart，别在业务代码里直接调这些。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

/// 不透明的端点句柄（Rust 侧 `Box<P2p>`）。
final class Fp2pEndpoint extends ffi.Opaque {}

typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _StringFreeC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _StringFreeDart = void Function(ffi.Pointer<ffi.Char>);
typedef _LastErrorC = ffi.Pointer<ffi.Char> Function();
typedef _CreateC =
    ffi.Pointer<Fp2pEndpoint> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _InfoC = ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>);
typedef _OnlineC =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, ffi.Uint32);
typedef _OnlineDart =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, int);
typedef _PortC =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, ffi.Uint16);
typedef _PortDart =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, int);
typedef _ForwardC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<Fp2pEndpoint>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _StatusC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<Fp2pEndpoint>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CloseC = ffi.Void Function(ffi.Pointer<Fp2pEndpoint>);
typedef _CloseDart = void Function(ffi.Pointer<Fp2pEndpoint>);

/// `fp2p_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对，立刻抛
/// [ArgumentError]，由 [FushiP2p.load] 转成「不可用」。
class FushiP2pBindings {
  FushiP2pBindings(ffi.DynamicLibrary lib)
    : fp2p_version = lib.lookupFunction<_VersionC, _VersionC>('fp2p_version'),
      fp2p_string_free = lib.lookupFunction<_StringFreeC, _StringFreeDart>(
        'fp2p_string_free',
      ),
      fp2p_last_error = lib.lookupFunction<_LastErrorC, _LastErrorC>(
        'fp2p_last_error',
      ),
      fp2p_endpoint_create = lib.lookupFunction<_CreateC, _CreateC>(
        'fp2p_endpoint_create',
      ),
      fp2p_endpoint_info = lib.lookupFunction<_InfoC, _InfoC>(
        'fp2p_endpoint_info',
      ),
      fp2p_endpoint_online = lib.lookupFunction<_OnlineC, _OnlineDart>(
        'fp2p_endpoint_online',
      ),
      fp2p_host_listen = lib.lookupFunction<_PortC, _PortDart>(
        'fp2p_host_listen',
      ),
      fp2p_client_forward = lib.lookupFunction<_ForwardC, _ForwardC>(
        'fp2p_client_forward',
      ),
      fp2p_client_forward_stop = lib.lookupFunction<_PortC, _PortDart>(
        'fp2p_client_forward_stop',
      ),
      fp2p_conn_status = lib.lookupFunction<_StatusC, _StatusC>(
        'fp2p_conn_status',
      ),
      fp2p_endpoint_close = lib.lookupFunction<_CloseC, _CloseDart>(
        'fp2p_endpoint_close',
      );

  /// 库版本（静态存储，不要 free）。
  final ffi.Pointer<ffi.Char> Function() fp2p_version;

  /// 释放本库返回的 `char*`。
  final void Function(ffi.Pointer<ffi.Char>) fp2p_string_free;

  /// 本线程最近一次 create 失败原因；可能为 NULL。
  final ffi.Pointer<ffi.Char> Function() fp2p_last_error;

  /// `(secret_key_hex?, relay_urls_json?)` → 句柄；失败 NULL。
  final ffi.Pointer<Fp2pEndpoint> Function(
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fp2p_endpoint_create;

  /// 端点信息 JSON。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>)
  fp2p_endpoint_info;

  /// 等连上 home relay（阻塞至多 timeout_ms），返回信息 JSON + `online`。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, int)
  fp2p_endpoint_online;

  /// 主机转发到 127.0.0.1:port；0 = 停止。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, int)
  fp2p_host_listen;

  /// `(node_id, addr_hint_json?)` → `{"port":N}`。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<Fp2pEndpoint>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fp2p_client_forward;

  /// 停止本地转发口。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<Fp2pEndpoint>, int)
  fp2p_client_forward_stop;

  /// 到某节点的连接/路径状态 JSON。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<Fp2pEndpoint>,
    ffi.Pointer<ffi.Char>,
  )
  fp2p_conn_status;

  /// 关闭并释放句柄。
  final void Function(ffi.Pointer<Fp2pEndpoint>) fp2p_endpoint_close;
}
