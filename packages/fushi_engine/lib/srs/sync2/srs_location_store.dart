/// 同步 v2 的存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.1、§6.5、§11）：只会「列目录 / 读 / 写 /
/// 删文件」的哑存储。协议保证每台设备只写自己的文件、文件写一次后不可变（清除重写的段例外：同名、同链值），
/// 所以这里不需要锁、原子比较交换或一致的列目录。
///
/// 路径一律相对于一个 profile 集合的根（`fushi-srs/<profileUid>/v3/`，[kSrsSync2Folder]），用 `/` 分隔：
/// `meta.json`、`devices/<DeviceId>/{head-*.json, seg-*.bin, rly-*.bin, profile.json}`、内容寻址媒体
/// `media/<sha256 前 2 位>/<sha256>`（加密时 `media-e/<密钥指纹>/<前 2 位>/<sha256>`）。
///
/// 协议 1 的集合根是 `fushi-srs/<profileUid>/v2/`（[kSrsSync2V1Folder]）：2026-10-30 断代后只剩一份让旧版本停下的
/// `meta.json`（文件夹位置另有一个同名普通文件 `media`），旧数据由一次性迁移搬进新根（srs_location_migration.dart）。
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

/// 能按文件读写的位置（审查 S-9）：大媒体从文件传、下载到文件，不整份读进内存。三个内置实现都支持；只实现了
/// [SrsLocationStore] 的位置经 [srsLocationGetFile] / [srsLocationPutNewFile] 退回按字节读写。
abstract interface class SrsLocationFileStore {
  /// 把 [path] 下载到 [dst]（覆盖）；不存在返回 false（[dst] 不动）。
  Future<bool> getFile(String path, File dst);

  /// 同 [SrsLocationStore.putNew]，内容来自 [src]（调用期间 [src] 不得改动）。
  Future<void> putNewFile(String path, File src);

  /// 同 [SrsLocationStore.put]（同名覆盖），内容来自 [src]，流式、不整份读进内存（调用期间 [src] 不得改动）。原子性
  /// 与 [SrsLocationStore.put] 相同：文件夹位置先写同目录临时文件再改名（读者看不到半截）；网盘位置用后端自己的覆盖
  /// 语义。只有可疑内容对象的覆盖重传用它（srs_media_sync.dart `putContent`）。
  Future<void> putFile(String path, File src);
}

/// 把 [path] 下载到 [dst]；不存在返回 false。
Future<bool> srsLocationGetFile(
  SrsLocationStore location,
  String path,
  File dst,
) async {
  if (location is SrsLocationFileStore) {
    return (location as SrsLocationFileStore).getFile(path, dst);
  }
  final Uint8List? bytes = await location.get(path);
  if (bytes == null) return false;
  await dst.writeAsBytes(bytes, flush: true);
  return true;
}

/// 把 [src] 覆盖写到 [path]（见 [SrsLocationFileStore.putFile]）；只实现了 [SrsLocationStore] 的位置退回按字节写。
Future<void> srsLocationPutFile(
  SrsLocationStore location,
  String path,
  File src,
) async {
  if (location is SrsLocationFileStore) {
    return (location as SrsLocationFileStore).putFile(path, src);
  }
  await location.put(path, await src.readAsBytes());
}

