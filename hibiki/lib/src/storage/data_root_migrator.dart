import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/sync/backup_service.dart'
    show
        rebaseFontCatalogJson,
        rebaseFontListJson,
        rebaseLocalAudioDbsJson,
        rebasePath;

/// TODO-935 E1：把应用「数据存储位置」整目录迁到新 dataRoot 的引擎（仅桌面）。
///
/// **本类只负责把数据从旧根搬到新根并把 DB 内绝对路径改写为新根**；它不接 UI、不重启
/// 进程、不在移动端调用（沙箱固定）。设置 UI（E2）/ 重启换根（E3）在后续阶段。
///
/// 设计准则：
///  - **可纯单测**：引擎不直接持有 `AppModel` / 全局单例。需要先关闭的运行时句柄
///    （Drift DB / 词典 FFI / 音频）作为 [DataRootMigrationRequest.closeResources]
///    回调传入；引擎只负责「确保关闭已发生」并执行文件系统 + DB 文件级改写。
///  - **失败回滚铁律**：迁移前**绝不删**旧目录；新根校验通过 + DB rebase 成功，才删旧
///    根。任一步失败 → 保留旧根、清理新根半成品、抛错、**不写 data_root**（断电/跨盘安全）。
///  - **同盘 rename / 跨盘 copy+verify+delete**：同卷用原子 `rename`；跨卷退回逐文件
///    复制并按字节数校验后再删源。
class DataRootMigrationRequest {
  const DataRootMigrationRequest({
    required this.oldDocumentsRoot,
    required this.oldSupportRoot,
    required this.newDataRoot,
    required this.closeResources,
    required this.writeDataRootPref,
    this.onProgress,
  });

  /// 旧「内容/书库」根（含 EPUB / 有声书 / 视频封面/字幕/shader / 词典资源 / 缩略图）。
  final Directory oldDocumentsRoot;

  /// 旧「数据库/支持」根（`hibiki.db` + 各 `local_audio_*.db`）。
  final Directory oldSupportRoot;

  /// 目标 dataRoot 绝对路径；其下派生 `<dataRoot>/documents` 与 `<dataRoot>/support`
  /// （与 [AppPaths.rootsForDataRoot] 逐字节一致）。
  final String newDataRoot;

  /// 迁移前**必须**完成的运行时关闭：checkpoint+关 Drift DB、关词典 FFI 句柄、停音频。
  /// 引擎在搬任何文件前 `await` 它；调用方负责真正关闭全局单例（保持引擎可纯测）。
  final Future<void> Function() closeResources;

  /// 迁移全部成功后，把新 dataRoot 写进 SharedPreferences（[AppPaths.dataRootPrefKey]）。
  /// 作为回调注入而非引擎内直连 SharedPreferences，使引擎在纯 Dart 单测里可断言写入。
  final Future<void> Function(String newDataRoot) writeDataRootPref;

  /// 跨盘 copy 阶段的进度回调（可选）。仅在退回逐文件复制（不同卷）时触发：每复制完一个
  /// 文件回报一次 (已复制文件数, 总文件数)。同盘 `rename` 是瞬时原子操作，不产生进度。
  /// 注入给 UI 显示百分比进度条，避免搬大库被误判死机（TODO-959）。null 表示不需要进度。
  final void Function(int copied, int total)? onProgress;
}

/// 迁移过程中可恢复的失败：旧根保持完整、未切换、新根半成品已清理。
class DataRootMigrationException implements Exception {
  const DataRootMigrationException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() =>
      'DataRootMigrationException: $message${cause == null ? '' : ' ($cause)'}';
}

class DataRootMigrator {
  const DataRootMigrator();

  /// SharedPreferences 落盘文件的**文件名前缀**族。桌面默认根迁移时，`oldSupportRoot`
  /// 恰好等于平台固定落点 `getApplicationSupportDirectory()`，`shared_preferences_windows`
  /// 插件把 `shared_preferences.json` 就存这个目录（见 `app_paths.dart:65-70` 的鸡生蛋
  /// 铁律：data_root 配置必须在被迁移的 DB 打开*之前*从这个固定落点可读，故 prefs 文件
  /// **不能**随数据根搬走）。用前缀而非精确名，覆盖插件可能派生的 sidecar（`.json` /
  /// `.json.lock` / journal / `.bak` 等同名族），且只在源根**顶层**匹配（prefs 恒在根
  /// 顶层，不在子目录），避免误伤子目录里恰好同名前缀的用户数据。
  static const List<String> _prefsFileNamePrefixes = <String>[
    'shared_preferences',
  ];

