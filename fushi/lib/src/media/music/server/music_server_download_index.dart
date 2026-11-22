/// 服务器曲目离线副本的进程内索引（v172 `music_server_downloads`）。
///
/// 播放项是同步现算的（`musicServerPlayItem`），起播前不能为每首去查一次库，所以这里持一份
/// 「trackUid → 副本行」的内存快照：初值与之后的每次变化都来自 Drift 的 watch（下完 / 删副本 /
/// 移出曲库任何一条写路径改了表都会推新快照），本身不另记状态。
///
/// 下载 ⊂ 音乐库：[attach] 时把不在曲库里的副本（移出曲库的撤销窗口里进程被杀留下的）连文件
/// 一起删掉；移出曲库过了撤销窗口由 [MusicServerDownloadIndex.dropDownloadsOutsideLibrary] 删。
///
/// 只认**文件确实在**的行：下载根所在的盘没挂上、文件被手动删了时，这一首退回串流（行不删：
/// 盘挂回来就又是离线副本）。每个路径只在第一次见到时查一次存在性。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show MusicServerLocalCopy, musicServerLocalCopyLookup;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 判断一个本机路径是不是文件（测试注入）。
typedef MusicServerDownloadFileExists = Future<bool> Function(String path);

class MusicServerDownloadIndex extends ChangeNotifier {
  MusicServerDownloadIndex({MusicServerDownloadFileExists? fileExists})
    : _fileExists = fileExists ?? _defaultExists;

  /// 进程级实例：`AppModel` 建音乐会话时 [attach] 到用户库，并装成
  /// [musicServerLocalCopyLookup]。
  static final MusicServerDownloadIndex instance = MusicServerDownloadIndex();

  static Future<bool> _defaultExists(String path) => File(path).exists();

  final MusicServerDownloadFileExists _fileExists;

  FushiDatabase? _db;
  StreamSubscription<List<MusicServerDownloadRow>>? _sub;
  Map<String, MusicServerDownloadRow> _rows =
      const <String, MusicServerDownloadRow>{};

  /// 路径 → 是否存在（只查一次）。
  final Map<String, bool> _exists = <String, bool>{};

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
      dropDownloadsOutsideLibrary().catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('MusicServerDownload.prune', e, s);
        return 0;
      }),
    );
  }

  /// 删掉不在音乐库里的离线副本（行 + 文件）；[trackUids] 给了只看这几首。返回删掉的个数。
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
      if (exists) next[r.trackUid] = r;
    }
    _rows = next;
    notifyListeners();
  }

  /// 刚删掉 / 刚写出的文件：忘掉记下的存在性，下次快照重新查。
  void forgetPaths(Iterable<String> paths) {
    for (final String p in paths) {
      _exists.remove(p);
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
    return (path: r.filePath, coverPath: r.coverPath, codec: r.codec);
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
    try {
      final File f = File(r.filePath);
      if (await f.exists()) await f.delete();
    } on FileSystemException catch (e, s) {
      ErrorLogService.instance.log('MusicServerDownload.delete', e, s);
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
