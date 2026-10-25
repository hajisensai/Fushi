/// 同步 v2 的存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.1、§6.5、§11）：只会「列目录 / 读 / 写 /
/// 删文件」的哑存储。协议保证每台设备只写自己的文件、文件写一次后不可变（清除重写的段例外：同名、同链值），
/// 所以这里不需要锁、原子比较交换或一致的列目录。
///
/// 路径一律相对于一个 profile 集合的根（`fushi-srs/<profileUid>/v2/`），用 `/` 分隔：
/// `meta.json`、`devices/<DeviceId>/{head-*.json, seg-*.bin, profile.json}`、`media/<sha256 前 2 位>/<sha256>`。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 目录里的一项。
class SrsLocationEntry {
  const SrsLocationEntry(
    this.name, {
    this.isFolder = false,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final bool isFolder;
  final int? size;

  /// 服务端修改时间（毫秒）；拿不到为 null。
  final int? modifiedAt;
}

/// 一个存储位置的最小接口。
abstract interface class SrsLocationStore {
  /// [dir] 下的直接子项；目录不存在 = 空列表。
  Future<List<SrsLocationEntry>> list(String dir);

  /// 读文件；不存在返回 null。
  Future<Uint8List?> get(String path);

  /// 写文件（同名覆盖；中间目录按需创建）。
  Future<void> put(String path, Uint8List bytes);

  /// 删文件（不存在视为成功）。
  Future<void> delete(String path);
}

/// 集合根在现有同步后端上的位置：`fushi-srs/<profileUid>/v2/`（与旧格式的写入者目录并列，互不干扰）。
const String kSrsSync2Namespace = 'fushi-srs';
const String kSrsSync2Folder = 'v2';

/// [SyncAssetStore]（各云盘后端 / 互联 / 本机 host 目录）上的位置。后端的文件夹定位符是不透明 id，
/// 这里按路径段逐级解析并缓存；正文经字节接口（开了「防扫盘混淆」时同样被混淆）。
class SrsAssetLocationStore implements SrsLocationStore {
  SrsAssetLocationStore({
    required this.store,
    required this.profileUid,
    Directory? tempDir,
  }) : _temp = tempDir ?? Directory.systemTemp;

  final SyncAssetStore store;
  final String profileUid;
  final Directory _temp;
  final Map<String, String> _folders = <String, String>{};
  final Random _rand = Random();

  Future<String> _root() async {
    final String? cached = _folders[''];
    if (cached != null) return cached;
    final String ns = await store.ensureNamespace(kSrsSync2Namespace);
    final String profile = await store.ensureFolder(ns, profileUid);
    return _folders[''] = await store.ensureFolder(profile, kSrsSync2Folder);
  }

  /// [dir] 的定位符；不存在时 [create] 为真才建，否则返回 null。
  Future<String?> _folder(String dir, {required bool create}) async {
    final List<String> parts = dir
        .split('/')
        .where((String s) => s.isNotEmpty)
        .toList();
    String cur = await _root();
    String key = '';
    for (final String part in parts) {
      key = key.isEmpty ? part : '$key/$part';
      final String? cached = _folders[key];
      if (cached != null) {
        cur = cached;
        continue;
      }
      if (create) {
        cur = await store.ensureFolder(cur, part);
      } else {
        String? found;
        for (final AssetEntry e in await store.listChildren(cur)) {
          if (e.isFolder && e.name == part) {
            found = e.id;
            break;
          }
        }
        if (found == null) return null;
        cur = found;
      }
      _folders[key] = cur;
    }
    return cur;
  }

  (String, String) _split(String path) {
    final int i = path.lastIndexOf('/');
    return i < 0 ? ('', path) : (path.substring(0, i), path.substring(i + 1));
  }

  File _tmp() => File(
    p.join(
      _temp.path,
      'fushi_srs2_${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 30)}',
    ),
  );

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    final String? id = await _folder(dir, create: false);
    if (id == null) return const <SrsLocationEntry>[];
    return <SrsLocationEntry>[
      for (final AssetEntry e in await store.listChildren(id))
        SrsLocationEntry(
          e.name,
          isFolder: e.isFolder,
          size: e.sizeBytes,
          modifiedAt: e.modifiedAt,
        ),
    ];
  }

  @override
  Future<Uint8List?> get(String path) async {
    final (String dir, String name) = _split(path);
    final String? id = await _folder(dir, create: false);
    if (id == null) return null;
    final AssetEntry? a = await store.findAsset(id, name);
    if (a == null) return null;
    final File f = _tmp();
    try {
      await store.getAsset(a.id, f);
      return await f.readAsBytes();
    } finally {
      try {
        await f.delete();
      } on FileSystemException {
        // 临时文件留给系统清理。
      }
    }
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    final (String dir, String name) = _split(path);
    final String id = (await _folder(dir, create: true))!;
    // 允许同名多文件的后端（Google Drive）先删旧的，免得读到旧的那份（只有清除重写的段与说明文件会覆盖）。
    final AssetEntry? old = await store.findAsset(id, name);
    if (old != null) await store.deleteAsset(old.id);
    final File f = _tmp();
    try {
      await f.writeAsBytes(bytes, flush: true);
      await store.putAsset(id, name, f);
    } finally {
      try {
        await f.delete();
      } on FileSystemException {
        // 临时文件留给系统清理。
      }
    }
  }

  @override
  Future<void> delete(String path) async {
    final (String dir, String name) = _split(path);
    final String? id = await _folder(dir, create: false);
    if (id == null) return;
    final AssetEntry? a = await store.findAsset(id, name);
    if (a != null) await store.deleteAsset(a.id);
  }
}

/// 本地文件夹位置（桌面任意目录、U 盘、NAS 挂载盘、Syncthing / 坚果云 / iCloud Drive 同步目录；设计 §6.5）。
/// 写先落临时文件再改名，读者永远看不到半截文件。
class SrsDirectoryLocationStore implements SrsLocationStore {
  SrsDirectoryLocationStore(this.root);

