/// `/api/torrent-engine` 的 shelf 路由（鉴权由 FushiSyncServer 先做：只认已配对
/// 设备的 per-peer 凭据，[owner] 是该凭据的指纹）。
///
/// ```
/// GET    /api/torrent-engine/probe                     {version}
/// POST   /api/torrent-engine/categories                {category} → {ok}
/// GET    /api/torrent-engine/torrents[?category=]      {torrents: [...]}（只含远程租约）
/// POST   /api/torrent-engine/torrents                  {magnet | torrent(base64)+fileName,
///                                                       category, savePath?, sequential?,
///                                                       firstLastPiecePrio?, paused?}
///                                                      → {ok, hash}
/// GET    /api/torrent-engine/torrents/<h>/files        {files: [...]}
/// POST   /api/torrent-engine/torrents/<h>/rename       {fileIndex, newPath} → 存储结果
/// POST   /api/torrent-engine/torrents/<h>/move         {savePath} → 存储结果
/// POST   /api/torrent-engine/torrents/<h>/pause|resume → {ok}
/// DELETE /api/torrent-engine/torrents/<h>[?deleteFiles=true]  → {ok}
/// POST   /api/torrent-engine/torrents/<h>/trackers     {urls: [...]} → {ok}
/// GET    /api/torrent-engine/torrents/<h>/peers|trackers|priorities|pieces
/// POST   /api/torrent-engine/torrents/<h>/priorities   {indexes: [...], priority} → {ok}
/// GET    /api/torrent-engine/session                   {session}
/// ```
///
/// 与 [TorrentBackend] 同一契约：后端层面的失败回 200 + `ok:false` / `null`，
/// 由 client 原样映射回 false / null；只有请求本身不合法（400）、种子不是远程任务
/// （404）、host 没有可用引擎（503）才用状态码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/media/torrent/magnet_utils.dart';
import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart'
    show readBoundedBodyString;
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';
import 'package:shelf/shelf.dart' as shelf;

/// add 的请求体上限：.torrent 的 base64 可能有几 MB（大合集）。
const int _kAddBodyMaxBytes = 32 * 1024 * 1024;

shelf.Response _json(Object? body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

shelf.Response _bad(String message) =>
    _json(<String, Object?>{'error': message}, status: 400);

shelf.Response _unavailable() => _json(const <String, Object?>{
  'error': 'no torrent engine is available on this host',
}, status: 503);

/// host 还没就绪（[HostTorrentEngine.leases] 交 null）：handler 统一回 503。
class _HostNotReady implements Exception {
  const _HostNotReady();
}

Future<PeerTorrentLeaseStore> _leasesOf(HostTorrentEngine engine) async =>
    await engine.leases() ?? (throw const _HostNotReady());

final RegExp _hashPattern = RegExp(r'^[0-9a-f]{40}$|^[0-9a-f]{64}$');

Future<Map<Object?, Object?>> _body(
  shelf.Request request, {
  int maxBytes = 1024 * 1024,
}) async {
  final String raw = await readBoundedBodyString(request, maxBytes: maxBytes);
  if (raw.trim().isEmpty) return const <Object?, Object?>{};
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('JSON object body required');
  }
  return decoded;
}

String? _optString(Map<Object?, Object?> body, String key) {
  final Object? v = body[key];
  if (v == null) return null;
  final String s = '$v'.trim();
  return s.isEmpty ? null : s;
}

