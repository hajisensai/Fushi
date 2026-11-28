/// 服务端数据根布局：`<data_dir>/documents` / `support` / `tmp` / `sync-data`。
///
/// 与 app 的三个根一一对应（`AppPaths` documents / support / temp）。子目录登记在
/// 受管存储区域上（fushi_engine `storage_area.dart`）：引擎共用的 [EngineStorageArea]
/// （`video_covers` / `fushi_books` 等，与 app 逐字节同形）+ 本文件的
/// [ServerStorageArea]，合成 [kServerStorageAreas]。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/foundation/storage_area.dart';
import 'package:path/path.dart' as p;

/// 服务端独有的区域（引擎共用的那些在 [EngineStorageArea]）。布局冻结：这些路径是
/// 现网服务端 `data_dir` 的磁盘布局，改名 / 换根要带搬迁（D2 之后）。
enum ServerStorageArea implements StorageArea {
  /// 互联 WebDAV 根与配对 / TLS 身份的落点（`FushiSyncServer` 内部再拼 `sync-data`）。
  interconnect(
    id: 'interconnect',
    root: StorageRootId.hostData,
    relativePath: 'interconnect',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.control,
    ensuredAtStartup: true,
  ),

  /// 远程 OCR 作业的上传页图（TTL 自清理）。
  mangaOcrJobs(
    id: 'manga_ocr_jobs',
    root: StorageRootId.hostData,
    relativePath: 'interconnect/manga_ocr_jobs',
    category: StorageCategoryId.cache,
    lifecycle: StorageLifecycle.cache,
  ),

  /// 通用任务（ASR 等）的输入 / 产物。
  hostJobs(
    id: 'host_jobs',
    root: StorageRootId.support,
    relativePath: 'host_jobs',
    category: StorageCategoryId.subtitleJobs,
    lifecycle: StorageLifecycle.derived,
    ensuredAtStartup: true,
  ),

  /// 词典资源根（host 服务的包导入落点）。与 app 的 `<documents>/dictionaryResources`
  /// 布局不同，统一要带一次搬迁，不在 D1 范围。
  dictionaries(
    id: 'dictionaries',
    root: StorageRootId.support,
    relativePath: 'dictionaries',
    category: StorageCategoryId.dictionaries,
    lifecycle: StorageLifecycle.libraryContent,
    ensuredAtStartup: true,
  ),

  /// 服务端日志。
  logs(
    id: 'logs',
    root: StorageRootId.hostData,
    relativePath: 'logs',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.control,
    ensuredAtStartup: true,
  ),

  /// 已配对设备经互联「配置文件」端点推来寄存的配置方案（见 `ServerProfileHub`）。
  interconnectProfiles(
    id: 'interconnect_profiles',
    root: StorageRootId.support,
    relativePath: 'interconnect_profiles',
    category: StorageCategoryId.database,
    lifecycle: StorageLifecycle.userData,
  ),

  /// 内置 torrent 引擎的 fastResume 目录（与 app 的 `<support>/torrent/resume` 同义）。
  torrentResume(
    id: 'torrent_resume',
    root: StorageRootId.support,
    relativePath: 'torrent/resume',
    category: StorageCategoryId.videoDownloads,
    lifecycle: StorageLifecycle.control,
  );

  const ServerStorageArea({
    required this.id,
    required this.root,
    required this.relativePath,
    required this.category,
    required this.lifecycle,
    this.ensuredAtStartup = false,
  });

  @override
  final String id;
  @override
  final StorageRootId root;
  @override
  final String relativePath;
  @override
  List<String> get legacyNames => const <String>[];
  @override
  final StorageCategoryId category;
  @override
  final StorageLifecycle lifecycle;
  @override
  StorageEntryDeletability? get deletabilityOverride => null;
  @override
  bool get countsAsLibraryEvidence => true;

  /// [ServerPaths.ensureLayout] 启动时就建好它。
  final bool ensuredAtStartup;
}

/// 服务端进程的区域登记表（引擎区域 + 服务端区域）。
final StorageAreaRegistry kServerStorageAreas = StorageAreaRegistry(
  <StorageArea>[...EngineStorageArea.values, ...ServerStorageArea.values],
);

class ServerPaths extends EnginePaths {
  ServerPaths(this.dataDir);

  final String dataDir;

  Directory get documents => Directory(p.join(dataDir, 'documents'));
  Directory get support => Directory(p.join(dataDir, 'support'));
  Directory get temp => Directory(p.join(dataDir, 'tmp'));

  /// [area] 的绝对路径（同步解析：服务端的根都由 [dataDir] 直接给出）。
  Directory area(StorageArea area) =>
      Directory(area.pathUnder(_root(area.root).path));

  Directory _root(StorageRootId root) => switch (root) {
    StorageRootId.documents => documents,
    StorageRootId.support => support,
    StorageRootId.temp => temp,
    StorageRootId.hostData => Directory(dataDir),
    StorageRootId.appCache || StorageRootId.userExports => throw StateError(
      'storage root ${root.name} is not available on the headless server',
    ),
  };

  /// 互联 WebDAV 根与配对/TLS 身份的落点（FushiSyncServer 内部再拼 `sync-data`）。
  Directory get syncData => area(ServerStorageArea.interconnect);

  /// 远程 OCR 作业的上传页图（TTL 自清理）。
  Directory get mangaOcrJobs => area(ServerStorageArea.mangaOcrJobs);

  /// 通用任务（ASR 等）的输入/产物。
  Directory get hostJobs => area(ServerStorageArea.hostJobs);

  /// 词典资源根（第 0 期不装词典引擎，但 host 服务需要一个目录做包导入落点）。
  Directory get dictionaryResources => area(ServerStorageArea.dictionaries);

  Directory get logs => area(ServerStorageArea.logs);

  /// 已配对设备经互联「配置文件」端点推来寄存的配置方案（见 `ServerProfileHub`）。
  Directory get interconnectProfiles =>
      area(ServerStorageArea.interconnectProfiles);

  /// 内置 torrent 引擎的 fastResume 目录（与 app 的 `<support>/torrent/resume` 同义）。
  Directory get torrentResume => area(ServerStorageArea.torrentResume);

  Future<void> ensureLayout() async {
    for (final Directory d in <Directory>[
      documents,
      support,
      temp,
      // 经登记表取：启动时顺带触发它的构造期校验（区域冲突是编程错误，进程起来前就炸）。
      for (final ServerStorageArea a
          in kServerStorageAreas.areas.whereType<ServerStorageArea>())
        if (a.ensuredAtStartup) area(a),
    ]) {
      await d.create(recursive: true);
    }
  }

  @override
  Future<Directory> documentsRootDirectory() async => documents;

  @override
  Future<Directory> supportRootDirectory() async => support;

  @override
  Future<Directory> tempRootDirectory() async => temp;

  @override
  Future<Directory> hostRootDirectory(StorageRootId root) async => _root(root);
}
