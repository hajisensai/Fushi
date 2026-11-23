/// 服务器曲目离线副本的进程内索引（v173 `music_server_downloads`）。
///
/// 播放项是同步现算的（`musicServerPlayItem`），起播前不能为每首去查一次库，所以这里持一份
/// 「trackUid → 副本行」的内存快照：初值与之后的每次变化都来自 Drift 的 watch（下完 / 删副本 /
/// 移出曲库任何一条写路径改了表都会推新快照），本身不另记状态。
///
/// 下载 ⊂ 音乐库，离线副本是设备本地的事实：恢复 / 合并 / 启动**从不删文件**。[attach] 时把
/// 副本对应、却不在曲库里的曲目放回曲库（[FushiDatabase.reconcileMusicServerDownloadsIntoLibrary]：
/// 覆盖恢复换掉了 `music_remote_tracks`、合并进来的较新一行清了入库时刻、移出曲库的撤销窗口里
/// 进程被杀）。副本文件只在本机显式「移出音乐库」([removeTracksFromLibrary]) 过了撤销窗口后由
/// [MusicServerDownloadIndex.dropDownloadsOutsideLibrary] 删、或「删除下载」删。
///
/// 只认**文件确实在**的行：下载根所在的盘没挂上、文件被手动删了时，这一首退回串流（行不删：
/// 盘挂回来就又是离线副本）。每个路径只在第一次见到时查一次存在性。
///
/// 下载时一并存下的服务器响度在音频旁的 `<文件名>.loudness.json`
/// （[musicServerDownloadLoudnessPath]，设备本地、只有几个数，没有地址 / 凭据）：服务器离线时
/// 离线副本照样按服务器测的增益放。服务器没给响度时，同一个文件里还有客户端对这份副本测的
/// 值（`measured`，下完时测、存量副本在播过之后补测），只在服务器没有值时用。与存在性一样
/// 每个路径只读一次（客户端刚测完的经 [MusicServerDownloadIndex.refreshLoudness] 重读）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show MusicServerKind, MusicServerLyrics;
import 'package:fushi_engine/media/music/server/music_server_loudness.dart'
    show MusicServerLoudness;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show MusicServerLocalCopy, musicServerLocalCopyLookup;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 把服务器歌词存进歌词缓存（[lyrics] 为 null = 服务器上这首没有歌词）。
typedef MusicServerDownloadLyricsSaver =
    Future<void> Function({
      required String trackUid,
      required int? durationMs,
      required MusicServerLyrics? lyrics,
    });

/// 进程级装配点：`AppModel` 建音乐会话时装上（`MusicLyricsService.storeServerLyrics`）；
/// 未装配（测试 / 无头入口）时下载不顺带存歌词。
MusicServerDownloadLyricsSaver? musicServerDownloadLyricsSaver;

/// 判断一个本机路径是不是文件（测试注入）。
typedef MusicServerDownloadFileExists = Future<bool> Function(String path);

/// 离线副本旁 `.loudness.json` 里的两份响度：[server] 是服务器给的（下载时一并存下），
/// [measured] 是客户端对这份文件用 FFmpeg `ebur128` 测的（服务器没给响度时测，只有曲目增益 /
/// 峰值）。播放时服务器的值永远优先。
typedef MusicServerDownloadSidecar = ({
  MusicServerLoudness? server,
  MusicServerLoudness? measured,
});

/// 读离线副本旁存下的响度（测试注入）。
typedef MusicServerDownloadLoudnessReader =
    Future<MusicServerDownloadSidecar?> Function(String audioPath);

/// 离线副本旁存响度的文件（音频路径 + `.loudness.json`）。
String musicServerDownloadLoudnessPath(String audioPath) =>
    '$audioPath.loudness.json';

Map<String, Object?> _loudnessJson(MusicServerLoudness l) => <String, Object?>{
  'trackGainDb': l.trackGainDb,
  'trackPeak': l.trackPeak,
  'albumGainDb': l.albumGainDb,
  'albumPeak': l.albumPeak,
};