/// 把 [src] 写成不可变对象 [path]（见 [SrsLocationStore.putNew]）。
Future<void> srsLocationPutNewFile(
  SrsLocationStore location,
  String path,
  File src,
) async {
  if (location is SrsLocationFileStore) {
    return (location as SrsLocationFileStore).putNewFile(path, src);
  }
  await location.putNew(path, await src.readAsBytes());
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

/// 集合根在现有同步后端上的位置：`fushi-srs/<profileUid>/v3/`（协议 2）。
const String kSrsSync2Namespace = 'fushi-srs';
const String kSrsSync2Folder = 'v3';

/// 协议 1 的集合根（`fushi-srs/<profileUid>/v2/`）：旧版本只认这里。新版本只在这里写一份让旧版本停下的 `meta.json`，
/// 并把里面的旧数据迁进 [kSrsSync2Folder]（srs_location_migration.dart）。
const String kSrsSync2V1Folder = 'v2';

/// 各后端身份上在途的「确保子文件夹」（`<父定位符>\0<名字>` → 结果）。只记在途的：跑完就移走，下一次照常问后端
/// （缓存跨轮的定位符会在文件夹被删 / 换掉之后一直指向不存在的地方）。
final Expando<Map<String, Future<String>>> _srsEnsuring =
    Expando<Map<String, Future<String>>>('srsEnsureFolder');

/// 在 [parentId] 下确保有子文件夹 [name]（[SyncAssetStore.ensureFolder]），同一 [backendIdentity] 上同一
/// （父, 名字）进程内单飞：并发的调用共用同一次，后端「先查后建」不原子（Google Drive）也不会因为本进程里的
/// 并发建出同名文件夹。失败不留：下一次重新问后端。
Future<String> srsEnsureFolderShared(
  SyncAssetStore store,
  Object backendIdentity,
  String parentId,
  String name,
) => _srsEnsureOnce(
  backendIdentity,
  'f\u0000$parentId\u0000$name',
  () => store.ensureFolder(parentId, name),
);

/// 同 [srsEnsureFolderShared]，确保的是后端根下的顶层命名空间（[SyncAssetStore.ensureNamespace]）。
Future<String> srsEnsureNamespaceShared(
  SyncAssetStore store,
  Object backendIdentity,
  String name,
) => _srsEnsureOnce(
  backendIdentity,
  'n\u0000$name',
  () => store.ensureNamespace(name),
);

Future<String> _srsEnsureOnce(
  Object backendIdentity,
  String key,
  Future<String> Function() ensure,
) {
  final Map<String, Future<String>> inFlight = _srsEnsuring[backendIdentity] ??=
      <String, Future<String>>{};
  final Future<String>? running = inFlight[key];
  if (running != null) return running;
  final Future<String> f = ensure();
  inFlight[key] = f;
  void settle() {
    if (identical(inFlight[key], f)) inFlight.remove(key);
  }

  return f.then(
    (String id) {
      settle();
      return id;
    },
    onError: (Object e, StackTrace s) {
      settle();
      Error.throwWithStackTrace(e, s);
    },
  );
}

/// [SyncAssetStore]（各云盘后端 / 互联 / 本机 host 目录）上的位置。后端的文件夹定位符是不透明 id，
/// 这里按路径段逐级解析并缓存；正文经字节接口（开了「防扫盘混淆」时同样被混淆）。
///
/// 列过的目录记下「文件名 → 定位符」：一轮同步先列各设备目录再读写其中的文件，读直接用列出来的定位符、写新文件
/// 不再先按名查一遍——每个文件少一次网盘请求。实例按一轮同步建（不跨轮复用），列表过期的代价只是退回按名查：
/// 定位符失效（文件刚被别的设备删掉 / 重写）就按名重查。
///
/// 一轮同步会并发读写（[srsSync2Round]）；[maxConcurrentWrites] 给同一命名空间并发写会互相锁冲突的后端（Dropbox：
/// `too_many_write_operations`）限流写 / 删，读不受限。
///
/// **同名文件夹**（Google Drive 允许同名文件夹，`ensureFolder` 是「先查后建」、不原子）：
/// - 建：同一后端（[backendIdentity]）上「在某个父目录下建某个名字」进程内单飞（[srsEnsureFolderShared]），
///   不只是本实例——一轮同步、发段前的媒体上传、后台旧根迁移各自建实例，并发往新根的 `media/<前2>/` 建目录时
///   以前会各建一个（PR #2768 审查）。
/// - 读：一个路径解析成**全部**同名文件夹（别的设备 / 旧版本已经建重了的照样在），列目录取并集、读 / 查 / 删在
///   每一个里找；按路径只认第一个会让另一个里的对象对所有读者都不可见。
class SrsAssetLocationStore implements SrsLocationStore, SrsLocationFileStore {
  SrsAssetLocationStore({
    required this.store,
    required this.profileUid,
    this.folder = kSrsSync2Folder,
    this.maxConcurrentWrites,
    Object? backendIdentity,
    Directory? tempDir,
  }) : backendIdentity = backendIdentity ?? store,
       _temp = tempDir ?? Directory.systemTemp;

  final SyncAssetStore store;

  /// 后端身份：同一身份上建文件夹进程内单飞（[srsEnsureFolderShared]）。缺省为 [store] 本身；调用方每次给的是包装
  /// （防扫盘混淆每次新建一层、`ensureFolder` 原样透传给里层的单例后端）时传里层那个。
  final Object backendIdentity;
  final String profileUid;

  /// 集合根目录名（`fushi-srs/<profileUid>/<folder>/`）：[kSrsSync2Folder]，迁移时也开一个 [kSrsSync2V1Folder] 的。
  final String folder;

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
    final String ns = await srsEnsureNamespaceShared(
      store,
      backendIdentity,
      kSrsSync2Namespace,
    );
    final String profile = await srsEnsureFolderShared(
      store,
      backendIdentity,
      ns,
      profileUid,
    );
    return srsEnsureFolderShared(store, backendIdentity, profile, folder);
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

  /// 已解析出的目录（路径 → 全部同名文件夹的定位符，非空）；在途的也在这里（解析出空 / 失败时移走，不缓存「不在」）。
  final Map<String, Future<List<String>>> _found =
      <String, Future<List<String>>>{};

  /// 本实例建好的目录（路径 → 定位符）：刚建的文件夹后端列目录可能还看不到，读的时候并进去。
  final Map<String, String> _made = <String, String>{};

  /// [dir]（已规范化）的全部同名文件夹定位符；不存在为空列表。
  Future<List<String>> _dirs(String key) {
    if (key.isEmpty) return _root().then((String id) => <String>[id]);
    final Future<List<String>>? known = _found[key];
    if (known != null) return known;
    final Future<List<String>> f = _resolveDirs(key);
    _found[key] = f;
    f.ignore();
    return f.then(
      (List<String> ids) {
        if (ids.isEmpty && identical(_found[key], f)) _found.remove(key);
        return ids;
      },
      onError: (Object e, StackTrace s) {
        if (identical(_found[key], f)) _found.remove(key);
        Error.throwWithStackTrace(e, s);
      },
    );
  }

  Future<List<String>> _resolveDirs(String key) async {
    final (String parentKey, String name) = _split(key);
    final List<String> ids = <String>[];
    for (final String parent in await _dirs(parentKey)) {
      for (final AssetEntry e in await store.listChildren(parent)) {
        if (e.isFolder && e.name == name && !ids.contains(e.id)) ids.add(e.id);
      }
    }
    final String? made = _made[key];
    if (made != null && !ids.contains(made)) ids.add(made);
    return ids;
  }

  /// 写的目标目录（已规范化的 [key]）：已有就用第一个，没有才建（后端上进程内单飞）。
  Future<String> _ensureDir(String key) {
    if (key.isEmpty) return _root();
    return _once(key, () async {
      final List<String> ids = await _dirs(key);
      if (ids.isNotEmpty) return ids.first;
      final (String parentKey, String name) = _split(key);
      final String parent = await _ensureDir(parentKey);
      final String id = await srsEnsureFolderShared(
        store,
        backendIdentity,
        parent,
        name,
      );
      _made[key] = id;
      return id;
    });
  }

  /// [path] 所在目录里名为 [name] 的文件（在每个同名文件夹里按名查，第一个找到的）。
  Future<AssetEntry?> _findIn(String dir, String name) async {
    for (final String id in await _dirs(_norm(dir))) {
      final AssetEntry? a = await store.findAsset(id, name);
      if (a != null) return a;
    }
    return null;
  }

  /// [dir] 里所有名为 [name] 的文件（每个同名文件夹里各按名查一次）。
  Future<List<AssetEntry>> _findAllIn(String dir, String name) async {
    final List<AssetEntry> out = <AssetEntry>[];
    for (final String id in await _dirs(_norm(dir))) {
      final AssetEntry? a = await store.findAsset(id, name);
      if (a != null) out.add(a);
    }
    return out;
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
    final List<String> ids = await _dirs(_norm(dir));
    if (ids.isEmpty) return const <SrsLocationEntry>[];
    // 同名文件夹取并集；同名的项（子文件夹、同一个内容对象）只列一次，读的时候取第一个找到的。
    final Map<(bool, String), AssetEntry> children =
        <(bool, String), AssetEntry>{};
    for (final String id in ids) {
      for (final AssetEntry e in await store.listChildren(id)) {
        children.putIfAbsent((e.isFolder, e.name), () => e);
      }
    }
    _listed[_norm(dir)] = <String, String?>{
      for (final AssetEntry e in children.values)
        if (!e.isFolder) e.name: e.id,
    };
    return <SrsLocationEntry>[
      for (final AssetEntry e in children.values)
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
    final AssetEntry? a = await _findIn(dir, name);
    if (a == null) return null;
    return _download(a.id);
  }

  @override
  Future<bool> getFile(String path, File dst) async {
    final (String dir, String name) = _split(path);
    final String? known = _listed[_norm(dir)]?[name];
    if (known != null) {
      try {
        await store.getAsset(known, dst);
        return true;
      } on Object {
        // 列出来之后被删 / 被重写（定位符变了）：按名重查。
        _listed[_norm(dir)]?.remove(name);
      }
    }
    final AssetEntry? a = await _findIn(dir, name);
    if (a == null) return false;
    await store.getAsset(a.id, dst);
    return true;
  }

  @override
  Future<bool> exists(String path) async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed != null && listed.containsKey(name)) return true;
    return await _findIn(dir, name) != null;
  }

  @override
  Future<void> put(String path, Uint8List bytes) => _write(() async {
    final File f = _tmp();
    try {
      await f.writeAsBytes(bytes, flush: true);
      await _putFile(path, f);
    } finally {
      try {
        await f.delete();
      } on FileSystemException {
        // 临时文件留给系统清理。
      }
    }
  });

  @override
  Future<void> putFile(String path, File src) =>
      _write(() => _putFile(path, src));

  /// 覆盖写：后端本来就是「从文件传」，直接传 [src]，不经内存。
  Future<void> _putFile(String path, File src) async {
    final (String dir, String name) = _split(path);
    final String id = await _ensureDir(_norm(dir));
    // 允许同名多文件的后端（Google Drive）先删旧的，免得读到旧的那份（只有清除重写的段与说明文件会覆盖）；同名
    // 文件夹里的旧份一样删（读的时候每个都找）。这一轮列过这个目录且其中没有这个名字（新段、新 head 的名字都是新的）
    // 就不必再按名查。
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed == null || listed.containsKey(name)) {
      await _deleteAll(dir, name, listed?[name]);
    }
    await store.putAsset(id, name, src);
    listed?[name] = null;
  }

  @override
  Future<void> putNew(String path, Uint8List bytes) => _write(() async {
    final File f = _tmp();
    try {
      await f.writeAsBytes(bytes, flush: true);
      await _putNewFile(path, f);
    } finally {
      try {
        await f.delete();
      } on FileSystemException {
        // 临时文件留给系统清理。
      }
    }
  });

  @override
  Future<void> putNewFile(String path, File src) =>
      _write(() => _putNewFile(path, src));

  /// 后端本来就是「从文件传」：直接传 [src]，不经内存、不再落一份临时文件。
  Future<void> _putNewFile(String path, File src) async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    if (listed != null && listed.containsKey(name)) return;
    final String id = await _ensureDir(_norm(dir));
    if (listed == null && await _findIn(dir, name) != null) return;
    await store.putAsset(id, name, src);
    listed?[name] = null;
  }

  @override
  Future<void> delete(String path) => _write(() => _delete(path));

  Future<void> _delete(String path) async {
    final (String dir, String name) = _split(path);
    final Map<String, String?>? listed = _listed[_norm(dir)];
    final String? cached = listed?[name];
    listed?.remove(name);
    await _deleteAll(dir, name, cached);
  }

  /// 删掉 [dir] 里所有名为 [name] 的文件（[cached] = 列目录时记下的那一份的定位符）。只有一个文件夹时有 [cached]
  /// 就不再按名查；有同名文件夹时每个里都按名查一遍（别的里可能还有一份，读的时候会读到它）。
  Future<void> _deleteAll(String dir, String name, String? cached) async {
    if (cached != null) {
      await store.deleteAsset(cached);
      if ((await _dirs(_norm(dir))).length < 2) return;
    }
    for (final AssetEntry a in await _findAllIn(dir, name)) {
      if (a.id != cached) await store.deleteAsset(a.id);
    }
  }
}

