/// 同步 v2 的存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.1、§6.5、§11）：只会「列目录 / 读 / 写 /
/// 删文件」的哑存储。协议保证每台设备只写自己的文件、文件写一次后不可变（清除重写的段例外：同名、同链值），
/// 所以这里不需要锁、原子比较交换或一致的列目录。
///
/// 路径一律相对于一个 profile 集合的根（`fushi-srs/<profileUid>/v2/`），用 `/` 分隔：
/// `meta.json`、`devices/<DeviceId>/{head-*.json, seg-*.bin, profile.json}`、`media/<文件名>`（加密时
/// `media-e/<密钥指纹>/<文件名>`）。
library;

import 'dart:async';
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

  /// 文件在不在（按名查一次，不下载内容、不列整个目录）。
  Future<bool> exists(String path);

  /// 写文件（同名覆盖；中间目录按需创建）。
  Future<void> put(String path, Uint8List bytes);

  /// 写不可变对象（内容寻址媒体：名字就是内容哈希）：已在就什么都不做，不在才写。**从不先删再写**——覆盖写在云盘
  /// 上是「删旧的 → 传新的」两步，中间被打断（或别的设备正好来读）就只剩半截 / 什么都没有。
  Future<void> putNew(String path, Uint8List bytes);

  /// 删文件（不存在视为成功）。
  Future<void> delete(String path);
}

/// 一个位置同时在途的读 / 写 / 删 / 列目录请求数上限。
const int kSrsSync2Concurrency = 6;