MusicServerLoudness? _loudnessOf(Object? j) {
  if (j is! Map<String, Object?>) return null;
  double? d(String k) => switch (j[k]) {
    final num v => v.toDouble(),
    _ => null,
  };
  final MusicServerLoudness l = MusicServerLoudness(
    trackGainDb: d('trackGainDb'),
    trackPeak: d('trackPeak'),
    albumGainDb: d('albumGainDb'),
    albumPeak: d('albumPeak'),
  );
  return l.isEmpty ? null : l;
}

/// 读 sidecar 的原始 JSON（没有 / 坏了为空表）。
Future<Map<String, Object?>> _readSidecarJson(String audioPath) async {
  final File f = File(musicServerDownloadLoudnessPath(audioPath));
  try {
    if (!await f.exists()) return <String, Object?>{};
    final Object? j = jsonDecode(await f.readAsString());
    return j is Map<String, Object?> ? j : <String, Object?>{};
  } on Object catch (e) {
    debugPrint('[music-download] loudness sidecar unreadable: $e');
    return <String, Object?>{};
  }
}

Future<void> _writeSidecarJson(
  String audioPath,
  Map<String, Object?> json,
) async {
  await File(
    musicServerDownloadLoudnessPath(audioPath),
  ).writeAsString(jsonEncode(json), flush: true);
}

/// 把服务器响度存到离线副本旁（[musicServerDownloadLoudnessPath]）；空的不写。服务器的四个数
/// 在顶层（v173 的格式），已有的客户端测量值（`measured`）保留。
Future<void> writeMusicServerDownloadLoudness(
  String audioPath,
  MusicServerLoudness loudness,
) async {
  if (loudness.isEmpty) return;
  final Map<String, Object?> json = await _readSidecarJson(audioPath);
  json.addAll(_loudnessJson(loudness));
  await _writeSidecarJson(audioPath, json);
}

/// 把客户端测的响度存到离线副本旁（`measured`：曲目增益 / 峰值 + 测量时刻；增益为 null =
/// 测过、测不出，不再测）。服务器那份原样保留。
Future<void> writeMusicServerDownloadMeasuredLoudness(
  String audioPath, {
  required double? trackGainDb,
  required double? trackPeak,
  required int measuredAt,
}) async {
  final Map<String, Object?> json = await _readSidecarJson(audioPath);
  json['measured'] = <String, Object?>{
    'trackGainDb': trackGainDb,
    'trackPeak': trackPeak,
    'measuredAt': measuredAt,
  };
  await _writeSidecarJson(audioPath, json);
}

/// 读离线副本旁存下的响度；没有 / 读不了为 null。两份都空也为 null。
Future<MusicServerDownloadSidecar?> readMusicServerDownloadLoudness(
  String audioPath,
) async {
  final Map<String, Object?> json = await _readSidecarJson(audioPath);
  if (json.isEmpty) return null;
  final MusicServerLoudness? server = _loudnessOf(json);
  final MusicServerLoudness? measured = _loudnessOf(json['measured']);
  return (server: server, measured: measured);
}

/// 这份离线副本客户端测过没有（测过、测不出也算）。
Future<bool> musicServerDownloadLoudnessMeasured(String audioPath) async {
  final Object? m = (await _readSidecarJson(audioPath))['measured'];
  return m is Map<String, Object?> && m['measuredAt'] is num;
}

class MusicServerDownloadIndex extends ChangeNotifier {
  MusicServerDownloadIndex({
    MusicServerDownloadFileExists? fileExists,
    MusicServerDownloadLoudnessReader? readLoudness,
    int Function()? clock,
  }) : _fileExists = fileExists ?? _defaultExists,
       _readLoudness = readLoudness ?? readMusicServerDownloadLoudness,
       _clock = clock ?? _now;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 进程级实例：`AppModel` 建音乐会话时 [attach] 到用户库，并装成
  /// [musicServerLocalCopyLookup]。
  static final MusicServerDownloadIndex instance = MusicServerDownloadIndex();

  static Future<bool> _defaultExists(String path) => File(path).exists();

  final MusicServerDownloadFileExists _fileExists;
  final MusicServerDownloadLoudnessReader _readLoudness;
  final int Function() _clock;

  FushiDatabase? _db;
  StreamSubscription<List<MusicServerDownloadRow>>? _sub;
  Map<String, MusicServerDownloadRow> _rows =
      const <String, MusicServerDownloadRow>{};

  /// 路径 → 是否存在（只查一次）。
  final Map<String, bool> _exists = <String, bool>{};

