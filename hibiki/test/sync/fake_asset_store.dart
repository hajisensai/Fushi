import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/sync/sync_asset_store.dart';

/// 内存资产库：命名空间用 `/` 分隔的路径作为 id；文件夹是已知路径集合，
/// 资产是 path->bytes 映射。仅供测试（契约测试 + Plan B 编排器测试）。
class FakeAssetStore implements SyncAssetStore {
  final Set<String> _folders = <String>{''};
  final Map<String, List<int>> _files = <String, List<int>>{};

  String _join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  @override
  Future<String> ensureNamespace(String name) async {
    _folders.add(name);
    return name;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final String path = _join(parentId, name);
    _folders.add(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final String prefix = namespaceId.isEmpty ? '' : '$namespaceId/';
    final List<AssetEntry> out = <AssetEntry>[];
    for (final String f in _folders) {
      if (f.isEmpty || f == namespaceId) continue;
      if (f.startsWith(prefix) && !f.substring(prefix.length).contains('/')) {
        out.add(AssetEntry(
            id: f, name: f.substring(prefix.length), isFolder: true));
      }
    }
    for (final MapEntry<String, List<int>> e in _files.entries) {
      if (e.key.startsWith(prefix) &&
          !e.key.substring(prefix.length).contains('/')) {
        out.add(AssetEntry(
          id: e.key,
          name: e.key.substring(prefix.length),
          sizeBytes: e.value.length,
        ));
      }
    }
    return out;
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final String path = _join(namespaceId, name);
    if (!_files.containsKey(path)) return null;
    return AssetEntry(id: path, name: name, sizeBytes: _files[path]!.length);
  }

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
      {void Function(double progress)? onProgress}) async {
    _files[_join(namespaceId, name)] = await file.readAsBytes();
    onProgress?.call(1.0);
  }

  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) async {
    final List<int>? bytes = _files[assetId];
    if (bytes == null) throw StateError('asset not found: $assetId');
    await destination.writeAsBytes(bytes, flush: true);
    onProgress?.call(1.0);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    final List<int>? bytes = _files[assetId];
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> putJsonAsset(
      String namespaceId, String name, Object? json) async {
    _files[_join(namespaceId, name)] = utf8.encode(jsonEncode(json));
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    // 文件资产：直接移除。
    _files.remove(id);
    if (isFolder) {
      // 递归移除该命名空间及其全部子项（路径前缀匹配）。
      final String prefix = '$id/';
      _folders.removeWhere((String f) => f == id || f.startsWith(prefix));
      _files.removeWhere((String k, List<int> _) => k.startsWith(prefix));
    }
  }
}
