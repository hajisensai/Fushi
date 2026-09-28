import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 本机目录上的 [SyncAssetStore]：命名空间 = 子目录，资产 = 文件，id = 绝对路径。
///
/// 用途：互联主机（无头服务端 / 桌面 app）自己就是别的设备的同步目标，别的设备经
/// WebDAV 写进来的文件就在本机磁盘上（`<sync-data>/fushi-data/<命名空间>/`）。
/// 主机要参与同一套资产协议（例如待发制卡中转）时，直接对这块目录跑同样的代码，
/// 不必走网络绕回自己。
///
/// 别的设备经 WebDAV PUT 写的文件**不是**原子落盘的：[getJsonAsset] 读到半截的 JSON
/// 返回 null（下一轮再读），而不是抛错。本类自己的写都是 `.tmp` → rename。
class LocalDirectoryAssetStore implements SyncAssetStore {
  LocalDirectoryAssetStore(this.root);

  /// 相当于远端的「根」（互联主机上是 `<sync-data>/fushi-data`）。
  final Directory root;

  static const String _tmpSuffix = '.fushi-tmp';

  @override
  Future<String> ensureNamespace(String name) => ensureFolder(root.path, name);

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final Directory dir = Directory(p.join(parentId, _safeName(name)));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final Directory dir = Directory(namespaceId);
    if (!dir.existsSync()) return const <AssetEntry>[];
    return <AssetEntry>[
      for (final FileSystemEntity e in dir.listSync())
        if (!e.path.endsWith(_tmpSuffix))
          AssetEntry(
            id: e.path,
            name: p.basename(e.path),
            isFolder: e is Directory,
            sizeBytes: e is File ? e.lengthSync() : null,
          ),
    ];
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final File f = File(p.join(namespaceId, _safeName(name)));
    if (!f.existsSync()) return null;
    return AssetEntry(id: f.path, name: name, sizeBytes: f.lengthSync());
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final File target = File(p.join(namespaceId, _safeName(name)));
    final File tmp = File('${target.path}$_tmpSuffix');
    await file.copy(tmp.path);
    await tmp.rename(target.path);
    onProgress?.call(1);
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await File(assetId).copy(destination.path);
    onProgress?.call(1);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    final File f = File(assetId);
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    final File target = File(p.join(namespaceId, _safeName(name)));
    final File tmp = File('${target.path}$_tmpSuffix');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    final FileSystemEntity e = isFolder ? Directory(id) : File(id);
    if (e.existsSync()) await e.delete(recursive: isFolder);
  }

  /// 名字只能是一段：带分隔符 / `..` 的名字会写出命名空间之外。
  static String _safeName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
      throw ArgumentError.value(name, 'name', 'not a single path segment');
    }
    return name;
  }
}