  /// 路径 → 旁边存下的响度（只读一次；没有记 null）。
  final Map<String, MusicServerDownloadSidecar?> _loudness =
      <String, MusicServerDownloadSidecar?>{};

  /// 每次快照换代 +1：异步查存在性期间又来了新快照，旧的那轮作废。
  int _generation = 0;

  /// 接到 [db]（同一个库重复调用是空操作），并装成进程级 [musicServerLocalCopyLookup]。
  void attach(FushiDatabase db) {
    musicServerLocalCopyLookup = lookup;
    if (identical(_db, db)) return;
    unawaited(_sub?.cancel());
    _db = db;
    _sub = db.watchMusicServerDownloads().listen(
      (List<MusicServerDownloadRow> rows) => unawaited(_apply(rows)),
    );
    unawaited(
      reconcileIntoLibrary().catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('MusicServerDownload.reconcile', e, s);
        return 0;
      }),
    );
  }

  /// 把离线副本对应、却不在音乐库里的曲目放回音乐库（不删任何文件）。返回放回的首数。
  Future<int> reconcileIntoLibrary() async {
    final FushiDatabase? db = _db;
    if (db == null) return 0;
    return db.reconcileMusicServerDownloadsIntoLibrary(at: _clock());
  }

  /// 每首曲目「移出音乐库」的次数（进程内）：下载任务开跑时记下，下完落库时比一次
  /// （[FushiDatabase.recordMusicServerDownload] 的 `stillWanted`）——开跑之后被移出过的不加回曲库。
  /// 下载任务的闭包本身只活在进程里（重启后不会自己接着跑），进程内计数就够。
  final Map<String, int> _removals = <String, int>{};

  /// 这首此刻的「移出音乐库」计数（见 [_removals]）。
  int removalMark(String trackUid) => _removals[trackUid] ?? 0;

  /// 取消一首曲目在跑 / 停着的下载并删半成品（`MusicServerDownloadService` 构造时装上：没建过
  /// 下载服务就不会有下载任务）。
  Future<bool> Function(String trackUid)? cancelDownload;

  /// 本机「从音乐库移除」服务器（及其他远程）曲目的唯一写路径：先记移出（在跑的下载下完也不
  /// 加回曲库），再清入库时刻，再取消这些曲目在跑 / 停着的下载（删半成品）。离线副本**不在
  /// 这里删**：调用方带撤销，过了撤销窗口再 [dropDownloadsOutsideLibrary]。
  Future<void> removeTracksFromLibrary(
    FushiDatabase db,
    Iterable<String> trackUids, {
    required int at,
  }) async {
    final List<String> uids = trackUids.toSet().toList();
    if (uids.isEmpty) return;
    for (final String uid in uids) {
      _removals[uid] = removalMark(uid) + 1;
    }
    await db.removeMusicRemoteTracksFromLibrary(uids, at: at);
    final Future<bool> Function(String trackUid)? cancel = cancelDownload;
    if (cancel == null) return;
    for (final String uid in uids) {
      try {
        await cancel(uid);
      } on Object catch (e, s) {
        ErrorLogService.instance.log('MusicServerDownload.cancel', e, s);
      }
    }
  }

  /// 删掉不在音乐库里的离线副本（行 + 文件）；[trackUids] 给了只看这几首。返回删掉的个数。
  /// 只给本机显式移出的收尾用（撤销窗口过去之后）。
  Future<int> dropDownloadsOutsideLibrary([Iterable<String>? trackUids]) async {
    final FushiDatabase? db = _db;
    if (db == null) return 0;
    final List<MusicServerDownloadRow> orphans = await db
        .listMusicServerDownloadsOutsideLibrary(trackUids);
    if (orphans.isEmpty) return 0;
    return deleteDownloads(<String>[
      for (final MusicServerDownloadRow r in orphans) r.trackUid,
    ]);
  }

  /// 删一批离线副本：先删行（播放立刻不再指向它），再删文件。返回删掉的行数。
  Future<int> deleteDownloads(Iterable<String> trackUids) async {
    final FushiDatabase? db = _db;
    if (db == null) return 0;
    final List<MusicServerDownloadRow> rows = await db
        .deleteMusicServerDownloads(trackUids);
    await deleteMusicServerDownloadFiles(rows);
    forgetPaths(<String>[
      for (final MusicServerDownloadRow r in rows) r.filePath,
    ]);
    return rows.length;
  }

  Future<void> _apply(List<MusicServerDownloadRow> rows) async {
    final int generation = ++_generation;
    final Map<String, MusicServerDownloadRow> next =
        <String, MusicServerDownloadRow>{};
    for (final MusicServerDownloadRow r in rows) {
      final bool exists = _exists[r.filePath] ??= await _fileExists(r.filePath);
      if (generation != _generation) return;
      if (!exists) continue;
      if (!_loudness.containsKey(r.filePath)) {
        final MusicServerDownloadSidecar? l = await _readLoudness(r.filePath);
        if (generation != _generation) return;
        _loudness[r.filePath] = l;
      }
      next[r.trackUid] = r;
    }
    _rows = next;
    notifyListeners();
  }

  /// 刚在离线副本旁写了响度（客户端测量）：重读这一份并推给听众（不必等表变化）。
  Future<void> refreshLoudness(String path) async {
    final MusicServerDownloadSidecar? l = await _readLoudness(path);
    _loudness[path] = l;
    notifyListeners();
  }

  /// 刚删掉 / 刚写出的文件：忘掉记下的存在性，下次快照重新查。
  void forgetPaths(Iterable<String> paths) {
    for (final String p in paths) {
      _exists.remove(p);
      _loudness.remove(p);
    }
  }

  /// 这首的离线副本行；没有（或文件不在）回 null。
  MusicServerDownloadRow? rowOf(String trackUid) => _rows[trackUid];

  bool isDownloaded(String trackUid) => _rows.containsKey(trackUid);

  /// 一批曲目里有离线副本的个数。
  int countDownloaded(Iterable<String> trackUids) {
    int n = 0;
    for (final String uid in trackUids) {
      if (_rows.containsKey(uid)) n++;
    }
    return n;
  }

  /// [musicServerLocalCopyLookup] 的实现。
  MusicServerLocalCopy? lookup(String trackUid) {
    final MusicServerDownloadRow? r = _rows[trackUid];
    if (r == null) return null;
    return (
      path: r.filePath,
      coverPath: r.coverPath,
      codec: r.codec,
      serverId: r.sourceKey,
      trackId: r.itemId,
      serverKind: MusicServerKind.fromWire(r.serverKind),
      loudness: _loudness[r.filePath]?.server,
      measuredLoudness: _loudness[r.filePath]?.measured,
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    if (musicServerLocalCopyLookup == lookup) {
      musicServerLocalCopyLookup = null;
    }
    super.dispose();
  }
}