Future<shelf.Response> handleHostTorrentEngineRequest(
  HostTorrentEngine engine,
  shelf.Request request,
  String method,
  String reqPath, {
  required String owner,
}) async {
  final List<String> seg = reqPath
      .substring(kTorrentEngineRoutePrefix.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  try {
    if (seg.isEmpty) return shelf.Response.notFound('Unknown route');
    switch (seg.first) {
      case 'probe':
        if (method != 'GET' || seg.length != 1) return shelf.Response(405);
        final Object? version = await engine.withBackend<String?>(
          (TorrentBackend b) => b.probeConnection(),
        );
        return _json(<String, Object?>{'version': version});
      case 'session':
        if (method != 'GET' || seg.length != 1) return shelf.Response(405);
        return await _withDetail(engine, (TorrentDetailBackend b) async {
          final TorrentSessionStatusInfo? s = await b.sessionStatus();
          return <String, Object?>{
            'session': s == null ? null : torrentSessionStatusToWire(s),
          };
        });
      case 'categories':
        if (method != 'POST' || seg.length != 1) return shelf.Response(405);
        final String? category = _optString(await _body(request), 'category');
        if (category == null || !isSafeTorrentCategory(category)) {
          return _bad('category must be a plain directory name');
        }
        final bool? ok = await engine.withBackend<bool>(
          (TorrentBackend b) => b.prepareCategory(category),
        );
        if (ok == null) return _unavailable();
        return _json(<String, Object?>{'ok': ok});
      case 'torrents':
        if (seg.length == 1) {
          if (method == 'GET') {
            return await _list(engine, request, owner: owner);
          }
          if (method == 'POST') {
            return await _add(engine, request, owner: owner);
          }
          return shelf.Response(405);
        }
        final String hash = seg[1].toLowerCase();
        if (!_hashPattern.hasMatch(hash)) return _bad('malformed torrent id');
        // 租约归属是远程可见性的唯一判据：host 自己的种子、别的已配对设备交来
        // 的种子，对这台设备都「不存在」（同样回 404，不泄露是否有人在下）。
        if (!await (await _leasesOf(engine)).ownedBy(hash, owner)) {
          return shelf.Response.notFound('Unknown remote torrent');
        }
        return await _onTorrent(engine, request, method, hash, seg.sublist(2));
    }
    return shelf.Response.notFound('Unknown torrent-engine route');
  } on FormatException catch (e) {
    return _bad(e.message);
  } on _HostNotReady {
    return _unavailable();
  }
}

Future<shelf.Response> _withDetail(
  HostTorrentEngine engine,
  Future<Map<String, Object?>> Function(TorrentDetailBackend backend) action,
) async {
  final Map<String, Object?>? body = await engine
      .withBackend<Map<String, Object?>>((TorrentBackend b) async {
        if (b is! TorrentDetailBackend) return const <String, Object?>{};
        return action(b);
      });
  if (body == null) return _unavailable();
  return _json(body);
}

Future<shelf.Response> _list(
  HostTorrentEngine engine,
  shelf.Request request, {
  required String owner,
}) async {
  final String? category = request.url.queryParameters['category'];
  final Set<String> leased = await (await _leasesOf(
    engine,
  )).hashesOwnedBy(owner);
  final List<TorrentSnapshot>? all = await engine
      .withBackend<List<TorrentSnapshot>>(
        (TorrentBackend b) => b.listTorrents(
          category: category == null || category.isEmpty ? null : category,
        ),
      );
  if (all == null) return _unavailable();
  return _json(<String, Object?>{
    'torrents': <Map<String, Object?>>[
      for (final TorrentSnapshot s in all)
        if (leased.contains(s.hash.toLowerCase())) torrentSnapshotToWire(s),
    ],
  });
}

Future<shelf.Response> _add(
  HostTorrentEngine engine,
  shelf.Request request, {
  required String owner,
}) async {
  final Map<Object?, Object?> body = await _body(
    request,
    maxBytes: _kAddBodyMaxBytes,
  );
  final String? category = _optString(body, 'category');
  if (category == null || !isSafeTorrentCategory(category)) {
    return _bad('category must be a plain directory name');
  }
  final String? rawSavePath = _optString(body, 'savePath');
  String? savePath;
  if (rawSavePath != null) {
    savePath = (await engine.paths()).confine(rawSavePath);
    if (savePath == null) {
      return _bad('savePath is outside every directory this host allows');
    }
  }
  final bool sequential = body['sequential'] == true;
  final bool firstLast = body['firstLastPiecePrio'] == true;
  final bool paused = body['paused'] == true;
  final String? magnet = _optString(body, 'magnet');
  final String? torrent = _optString(body, 'torrent');
  if ((magnet == null) == (torrent == null)) {
    return _bad('give exactly one of magnet or torrent');
  }

  final String hash;
  final Future<bool> Function(TorrentBackend b) add;
  if (magnet != null) {
    if (paused) return _bad('paused add requires torrent metainfo');
    final String? parsed = parseMagnetInfoHash(magnet);
    if (parsed == null) return _bad('magnet has no BitTorrent info hash');
    hash = parsed;
    add = (TorrentBackend b) => b.addTorrent(
      magnet,
      category: category,
      savePath: savePath,
      sequential: sequential,
      firstLastPiecePrio: firstLast,
    );
  } else {
    final Uint8List bytes;
    try {
      bytes = base64Decode(torrent!);
    } on FormatException {
      return _bad('torrent must be the base64 of a .torrent file');
    }
    // hash 由 host 自己从字节算，不信 client 报的 id。
    final InspectedTorrentMetainfo inspected = inspectTorrentMetainfo(bytes);
    hash = inspected.torrentId.toLowerCase();
    final TorrentMetainfoPayload payload = inspected.toPayload(
      fileName: _optString(body, 'fileName') ?? '$hash.torrent',
    );
    add = (TorrentBackend b) async {
      if (paused) {
        return b is TorrentPausedMetainfoBackend &&
            await b.addTorrentMetainfoPaused(
              payload,
              category: category,
              savePath: savePath,
            );
      }
      return b is TorrentMetainfoBackend &&
          await b.addTorrentMetainfo(
            payload,
            category: category,
            savePath: savePath,
            sequential: sequential,
            firstLastPiecePrio: firstLast,
          );
    };
  }

  final PeerTorrentLeaseStore leases = await _leasesOf(engine);
  // 别的设备已交来同一颗种子：和 host 自己的种子一样不让接管，回 ok:false。
  if (await leases.contains(hash) && !await leases.ownedBy(hash, owner)) {
    return _json(<String, Object?>{'ok': false, 'hash': hash});
  }
  final bool alreadyLeased = await leases.contains(hash);
  // 先登记租约再加：加成功、登记还没落盘时 host 崩溃，种子会在下次剪枝时被删；
  // 反过来最多留一条指向不存在种子的租约（无害，删除时一并清）。
  if (!alreadyLeased) await leases.add(hash, owner: owner);
  final bool? ok = await engine.withBackend<bool>((TorrentBackend b) async {
    if (!alreadyLeased) {
      // host 自己已有同一颗种子：不让远程接管（同管线「不接管已有同 hash 任务」）。
      final List<TorrentSnapshot> present = await b.listTorrents();
      if (present.any((TorrentSnapshot s) => s.hash.toLowerCase() == hash)) {
        return false;
      }
    }
    return add(b);
  });
  if (ok != true && !alreadyLeased) await leases.remove(hash);
  if (ok == null) return _unavailable();
  return _json(<String, Object?>{'ok': ok, 'hash': hash});
}

Future<shelf.Response> _onTorrent(
  HostTorrentEngine engine,
  shelf.Request request,
  String method,
  String hash,
  List<String> rest,
) async {
  if (rest.isEmpty) {
    if (method != 'DELETE') return shelf.Response(405);
    final String? raw = request.url.queryParameters['deleteFiles'];
    final bool deleteFiles = raw == 'true' || raw == '1';
    final bool? ok = await engine.withBackend<bool>(
      (TorrentBackend b) async =>
          b is TorrentRemovalBackend &&
          await b.removeTorrent(hash, deleteFiles: deleteFiles),
    );
    if (ok == null) return _unavailable();
    if (ok) await (await _leasesOf(engine)).remove(hash);
    return _json(<String, Object?>{'ok': ok});
  }
  if (rest.length != 1) return shelf.Response.notFound('Unknown route');
  final String action = rest.single;
  if (method == 'GET') {
    switch (action) {
      case 'files':
        final List<TorrentFileEntry>? files = await engine
            .withBackend<List<TorrentFileEntry>>(
              (TorrentBackend b) => b.listFiles(hash),
            );
        if (files == null) return _unavailable();
        return _json(<String, Object?>{
          'files': files.map(torrentFileEntryToWire).toList(growable: false),
        });
      case 'peers':
        return _withDetail(engine, (TorrentDetailBackend b) async {
          final List<TorrentPeerDetail>? rows = await b.listPeers(hash);
          return <String, Object?>{
            'peers': rows?.map(torrentPeerDetailToWire).toList(growable: false),
          };
        });
      case 'trackers':
        return _withDetail(engine, (TorrentDetailBackend b) async {
          final List<TorrentTrackerDetail>? rows = await b.listTrackers(hash);
          return <String, Object?>{
            'trackers': rows
                ?.map(torrentTrackerDetailToWire)
                .toList(growable: false),
          };
        });
      case 'priorities':
        return _withDetail(engine, (TorrentDetailBackend b) async {
          final List<TorrentFilePriority>? rows = await b.filePriorities(hash);
          return <String, Object?>{
            'priorities': rows
                ?.map((TorrentFilePriority v) => v.name)
                .toList(growable: false),
          };
        });
      case 'pieces':
        return _withDetail(engine, (TorrentDetailBackend b) async {
          final TorrentPieceStates? pieces = await b.pieceStates(hash);
          return <String, Object?>{'pieces': pieces?.states};
        });
    }
    return shelf.Response.notFound('Unknown route');
  }
  if (method != 'POST') return shelf.Response(405);
  switch (action) {
    case 'pause':
    case 'resume':
      final bool? ok = await engine.withBackend<bool>((TorrentBackend b) async {
        if (b is! TorrentPauseBackend) return false;
        return action == 'pause' ? b.pauseTorrent(hash) : b.resumeTorrent(hash);
      });
      if (ok == null) return _unavailable();
      return _json(<String, Object?>{'ok': ok});
    case 'rename':
      final Map<Object?, Object?> body = await _body(request);
      final Object? index = body['fileIndex'];
      final String? newPath = _optString(body, 'newPath');
      if (index is! int || index < 0) return _bad('fileIndex is required');
      if (newPath == null || !isSafeTorrentRelativePath(newPath)) {
        return _bad('newPath must be a relative path inside the torrent');
      }
      final TorrentStorageResult? r = await engine
          .withBackend<TorrentStorageResult>(
            (TorrentBackend b) => b.renameFile(hash, index, newPath),
          );
      if (r == null) return _unavailable();
      return _json(torrentStorageResultToWire(r));
    case 'move':
      final String? raw = _optString(await _body(request), 'savePath');
      final String? target = raw == null
          ? null
          : (await engine.paths()).confine(raw);
      if (target == null) {
        return _bad('savePath is outside every directory this host allows');
      }
      final TorrentStorageResult? r = await engine
          .withBackend<TorrentStorageResult>(
            (TorrentBackend b) => b.moveStorage(hash, target),
          );
      if (r == null) return _unavailable();
      return _json(torrentStorageResultToWire(r));
    case 'trackers':
      final Object? urls = (await _body(request))['urls'];
      if (urls is! List) return _bad('urls must be a list');
      final List<String> list = <String>[
        for (final Object? u in urls)
          if ('$u'.trim().isNotEmpty) '$u'.trim(),
      ];
      final bool? ok = await engine.withBackend<bool>(
        (TorrentBackend b) async =>
            b is TorrentTrackerMutationBackend &&
            await b.addTrackers(hash, list),
      );
      if (ok == null) return _unavailable();
      return _json(<String, Object?>{'ok': ok});
    case 'priorities':
      final Map<Object?, Object?> body = await _body(request);
      final TorrentFilePriority? priority = torrentFilePriorityFromWire(
        body['priority'],
      );
      final Object? indexes = body['indexes'];
      if (priority == null) return _bad('priority must be skip|normal|high');
      if (indexes is! List || indexes.isEmpty) {
        return _bad('indexes must be a non-empty list');
      }
      final List<int> idx = <int>[];
      for (final Object? i in indexes) {
        if (i is! int || i < 0) return _bad('file index out of range: $i');
        idx.add(i);
      }
      final bool? ok = await engine.withBackend<bool>((TorrentBackend b) async {
        if (b is TorrentBulkFilePriorityBackend) {
          return b.setFilePriorities(hash, idx, priority);
        }
        if (b is! TorrentDetailBackend) return false;
        for (final int i in idx) {
          if (!await b.setFilePriority(hash, i, priority)) {
            return false;
          }
        }
        return true;
      });
      if (ok == null) return _unavailable();
      return _json(<String, Object?>{'ok': ok});
  }
  return shelf.Response.notFound('Unknown route');
}
