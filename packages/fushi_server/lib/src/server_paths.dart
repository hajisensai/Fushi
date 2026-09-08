/// 服务端数据根布局：`<data_dir>/documents` / `support` / `tmp` / `sync-data`。
///
/// 与 app 的三个根一一对应（`AppPaths` documents / support / temp），子目录派生
/// 规则在引擎基类 `EnginePaths` 里，所以 `video_covers` / `fushi_books` 等落点
/// 与 app 逐字节同形——同一份 DB 与目录树理论上可以被桌面 Fushi 直接打开。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:path/path.dart' as p;

class ServerPaths extends EnginePaths {
  ServerPaths(this.dataDir);

  final String dataDir;

  Directory get documents => Directory(p.join(dataDir, 'documents'));
  Directory get support => Directory(p.join(dataDir, 'support'));
  Directory get temp => Directory(p.join(dataDir, 'tmp'));

  /// 互联 WebDAV 根与配对/TLS 身份的落点（FushiSyncServer 内部再拼 `sync-data`）。
  Directory get syncData => Directory(p.join(dataDir, 'interconnect'));

  /// 远程 OCR 作业的上传页图（TTL 自清理）。
  Directory get mangaOcrJobs => Directory(p.join(syncData.path, 'manga_ocr_jobs'));

  /// 通用任务（ASR 等）的输入/产物。
  Directory get hostJobs => Directory(p.join(support.path, 'host_jobs'));

  /// 词典资源根（第 0 期不装词典引擎，但 host 服务需要一个目录做包导入落点）。
  Directory get dictionaryResources =>
      Directory(p.join(support.path, 'dictionaries'));

  Directory get logs => Directory(p.join(dataDir, 'logs'));

  Future<void> ensureLayout() async {
    for (final Directory d in <Directory>[
      documents,
      support,
      temp,
      syncData,
      hostJobs,
      dictionaryResources,
      logs,
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
}