  /// 持久化的字体目录配置 pref 键（含 ReaderSettings 前缀）。与 `backup_service.dart`
  /// 的同名常量保持一致（那边是 private，迁移引擎独立持有同一字面量）。
  static const String _fontCatalogPrefKey = 'src:reader_ttu:font_catalog';
  static const List<String> _legacyFontPrefKeys = <String>[
    'src:reader_ttu:custom_fonts',
    'src:reader_ttu:app_ui_fonts',
    'src:reader_ttu:dict_fonts',
    'src:reader_ttu:video_sub_fonts',
  ];
  static const String _localAudioDbsPrefKey = 'local_audio_dbs';

  /// 执行迁移。成功返回新 dataRoot 派生的 (documents, support) 根。
  ///
  /// 步骤：① await 关闭运行时句柄；② 校验新 dataRoot 可建且为空（不覆盖已有数据）；
  /// ③ 把旧 documents/support 整目录搬进新根的 documents/support；④ 在已搬过去的
  /// `hibiki.db` 上把所有绝对路径列从旧根 rebase 到新根（含 prefs 里的字体 / 本地音频
  /// 库 JSON）；⑤ 全成功后删旧根 + 写 data_root pref。任一步失败抛
  /// [DataRootMigrationException]，旧根原样保留、新根半成品清理、不写 pref。
  Future<(Directory documents, Directory support)> migrate(
    DataRootMigrationRequest req,
  ) async {
    final Directory newRoot = Directory(req.newDataRoot);
    final (Directory newDocs, Directory newSupport) =
        AppPaths.rootsForDataRoot(req.newDataRoot);

    _validateTarget(req, newDocs, newSupport);

    // ① 先关运行时句柄（DB/FFI/音频），否则 Windows 上 rename/删源会被占用锁住。
    await req.closeResources();

    // ② 整目录搬动（同盘 rename / 跨盘 copy+verify+delete）。先 documents 再 support；
    //    任一失败 → 回滚已搬的部分，清理新根半成品。
    //
    // **prefs 例外**：默认根迁移时 oldSupportRoot == 平台固定落点，内含活的
    // `shared_preferences.json`（data_root 配置本身就存在这里）。它必须留在原地——否则
    // 迁移后固定落点读不到 data_root，重启回退默认根（TODO-935/959 根因）。故对 support
    // 搬移排除源根顶层的 prefs 文件族；从自定义根迁移时源根顶层无 prefs → 排除集为空 →
    // 走原子 rename 快路径，行为不变。
    final Set<String> supportExclude =
        _prefsFileNamesToPreserveAt(req.oldSupportRoot);
    final List<_MovePlan> moves = <_MovePlan>[
      _MovePlan(req.oldDocumentsRoot, newDocs,
          excludeTopLevelNames: const <String>{}),
      _MovePlan(req.oldSupportRoot, newSupport,
          excludeTopLevelNames: supportExclude),
    ];
    final List<_MovePlan> done = <_MovePlan>[];
    // 跨盘复制的进度状态：累积已复制文件数 + 两子树总文件数（同盘 rename 不计）。
    // 跨盘搬移前一次性数清总数，便于 UI 显示稳定的百分比；同盘搬移此对象不被用到。
    final _CopyProgress progress = _CopyProgress(req.onProgress);
    try {
      newRoot.createSync(recursive: true);
      for (final _MovePlan m in moves) {
        await _moveTree(m.src, m.dst, progress, m.excludeTopLevelNames);
        done.add(m);
      }
    } catch (e) {
      await _rollbackMoves(done);
      await _deleteIfPresent(newRoot);
      throw DataRootMigrationException('搬动数据目录失败，已回滚到旧根', cause: e);
    }

    // ③ 在新 support 根的 hibiki.db 上把绝对路径从旧根 rebase 到新根。
    try {
      await _rebaseDatabasePaths(
        dbDirectory: newSupport.path,
        oldDocumentsRoot: req.oldDocumentsRoot.path,
        newDocumentsRoot: newDocs.path,
        oldSupportRoot: req.oldSupportRoot.path,
        newSupportRoot: newSupport.path,
      );
    } catch (e) {
      // DB 改写失败：把已搬目录搬回旧根、清新根，绝不留半迁移状态。
      await _rollbackMoves(done);
      await _deleteIfPresent(newRoot);
      throw DataRootMigrationException('改写数据库内绝对路径失败，已回滚到旧根', cause: e);
    }

    // ④ 全成功：删旧根（已确认数据都在新根且 DB 指向新根）+ 写 data_root pref。
    //    oldSupportRoot 若保留了 prefs 文件（默认根迁移），只删非 prefs 残留、保住 prefs
    //    本体（那正是持久化 data_root 的地方），不因目录删不掉而报错。
    await _deleteIfPresent(req.oldDocumentsRoot);
    await _deleteOldSupportPreservingPrefs(req.oldSupportRoot, supportExclude);
    await req.writeDataRootPref(req.newDataRoot);

    return (newDocs, newSupport);
  }

