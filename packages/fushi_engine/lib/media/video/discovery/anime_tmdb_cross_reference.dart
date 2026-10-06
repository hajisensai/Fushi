/// 发现页「动画条目 → TMDB」的本地交叉索引（Fribb anime-lists 的紧凑投影）。
///
/// 为什么要它：AniList / MAL 的简介只有英文，资料语言不是英文时详情要靠 TMDB
/// 才有本地语言的简介；而 AniList `externalLinks`、Jikan `external` 都不给
/// TMDB 链接（2026-10-05 实测《葬送のフリーレン》《進撃の巨人》），只能查
/// Fribb 映射。刮削链的 `AnimeIdentityMapping` 是**纯内存**的（每次进程启动都
/// 重下十几 MB 全表），发现页不复用它的下载，而是：
///
/// * 落盘一份只含 `MAL → (AniDB, TMDB, 命名空间, 季, 集偏移)` 的紧凑索引
///   （几百 KB，`<support>/video_metadata/fribb/mal_tmdb_index.json`），重启直接
///   读盘，不再下载；
/// * 每周最多一次条件请求刷新（`If-None-Match` / `If-Modified-Since`），304 只
///   更新检查时间；
/// * **查询永不联网**：[entriesForMal] 只读本地索引，没有索引返回 null（详情照常
///   出英文），下载在后台由 [refreshIfStale] 做，完成后经 [updates] 通知界面补上
///   本地语言。任何失败静默降级。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:path/path.dart' as p;

/// 只读交叉引用端口（测试注入假实现）。
abstract interface class AnimeTmdbCrossReference {
  /// MAL id 对应的全部 AniDB 条目（只含带 TMDB id 的）。**只查本地**：索引还
  /// 没有时返回 null，绝不在调用路径上下载。
  Future<List<AnimeIdentityEntry>?> entriesForMal(int malId);

  /// 本地索引被（后台刷新）替换后发一次事件，界面据此重取详情。
  Stream<void> get updates;

  /// 索引缺失或过期时在后台刷新；调用方不等它。返回索引是否被替换。
  Future<bool> refreshIfStale();
}

/// 紧凑索引文件格式版本：字段布局变了就加一，旧文件当作不存在。
const int kAnimeTmdbCrossReferenceFormat = 1;

class AnimeTmdbCrossReferenceStore implements AnimeTmdbCrossReference {
  AnimeTmdbCrossReferenceStore({
    VideoMetadataHttpClient? httpClient,
    Directory? directory,
    this.refreshInterval = const Duration(days: 7),
    this.maxResponseBytes = 32 * 1024 * 1024,
    DateTime Function()? now,
  })  : _http = httpClient ??
            VideoMetadataHttpClient(
              // 全表十几 MB：默认 15 秒整包超时在慢网下必然失败。
              timeout: const Duration(minutes: 3),
              maxAttempts: 2,
            ),
        _ownsHttp = httpClient == null,
        _directory = directory,
        _now = now ?? DateTime.now;

  static final Uri sourceUri = AnimeIdentityMapping.sourceUri;
  static const String fileName = 'mal_tmdb_index.json';

  final VideoMetadataHttpClient _http;
  final bool _ownsHttp;
  final Directory? _directory;
  final DateTime Function() _now;
  final Duration refreshInterval;
  final int maxResponseBytes;

  final StreamController<void> _updates = StreamController<void>.broadcast();
  _CompactIndex? _index;
  bool _loadedFromDisk = false;
  Future<_CompactIndex?>? _loading;
  Future<bool>? _refreshing;
  bool _closed = false;
  bool _failed = false;

  /// 固定同一个 Stream 对象：界面按 identical 判断要不要重订阅。
  @override
  late final Stream<void> updates = _updates.stream;

  @override
  Future<List<AnimeIdentityEntry>?> entriesForMal(int malId) async {
    if (malId <= 0) return const <AnimeIdentityEntry>[];
    final _CompactIndex? index = await _loadLocal();
    return index?.entriesForMal(malId);
  }

