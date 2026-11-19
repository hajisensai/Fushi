/// 互联 host 把自己的 BT 引擎借给已配对设备当下载后端（`/api/torrent-engine`）。
///
/// 与代下载（`/api/downloads`）的区别：代下载是「交一条磁链，host 下到**它自己的**
/// 库里」；这里是「client 的下载管线照常跑在 client 上，只有 BT 引擎在 host」——
/// 任务行、整理、入库全在 client，host 只执行 [TorrentBackend] 的粗粒度命令。
/// client 经路径映射看到 host 写出的文件（典型：host 把 client 的媒体库共享目录
/// 挂载进来，下载直接落进 client 的库）。
///
/// 两道边界由 host 守，不信 client：
///
/// * **租约**（[PeerTorrentLeaseStore]）：只有经本路由加进来的种子才对远程可见、
///   可操作；host 自己管线的种子对远程不存在。租约落盘，host 重启时并进内置引擎的
///   resume 保留集合——否则 resume 剪枝会把远程任务当无主文件删掉。
/// * **落盘范围**（[HostTorrentPathPolicy]）：保存目录 / 移动目标只能在 host
///   主人配置的根目录下，已配对设备不能让 host 往任意路径写。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:path/path.dart' as p;

/// 远程租约文件名（服务端在 `<support>/torrent/` 下，app 在下载数据根下）。
const String kPeerTorrentLeaseFileName = 'peer_leases.json';

abstract interface class HostTorrentEngine {
  /// `/api/capabilities.torrentEngine`。
  Future<TorrentEngineCapability> capability();

  /// 用当前可用的后端执行 [action]；没有可用后端 → null，不调用 [action]。
  /// 后端视图的生命周期（建 / 关）归实现方。
  Future<R?> withBackend<R>(Future<R> Function(TorrentBackend backend) action);

  /// 远程任务的租约；null = host 此刻还没就绪（例如 app 的下载中心还没起，租约
  /// 文件的位置都还定不下来），路由回 503。
  Future<PeerTorrentLeaseStore?> leases();

  /// 远程任务允许落盘的根目录（现算：用户改了下载目录 / 媒体来源即生效）。
  Future<HostTorrentPathPolicy> paths();
}

/// 远程任务允许落盘的根目录（host 视角的绝对路径）。
class HostTorrentPathPolicy {
  HostTorrentPathPolicy(Iterable<String> roots, {p.Context? context})
    : _context = context ?? p.context,
      roots = List<String>.unmodifiable(<String>[
        for (final String r in roots)
          if (r.trim().isNotEmpty) (context ?? p.context).normalize(r.trim()),
      ]);

  final p.Context _context;
  final List<String> roots;

  /// [raw] 规范化后落在某个根下（含根本身）就返回规范化路径，否则 null。
  /// 相对路径一律拒绝：client 不知道 host 的工作目录，相对路径只可能是错。
  String? confine(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || !_context.isAbsolute(trimmed)) return null;
    final String normalized = _context.normalize(trimmed);
    for (final String root in roots) {
      if (_context.equals(root, normalized) ||
          _context.isWithin(root, normalized)) {
        return normalized;
      }
    }
    return null;
  }
}