  void _validateTarget(
    DataRootMigrationRequest req,
    Directory newDocs,
    Directory newSupport,
  ) {
    final String canonNew = p.canonicalize(req.newDataRoot);
    if (canonNew == p.canonicalize(req.oldDocumentsRoot.path) ||
        canonNew == p.canonicalize(req.oldSupportRoot.path) ||
        p.isWithin(p.canonicalize(req.oldDocumentsRoot.path), canonNew) ||
        p.isWithin(p.canonicalize(req.oldSupportRoot.path), canonNew)) {
      throw const DataRootMigrationException('新数据根不能位于旧数据目录内部');
    }
    // 目标 dataRoot 若已存在且其 documents/support 子树非空 → 拒绝（不覆盖已有数据）。
    if ((newDocs.existsSync() && _hasAnyFile(newDocs)) ||
        (newSupport.existsSync() && _hasAnyFile(newSupport))) {
      throw const DataRootMigrationException('目标数据根已存在数据，拒绝覆盖');
    }
  }

  /// 同卷直接 `rename`（原子、瞬时）；跨卷（rename 抛 errno 18 / EXDEV / Windows 17）
  /// 退回逐文件 copy + 字节数校验，校验通过才删源。源不存在 → 视为空内容，建空目标根。
  ///
  /// [excludeTopLevelNames] 非空时（默认根迁移的 support 搬移，需把 `shared_preferences*`
  /// 留在原固定落点）**不能**用整目录 rename（会把 prefs 一起搬走），退回逐顶层项搬移，
  /// 跳过被排除的 prefs 文件。为空（documents 搬移 / 自定义根 support 搬移）时保留原子
  /// rename 快路径，行为逐字节不变。
  Future<void> _moveTree(
    Directory src,
    Directory dst,
    _CopyProgress progress,
    Set<String> excludeTopLevelNames,
  ) async {
    if (!await src.exists()) {
      // 旧根某子树不存在（如全新装从未产出有声书目录）：建空目标，无内容可搬。
      await dst.create(recursive: true);
      return;
    }
    if (excludeTopLevelNames.isNotEmpty) {
      // 含排除项：逐顶层项选择性搬移，prefs 文件留在原地。
      await _moveTreeSelective(src, dst, progress, excludeTopLevelNames);
      return;
    }
    await dst.parent.create(recursive: true);
    try {
      await src.rename(dst.path);
      return;
    } on FileSystemException catch (e) {
      if (!_isCrossDevice(e)) rethrow;
    }
    // 跨卷：copy + verify + delete。
    await _copyTreeVerified(src, dst, progress);
    await src.delete(recursive: true);
  }

