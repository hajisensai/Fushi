import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 对端聚合快照的本地副本，只用来省掉「对端没变还整份重下」的流量。
///
/// 它是**远端文件的镜像**，与本地数据库无关：命中条件是资产 id 与
/// [AssetEntry.revision] 都和上次下载时一致，此时远端内容与缓存逐字节同源，
/// 拿缓存去合并和重新下载没有任何区别。所以合并语义一点不变——每轮照样把所有
/// 对端快照完整折进来，只是没变的那几份从磁盘读。
///
/// 反过来，「对端没变就干脆不折」是错的：本地数据可能在没有墓碑的情况下丢过
/// （恢复备份、换数据目录），那样会永远漏掉对端的数据。
abstract interface class AggregatePeerSnapshotCache {
  /// [entry] 的缓存副本；没有、过期或读坏了都返回 null（调用方去下载）。
  Future<Object?> read(String channel, AssetEntry entry);

  /// 记下刚从远端下载的 [entry] 内容。[AssetEntry.revision] 为 null 时不缓存。
  Future<void> write(String channel, AssetEntry entry, Object? json);

  /// 删掉 [channel] 下不在 [liveAssetNames] 里的副本（对端文件已从远端消失）。
  Future<void> retainOnly(String channel, Set<String> liveAssetNames);
}

/// 落在 `<root>/<channel>/<资产名>.json` 的 [AggregatePeerSnapshotCache]。
///
/// 缓存失效从不影响正确性（最坏多下一次），所以读写失败一律降级为未命中并记日志，
/// 不让一次磁盘错误打断整轮同步。
class DirectoryAggregatePeerSnapshotCache
    implements AggregatePeerSnapshotCache {
  DirectoryAggregatePeerSnapshotCache(this._root);

  final Future<Directory> Function() _root;

  static const String _logSource = 'AggregatePeerSnapshotCache';

  /// 文件名只留安全字符；不同名字撞成同一个文件时，内容里的 id 校验会让它未命中。
  static String _safe(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<Directory> _channelDir(String channel) async =>
      Directory(p.join((await _root()).path, _safe(channel)));

  Future<File> _fileFor(String channel, String assetName) async => File(
    p.join((await _channelDir(channel)).path, '${_safe(assetName)}.json'),
  );

  @override
  Future<Object?> read(String channel, AssetEntry entry) async {
    final String? revision = entry.revision;
    if (revision == null) return null;
    try {
      final File file = await _fileFor(channel, entry.name);
      if (!await file.exists()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['id'] != entry.id || decoded['revision'] != revision) {
        return null;
      }
      return decoded['snapshot'];
    } catch (e, st) {
      engineLog.log(_logSource, 'read ${entry.name}: $e', st);
      return null;
    }
  }

  @override
  Future<void> write(String channel, AssetEntry entry, Object? json) async {
    try {
      final File file = await _fileFor(channel, entry.name);
      final String? revision = entry.revision;
      if (revision == null) {
        // 后端这回给不出版本标记：旧副本无从验证，删掉免得以后误命中。
        if (await file.exists()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          'id': entry.id,
          'revision': revision,
          'snapshot': json,
        }),
      );
      await tmp.rename(file.path);
    } catch (e, st) {
      engineLog.log(_logSource, 'write ${entry.name}: $e', st);
    }
  }

  @override
  Future<void> retainOnly(String channel, Set<String> liveAssetNames) async {
    try {
      final Directory dir = await _channelDir(channel);
      if (!await dir.exists()) return;
      final Set<String> keep = <String>{
        for (final String name in liveAssetNames) '${_safe(name)}.json',
      };
      // listSync：fake-async 测试区里 `await for (dir.list())` 收不到完成事件。
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is File && !keep.contains(p.basename(e.path))) e.deleteSync();
      }
    } catch (e, st) {
      engineLog.log(_logSource, 'prune $channel: $e', st);
    }
  }
}