/// 种子内相对路径（改名目标）是否安全：非空、非绝对、不含 `..` 段。
bool isSafeTorrentRelativePath(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return false;
  if (value.startsWith('/') || value.startsWith(r'\')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(value)) return false;
  for (final String part in value.split(RegExp(r'[\\/]'))) {
    if (part == '..') return false;
  }
  return true;
}

/// 分类名是否安全：内置引擎把分类当下载根下的子目录名用。
bool isSafeTorrentCategory(String raw) {
  final String value = raw.trim();
  if (value.isEmpty || value == '.' || value == '..') return false;
  return !value.contains('/') && !value.contains(r'\');
}

/// 一条远程租约。
class PeerTorrentLease {
  const PeerTorrentLease({
    required this.hash,
    required this.owner,
    required this.createdAt,
  });

  /// infohash（小写十六进制）。
  final String hash;

  /// 加入它的已配对设备凭据指纹。访问控制的判据：远程只看得到、只能操作
  /// owner 等于自己凭据指纹的租约（见 [PeerTorrentLeaseStore.ownedBy]）。
  final String owner;
  final int createdAt;
}

/// 远程任务租约的持久化（一个 JSON 文件，原子替换写）。
///
/// 写入串行化：并发的 add / remove 按调用顺序落盘，不会互相覆盖。
class PeerTorrentLeaseStore {
  PeerTorrentLeaseStore(
    this.file, {
    DateTime Function()? now,
    void Function(Set<String> hashes)? onChanged,
  }) : _now = now ?? DateTime.now,
       _onChanged = onChanged;

  final File file;
  final DateTime Function() _now;

  /// 每次写盘成功后带着最新的全部 hash 调用：宿主据此立刻更新 resume 保留集合，
  /// 不等下一轮刷新（其间的周期剪枝会删掉刚交来的远程任务的 resume）。
  final void Function(Set<String> hashes)? _onChanged;
  Map<String, PeerTorrentLease>? _leases;
  Future<void> _writes = Future<void>.value();

  Future<Map<String, PeerTorrentLease>> _load() async {
    final Map<String, PeerTorrentLease>? cached = _leases;
    if (cached != null) return cached;
    final Map<String, PeerTorrentLease> loaded = <String, PeerTorrentLease>{};
    try {
      if (await file.exists()) {
        final Object? decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['leases'] is List) {
          for (final Object? entry in decoded['leases'] as List<Object?>) {
            if (entry is! Map) continue;
            final String hash = '${entry['hash'] ?? ''}'.trim().toLowerCase();
            if (hash.isEmpty) continue;
            loaded[hash] = PeerTorrentLease(
              hash: hash,
              owner: '${entry['owner'] ?? ''}',
              createdAt: entry['createdAt'] is num
                  ? (entry['createdAt'] as num).toInt()
                  : 0,
            );
          }
        }
      }
    } on Object catch (e, s) {
      // 坏文件不能当「没有租约」悄悄覆盖掉：那样下一次剪枝就删远程任务。记日志并
      // 把原文件挪开留证，再从空集开始。
      engineLog.log('PeerTorrentLeaseStore.load', e, s);
      try {
        await file.rename(
          '${file.path}.corrupt-${_now().millisecondsSinceEpoch}',
        );
      } on Object {
        // 挪不开就留在原地；下一次写会覆盖它。
      }
    }
    return _leases ??= loaded;
  }

  /// 全部租约的 infohash（宿主的 resume 保留集合用，不分设备）。
  Future<Set<String>> hashes() async => (await _load()).keys.toSet();

  /// [owner] 自己交来的租约的 infohash：远程列表的唯一来源。
  Future<Set<String>> hashesOwnedBy(String owner) async => <String>{
    for (final PeerTorrentLease l in (await _load()).values)
      if (l.owner == owner) l.hash,
  };

  /// 是否有这条租约（不论属于哪台设备）。
  Future<bool> contains(String hash) async =>
      (await _load()).containsKey(hash.trim().toLowerCase());

  /// 这条租约是否由 [owner] 交来：远程逐种子操作的访问判据。别的设备的租约和
  /// host 自己的种子一样，对 [owner] 来说「不存在」。
  Future<bool> ownedBy(String hash, String owner) async =>
      (await _load())[hash.trim().toLowerCase()]?.owner == owner;

  Future<List<PeerTorrentLease>> all() async =>
      (await _load()).values.toList(growable: false);

  /// 登记一条租约（已存在则保留原登记）。
  Future<void> add(String hash, {required String owner}) =>
      _mutate((Map<String, PeerTorrentLease> leases) {
        final String key = hash.trim().toLowerCase();
        leases.putIfAbsent(
          key,
          () => PeerTorrentLease(
            hash: key,
            owner: owner,
            createdAt: _now().millisecondsSinceEpoch,
          ),
        );
      });

  Future<void> remove(String hash) => _mutate(
    (Map<String, PeerTorrentLease> leases) =>
        leases.remove(hash.trim().toLowerCase()),
  );

  Future<void> _mutate(void Function(Map<String, PeerTorrentLease>) change) {
    final Future<void> next = _writes.then((_) async {
      final Map<String, PeerTorrentLease> leases = await _load();
      change(leases);
      await _persist(leases);
      _onChanged?.call(leases.keys.toSet());
    });
    // 一次写失败不能卡死后续写：链上只挂吞掉错误的版本，调用方拿到原 future。
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _persist(Map<String, PeerTorrentLease> leases) async {
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'leases': <Map<String, Object?>>[
          for (final PeerTorrentLease l in leases.values)
            <String, Object?>{
              'hash': l.hash,
              'owner': l.owner,
              'createdAt': l.createdAt,
            },
        ],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