  /// 选择性搬移：逐个搬 [src] 顶层项到 [dst]，跳过基名命中 [excludeTopLevelNames] 的
  /// prefs 文件（它们留在 src 原地）。每个顶层项优先同卷 `rename`；跨卷退回 copy+verify+
  /// delete（子目录整树、文件逐个），保持与整目录搬移一致的字节校验与跨盘语义。被排除的
  /// prefs 文件既不复制也不删除；搬完 [src] 里应只剩 prefs 文件。
  Future<void> _moveTreeSelective(
    Directory src,
    Directory dst,
    _CopyProgress progress,
    Set<String> excludeTopLevelNames,
  ) async {
    await dst.create(recursive: true);
    for (final FileSystemEntity entity
        in src.listSync(recursive: false, followLinks: false)) {
      final String name = p.basename(entity.path);
      if (excludeTopLevelNames.contains(name)) continue; // prefs 留原地。
      final String target = p.join(dst.path, name);
      try {
        await entity.rename(target);
        continue;
      } on FileSystemException catch (e) {
        if (!_isCrossDevice(e)) rethrow;
      }
      // 跨卷：整树复制校验后删源（目录）/ 单文件复制校验后删源。
      if (entity is Directory) {
        await _copyTreeVerified(entity, Directory(target), progress);
        await entity.delete(recursive: true);
      } else if (entity is File) {
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
        final int srcLen = await entity.length();
        final int dstLen = await File(target).length();
        if (srcLen != dstLen) {
          throw DataRootMigrationException(
              '跨盘复制校验失败：$name 字节数不一致（$srcLen != $dstLen）');
        }
        progress.fileCopied();
        await entity.delete();
      }
    }
  }

  static bool _isCrossDevice(FileSystemException e) {
    final int? code = e.osError?.errorCode;
    // POSIX EXDEV=18；Windows ERROR_NOT_SAME_DEVICE=17。
    return code == 18 || code == 17;
  }

  /// 仅供单测：直接驱动跨盘复制 + 进度回报，不依赖伪造 EXDEV/EXDEV-17 错误。复制 [src]
  /// 整树到 [dst] 并按真实文件数回报 (copied, total)，与生产跨盘路径走同一份逻辑。
  @visibleForTesting
  Future<void> copyTreeWithProgressForTesting(
    Directory src,
    Directory dst,
    void Function(int copied, int total) onProgress,
  ) async {
    await _copyTreeVerified(src, dst, _CopyProgress(onProgress));
  }