/// 对 [items] 逐个跑 [task]，同时最多 [limit] 个在途，结果按 [items] 的顺序返回。任一个失败：不再开新的，
/// 等在途的跑完后抛出第一个错误（与逐个 await 时一样，这一轮就此中止）。
Future<List<R>> srsRunPooled<T, R>(
  List<T> items,
  int limit,
  Future<R> Function(T item) task,
) async {
  final List<R?> out = List<R?>.filled(items.length, null);
  int next = 0;
  Object? error;
  StackTrace? stack;
  Future<void> worker() async {
    while (error == null && next < items.length) {
      final int i = next++;
      try {
        out[i] = await task(items[i]);
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
  }

  await Future.wait(<Future<void>>[
    for (int w = 0; w < min(limit, items.length); w++) worker(),
  ]);
  final Object? failure = error;
  if (failure != null) Error.throwWithStackTrace(failure, stack!);
  return <R>[for (final R? r in out) r as R];
}

/// 集合根在现有同步后端上的位置：`fushi-srs/<profileUid>/v2/`（与旧格式的写入者目录并列，互不干扰）。
const String kSrsSync2Namespace = 'fushi-srs';
const String kSrsSync2Folder = 'v2';

/// [SyncAssetStore]（各云盘后端 / 互联 / 本机 host 目录）上的位置。后端的文件夹定位符是不透明 id，
/// 这里按路径段逐级解析并缓存；正文经字节接口（开了「防扫盘混淆」时同样被混淆）。
///
/// 列过的目录记下「文件名 → 定位符」：一轮同步先列各设备目录再读写其中的文件，读直接用列出来的定位符、写新文件
/// 不再先按名查一遍——每个文件少一次网盘请求。实例按一轮同步建（不跨轮复用），列表过期的代价只是退回按名查：
/// 定位符失效（文件刚被别的设备删掉 / 重写）就按名重查。
///
/// 一轮同步会并发读写（[srsSync2Round]）：建文件夹按路径单飞（同一路径只建一次——Google Drive 允许同名文件夹，
/// 并发各建一个会把文件写散）；[maxConcurrentWrites] 给同一命名空间并发写会互相锁冲突的后端（Dropbox：
/// `too_many_write_operations`）限流写 / 删，读不受限。
class SrsAssetLocationStore implements SrsLocationStore {
  SrsAssetLocationStore({
    required this.store,
    required this.profileUid,
    this.maxConcurrentWrites,
    Directory? tempDir,
  }) : _temp = tempDir ?? Directory.systemTemp;

  final SyncAssetStore store;
  final String profileUid;

  /// 同时在途的写 / 删上限；null = 不限（由调用方的并发上限决定）。
  final int? maxConcurrentWrites;
  final Directory _temp;
  final Map<String, Future<String>> _folders = <String, Future<String>>{};
  final Random _rand = Random();
  int _writing = 0;
  final List<Completer<void>> _writeWaiters = <Completer<void>>[];

  /// 列过的目录 → (文件名 → 定位符；null = 本实例写过、定位符未知)。
  final Map<String, Map<String, String?>> _listed =
      <String, Map<String, String?>>{};

  /// 同一 [key] 的解析 / 创建只跑一次（并发调用共用同一个 future）；失败不缓存。
  Future<String> _once(String key, Future<String> Function() resolve) {
    final Future<String>? inFlight = _folders[key];
    if (inFlight != null) return inFlight;
    final Future<String> f = resolve();
    _folders[key] = f;
    f.ignore();
    return f.catchError((Object e, StackTrace s) {
      if (identical(_folders[key], f)) _folders.remove(key);
      Error.throwWithStackTrace(e, s);
    });
  }

  Future<String> _root() => _once('', () async {
    final String ns = await store.ensureNamespace(kSrsSync2Namespace);
    final String profile = await store.ensureFolder(ns, profileUid);
    return store.ensureFolder(profile, kSrsSync2Folder);
  });

  Future<T> _write<T>(Future<T> Function() body) async {
    final int? cap = maxConcurrentWrites;
    if (cap == null) return body();
    while (_writing >= cap) {
      final Completer<void> turn = Completer<void>();
      _writeWaiters.add(turn);
      await turn.future;
    }
    _writing++;
    try {
      return await body();
    } finally {
      _writing--;
      if (_writeWaiters.isNotEmpty) _writeWaiters.removeAt(0).complete();
    }
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
      final Future<String>? known = _folders[key];
      if (known != null) {
        cur = await known;
        continue;
      }
      final String parent = cur;
      if (create) {
        cur = await _once(key, () => store.ensureFolder(parent, part));
      } else {
        String? found;
        for (final AssetEntry e in await store.listChildren(parent)) {
          if (e.isFolder && e.name == part) {
            found = e.id;
            break;
          }
        }
        if (found == null) return null;
        final String id = found;
        // 期间别的调用建好了同一路径：以它为准。
        cur = await _once(key, () async => id);
      }
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
    final List<AssetEntry> children = await store.listChildren(id);
    _listed[_norm(dir)] = <String, String?>{
      for (final AssetEntry e in children)
        if (!e.isFolder) e.name: e.id,
    };
    return <SrsLocationEntry>[
      for (final AssetEntry e in children)
        SrsLocationEntry(
          e.name,
          isFolder: e.isFolder,
          size: e.sizeBytes,
          modifiedAt: e.modifiedAt,
        ),
    ];
  }

  String _norm(String dir) =>
      dir.split('/').where((String s) => s.isNotEmpty).join('/');

  Future<Uint8List> _download(String assetId) async {
    final File f = _tmp();
    try {
      await store.getAsset(assetId, f);
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
  Future<Uint8List?> get(String path) async {
    final (String dir, String name) = _split(path);
    final String? known = _listed[_norm(dir)]?[name];
    if (known != null) {
      try {
        return await _download(known);
      } on Object {
        // 列出来之后被删 / 被重写（定位符变了）：按名重查。
        _listed[_norm(dir)]?.remove(name);
      }
    }
    final String? id = await _folder(dir, create: false);
    if (id == null) return null;
    final AssetEntry? a = await store.findAsset(id, name);
    if (a == null) return null;
    return _download(a.id);
  }

  @override
  Future<bool> exists(String path) async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed != null && listed.containsKey(name)) return true;
    final String? id = await _folder(dir, create: false);
    if (id == null) return false;
    return await store.findAsset(id, name) != null;
  }

  @override
  Future<void> put(String path, Uint8List bytes) =>
      _write(() => _put(path, bytes));

  Future<void> _put(String path, Uint8List bytes) async {
    final (String dir, String name) = _split(path);
    final String id = (await _folder(dir, create: true))!;
    // 允许同名多文件的后端（Google Drive）先删旧的，免得读到旧的那份（只有清除重写的段与说明文件会覆盖）。
    // 这一轮列过这个目录且其中没有这个名字（新段、新 head 的名字都是新的）就不必再按名查。
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed == null || listed.containsKey(name)) {
      final String? cached = listed?[name];
      if (cached != null) {
        await store.deleteAsset(cached);
      } else {
        final AssetEntry? old = await store.findAsset(id, name);
        if (old != null) await store.deleteAsset(old.id);
      }
    }
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
    listed?[name] = null;
  }

  @override
  Future<void> putNew(String path, Uint8List bytes) => _write(() async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed != null && listed.containsKey(name)) return;
    final String id = (await _folder(dir, create: true))!;
    if (listed == null && await store.findAsset(id, name) != null) return;
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
    listed?[name] = null;
  });

  @override
  Future<void> delete(String path) => _write(() => _delete(path));

  Future<void> _delete(String path) async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    final String? cached = listed?[name];
    listed?.remove(name);
    if (cached != null) {
      await store.deleteAsset(cached);
      return;
    }
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
  Future<bool> exists(String path) => _file(path).exists();

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
  Future<void> putNew(String path, Uint8List bytes) async {
    if (await _file(path).exists()) return;
    await put(path, bytes);
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
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> put(String path, Uint8List bytes) async =>
      files[path] = Uint8List.fromList(bytes);

  @override
  Future<void> putNew(String path, Uint8List bytes) async {
    if (files.containsKey(path)) return;
    await put(path, bytes);
  }

  @override
  Future<void> delete(String path) async => files.remove(path);
}