/// 本地文件夹位置（桌面任意目录、U 盘、NAS 挂载盘、Syncthing / 坚果云 / iCloud Drive 同步目录；设计 §6.5）。
/// 写先落临时文件再改名，读者永远看不到半截文件。
class SrsDirectoryLocationStore
    implements SrsLocationStore, SrsLocationFileStore {
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
    final List<SrsLocationEntry> out = <SrsLocationEntry>[];
    try {
      await for (final FileSystemEntity e in d.list(followLinks: false)) {
        final String name = p.basename(e.path);
        if (name.startsWith('.srs2tmp-')) continue;
        if (e is Directory) {
          out.add(SrsLocationEntry(name, isFolder: true));
        } else if (e is File) {
          final FileStat st = await e.stat();
          // 列出来之后被别的设备 / 同步工具删了：当不在。
          if (st.type == FileSystemEntityType.notFound) continue;
          out.add(
            SrsLocationEntry(
              name,
              size: st.size,
              modifiedAt: st.modified.millisecondsSinceEpoch,
            ),
          );
        }
      }
    } on PathNotFoundException {
      // 目录不在，或列到一半被别的设备删掉（迁移收尾删空目录、同步工具）：与云盘上列一个不存在的目录同义——空。
      return const <SrsLocationEntry>[];
    }
    return out;
  }

  @override
  Future<Uint8List?> get(String path) async {
    final File f = _file(path);
    try {
      return await _whileReplaced(f.readAsBytes);
    } on PathNotFoundException {
      return null;
    }
  }

  /// Windows 平台语义：别的句柄（另一台设备 / 同步工具）正把这个路径改名替换的那一瞬间，打开它报共享冲突
  /// （ERROR_SHARING_VIOLATION，errno 32）——文件既不是不在、也不是坏了，替换完就能读到新的那份（POSIX 上改名替换
  /// 对读者原子，没有这一态）。只对这一个错误码、有界地重新打开；别的错误、以及超过上限的共享冲突原样抛出。
  /// 不可控的平台限制，没有清理条件（只要位置可能在 Windows 上被并发替换就需要）。
  static Future<T> _whileReplaced<T>(Future<T> Function() open) async {
    for (int attempt = 0; ; attempt++) {
      try {
        return await open();
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode != _kSharingViolation ||
            attempt >= _kSharingViolationAttempts) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  static const int _kSharingViolation = 32;
  static const int _kSharingViolationAttempts = 200;

  @override
  Future<bool> exists(String path) => _file(path).exists();

  File _tempNextTo(File f) =>
      File(p.join(f.parent.path, '.srs2tmp-${_rand.nextInt(1 << 30)}'));

  /// 把写好的临时文件 [tmp] 改名成 [f]。几台设备同时写同一个路径（两台新版本同时迁移同一个位置、内容寻址的同一个
  /// 对象）时，Windows 上改名盖一个正被别人改名 / 读的目标会报 errno 5 / 32。这时重新看目标：
  /// - [onlyIfAbsent]（putNew 系列：只在不在时创建）：目标已经在了 = 别人先建了，正是这个调用的约定，不再盖；
  /// - 覆盖写：目标已经是我们要写的这份字节，结果就是我们要的；
  /// 否则原样抛出。临时文件总是删掉。
  Future<void> _land(File tmp, File f, {required bool onlyIfAbsent}) async {
    try {
      // 写临时文件期间别人已经建好了：不再去替换它（替换会让正在读它的设备撞上共享冲突）。
      if (onlyIfAbsent && await f.exists()) return;
      await tmp.rename(f.path);
    } on FileSystemException {
      if (!await f.exists()) rethrow;
      if (!onlyIfAbsent && !await _sameBytes(tmp, f)) rethrow;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时名不会被列出来（list 跳过 `.srs2tmp-`），留给下次清理。
      }
    }
  }

  static Future<bool> _sameBytes(File a, File b) async {
    try {
      final Uint8List x = await a.readAsBytes();
      final Uint8List y = await b.readAsBytes();
      if (x.length != y.length) return false;
      for (int i = 0; i < x.length; i++) {
        if (x[i] != y[i]) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> put(String path, Uint8List bytes) =>
      _putBytes(path, bytes, false);

  @override
  Future<void> putNew(String path, Uint8List bytes) async {
    if (await _file(path).exists()) return;
    await _putBytes(path, bytes, true);
  }

  Future<void> _putBytes(
    String path,
    Uint8List bytes,
    bool onlyIfAbsent,
  ) async {
    final File f = _file(path);
    await f.parent.create(recursive: true);
    final File tmp = _tempNextTo(f);
    await tmp.writeAsBytes(bytes, flush: true);
    await _land(tmp, f, onlyIfAbsent: onlyIfAbsent);
  }

  /// 先流式拷成同目录临时文件再改名盖上去（读者看不到半截；改名失败不留临时文件）。
  @override
  Future<void> putFile(String path, File src) => _putCopy(path, src, false);

  Future<void> _putCopy(String path, File src, bool onlyIfAbsent) async {
    final File f = _file(path);
    await f.parent.create(recursive: true);
    final File tmp = _tempNextTo(f);
    try {
      await src.copy(tmp.path);
    } on Object {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 同 _land。
      }
      rethrow;
    }
    await _land(tmp, f, onlyIfAbsent: onlyIfAbsent);
  }

  @override
  Future<bool> getFile(String path, File dst) async {
    try {
      await _whileReplaced(() => _file(path).copy(dst.path));
      return true;
    } on PathNotFoundException {
      return false;
    }
  }

  /// 先流式拷成同目录临时文件再改名（读者看不到半截）。
  @override
  Future<void> putNewFile(String path, File src) async {
    if (await _file(path).exists()) return;
    await _putCopy(path, src, true);
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
class SrsMemoryLocationStore implements SrsLocationStore, SrsLocationFileStore {
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
  Future<bool> getFile(String path, File dst) async {
    final Uint8List? bytes = await get(path);
    if (bytes == null) return false;
    await dst.writeAsBytes(bytes, flush: true);
    return true;
  }

  @override
  Future<void> putNewFile(String path, File src) async =>
      putNew(path, await src.readAsBytes());

  @override
  Future<void> putFile(String path, File src) async =>
      put(path, await src.readAsBytes());

  @override
  Future<void> delete(String path) async => files.remove(path);
}