  Future<void> _copyTreeVerified(
    Directory src,
    Directory dst, [
    _CopyProgress? progress,
  ]) async {
    await dst.create(recursive: true);
    // 进度模式：先一次性数清本子树的文件总数并并入全局分母，再逐文件复制时累加分子。
    // null（回滚路径）时不报告进度——回滚是异常清理，没有 UI 等它。
    progress?.addToTotal(_countFiles(src));
    await for (final FileSystemEntity entity
        in src.list(recursive: true, followLinks: false)) {
      final String rel = p.relative(entity.path, from: src.path);
      final String target = p.join(dst.path, rel);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
        final int srcLen = await entity.length();
        final int dstLen = await File(target).length();
        if (srcLen != dstLen) {
          throw DataRootMigrationException(
              '跨盘复制校验失败：$rel 字节数不一致（$srcLen != $dstLen）');
        }
        progress?.fileCopied();
      }
    }
  }

  /// 同步数清目录树下的文件数（不含目录项）。用于跨盘复制前确定进度分母。
  static int _countFiles(Directory dir) {
    int count = 0;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File) count++;
    }
    return count;
  }

  Future<void> _rollbackMoves(List<_MovePlan> done) async {
    // 把已搬到新根的子树搬回旧根原位（尽力而为）。选择性搬移的 plan（support + prefs
    // 例外）：src 里还留着 prefs 文件，不能整目录 rename 覆盖 → 逐顶层项合并搬回。
    for (final _MovePlan m in done.reversed) {
      if (m.isSelective) {
        await _rollbackSelective(m);
        continue;
      }
      try {
        if (await m.dst.exists()) {
          if (await m.src.exists()) await m.src.delete(recursive: true);
          await m.dst.rename(m.src.path);
        }
      } on FileSystemException catch (e) {
        if (_isCrossDevice(e)) {
          try {
            await _copyTreeVerified(m.dst, m.src);
            await m.dst.delete(recursive: true);
          } catch (e2) {
            debugPrint('DataRootMigrator: 跨盘回滚失败 ${m.dst.path}: $e2');
          }
        } else {
          debugPrint('DataRootMigrator: 回滚失败 ${m.dst.path}: $e');
        }
      }
    }
  }

  /// 选择性搬移的回滚：把 [m.dst]（新根 support，含已搬的非 prefs 数据）顶层项逐个搬回
  /// [m.src]（旧固定落点，prefs 仍在原地），同卷 rename / 跨卷 copy+delete；搬完删空的
  /// dst 目录。尽力而为——回滚是异常清理，任何一步失败只记日志不再抛。
  Future<void> _rollbackSelective(_MovePlan m) async {
    try {
      if (!await m.dst.exists()) return;
      await m.src.create(recursive: true);
      for (final FileSystemEntity entity
          in m.dst.listSync(recursive: false, followLinks: false)) {
        final String name = p.basename(entity.path);
        final String back = p.join(m.src.path, name);
        try {
          await entity.rename(back);
        } on FileSystemException catch (e) {
          if (!_isCrossDevice(e)) rethrow;
          if (entity is Directory) {
            await _copyTreeVerified(entity, Directory(back));
            await entity.delete(recursive: true);
          } else if (entity is File) {
            await entity.copy(back);
            await entity.delete();
          }
        }
      }
      await _deleteIfPresent(m.dst);
    } catch (e) {
      debugPrint('DataRootMigrator: 选择性回滚失败 ${m.dst.path}: $e');
    }
  }

  static Future<void> _deleteIfPresent(Directory dir) async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 源根 [root] **顶层**里需要留在原地的 prefs 文件基名集合（基名前缀命中
  /// [_prefsFileNamePrefixes]）。默认根迁移时命中 `shared_preferences.json`（及可能的
  /// sidecar）；自定义根 support（`<root>/support`，顶层无 prefs）→ 返回空集，搬移逻辑
  /// 自然走原子 rename 快路径。root 不存在 → 空集。只看顶层文件，不递归、不含目录。
  static Set<String> _prefsFileNamesToPreserveAt(Directory root) {
    if (!root.existsSync()) return const <String>{};
    final Set<String> names = <String>{};
    for (final FileSystemEntity e in root.listSync(recursive: false)) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      if (_isPrefsFileName(name)) names.add(name);
    }
    return names;
  }

  /// 文件基名是否属于 SharedPreferences 落盘族（按 [_prefsFileNamePrefixes] 前缀判定，
  /// 覆盖 `.json` / `.json.lock` / journal / `.bak` 等 sidecar）。
  static bool _isPrefsFileName(String basename) {
    for (final String prefix in _prefsFileNamePrefixes) {
      if (basename.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 迁移成功后删旧 support 根，但**保住**留在原地的 prefs 文件（[preservedNames]）。
  /// 选择性搬移后 [oldSupportRoot] 顶层应只剩这些 prefs 文件——删除其余任何残留（防御性：
  /// 正常情况无残留），保留 prefs 本体（那是持久化 data_root 的地方），且不因目录非空删不掉
  /// 而报错。[preservedNames] 为空（自定义根迁移，无 prefs 需保）→ 退回整目录删除。
  static Future<void> _deleteOldSupportPreservingPrefs(
    Directory oldSupportRoot,
    Set<String> preservedNames,
  ) async {
    if (preservedNames.isEmpty) {
      await _deleteIfPresent(oldSupportRoot);
      return;
    }
    if (!await oldSupportRoot.exists()) return;
    for (final FileSystemEntity e
        in oldSupportRoot.listSync(recursive: false)) {
      final String name = p.basename(e.path);
      if (preservedNames.contains(name)) continue; // 保住 prefs 本体。
      try {
        if (e is Directory) {
          await e.delete(recursive: true);
        } else {
          await e.delete();
        }
      } on FileSystemException catch (err) {
        // 尽力清理残留；删不掉不致命（数据已在新根，prefs 已保）。
        debugPrint('DataRootMigrator: 清理旧 support 残留失败 ${e.path}: $err');
      }
    }
    // 不删 oldSupportRoot 目录本身：它现在承载着 prefs 文件，是固定平台落点。
  }

  static bool _hasAnyFile(Directory dir) {
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File) return true;
    }
    return false;
  }

  /// 在 [dbDirectory] 的 `hibiki.db` 上把所有绝对路径列从旧根 rebase 到新根。复用
  /// `backup_service.dart` 的纯函数（[rebasePath] / [rebaseLocalAudioDbsJson] /
  /// 字体 JSON rebaser）+ Drift CRUD，逐行改写 epub / audiobook / srt / video_books，
  /// 以及 prefs 里的字体目录与本地音频库 JSON。改完 checkpoint(TRUNCATE) 落盘。
  ///
  /// `MediaSources.rootPath` **不**改写：它是用户自选的外部素材文件夹（用户把 Hibiki
  /// 指向去扫描），不在应用数据根内、不随数据根迁移，动它会让外部库失联。
  Future<void> _rebaseDatabasePaths({
    required String dbDirectory,
    required String oldDocumentsRoot,
    required String newDocumentsRoot,
    required String oldSupportRoot,
    required String newSupportRoot,
  }) async {
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      // ── epub_books：epubPath / extractDir / coverPath（coverPath 双语义：导入存的
      //    相对 href 不该被当绝对路径 rebase；rebasePath 只在 startsWith(oldRoot/) 时
      //    改写，相对 href 不以旧根开头故天然跳过）。
      for (final EpubBookRow b in await db.getAllEpubBooks()) {
        await db.updateEpubBookContentPaths(
          b.bookKey,
          epubPath: rebasePath(b.epubPath, oldDocumentsRoot, newDocumentsRoot),
          extractDir:
              rebasePath(b.extractDir, oldDocumentsRoot, newDocumentsRoot),
          coverPath: b.coverPath == null
              ? null
              : rebasePath(b.coverPath!, oldDocumentsRoot, newDocumentsRoot),
        );
      }

      // ── audiobooks：audioRoot / audioPathsJson(列表) / alignmentPath。
      for (final AudiobookRow a in await db.getAllAudiobooks()) {
        await db.updateAudiobookPaths(
          a.bookKey,
          audioRoot: a.audioRoot == null
              ? null
              : rebasePath(a.audioRoot!, oldDocumentsRoot, newDocumentsRoot),
          audioPathsJson: _rebaseJsonStringList(
              a.audioPathsJson, oldDocumentsRoot, newDocumentsRoot),
          alignmentPath:
              rebasePath(a.alignmentPath, oldDocumentsRoot, newDocumentsRoot),
        );
      }

      // ── srt_books（独立 SRT/有声书，无 epub 背书）：audioRoot / audioPathsJson /
      //    srtPath / coverPath 都在 documents 根下，随数据根迁移。
      for (final SrtBookRow s in await db.getAllSrtBooks()) {
        await db.upsertSrtBook(
          SrtBooksCompanion(
            uid: Value(s.uid),
            title: Value(s.title),
            author: Value(s.author),
            audioRoot: Value(s.audioRoot == null
                ? null
                : rebasePath(s.audioRoot!, oldDocumentsRoot, newDocumentsRoot)),
            audioPathsJson: Value(_rebaseJsonStringList(
                s.audioPathsJson, oldDocumentsRoot, newDocumentsRoot)),
            srtPath: Value(
                rebasePath(s.srtPath, oldDocumentsRoot, newDocumentsRoot)),
            coverPath: Value(s.coverPath == null
                ? null
                : rebasePath(s.coverPath!, oldDocumentsRoot, newDocumentsRoot)),
            importedAt: Value(s.importedAt),
            bookKey: Value(s.bookKey),
          ),
        );
      }

      // ── video_books：video_path / playlist_json（仅当原本指向 documents 根下的内部
      //    副本时才改写；用户原位外部视频不以旧根开头 → rebasePath 天然跳过）。
      for (final VideoBookRow v in await db.allVideoBooks()) {
        final String newVideoPath =
            rebasePath(v.videoPath, oldDocumentsRoot, newDocumentsRoot);
        final String? newPlaylist = _rebasePlaylistJson(
            v.playlistJson, oldDocumentsRoot, newDocumentsRoot);
        if (newVideoPath == v.videoPath && newPlaylist == v.playlistJson) {
          continue;
        }
        await db.customStatement(
          'UPDATE video_books SET video_path = ?, playlist_json = ? '
          'WHERE book_uid = ?',
          <Object?>[newVideoPath, newPlaylist, v.bookUid],
        );
      }

      // ── prefs：字体目录配置（catalog + 旧 shadow 列表）走 documents 根；本地音频库
      //    JSON（local_audio_*.db 内部副本）走 support 根。
      final Map<String, String> prefs = await db.getAllPrefs();
      final String? catalog = prefs[_fontCatalogPrefKey];
      if (catalog != null) {
        final String rebased =
            rebaseFontCatalogJson(catalog, oldDocumentsRoot, newDocumentsRoot);
        if (rebased != catalog) await db.setPref(_fontCatalogPrefKey, rebased);
      }
      for (final String key in _legacyFontPrefKeys) {
        final String? raw = prefs[key];
        if (raw == null) continue;
        final String rebased =
            rebaseFontListJson(raw, oldDocumentsRoot, newDocumentsRoot);
        if (rebased != raw) await db.setPref(key, rebased);
      }
      final String? localAudio = prefs[_localAudioDbsPrefKey];
      if (localAudio != null) {
        final String rebased =
            rebaseLocalAudioDbsJson(localAudio, oldSupportRoot, newSupportRoot);
        if (rebased != localAudio) {
          await db.setPref(_localAudioDbsPrefKey, rebased);
        }
      }

      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// rebase 一个「JSON 字符串数组」里每个绝对路径（如 audioPathsJson）。非 JSON 列表
  /// 原样返回（一个坏行不该中断整次迁移）。
  static String? _rebaseJsonStringList(
    String? json,
    String oldRoot,
    String newRoot,
  ) {
    if (json == null) return null;
    try {
      final dynamic decoded = jsonDecode(json);
      if (decoded is! List) return json;
      return jsonEncode(decoded
          .whereType<String>()
          .map((String s) => rebasePath(s, oldRoot, newRoot))
          .toList());
    } catch (_) {
      return json;
    }
  }

  /// rebase 视频 playlist JSON 里每个 `path`。结构同 backup_service 的同名逻辑。
  static String? _rebasePlaylistJson(
    String? playlistJson,
    String oldRoot,
    String newRoot,
  ) {
    if (playlistJson == null || playlistJson.isEmpty) return playlistJson;
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return playlistJson;
      bool changed = false;
      final List<dynamic> out = decoded.map<dynamic>((dynamic entry) {
        if (entry is! Map) return entry;
        final Map<String, dynamic> row = Map<String, dynamic>.from(entry);
        final Object? path = row['path'];
        if (path is! String) return row;
        final String rebased = rebasePath(path, oldRoot, newRoot);
        if (rebased != path) {
          row['path'] = rebased;
          changed = true;
        }
        return row;
      }).toList();
      return changed ? jsonEncode(out) : playlistJson;
    } catch (_) {
      return playlistJson;
    }
  }
}

class _MovePlan {
  _MovePlan(this.src, this.dst, {required this.excludeTopLevelNames});
  final Directory src;
  final Directory dst;

  /// 搬移时需留在源根顶层的文件基名（prefs 文件）。非空 ⇒ 走选择性搬移（非整目录
  /// rename），回滚也走合并式（dst 顶层项逐个搬回 src，不能整目录 rename 覆盖 src——src
  /// 里还留着 prefs）。
  final Set<String> excludeTopLevelNames;

  bool get isSelective => excludeTopLevelNames.isNotEmpty;
}

/// 跨盘复制进度累加器：把多个子树的文件总数累进 [_total]，每复制完一个文件 [_copied]++
/// 并向注入的回调回报 (copied, total)。同盘 rename 路径永不触碰它（回调不会被调用）。
class _CopyProgress {
  _CopyProgress(this._onProgress);
  final void Function(int copied, int total)? _onProgress;
  int _copied = 0;
  int _total = 0;

  void addToTotal(int count) {
    _total += count;
    // 数清新子树总数后立即回报一次（分子不变、分母变大），让 UI 早早呈现进度条。
    _onProgress?.call(_copied, _total);
  }

  void fileCopied() {
    _copied++;
    _onProgress?.call(_copied, _total);
  }
}