  final Directory root;
  final Random _rand = Random();

  File _file(String path) => File(
    p.joinAll(<String>[
      root.path,
      ...path.split('/').where((String s) => s.isNotEmpty),
    ]),
  );

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    final Directory d = Directory(
      p.joinAll(<String>[
        root.path,
        ...dir.split('/').where((String s) => s.isNotEmpty),
      ]),
    );
    if (!await d.exists()) return const <SrsLocationEntry>[];
    final List<SrsLocationEntry> out = <SrsLocationEntry>[];
    await for (final FileSystemEntity e in d.list(followLinks: false)) {
      final String name = p.basename(e.path);
      if (name.startsWith('.srs2tmp-')) continue;
      if (e is Directory) {
        out.add(SrsLocationEntry(name, isFolder: true));
      } else if (e is File) {
        final FileStat st = await e.stat();
        out.add(
          SrsLocationEntry(
            name,
            size: st.size,
            modifiedAt: st.modified.millisecondsSinceEpoch,
          ),
        );
      }
    }
    return out;
  }

  @override
  Future<Uint8List?> get(String path) async {
    final File f = _file(path);
    try {
      return await f.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    final File f = _file(path);
    await f.parent.create(recursive: true);
    final File tmp = File(
      p.join(f.parent.path, '.srs2tmp-${_rand.nextInt(1 << 30)}'),
    );
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String path) async {
    try {
      await _file(path).delete();
    } on PathNotFoundException {
      // 已经不在。
    }
  }
}

/// 内存位置（测试 / 模拟哑存储的故障注入）。
class SrsMemoryLocationStore implements SrsLocationStore {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    final String prefix = dir.isEmpty ? '' : '$dir/';
    final Map<String, bool> out = <String, bool>{};
    for (final String path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final String rest = path.substring(prefix.length);
      final int i = rest.indexOf('/');
      if (i < 0) {
        out[rest] = false;
      } else {
        out[rest.substring(0, i)] = true;
      }
    }
    return <SrsLocationEntry>[
      for (final MapEntry<String, bool> e in out.entries)
        SrsLocationEntry(
          e.key,
          isFolder: e.value,
          size: e.value ? null : files['$prefix${e.key}']!.length,
        ),
    ];
  }

  @override
  Future<Uint8List?> get(String path) async => files[path];

  @override
  Future<void> put(String path, Uint8List bytes) async =>
      files[path] = Uint8List.fromList(bytes);

  @override
  Future<void> delete(String path) async => files.remove(path);
}
