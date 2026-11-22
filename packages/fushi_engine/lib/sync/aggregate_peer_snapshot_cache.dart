import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 对端聚合快照（及 per-device 清单）的本地副本，只用来省掉「对端没变还整份重下」
/// 的流量。
///
/// 它是**远端文件的镜像**，与本地数据库无关：命中条件是资产 id 与
/// [AssetEntry.revision] 都和上次下载时一致，此时远端内容与缓存逐字节同源，
/// 拿缓存去合并和重新下载没有任何区别。所以合并语义一点不变——每轮照样把所有
/// 对端快照完整折进来，只是没变的那几份从磁盘读。
///
/// 副本存的是远端文件的**原样字节**（BUG-5159）：读写副本不做 JSON 编解码，聚合
/// 快照的解码由同步的后台所有者做，调用方（app 里即 UI isolate）只搬字节。
///
/// 反过来，「对端没变就干脆不折」是错的：本地数据可能在没有墓碑的情况下丢过
/// （恢复备份、换数据目录），那样会永远漏掉对端的数据。
abstract interface class AggregatePeerSnapshotCache {
  /// [entry] 的缓存副本（远端文件原样字节）；没有、过期或读坏了都返回 null
  /// （调用方去下载）。
  Future<Uint8List?> read(String channel, AssetEntry entry);

  /// 记下刚从远端下载的 [entry] 内容（原样字节）。[AssetEntry.revision] 为 null
  /// 时不缓存。
  Future<void> write(String channel, AssetEntry entry, Uint8List bytes);

  /// 删掉 [channel] 下不在 [liveAssetNames] 里的副本（对端文件已从远端消失）。
  Future<void> retainOnly(String channel, Set<String> liveAssetNames);
}

/// 落在 `<root>/<channel>/<资产名>.snap` 的 [AggregatePeerSnapshotCache]。
///
/// 文件格式：一行 UTF-8 JSON 头（`format` / `id` / `revision`，`jsonEncode` 不会产出
/// 裸换行）+ `
` + 远端文件的原样字节。读命中只解析这一行头。
///
/// 缓存失效从不影响正确性（最坏多下一次），所以读写失败一律降级为未命中并记日志，
/// 不让一次磁盘错误打断整轮同步。
class DirectoryAggregatePeerSnapshotCache
    implements AggregatePeerSnapshotCache {
  DirectoryAggregatePeerSnapshotCache(this._root);

  final Future<Directory> Function() _root;

  static const String _logSource = 'AggregatePeerSnapshotCache';

  /// 副本格式代号；不一致的副本一律当未命中（重新下载一次）。
  ///
  /// 2：OneDrive / Dropbox 曾把下载到的快照按 latin1 解码（反馈 hbIHtWi2Q7），那时写下
  /// 的副本内容就是错码的；无代号的副本即修复前写的。
  /// 3：副本改存远端原样字节（BUG-5159），文件名后缀从 `.json` 换成 `.snap`——旧的
  /// `.json` 副本不再被读到，下一次 [retainOnly] 把它们当「不在活名单里」删掉。
  static const int kFormat = 3;

  static const String _suffix = '.snap';

  static const int _newline = 0x0a;

  /// 文件名只留安全字符；不同名字撞成同一个文件时，头里的 id 校验会让它未命中。
  static String _safe(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<Directory> _channelDir(String channel) async =>
      Directory(p.join((await _root()).path, _safe(channel)));

  Future<File> _fileFor(String channel, String assetName) async => File(
    p.join((await _channelDir(channel)).path, '${_safe(assetName)}$_suffix'),
  );

  @override
  Future<Uint8List?> read(String channel, AssetEntry entry) async {
    final String? revision = entry.revision;
    if (revision == null) return null;
    try {
      final File file = await _fileFor(channel, entry.name);
      if (!await file.exists()) return null;
      final Uint8List raw = await file.readAsBytes();
      final int split = raw.indexOf(_newline);
      if (split < 0) return null;
      final Object? header = jsonDecode(
        utf8.decode(Uint8List.sublistView(raw, 0, split)),
      );
      if (header is! Map<String, Object?> ||
          header['format'] != kFormat ||
          header['id'] != entry.id ||
          header['revision'] != revision) {
        return null;
      }
      return Uint8List.sublistView(raw, split + 1);
    } catch (e, st) {
      engineLog.log(_logSource, 'read ${entry.name}: $e', st);
      return null;
    }
  }

  @override
  Future<void> write(String channel, AssetEntry entry, Uint8List bytes) async {
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
      // 头与正文分两次写进同一个流，不为拼接再拷一份整份快照。
      final IOSink out = tmp.openWrite()
        ..add(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'format': kFormat,
              'id': entry.id,
              'revision': revision,
            }),
          ),
        )
        ..add(const <int>[_newline])
        ..add(bytes);
      await out.close();
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
        for (final String name in liveAssetNames) '${_safe(name)}$_suffix',
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
