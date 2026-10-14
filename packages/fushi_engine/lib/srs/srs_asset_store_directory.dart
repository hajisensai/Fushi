/// SRS 同步目录（[SrsSyncDirectory]）在现有同步后端（[SyncAssetStore]）上的实现。
///
/// 布局：`<namespace fushi-srs>/<profileUid>/<writerId>/<batch-* | snapshot-* | cursor | probe>`。
/// 每个文件只由一个写入者写；普通网盘（Google Drive / OneDrive / Dropbox / WebDAV / FTP / SFTP）与互联同一份格式。
/// 全部经字节接口（putAsset / getAsset），开启「防扫盘混淆」时正文也会被混淆。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

const String kSrsSyncNamespace = 'fushi-srs';

class SrsAssetStoreDirectory implements SrsSyncDirectory {
  SrsAssetStoreDirectory({
    required this.store,
    required this.profileUid,
    Directory? tempDir,
  }) : _temp = tempDir ?? Directory.systemTemp;

  final SyncAssetStore store;
  final String profileUid;
  final Directory _temp;

  String? _profileFolder;
  final Map<String, String> _writerFolders = <String, String>{};
  final Random _rand = Random();

  Future<String> _profile() async {
    final String? cached = _profileFolder;
    if (cached != null) return cached;
    final String ns = await store.ensureNamespace(kSrsSyncNamespace);
    return _profileFolder = await store.ensureFolder(ns, profileUid);
  }

  /// 写入者目录（不存在时只有 [create] 为真才建）。
  Future<String?> _writer(String writerId, {required bool create}) async {
    final String? cached = _writerFolders[writerId];
    if (cached != null) return cached;
    final String parent = await _profile();
    if (!create) {
      for (final AssetEntry e in await store.listChildren(parent)) {
        if (e.isFolder && e.name == writerId) {
          return _writerFolders[writerId] = e.id;
        }
      }
      return null;
    }
    return _writerFolders[writerId] = await store.ensureFolder(
      parent,
      writerId,
    );
  }

  File _tmpFile() => File(
    p.join(
      _temp.path,
      'fushi_srs_${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 30)}',
    ),
  );

  @override
  Future<List<String>> listWriters() async => <String>[
    for (final AssetEntry e in await store.listChildren(await _profile()))
      if (e.isFolder) e.name,
  ]..sort();

  @override
  Future<List<String>?> listFiles(String writerId) async {
    final String? folder = await _writer(writerId, create: false);
    if (folder == null) return null;
    return <String>[
      for (final AssetEntry e in await store.listChildren(folder))
        if (!e.isFolder) e.name,
    ];
  }

  @override
  Future<Uint8List?> read(String writerId, String name) async {
    final String? folder = await _writer(writerId, create: false);
    if (folder == null) return null;
    final AssetEntry? a = await store.findAsset(folder, name);
    if (a == null) return null;
    final File tmp = _tmpFile();
    try {
      await store.getAsset(a.id, tmp);
      return await tmp.readAsBytes();
    } on Object {
      // 读不到（传输中断等）= 这个文件还不存在，下一轮再读。
      return null;
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  /// cursor / probe 是会被覆盖的「最新值」文件：先删旧的再写，避免允许同名多文件的后端（Google Drive）
  /// 留下两份、读到旧的那份。批次 / 快照写一次不再改，不需要。
  static bool _mutable(String name) =>
      name == srsCursorName || name == srsProbeName;

  @override
  Future<void> write(String writerId, String name, Uint8List bytes) async {
    final String folder = (await _writer(writerId, create: true))!;
    if (_mutable(name)) {
      final AssetEntry? old = await store.findAsset(folder, name);
      if (old != null) await store.deleteAsset(old.id);
    }
    final File tmp = _tmpFile();
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await store.putAsset(folder, name, tmp);
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  @override
  Future<void> delete(String writerId, String name) async {
    final String? folder = await _writer(writerId, create: false);
    if (folder == null) return;
    final AssetEntry? a = await store.findAsset(folder, name);
    if (a != null) await store.deleteAsset(a.id);
  }

  @override
  Future<void> deleteWriter(String writerId) async {
    final String? folder = await _writer(writerId, create: false);
    if (folder == null) return;
    await store.deleteAsset(folder, isFolder: true);
    _writerFolders.remove(writerId);
  }

  /// 写探针文件（写入者自己的目录）再读回服务端修改时间。后端不提供修改时间时返回 null，
  /// 该后端不提供 SRS 同步（同步引擎据此报错，不用本机墙钟冒充服务器时间）。
  @override
  Future<int?> serverTime(String writerId) async {
    await write(writerId, srsProbeName, Uint8List.fromList(<int>[1]));
    final String folder = (await _writer(writerId, create: true))!;
    for (final AssetEntry e in await store.listChildren(folder)) {
      if (e.name != srsProbeName) continue;
      if (e.modifiedAt != null) return e.modifiedAt;
      // 列目录没带时间（FTP 目录文件多时不逐个 MDTM），退到按名查找——FTP 的
      // findAsset 总会 MDTM；其它后端 findAsset 不带时间，这里仍为 null。
      return (await store.findAsset(folder, srsProbeName))?.modifiedAt;
    }
    return null;
  }
}