/// 删一批离线副本的文件（行已经删掉之后调用）：音频文件；专辑目录里只剩封面时连封面与空目录
/// 一起删。删不掉的记错误日志、不抛（行已经没了，播放不会再指向它）。
Future<void> deleteMusicServerDownloadFiles(
  Iterable<MusicServerDownloadRow> rows,
) async {
  final Set<String> dirs = <String>{};
  for (final MusicServerDownloadRow r in rows) {
    dirs.add(p.dirname(r.filePath));
    for (final String path in <String>[
      r.filePath,
      musicServerDownloadLoudnessPath(r.filePath),
    ]) {
      try {
        final File f = File(path);
        if (await f.exists()) await f.delete();
      } on FileSystemException catch (e, s) {
        ErrorLogService.instance.log('MusicServerDownload.delete', e, s);
      }
    }
  }
  for (final String dir in dirs) {
    final Directory d = Directory(dir);
    try {
      if (!await d.exists()) continue;
      final List<FileSystemEntity> left = await d.list().toList();
      bool onlyCovers = true;
      for (final FileSystemEntity e in left) {
        final String name = p.basename(e.path).toLowerCase();
        if (e is! File || !RegExp(r'^cover\.(jpg|png|webp)$').hasMatch(name)) {
          onlyCovers = false;
          break;
        }
      }
      if (!onlyCovers) continue;
      for (final FileSystemEntity e in left) {
        await e.delete();
      }
      await d.delete();
    } on FileSystemException catch (e, s) {
      ErrorLogService.instance.log('MusicServerDownload.deleteDir', e, s);
    }
  }
}
