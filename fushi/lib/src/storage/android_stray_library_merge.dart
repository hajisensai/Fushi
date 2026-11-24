import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/directory_move.dart'
    show kDirectoryCopyPartSuffix;

/// 两个 Android 书库根都有书时，把落选的根（[AppPaths.androidStrayLibraryRoot]）里的
/// 书并进书库根（拍板台 review-library-anchor-both-roots，承接 BUG-5375）。
///
/// 场景：锚点错指期间用户往错的根导入了书。启动期主库作证选对了根之后，错根里的那几本
/// 仍按绝对路径能打开，但它们不在书库根下：下一次「移动书库」不会带上它们，迁移前的
/// 子集核实还会因为目标里有源里没有的文件而拒绝迁移。这一步把它们并回来，让磁盘与主库
/// 都只剩一个书库根。
///
/// 纪律（误删代价大）：
///  - **一个字节都不丢**：同相对路径两边都有、内容不同 → 整次合并放弃，什么都不动
///    （只写诊断），绝不覆盖、绝不二选一；
///  - 内容逐字节相同的副本（中断迁移留下的完整复制）才删落选那边的；
///  - `*.fushi-part` 是中断复制的半截临时文件，直接删；
///  - 只碰数据根自有的顶层项（[AppPaths.fushiOwnedDocumentsEntries]，去掉不计证据的
///    运行目录），别的一概不碰。
///
/// 顺序（崩溃安全）：先在主库里把落选根前缀的路径改写到书库根，再逐个搬文件。半途崩溃时
/// 没搬完的文件仍在落选根里，下次启动两边仍都有书 → 再作证一次（尾段计票与路径前缀无关，
/// 结论不变）→ 再合并一次（改写已是空操作，搬剩下的）。
class AndroidStrayLibraryMerge {
  const AndroidStrayLibraryMerge._();

  /// 参与合并的顶层项：自有项去掉不计证据的运行目录（导出目录、导入暂存等）。
  static Set<String> get mergedTopLevelNames => AppPaths
      .fushiOwnedDocumentsEntries
      .difference(AppPaths.libraryEvidenceIgnoredEntries);

  /// 规划：只读，不改磁盘。
  static Future<AndroidStrayMergePlan> plan({
    required Directory libraryRoot,
    required Directory strayRoot,
  }) async {
    final List<String> moves = <String>[];
    final List<String> duplicates = <String>[];
    final List<String> partials = <String>[];
    final List<String> conflicts = <String>[];
    for (final String name in mergedTopLevelNames) {
      final Directory dir = Directory(p.join(strayRoot.path, name));
      if (!await dir.exists()) continue;
      await for (final FileSystemEntity e in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File) continue;
        final String base = p.basename(e.path);
        final String rel = p.relative(e.path, from: strayRoot.path);
        if (base.endsWith(kDirectoryCopyPartSuffix)) {
          partials.add(rel);
          continue;
        }
        if (base == '.nomedia') continue;
        final String target = p.join(libraryRoot.path, rel);
        switch (FileSystemEntity.typeSync(target, followLinks: false)) {
          case FileSystemEntityType.notFound:
            moves.add(rel);
          case FileSystemEntityType.file:
            if (await sameContent(e, File(target))) {
              duplicates.add(rel);
            } else {
              conflicts.add(rel);
            }
          default:
            conflicts.add(rel);
        }
      }
    }
    return AndroidStrayMergePlan(
      moves: moves,
      duplicates: duplicates,
      partials: partials,
      conflicts: conflicts,
    );
  }

  /// 执行合并。不抛异常：失败 / 放弃都写进返回值，由调用方记诊断。
  static Future<AndroidStrayMergeOutcome> run({
    required FushiDatabase db,
    required Directory libraryRoot,
    required Directory strayRoot,
    required String supportRoot,
  }) async {
    try {
      final String lib = p.normalize(libraryRoot.absolute.path);
      final String stray = p.normalize(strayRoot.absolute.path);
      if (p.equals(lib, stray) ||
          p.isWithin(lib, stray) ||
          p.isWithin(stray, lib)) {
        return const AndroidStrayMergeOutcome.skipped('两个根重合或互相嵌套');
      }
      final AndroidStrayMergePlan planned = await plan(
        libraryRoot: libraryRoot,
        strayRoot: strayRoot,
      );
      if (planned.conflicts.isNotEmpty) {
        return AndroidStrayMergeOutcome.conflicted(planned);
      }
      if (planned.isEmpty) return AndroidStrayMergeOutcome.merged(planned);

      final DocumentsPathRebaser docs = DocumentsPathRebaser(
        oldRoot: strayRoot.path,
        newRoot: libraryRoot.path,
        scopeTopLevelNames: mergedTopLevelNames,
      );
      // ① 先改写：内置引擎 fast-resume（两个根里的都改，落选根的随后被搬走）+ 主库。
      for (final Directory root in <Directory>[libraryRoot, strayRoot]) {
        await DataRootMigrator.rebaseEmbeddedTorrentFastResume(
          documentsRoot: root.path,
          docs: docs,
        );
      }
      await DataRootMigrator.rebaseOpenDatabasePaths(
        db: db,
        docs: docs,
        newSupportRoot: supportRoot,
      );
      // ② 再搬文件。
      for (final String rel in planned.moves) {
        await _moveFile(
          File(p.join(strayRoot.path, rel)),
          File(p.join(libraryRoot.path, rel)),
        );
      }
      for (final String rel in <String>[
        ...planned.duplicates,
        ...planned.partials,
      ]) {
        final File f = File(p.join(strayRoot.path, rel));
        if (await f.exists()) await f.delete();
      }
      for (final String name in mergedTopLevelNames) {
        await _deleteEmptyDirectories(Directory(p.join(strayRoot.path, name)));
      }
      return AndroidStrayMergeOutcome.merged(planned);
    } on Object catch (e) {
      return AndroidStrayMergeOutcome.failed(e);
    }
  }

  /// 搬一个文件：同卷 rename；跨卷先复制成 `*.fushi-part` 再改名、最后删源，任何时刻
  /// 目标里的正式名都是完整文件。
  static Future<void> _moveFile(File source, File target) async {
    await target.parent.create(recursive: true);
    try {
      await source.rename(target.path);
      return;
    } on FileSystemException {
      // 跨卷（内部 filesDir ↔ 外部 Android/data）：走复制。
    }
    final File part = File('${target.path}$kDirectoryCopyPartSuffix');
    await source.copy(part.path);
    await part.rename(target.path);
    await source.delete();
  }

  /// 自底向上删掉 [dir] 里没有任何文件的目录（含 [dir] 本身）；返回删完后它是否为空。
  static Future<bool> _deleteEmptyDirectories(Directory dir) async {
    if (!await dir.exists()) return true;
    bool empty = true;
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is Directory) {
        if (!await _deleteEmptyDirectories(e)) empty = false;
      } else {
        empty = false;
      }
    }
    if (empty) {
      try {
        await dir.delete();
      } on FileSystemException {
        return false;
      }
    }
    return empty;
  }

  /// 两个文件内容是否逐字节相同（先比长度）。
  static Future<bool> sameContent(File a, File b) async {
    if (await a.length() != await b.length()) return false;
    final RandomAccessFile ra = await a.open();
    final RandomAccessFile rb = await b.open();
    try {
      const int chunk = 1 << 20;
      while (true) {
        final Uint8List ba = await ra.read(chunk);
        final Uint8List bb = await rb.read(chunk);
        if (ba.length != bb.length) return false;
        if (ba.isEmpty) return true;
        for (int i = 0; i < ba.length; i++) {
          if (ba[i] != bb[i]) return false;
        }
      }
    } finally {
      await ra.close();
      await rb.close();
    }
  }
}

