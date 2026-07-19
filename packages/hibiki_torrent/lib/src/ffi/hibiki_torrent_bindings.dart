// GENERATED / hand-mirrored — do not edit by hand except to re-run ffigen.
//
// 本文件是 `ffigen.yaml` 对 native/hibiki_torrent/.../hibiki_torrent.h 的产物。
// 本机装有 LLVM/libclang 时可 `dart run ffigen --config ffigen.yaml` 覆盖重生；
// 内容与 ffigen 对该 C ABI 的输出等价（单一 DynamicLibrary 构造 +
// lookup 惰性字段），与仓库既有 hoshidicts FFI 手写范式一致。
//
// ignore_for_file: always_specify_types, camel_case_types, non_constant_identifier_names

import 'dart:ffi' as ffi;

/// Dart FFI bindings for the hibiki_torrent C ABI bridge over libtorrent.
class HibikiTorrentBindings {
  /// Holds the symbol lookup function.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  /// The symbols are looked up in [dynamicLibrary].
  HibikiTorrentBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  /// The symbols are looked up with [lookup].
  HibikiTorrentBindings.fromLookup(
    ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) lookup,
  ) : _lookup = lookup;

  /// 返回 libtorrent 运行时版本串（如 "2.0.11.0"）。指向 libtorrent 内部
  /// 静态存储，调用方不得 free。
  ffi.Pointer<ffi.Char> ht_libtorrent_version() {
    return _ht_libtorrent_version();
  }

  late final _ht_libtorrent_versionPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'ht_libtorrent_version');
  late final _ht_libtorrent_version =
      _ht_libtorrent_versionPtr.asFunction<ffi.Pointer<ffi.Char> Function()>();

  /// 创建 libtorrent session；listen_interfaces NULL/空串 = 不监听，
  /// enable_dht 非 0 开 DHT。失败返回 NULL。
  ffi.Pointer<ffi.Void> ht_session_create(
    ffi.Pointer<ffi.Char> listen_interfaces,
    int enable_dht,
  ) {
    return _ht_session_create(listen_interfaces, enable_dht);
  }

  late final _ht_session_createPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.Char>, ffi.Int)>>('ht_session_create');
  late final _ht_session_create = _ht_session_createPtr
      .asFunction<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>, int)>();

  /// 销毁 ht_session_create 返回的句柄；传 NULL 为 no-op。
  void ht_session_destroy(ffi.Pointer<ffi.Void> session) {
    return _ht_session_destroy(session);
  }

  late final _ht_session_destroyPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          'ht_session_destroy');
  late final _ht_session_destroy =
      _ht_session_destroyPtr.asFunction<void Function(ffi.Pointer<ffi.Void>)>();

  /// 实际监听端口；未监听/无效返回 0。
  int ht_session_listen_port(ffi.Pointer<ffi.Void> session) {
    return _ht_session_listen_port(session);
  }

  late final _ht_session_listen_portPtr =
      _lookup<ffi.NativeFunction<ffi.Int Function(ffi.Pointer<ffi.Void>)>>(
          'ht_session_listen_port');
  late final _ht_session_listen_port = _ht_session_listen_portPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// 全局速率上限（字节/秒；<=0 不限）。1 成功 0 失败。
  int ht_session_set_rate_limits(
    ffi.Pointer<ffi.Void> session,
    int download_bps,
    int upload_bps,
  ) {
    return _ht_session_set_rate_limits(session, download_bps, upload_bps);
  }

  late final _ht_session_set_rate_limitsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Int,
              ffi.Int)>>('ht_session_set_rate_limits');
  late final _ht_session_set_rate_limits = _ht_session_set_rate_limitsPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>, int, int)>();

  /// 一次设全局资源限制（速率 bps + 连接数）。1 成功 0 失败。
  int ht_apply_limits(
    ffi.Pointer<ffi.Void> session,
    int download_bps,
    int upload_bps,
    int connections_limit,
  ) {
    return _ht_apply_limits(
        session, download_bps, upload_bps, connections_limit);
  }

  late final _ht_apply_limitsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Int, ffi.Int,
              ffi.Int)>>('ht_apply_limits');
  late final _ht_apply_limits = _ht_apply_limitsPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>, int, int, int)>();

  /// 添加磁力；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_add_magnet(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> magnet_uri,
    ffi.Pointer<ffi.Char> save_path,
    int sequential,
  ) {
    return _ht_add_magnet(session, magnet_uri, save_path, sequential);
  }

  late final _ht_add_magnetPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>,
              ffi.Int)>>('ht_add_magnet');
  late final _ht_add_magnet = _ht_add_magnetPtr.asFunction<
      ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int)>();

  /// 添加本地 .torrent 文件；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_add_torrent_file(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> torrent_path,
    ffi.Pointer<ffi.Char> save_path,
    int sequential,
  ) {
    return _ht_add_torrent_file(session, torrent_path, save_path, sequential);
  }

  late final _ht_add_torrent_filePtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>,
              ffi.Int)>>('ht_add_torrent_file');
  late final _ht_add_torrent_file = _ht_add_torrent_filePtr.asFunction<
      ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int)>();

  /// 从本地文件/目录生成 .torrent；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_make_torrent(
    ffi.Pointer<ffi.Char> content_path,
    ffi.Pointer<ffi.Char> out_torrent_path,
  ) {
    return _ht_make_torrent(content_path, out_torrent_path);
  }

  late final _ht_make_torrentPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>)>>('ht_make_torrent');
  late final _ht_make_torrent = _ht_make_torrentPtr.asFunction<
      ffi.Pointer<ffi.Char> Function(
          ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)>();

  /// 手动连接 peer。1 成功 0 失败。
  int ht_connect_peer(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
    ffi.Pointer<ffi.Char> ip,
    int port,
  ) {
    return _ht_connect_peer(session, info_hash, ip, port);
  }

  late final _ht_connect_peerPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>, ffi.Int)>>('ht_connect_peer');
  late final _ht_connect_peer = _ht_connect_peerPtr.asFunction<
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Char>, int)>();

  /// 列出所有种子；返回 malloc JSON 数组（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_list_torrents(ffi.Pointer<ffi.Void> session) {
    return _ht_list_torrents(session);
  }

  late final _ht_list_torrentsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Void>)>>('ht_list_torrents');
  late final _ht_list_torrents = _ht_list_torrentsPtr
      .asFunction<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>();

  /// 某种子的文件列表；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_torrent_files(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
  ) {
    return _ht_torrent_files(session, info_hash);
  }

  late final _ht_torrent_filesPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>)>>('ht_torrent_files');
  late final _ht_torrent_files = _ht_torrent_filesPtr.asFunction<
      ffi.Pointer<ffi.Char> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>();

  /// 分片持有位图；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_torrent_pieces(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
  ) {
    return _ht_torrent_pieces(session, info_hash);
  }

  late final _ht_torrent_piecesPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>)>>('ht_torrent_pieces');
  late final _ht_torrent_pieces = _ht_torrent_piecesPtr.asFunction<
      ffi.Pointer<ffi.Char> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>();

  /// 排空 piece 完成事件；返回 malloc JSON 数组（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_poll_piece_events(ffi.Pointer<ffi.Void> session) {
    return _ht_poll_piece_events(session);
  }

  late final _ht_poll_piece_eventsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Void>)>>('ht_poll_piece_events');
  late final _ht_poll_piece_events = _ht_poll_piece_eventsPtr
      .asFunction<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>();

  /// 单 piece 截止期（ms）。1 成功 0 失败。
  int ht_set_piece_deadline(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
    int piece,
    int deadline_ms,
  ) {
    return _ht_set_piece_deadline(session, info_hash, piece, deadline_ms);
  }

  late final _ht_set_piece_deadlinePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>,
              ffi.Int, ffi.Int)>>('ht_set_piece_deadline');
  late final _ht_set_piece_deadline = _ht_set_piece_deadlinePtr.asFunction<
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, int, int)>();

  /// 首尾 piece 提优。1 已应用 0 元数据未就绪 -1 种子不存在。
  int ht_apply_first_last_priority(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
  ) {
    return _ht_apply_first_last_priority(session, info_hash);
  }

  late final _ht_apply_first_last_priorityPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>)>>('ht_apply_first_last_priority');
  late final _ht_apply_first_last_priority = _ht_apply_first_last_priorityPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>();

  /// 某种子当前连接的 peer 列表；返回 malloc JSON（ht_free_string 释放）。
  ffi.Pointer<ffi.Char> ht_torrent_peers(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
  ) {
    return _ht_torrent_peers(session, info_hash);
  }

  late final _ht_torrent_peersPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>)>>('ht_torrent_peers');
  late final _ht_torrent_peers = _ht_torrent_peersPtr.asFunction<
      ffi.Pointer<ffi.Char> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>();

  /// 用换行分隔的 CIDR 列表整体重建 ip_filter。1 成功 0 失败。
  int ht_apply_ip_filter(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> cidrs,
  ) {
    return _ht_apply_ip_filter(session, cidrs);
  }

  late final _ht_apply_ip_filterPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Char>)>>('ht_apply_ip_filter');
  late final _ht_apply_ip_filter = _ht_apply_ip_filterPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)>();

  /// 移除种子。1 成功 0 失败。
  int ht_remove_torrent(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Char> info_hash,
    int delete_files,
  ) {
    return _ht_remove_torrent(session, info_hash, delete_files);
  }

  late final _ht_remove_torrentPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>,
              ffi.Int)>>('ht_remove_torrent');
  late final _ht_remove_torrent = _ht_remove_torrentPtr.asFunction<
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, int)>();

  /// 释放本库返回的 char* 串；传 NULL 为 no-op。
  void ht_free_string(ffi.Pointer<ffi.Char> s) {
    return _ht_free_string(s);
  }

  late final _ht_free_stringPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>(
          'ht_free_string');
  late final _ht_free_string =
      _ht_free_stringPtr.asFunction<void Function(ffi.Pointer<ffi.Char>)>();
}