  /// 索引缺失或上次检查已超过 [refreshInterval] 时发一次（条件）请求。返回
  /// 本地索引是否因此被替换。失败只记诊断、返回 false；同一时刻只有一个刷新；
  /// 本进程失败过一次就不再重试（离线时不让每次开详情都重打一遍）。
  @override
  Future<bool> refreshIfStale() {
    if (_failed) return Future<bool>.value(false);
    if (_closed) return Future<bool>.value(false);
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _refresh() async {
    try {
      final _CompactIndex? local = await _loadLocal();
      if (local != null &&
          _now().difference(local.checkedAt) < refreshInterval) {
        return false;
      }
      final Map<String, String> headers = <String, String>{
        if (local?.etag case final String etag) 'If-None-Match': etag,
        if (local?.lastModified case final String modified)
          'If-Modified-Since': modified,
      };
      final VideoMetadataHttpResponse response;
      try {
        response = await _http.get(
          sourceUri,
          headers: headers,
          operation: 'Anime TMDB cross reference',
        );
      } on VideoMetadataNetworkException catch (error) {
        if (error.statusCode == 304 && local != null) {
          final _CompactIndex touched = local.withCheckedAt(_now());
          await _write(touched.encode());
          _index = touched;
          return false;
        }
        rethrow;
      }
      if (_closed) return false;
      if (response.body.length > maxResponseBytes) {
        throw const FormatException('Anime TMDB cross reference too large');
      }
      final String body = response.body;
      final String? etag = response.headers['etag'];
      final String? lastModified = response.headers['last-modified'];
      final int checkedAt = _now().millisecondsSinceEpoch;
      // 十几 MB 的 jsonDecode + 投影整段放后台 isolate，结果只回传紧凑串。
      final String encoded = await Isolate.run(
        () => _buildCompactJson(
          body,
          etag: etag,
          lastModified: lastModified,
          checkedAt: checkedAt,
        ),
        debugName: 'anime-tmdb-cross-reference',
      );
      if (_closed) return false;
      await _write(encoded);
      _index = _CompactIndex.decode(encoded);
      _updates.add(null);
      return true;
    } on Object catch (error) {
      _failed = true;
      engineLog.logDiagnostic('AnimeTmdbCrossReferenceStore.refresh', '$error');
      return false;
    }
  }

  Future<_CompactIndex?> _loadLocal() async {
    if (_index != null || _loadedFromDisk) return _index;
    return _loading ??= () async {
      try {
        final File file = await _file();
        if (await file.exists()) {
          _index = _CompactIndex.decode(await file.readAsString());
        }
      } on Object catch (error) {
        // 坏文件当作没有：后台刷新会整份重写。
        engineLog.logDiagnostic('AnimeTmdbCrossReferenceStore.load', '$error');
        _index = null;
      } finally {
        _loadedFromDisk = true;
        _loading = null;
      }
      return _index;
    }();
  }

  Future<File> _file() async {
    final Directory directory = _directory ??
        Directory(
          p.join(
            (await enginePaths.supportRootDirectory()).path,
            'video_metadata',
            'fribb',
          ),
        );
    return File(p.join(directory.path, fileName));
  }

  Future<void> _write(String contents) async {
    final File target = await _file();
    await target.parent.create(recursive: true);
    final File temporary = File(
      '${target.path}.tmp.$pid.${_now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(contents, flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_updates.close());
    if (_ownsHttp) _http.close();
  }
}

/// MAL id → `[anidb, tmdb, movie(0/1), tmdbSeason(-1=无), tmdbOffset(-1=无)]`。
class _CompactIndex {
  _CompactIndex({
    required this.byMal,
    required this.checkedAt,
    this.etag,
    this.lastModified,
  });

  factory _CompactIndex.decode(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['format'] != kAnimeTmdbCrossReferenceFormat ||
        decoded['mal'] is! Map) {
      throw const FormatException('unsupported cross reference index');
    }
    final Map<int, List<List<int>>> byMal = <int, List<List<int>>>{};
    (decoded['mal'] as Map).forEach((Object? key, Object? value) {
      final int? mal = int.tryParse('$key');
      if (mal == null || value is! List) return;
      byMal[mal] = <List<int>>[
        for (final Object? row in value)
          if (row is List &&
              row.length == 5 &&
              row.every((Object? v) => v is int))
            row.cast<int>(),
      ];
    });
    return _CompactIndex(
      byMal: byMal,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(
        decoded['checkedAt'] is int ? decoded['checkedAt'] as int : 0,
      ),
      etag: decoded['etag'] is String ? decoded['etag'] as String : null,
      lastModified: decoded['lastModified'] is String
          ? decoded['lastModified'] as String
          : null,
    );
  }

  final Map<int, List<List<int>>> byMal;
  final DateTime checkedAt;
  final String? etag;
  final String? lastModified;

  List<AnimeIdentityEntry> entriesForMal(int malId) => <AnimeIdentityEntry>[
        for (final List<int> row in byMal[malId] ?? const <List<int>>[])
          AnimeIdentityEntry(
            anidbId: row[0],
            malIds: <int>{malId},
            tmdbId: row[1],
            tmdbIsMovieNamespace: row[2] == 1,
            tmdbSeason: row[3] < 0 ? null : row[3],
            tmdbEpisodeOffset: row[4] < 0 ? null : row[4],
          ),
      ];

  _CompactIndex withCheckedAt(DateTime value) => _CompactIndex(
        byMal: byMal,
        checkedAt: value,
        etag: etag,
        lastModified: lastModified,
      );

  String encode() => _encodeCompact(
        byMal,
        etag: etag,
        lastModified: lastModified,
        checkedAt: checkedAt.millisecondsSinceEpoch,
      );
}

String _encodeCompact(
  Map<int, List<List<int>>> byMal, {
  required String? etag,
  required String? lastModified,
  required int checkedAt,
}) =>
    jsonEncode(<String, Object?>{
      'format': kAnimeTmdbCrossReferenceFormat,
      'etag': etag,
      'lastModified': lastModified,
      'checkedAt': checkedAt,
      'mal': <String, Object?>{
        for (final MapEntry<int, List<List<int>>> entry in byMal.entries)
          '${entry.key}': entry.value,
      },
    });

/// 后台 isolate 入口：Fribb 全表 → 紧凑索引 JSON（只留带 TMDB id 的行）。
String _buildCompactJson(
  String body, {
  required String? etag,
  required String? lastModified,
  required int checkedAt,
}) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('Fribb anime list must be a JSON list');
  }
  final Map<int, List<List<int>>> byMal = <int, List<List<int>>>{};
  for (final AnimeIdentityEntry entry
      in animeIdentityEntriesFromRows(decoded)) {
    final int? tmdb = entry.tmdbId;
    if (tmdb == null) continue;
    for (final int mal in entry.malIds) {
      (byMal[mal] ??= <List<int>>[]).add(<int>[
        entry.anidbId,
        tmdb,
        entry.tmdbIsMovieNamespace ? 1 : 0,
        entry.tmdbSeason ?? -1,
        entry.tmdbEpisodeOffset ?? -1,
      ]);
    }
  }
  return _encodeCompact(
    byMal,
    etag: etag,
    lastModified: lastModified,
    checkedAt: checkedAt,
  );
}