/// 合并规划（相对落选根的路径，`p` 风格分隔符）。
class AndroidStrayMergePlan {
  const AndroidStrayMergePlan({
    required this.moves,
    required this.duplicates,
    required this.partials,
    required this.conflicts,
  });

  /// 书库根里没有、要搬过去的文件。
  final List<String> moves;

  /// 书库根里有逐字节相同副本、删落选那边即可的文件。
  final List<String> duplicates;

  /// 中断复制留下的 `*.fushi-part`。
  final List<String> partials;

  /// 两边都有、内容不同：出现任何一条就整次放弃。
  final List<String> conflicts;

  bool get isEmpty =>
      moves.isEmpty &&
      duplicates.isEmpty &&
      partials.isEmpty &&
      conflicts.isEmpty;
}

enum AndroidStrayMergeStatus { merged, conflicted, skipped, failed }

/// 合并结果（供诊断日志）。
class AndroidStrayMergeOutcome {
  const AndroidStrayMergeOutcome._(
    this.status, {
    this.plan,
    this.reason,
    this.error,
  });

  const AndroidStrayMergeOutcome.skipped(String reason)
    : this._(AndroidStrayMergeStatus.skipped, reason: reason);

  const AndroidStrayMergeOutcome.merged(AndroidStrayMergePlan plan)
    : this._(AndroidStrayMergeStatus.merged, plan: plan);

  const AndroidStrayMergeOutcome.conflicted(AndroidStrayMergePlan plan)
    : this._(AndroidStrayMergeStatus.conflicted, plan: plan);

  const AndroidStrayMergeOutcome.failed(Object error)
    : this._(AndroidStrayMergeStatus.failed, error: error);

  final AndroidStrayMergeStatus status;
  final AndroidStrayMergePlan? plan;
  final String? reason;
  final Object? error;

  String describe() {
    final AndroidStrayMergePlan? pl = plan;
    switch (status) {
      case AndroidStrayMergeStatus.merged:
        return '已并回：搬 ${pl?.moves.length ?? 0} 个文件，删同内容副本 '
            '${pl?.duplicates.length ?? 0} 个、半截临时文件 ${pl?.partials.length ?? 0} 个';
      case AndroidStrayMergeStatus.conflicted:
        return '放弃合并（什么都没动）：${pl?.conflicts.length ?? 0} 个文件两边内容不同，'
            '例如 ${pl?.conflicts.first}';
      case AndroidStrayMergeStatus.skipped:
        return '跳过：$reason';
      case AndroidStrayMergeStatus.failed:
        return '合并失败：$error';
    }
  }
}
