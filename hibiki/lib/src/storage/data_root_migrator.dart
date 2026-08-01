import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show QueryRow, Variable;

import 'package:hibiki/src/media/media_source.dart' show dbSourcePrefKey;
import 'package:hibiki/src/media/video/video_subtitle_source.dart'
    show SubtitleSource;
import 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioManager;
import 'package:hibiki/src/profile/profile_keys.dart' show ProfileKeys;
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/storage/path_rebase_coverage.dart';
import 'package:hibiki/src/sync/backup_service.dart'
    show
        joinPrefTag,
        normalizeAudioSourceConfigsJson,
        normalizeLocalAudioDbsJson,
        rebaseFontCatalogJson,
        rebaseFontListJson,
        rebasePath,
        splitPrefTag;

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
/// BUG-1188：一次迁移的**目标形态**——解析后的两个根 + 提交时如何记录位置。
///
/// 历史上目标只有一种表达：一个 `newDataRoot` 字符串，引擎按 `<root>/documents` +
/// `<root>/support` 硬派生。于是「把数据收回默认位置」这件事**无法表达**——用户按
/// BUG-1115 的文档指引选 `<Documents>\Hibiki`，得到的是 `<Documents>\Hibiki\documents`
/// + `<Documents>\Hibiki\support`（DB 被一起搬进文档目录），与**全新安装**的
/// `<Documents>\Hibiki\data` + 平台固定 support 根形成两种并存布局。
///
/// 把目标提升成数据结构之后，两种情形是**同一条代码路径的两个取值**，不是两条分支：
///  - [DataRootMigrationTarget.customRoot]：用户挑了一个普通目录 →
///    `<root>/documents` + `<root>/support`，提交写 `data_root`，行为逐字节不变。
///  - [DataRootMigrationTarget.defaultLocation]：用户挑的就是默认位置 → documents 根 =
///    `<Documents>/Hibiki/data`、support 根 = 平台固定落点（**DB 不进文档目录**），提交
///    清掉 `data_root` 并把 `documents_layout` 锚成 [AppPaths.documentsLayoutNested]。
class DataRootMigrationTarget {
  const DataRootMigrationTarget._({
    required this.pickedPath,
    required this.documentsRoot,
    required this.supportRoot,
    required this.dataRootPrefValue,
  });

  /// 普通自定义数据根：两个根都落在 [dataRootPath] 下（TODO-935 的原语义）。
  factory DataRootMigrationTarget.customRoot(String dataRootPath) {
    final (Directory documents, Directory support) =
        AppPaths.rootsForDataRoot(dataRootPath);
    return DataRootMigrationTarget._(
      pickedPath: dataRootPath,
      documentsRoot: documents,
      supportRoot: support,
      dataRootPrefValue: dataRootPath,
    );
  }

  /// 默认位置：与**全新安装**逐字节同形。[platformSupportRoot] 必须是
  /// `getApplicationSupportDirectory()` 的真实返回值（不是当前可能被自定义根覆盖过的
  /// support 根）——它就是新装时 DB 的落点。
  factory DataRootMigrationTarget.defaultLocation({
    required String pickedPath,
    required String defaultDocumentsRoot,
    required String platformSupportRoot,
  }) =>
      DataRootMigrationTarget._(
        pickedPath: pickedPath,
        documentsRoot: Directory(defaultDocumentsRoot),
        supportRoot: Directory(platformSupportRoot),
        dataRootPrefValue: null,
      );

  /// 用户在目录选择器里真正挑中的路径。校验（自我迁移 / 安装目录）按它判定，与用户看到的
  /// 那个目录一致。
  final String pickedPath;

  /// 目标「内容/书库」根。
  final Directory documentsRoot;

  /// 目标「数据库/支持」根。等于旧 support 根时表示**本次不搬 DB**（归一化到默认位置且
  /// DB 本来就在平台固定落点）。
  final Directory supportRoot;

  /// 提交时要写进 [AppPaths.dataRootPrefKey] 的值；null = 默认位置（清掉该 pref）。
  final String? dataRootPrefValue;

  /// 本次目标是否是「默认位置」（= 与全新安装同形）。
  bool get isDefaultLocation => dataRootPrefValue == null;

  @override
  String toString() => 'DataRootMigrationTarget(picked: $pickedPath, '
      'documents: ${documentsRoot.path}, support: ${supportRoot.path}, '
      'dataRootPref: $dataRootPrefValue)';
}

/// BUG-1188：把用户挑的目录 [pickedRoot] 解析成 [DataRootMigrationTarget]。
///
/// 挑中**默认位置**时归一化成 [DataRootMigrationTarget.defaultLocation]。接受两种等价
/// 写法：默认 documents 根本身（`<Documents>/Hibiki/data`），或它的 `Hibiki` 伞目录
/// （`<Documents>/Hibiki` —— BUG-1115 的文档指引一直让老用户选的就是这个）。
///
/// 归一化消除的是「同一个物理位置有两种持久化表达」这个歧义：`data_root=<Documents>/
/// Hibiki`（派生 documents/support 两个子目录、把 DB 拖进文档目录）和全新安装的默认形态
/// 指的是同一个地方，却解析成不同布局。留着两种表达，用户按文档整理完就永远回不到新装形态。
///
/// [defaultDocumentsRoot] 传 [AppPaths.defaultLocationDocumentsRoot] 的结果，
/// [platformSupportRoot] 传 `getApplicationSupportDirectory()` 的结果。
DataRootMigrationTarget resolveDataRootMigrationTarget({
  required String pickedRoot,
  required String defaultDocumentsRoot,
  required String platformSupportRoot,
}) {
  final String canonPicked = p.canonicalize(pickedRoot);
  final String canonDefaultDocs = p.canonicalize(defaultDocumentsRoot);
  // 伞目录 = 默认 documents 根的父目录。`defaultDocumentsChildSegments` 恒有 ≥2 段
  // （`Hibiki/data`），故伞目录绝不会等于共享的平台 `Documents` 本身——否则「挑 Documents
  // 根」会被误判成默认位置。该不变量由 `data_root_default_location_test.dart` 守卫。
  final String canonUmbrella = p.canonicalize(p.dirname(defaultDocumentsRoot));
  if (canonPicked == canonDefaultDocs || canonPicked == canonUmbrella) {
    return DataRootMigrationTarget.defaultLocation(
      pickedPath: pickedRoot,
      defaultDocumentsRoot: defaultDocumentsRoot,
      platformSupportRoot: platformSupportRoot,
    );
  }
  return DataRootMigrationTarget.customRoot(pickedRoot);
}

class DataRootMigrationRequest {
  const DataRootMigrationRequest({
    required this.oldDocumentsRoot,
    required this.oldSupportRoot,
    required this.target,
    required this.closeResources,
    required this.commitLocation,
    required this.documentsTopLevelIncludeNames,
    this.onProgress,
    this.resolvedExecutablePath,
  });

  /// 旧「内容/书库」根（含 EPUB / 有声书 / 视频封面/字幕/shader / 词典资源 / 缩略图）。
  final Directory oldDocumentsRoot;

  /// 旧「数据库/支持」根（`hibiki.db` + 各 `local_audio_*.db`）。
  final Directory oldSupportRoot;

  /// BUG-1188：本次迁移的目标形态（两个根 + 位置如何记录）。见 [DataRootMigrationTarget]。
  final DataRootMigrationTarget target;

  /// 迁移前**必须**完成的运行时关闭：checkpoint+关 Drift DB、关词典 FFI 句柄、停音频。
  /// 引擎在搬任何文件前 `await` 它；调用方负责真正关闭全局单例（保持引擎可纯测）。
  final Future<void> Function() closeResources;

  /// 迁移全部成功后**提交新位置**：自定义根写 [AppPaths.dataRootPrefKey]；默认位置清掉
  /// 它并把 [AppPaths.documentsLayoutPrefKey] 锚成
  /// [AppPaths.documentsLayoutNested]。作为回调注入而非引擎内直连 SharedPreferences，使
  /// 引擎在纯 Dart 单测里可断言提交内容。抛错 ⇒ 引擎整次回滚（文件搬回旧根 + DB 路径改回）。
  final Future<void> Function(DataRootMigrationTarget target) commitLocation;

  /// 跨盘 copy 阶段的进度回调（可选）。仅在退回逐文件复制（不同卷）时触发：每复制完一个
  /// 文件回报一次 (已复制文件数, 总文件数)。同盘 `rename` 是瞬时原子操作，不产生进度。
  /// 注入给 UI 显示百分比进度条，避免搬大库被误判死机（TODO-959）。null 表示不需要进度。
  final void Function(int copied, int total)? onProgress;

  /// TODO-1182：当前正在运行的可执行文件绝对路径（生产传 `Platform.resolvedExecutable`）。
  /// 引擎据此拒绝把**含正在运行程序的目录 / 其祖先目录**（= 应用安装目录）当数据根——否则
  /// 迁移搬大库遇文件锁失败时，回滚会试图删掉含运行 exe 的整个安装目录（删不掉、留半状态）。
  /// null（旧测试夹具/移动端）→ 跳过该校验，行为与 1182 前一致。
  final String? resolvedExecutablePath;

  /// TODO-1226：documents 根搬移的**顶层项白名单**。
  ///
  /// - `null` ⇒ [oldDocumentsRoot] 是 Hibiki 专属目录（自定义数据根的
  ///   `<root>/documents`）：整树搬移、迁移成功后整目录删除（原行为不变）。
  /// - 非 null ⇒ [oldDocumentsRoot] 是**共享用户目录**（默认根 = 平台 `Documents`）：
  ///   只搬基名命中白名单的顶层项（生产传 `AppPaths.hibikiOwnedDocumentsEntries`），
  ///   用户自己的文件 / shell junction（My Music 等 ACL 全拒目录）一概不碰；迁移成功
  ///   后**绝不删除** [oldDocumentsRoot] 本体（白名单项已随搬移离开源根）。
  ///
  /// 必填、无默认值：强制每个调用方显式声明源根是否共享目录，杜绝「忘传 → 整树搬走并
  /// 删掉整个用户 Documents」的数据事故。
  final Set<String>? documentsTopLevelIncludeNames;
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

  /// 仅供单测：强制走「跨盘 copy + 延迟删源」分支（跳过同盘 rename 快路径），
  /// 让 TODO-1324 的中断安全（提交前绝不删源）在单卷临时目录里可确定性验证。
  /// 生产恒 false。测试须在 try/finally 里复位，避免污染其它用例。
  @visibleForTesting
  static bool debugForceCopyFallback = false;

  /// 仅供单测（BUG-1174 ④）：在 DB 路径改写事务里、改完 video_books 之后抛错，用来
  /// 确定性验证「整段改写在单事务里，中途失败整体回滚、不留半改状态」。生产恒 false。
  @visibleForTesting
  static bool debugFailMidRebase = false;

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

  /// BUG-1174：所有承载路径的 pref key（含它们的值形态与改写理由）已收敛到
  /// `path_rebase_coverage.dart` 的 [kPathRebasePrefs]，这里不再重复声明。字体 key 的
  /// 字面值与单一真相编码器 [dbSourcePrefKey] 的一致性由
  /// `path_rebase_coverage_guard_test.dart` 锁定（与 `backup_service.dart` 同款做法）。

  /// 执行迁移。成功返回新 dataRoot 派生的 (documents, support) 根。
  ///
  /// 步骤：① await 关闭运行时句柄；② 校验新 dataRoot 可建且为空（不覆盖已有数据）；
  /// ③ 把旧 documents/support 整目录搬进新根的 documents/support；④ 在已搬过去的
  /// `hibiki.db` 上把所有绝对路径列从旧根 rebase 到新根（含 prefs 里的字体 / 本地音频
  /// 库 JSON）；⑤ 写 data_root pref；⑥ pref 已写成功后尽力删除旧根。pref 写入前任一
  /// 步失败抛 [DataRootMigrationException]，旧根原样保留、新根半成品清理、不写 pref。
  Future<(Directory documents, Directory support)> migrate(
    DataRootMigrationRequest req,
  ) async {
    final Directory newRoot = Directory(req.target.pickedPath);
    final Directory newDocs = req.target.documentsRoot;
    final Directory newSupport = req.target.supportRoot;
    // BUG-1188：归一化到默认位置时 DB 本来就躺在平台固定落点（新装的落点也是它）→ support
    // 根根本不需要搬。这一条必须在建搬移计划**之前**判定：源=目标时既不能建搬移计划
    // （rename 到自己），也绝不能跑迁移末尾的 `_deleteOldSupportPreservingPrefs`
    // （那会把活着的 support 根里除 prefs 外的一切删光，包括刚"搬"过去的 hibiki.db）。
    final bool supportUnchanged =
        p.equals(req.oldSupportRoot.path, newSupport.path);
    // 目标 support 根已有内容（回到默认位置时 = 平台固定落点里的 `shared_preferences.json`）
    // → 逐顶层项**合并**搬入，不能整目录 rename（Windows 上 dst 非空必失败）。
    final bool mergeSupport =
        !supportUnchanged && await _hasAnyEntryAsync(newSupport);

    await _validateTarget(req, newDocs, newSupport, supportUnchanged);

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
    final Set<String> supportExclude = supportUnchanged
        ? const <String>{}
        : _prefsFileNamesToPreserveAt(req.oldSupportRoot);
    final List<_MovePlan> moves = <_MovePlan>[
      // documents：共享默认根（白名单非 null）只搬 Hibiki 自有顶层项；自定义根整树搬。
      _MovePlan(req.oldDocumentsRoot, newDocs,
          includeTopLevelNames: req.documentsTopLevelIncludeNames,
          excludeTopLevelNames: const <String>{}),
      // BUG-1188：support 根未变（默认位置归一化）⇒ 一个搬移计划都不建。
      if (!supportUnchanged)
        _MovePlan(req.oldSupportRoot, newSupport,
            includeTopLevelNames: null,
            excludeTopLevelNames: supportExclude,
            mergeIntoDestination: mergeSupport),
    ];
    // BUG-1188：回滚时可以**整目录清掉**的「本次迁移自建子树」。support 根在两种情况下
    // 绝不能进这个列表：① 未变（它就是活着的平台固定落点，里面还躺着刚 rebase 完的
    // hibiki.db）；② 合并搬入（里面有先于本次迁移就存在的 `shared_preferences.json`）。
    // 整目录删掉等于抹掉用户的全部设置与 data_root 配置本身。
    final List<Directory> createdSubtrees = <Directory>[
      newDocs,
      if (!supportUnchanged && !mergeSupport) newSupport,
    ];
    final List<_MovePlan> done = <_MovePlan>[];
    // TODO-1324（数据完整性铁律）：跨盘复制阶段**刻意保留的源**，只有在 DB rebase + pref
    // 提交都成功后才删除。任何在提交前的中断（崩溃 / 用户强杀卡住的迁移 / 任一步抛错）都能
    // 从**完整未删的旧根**恢复；旧实现在搬移阶段就 `_deleteSourceAfterVerifiedCopy` 删源，
    // 违反本类文档声明的「新根校验通过 + DB rebase 成功，才删旧根」，中断即丢已删源数据。
    final List<FileSystemEntity> deferredSourceDeletions = <FileSystemEntity>[];
    // 跨盘复制的进度状态：累积已复制文件数 + 两子树总文件数（同盘 rename 不计）。
    // 跨盘搬移前一次性数清总数，便于 UI 显示稳定的百分比；同盘搬移此对象不被用到。
    final _CopyProgress progress = _CopyProgress(req.onProgress);
    try {
      newRoot.createSync(recursive: true);
      for (final _MovePlan m in moves) {
        await _moveTree(m, progress, deferredSourceDeletions);
        done.add(m);
      }
    } catch (e) {
      await _rollbackMoves(done);
      // TODO-1182：回滚只清理迁移自己创建的 documents/support 子树，**绝不**删用户选定的
      // 整个 newRoot（它可能是安装目录或含用户其它文件）；newRoot 本体一律保留。
      await _cleanupCreatedSubtrees(createdSubtrees);
      if (_isFileInUseError(e)) {
        throw DataRootMigrationException(
            '有文件被占用，无法迁移数据（请关闭正在使用书库/音频的功能后重试），已回滚到旧根',
            cause: e);
      }
      throw DataRootMigrationException('搬动数据目录失败，已回滚到旧根', cause: e);
    }

    // ③ 在新 support 根的 hibiki.db 上把绝对路径从旧根 rebase 到新根。
    try {
      await _rebaseDatabasePaths(
        dbDirectory: newSupport.path,
        oldDocumentsRoot: req.oldDocumentsRoot.path,
        newDocumentsRoot: newDocs.path,
        newSupportRoot: newSupport.path,
        documentsScopeEntries: req.documentsTopLevelIncludeNames,
      );
    } catch (e) {
      // DB 改写失败：把已搬目录搬回旧根、只清迁移自建子树（不删用户选定的 newRoot 本体）。
      await _rollbackMoves(done);
      await _cleanupCreatedSubtrees(createdSubtrees);
      throw DataRootMigrationException('改写数据库内绝对路径失败，已回滚到旧根', cause: e);
    }

    // ④ 全成功：先提交新位置（自定义根写 data_root / 默认位置清它并锚 nested 布局）；只有
    // 提交成功后才删除旧根。若提交失败，先把新 DB 路径 rebase 回旧根，再把目录搬回旧位置，
    // 避免下次启动仍按旧配置解析、而旧 DB 里已指向新根。提交成功后删旧根时，oldSupportRoot
    // 若保留了 prefs 文件（默认根迁移），只删非 prefs 残留、保住 prefs 本体（那正是持久化
    // data_root / documents_layout 的地方）。
    try {
      await req.commitLocation(req.target);
    } catch (e) {
      try {
        await _rebaseDatabasePaths(
          dbDirectory: newSupport.path,
          oldDocumentsRoot: newDocs.path,
          newDocumentsRoot: req.oldDocumentsRoot.path,
          newSupportRoot: req.oldSupportRoot.path,
          documentsScopeEntries: req.documentsTopLevelIncludeNames,
        );
      } catch (rollbackError) {
        debugPrint(
          'DataRootMigrator: 写入 pref 失败后的 DB 路径回滚失败: '
          '$rollbackError',
        );
      }
      await _rollbackMoves(done);
      await _cleanupCreatedSubtrees(createdSubtrees);
      throw DataRootMigrationException('写入新数据根设置失败，已回滚到旧根', cause: e);
    }

    // pref 已成功写入（提交完成）。此刻才删除跨盘复制阶段刻意保留的源——遵守本类的
    // 「失败回滚铁律」：DB rebase + pref 提交成功前绝不删源。删源属提交后的清理，不再属
    // 关键路径：源被顽固锁住（删不掉）不判失败——校验过的完整数据已在新根、pref 已写、
    // 重启读新根；旧根残留留待后续清理（best-effort + 有界锁重试，与旧的删源语义一致）。
    for (final FileSystemEntity src in deferredSourceDeletions) {
      await _deleteSourceAfterVerifiedCopy(src);
    }

    // 现在删旧根（prefs-preserving）。
    //
    // TODO-1226：documents 根仅在**整树搬移**（Hibiki 专属根）时删除本体。白名单模式
    // 下源根是共享用户 `Documents`——白名单项已随搬移离开源根（同盘 rename 移走 /
    // 跨盘 copy 校验后删源），剩下的全是用户自己的文件，**绝不**删除目录本体或残留。
    if (req.documentsTopLevelIncludeNames == null) {
      await _deleteOldRootAfterSwitch(req.oldDocumentsRoot);
    }
    // BUG-1188：support 根未变时**绝不**跑这一步——它会把源根里除 prefs 外的一切删光，
    // 而此时源根就是目标根（刚 rebase 好的 hibiki.db 正躺在里面）。
    if (!supportUnchanged) {
      await _deleteOldSupportPreservingPrefs(
          req.oldSupportRoot, supportExclude);
    }

    return (newDocs, newSupport);
  }

  Future<void> _validateTarget(
    DataRootMigrationRequest req,
    Directory newDocs,
    Directory newSupport,
    bool supportUnchanged,
  ) async {
    final String canonNew = p.canonicalize(req.target.pickedPath);
    // BUG-1115：共享 documents 根（白名单选择性搬移）下的**非白名单**子目录是安全目标
    // ——搬移只动白名单顶层项，新根在整个过程里是旁观者。这让老安装能把散落在用户
    // `Documents` 根下的 16 个 Hibiki 目录一键收进 `Documents\Hibiki`。白名单为 null
    // （Hibiki 专属根、整树搬移语义）时不适用：那时新根真会被连同整棵树搬走。
    final Set<String>? whitelist = req.documentsTopLevelIncludeNames;
    final bool nestedInSharedDocuments = whitelist != null &&
        AppPaths.isSafeNestedTargetInSharedDocuments(
          sharedDocumentsRoot: req.oldDocumentsRoot.path,
          newDataRoot: req.target.pickedPath,
          ownedEntries: whitelist,
        );
    if (canonNew == p.canonicalize(req.oldDocumentsRoot.path) ||
        canonNew == p.canonicalize(req.oldSupportRoot.path) ||
        (p.isWithin(p.canonicalize(req.oldDocumentsRoot.path), canonNew) &&
            !nestedInSharedDocuments) ||
        p.isWithin(p.canonicalize(req.oldSupportRoot.path), canonNew)) {
      throw const DataRootMigrationException('新数据根不能位于旧数据目录内部');
    }
    // TODO-1182：拒绝把含正在运行 exe 的目录（安装目录）或其祖先目录当数据根。否则搬大库
    // 遇文件锁失败回滚时会试图删掉含运行程序的整个安装目录（删不掉、留半状态、pref 没写）。
    final String? exe = req.resolvedExecutablePath;
    if (exe != null && exe.trim().isNotEmpty) {
      final String canonExe = p.canonicalize(exe);
      if (p.isWithin(canonNew, canonExe)) {
        throw const DataRootMigrationException(
            '新数据根不能是应用安装目录（含正在运行的程序），请另选一个空目录');
      }
    }
    // 目标的 documents/support 根若已存在且非空 → 拒绝（不覆盖已有数据）。
    // TODO-1324：用**异步** list 探测，绝不在主 isolate 上同步递归列目录——用户挑的目标可能
    // 含庞大预存子树，同步 listSync(recursive) 会卡死 UI 线程（黑屏/转圈）。
    //
    // BUG-1188 两处收窄：
    //  - support 根未变时**不检查**（它当然非空——里面正是本次要保留在原地的 DB）。
    //  - 检查目标 support 根时**忽略顶层 prefs 文件**：归一化回默认位置时目标就是平台固定
    //    落点，`shared_preferences.json` 一直住在那儿、且刻意不参与搬移，它的存在不代表
    //    「那里已有一份别的数据」。除 prefs 外的任何残留（比如一个陈旧的 hibiki.db）仍照拒。
    if (newDocs.existsSync() && await _hasAnyFileAsync(newDocs)) {
      throw const DataRootMigrationException('目标数据根已存在数据，拒绝覆盖');
    }
    if (!supportUnchanged &&
        newSupport.existsSync() &&
        await _hasAnyFileAsync(
          newSupport,
          ignoreTopLevelNames: _prefsFileNamesToPreserveAt(newSupport),
        )) {
      throw const DataRootMigrationException('目标数据根已存在数据，拒绝覆盖');
    }
  }

  /// 同卷直接 `rename`（原子、瞬时）；跨卷（rename 抛 errno 18 / EXDEV / Windows 17）
  /// 或沙箱/权限层拒绝 rename 但允许逐文件写入时，退回逐文件 copy + 字节数校验，校验
  /// 通过才删源。源不存在 → 视为空内容，建空目标根。
  ///
  /// [_MovePlan.isSelective]（prefs 排除项，或 TODO-1226 共享根白名单）时**不能**用
  /// 整目录 rename（会把不该搬的项一起搬走），退回逐顶层项搬移。非选择性（自定义根的
  /// documents / support 搬移）时保留原子 rename 快路径，行为逐字节不变。
  Future<void> _moveTree(
    _MovePlan plan,
    _CopyProgress progress,
    List<FileSystemEntity> deferredSourceDeletions,
  ) async {
    final Directory src = plan.src;
    final Directory dst = plan.dst;
    if (!await src.exists()) {
      // 旧根某子树不存在（如全新装从未产出有声书目录）：建空目标，无内容可搬。
      await dst.create(recursive: true);
      return;
    }
    if (plan.isSelective) {
      // 选择性搬移：白名单外 / 被排除的顶层项留在原地（TODO-1226 / prefs 例外）。
      await _moveTreeSelective(plan, progress, deferredSourceDeletions);
      return;
    }
    await dst.parent.create(recursive: true);
    if (!debugForceCopyFallback) {
      try {
        // Windows 上刚关闭的 DB/音频/FFI 句柄可能滞后释放，或 Defender/索引器短暂锁住
        // 树里某个文件 → rename 返回锁码 5/32/33；有界退避重试把瞬态锁转成成功。
        // 同盘原子 rename：源随之移走（单条 syscall、near-instant），无需延迟删源。
        await _withLockRetry(() => src.rename(dst.path));
        return;
      } on FileSystemException catch (e) {
        if (!_shouldCopyAfterRenameFailure(e)) rethrow;
      }
    }
    // 跨卷或 rename 被沙箱/权限层拒绝：copy + verify，**不立即删源**。TODO-1324：把源
    // 记入 deferredSourceDeletions，只有 DB rebase + pref 提交成功后才删（中断安全）。
    await _copyTreeVerified(src, dst, progress);
    plan.deferredCopy = true;
    deferredSourceDeletions.add(src);
  }

  /// 选择性搬移：逐个搬 [plan] 源根顶层项到目标根，跳过 [_MovePlan.shouldMoveTopLevel]
  /// 判为不搬的项（prefs 排除项 / TODO-1226 白名单外的用户文件与 junction，留在源根
  /// 原地）。每个顶层项优先同卷 `rename`；跨卷退回 copy+verify+delete（子目录整树、
  /// 文件逐个），保持与整目录搬移一致的字节校验与跨盘语义。不搬的项既不复制也不删除。
  Future<void> _moveTreeSelective(
    _MovePlan plan,
    _CopyProgress progress,
    List<FileSystemEntity> deferredSourceDeletions,
  ) async {
    final Directory src = plan.src;
    final Directory dst = plan.dst;
    await dst.create(recursive: true);
    // 顶层项列举（非递归）：仅一层、成本低，保持同步无碍主 isolate。递归大树的开销在
    // _copyTreeVerified 的 _countFilesAsync（已异步化）里，不在此。
    for (final FileSystemEntity entity
        in src.listSync(recursive: false, followLinks: false)) {
      final String name = p.basename(entity.path);
      if (!plan.shouldMoveTopLevel(name)) continue; // 白名单外 / prefs 留原地。
      final String target = p.join(dst.path, name);
      if (!debugForceCopyFallback) {
        try {
          // 同盘 rename：源随之移走（原子、near-instant），无需延迟删源。
          await _withLockRetry(() => entity.rename(target));
          plan.movedTopLevelNames.add(name);
          continue;
        } on FileSystemException catch (e) {
          if (!_shouldCopyAfterRenameFailure(e)) rethrow;
        }
      }
      // 跨卷或沙箱/权限拒绝 rename：整树复制校验（目录）/ 单文件复制校验，**不立即删源**。
      // TODO-1324：把源记入 deferredSourceDeletions，只有 pref 提交成功后才删（中断安全）。
      if (entity is Directory) {
        await _copyTreeVerified(entity, Directory(target), progress);
        plan.deferredCopy = true;
        deferredSourceDeletions.add(entity);
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
        plan.deferredCopy = true;
        deferredSourceDeletions.add(entity);
      }
    }
  }

  static bool _isCrossDevice(FileSystemException e) {
    final int? code = e.osError?.errorCode;
    // POSIX EXDEV=18；Windows ERROR_NOT_SAME_DEVICE=17。
    return code == 18 || code == 17;
  }

  static bool _shouldCopyAfterRenameFailure(FileSystemException e) {
    if (_isCrossDevice(e)) return true;
    final int? code = e.osError?.errorCode;
    // macOS sandboxed apps can receive EPERM/EACCES for directory rename into
    // a user-selected security-scoped folder while individual file copy/delete
    // still works. Falling back is safe: if copy or source delete fails, the
    // caller rolls the new root back and leaves the old root intact.
    return code == 1 || code == 13;
  }

  @visibleForTesting
  static bool shouldCopyAfterRenameFailureForTesting(int errorCode) =>
      _shouldCopyAfterRenameFailure(FileSystemException(
        'rename failed',
        null,
        OSError('', errorCode),
      ));

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
    // TODO-1324：用**异步** list 数文件——搬大库时同步 listSync(recursive) 会把主 isolate
    // 卡到 OS 层遍历完（黑屏/转圈冻结、进度条不动、被误判死机）；异步遍历让事件循环得以
    // 继续绘制遮罩与进度。
    if (progress != null) {
      progress.addToTotal(await _countFilesAsync(src));
    }
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

  /// 异步数清目录树下的文件数（不含目录项）。用于跨盘复制前确定进度分母。
  /// TODO-1324：**异步** list（非 listSync）——绝不在主 isolate 上同步递归列大目录（冻结 UI）。
  static Future<int> _countFilesAsync(Directory dir) async {
    int count = 0;
    // followLinks: false —— 绝不追 symlink/junction：用户 Documents 里的 shell
    // junction（My Music 等）ACL 全拒，追进去 list 直接 errno 5 硬炸（TODO-1226）。
    await for (final FileSystemEntity e
        in dir.list(recursive: true, followLinks: false)) {
      if (e is File) count++;
    }
    return count;
  }

  Future<void> _rollbackMoves(List<_MovePlan> done) async {
    // 把已搬到新根的子树搬回旧根原位（尽力而为）。选择性搬移的 plan（support + prefs
    // 例外）：src 里还留着 prefs 文件，不能整目录 rename 覆盖 → 逐顶层项合并搬回。
    for (final _MovePlan m in done.reversed) {
      if (m.deferredCopy) {
        // TODO-1324：跨盘复制且源尚未删除（延迟到提交后）——源在旧根**完好无损**，无需搬回。
        // 新根里的副本由随后的 _cleanupCreatedSubtrees 整目录清除。这是本次修复的核心不变量：
        // 提交前绝不删源 → 任何失败/中断都能从完整旧根恢复，回滚只是清掉新根半成品。
        continue;
      }
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
        if (_shouldCopyAfterRenameFailure(e)) {
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

  /// 选择性搬移的回滚：把**本次真正搬进去**的顶层项（[_MovePlan.movedTopLevelNames]）
  /// 逐个从 [m.dst] 搬回 [m.src]，同卷 rename / 跨卷 copy+delete；搬完删掉本次自建的 dst
  /// 目录。尽力而为——回滚是异常清理，任何一步失败只记日志不再抛。
  ///
  /// BUG-1188：判据从「列 dst 的全部顶层项」改成「本次搬进去的那些项」，并在
  /// [_MovePlan.mergeIntoDestination] 时保留 dst 本体。旧实现假设 dst 是迁移自建的空目录，
  /// 合并搬入（归一化回默认位置，dst = 平台固定落点）下会把用户的 `shared_preferences.json`
  /// 一起搬进即将被删的旧根、再把 dst 整个删掉 = 抹掉全部设置。
  Future<void> _rollbackSelective(_MovePlan m) async {
    try {
      if (!await m.dst.exists()) return;
      await m.src.create(recursive: true);
      for (final String name in m.movedTopLevelNames) {
        final String from = p.join(m.dst.path, name);
        final FileSystemEntity entity = await FileSystemEntity.isDirectory(from)
            ? Directory(from)
            : File(from);
        if (!await entity.exists()) continue;
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
      if (!m.mergeIntoDestination) await _deleteIfPresent(m.dst);
    } catch (e) {
      debugPrint('DataRootMigrator: 选择性回滚失败 ${m.dst.path}: $e');
    }
  }

  static Future<void> _deleteIfPresent(Directory dir) async {
    if (await dir.exists()) {
      // 迁移末尾删旧根同样可能撞瞬态锁（AV 扫刚搬完的文件）：有界重试后仍锁则由调用方
      // 的 best-effort catch 记日志放行（数据已在新根，残留可后续清）。
      await _withLockRetry(() => dir.delete(recursive: true));
    }
  }

  /// TODO-1182：回滚时只删迁移**自己创建**的目标子树，**绝不**触碰用户选定的根本体（它可能
  /// 是安装目录或含用户其它文件）。[_validateTarget] 已保证迁移前这些子树为空或不存在，故此处
  /// 清掉的必然是本次迁移搬进去的数据（正常路径下 `_rollbackMoves` 已把它们搬回旧根、这里是
  /// 幂等兜底）。尽力而为：任一子树删不掉只记日志不抛（数据已回滚在旧根，用户根保留完整）。
  ///
  /// BUG-1188：[subtrees] 由 `migrate` 计算——support 根未变 / 合并搬入时它**不在列表里**
  /// （那是活着的平台固定落点，删掉等于抹掉用户全部设置）。
  static Future<void> _cleanupCreatedSubtrees(
    List<Directory> subtrees,
  ) async {
    for (final Directory sub in subtrees) {
      try {
        await _deleteIfPresent(sub);
      } catch (e) {
        debugPrint('DataRootMigrator: 清理迁移自建子树失败 ${sub.path}: $e');
      }
    }
  }

  /// TODO-1182：判断异常是否为「文件被占用」类（仅 Windows 有意义）。搬移/删源时若目标位置
  /// 或源文件被其它句柄（词典/音频/杀软/资源管理器）锁住，Windows 返回
  /// ERROR_ACCESS_DENIED(5) / ERROR_SHARING_VIOLATION(32) / ERROR_LOCK_VIOLATION(33)。
  /// 命中则由 [migrate] 抛出明确的「文件被占用」提示，而非静默回滚成泛化失败。
  static bool _isFileInUseError(Object? e) {
    if (!Platform.isWindows) return false;
    if (e is DataRootMigrationException) return _isFileInUseError(e.cause);
    if (e is FileSystemException) {
      return _isWindowsLockCode(e.osError?.errorCode);
    }
    return false;
  }

  /// Windows「文件被占用」错误码：ERROR_ACCESS_DENIED(5) / ERROR_SHARING_VIOLATION(32)
  /// / ERROR_LOCK_VIOLATION(33)。与平台判定分离，便于跨平台单测分类逻辑。
  static bool _isWindowsLockCode(int? code) =>
      code == 5 || code == 32 || code == 33;

  @visibleForTesting
  static bool isWindowsLockCodeForTesting(int code) => _isWindowsLockCode(code);

  /// 有界退避重试次数与基础退避。迁移整库时至少有一个文件被短暂锁住的概率不低
  /// （我方刚关闭的句柄异步释放滞后、Defender 实时扫描刚复制的大文件、资源管理器/
  /// 索引器持句柄）——这些锁通常数百毫秒内自行释放。与词典导入 BUG-050 的 rename
  /// 抗锁重试同构：只对 Windows 锁码 5/32/33 重试，非锁错误立即上抛。
  static const int _lockRetryAttempts = 6;
  static const Duration _lockRetryBackoff = Duration(milliseconds: 250);

  /// 对可能命中 Windows 文件锁的文件系统操作做有界退避重试。仅当异常是
  /// [FileSystemException] 且错误码是 Windows 锁码（[_isWindowsLockCode]）时重试；
  /// 跨盘 EXDEV(17/18)、POSIX EPERM/EACCES(1/13) 等**非锁**错误立即上抛（不无谓重试，
  /// 保留原有的跨盘 copy 回退 / 校验失败语义）。POSIX 生产永不产出 5/32/33，故此路径
  /// 在非 Windows 上透明无副作用。
  static Future<void> _withLockRetry(
    Future<void> Function() op, {
    int maxAttempts = _lockRetryAttempts,
    Duration backoff = _lockRetryBackoff,
  }) async {
    for (int attempt = 0;; attempt++) {
      try {
        await op();
        return;
      } on FileSystemException catch (e) {
        final bool lock = _isWindowsLockCode(e.osError?.errorCode);
        if (!lock || attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(backoff * (attempt + 1));
      }
    }
  }

  @visibleForTesting
  static Future<void> withLockRetryForTesting(
    Future<void> Function() op, {
    int maxAttempts = 3,
    Duration backoff = Duration.zero,
  }) =>
      _withLockRetry(op, maxAttempts: maxAttempts, backoff: backoff);

  /// 跨盘 copy+verify **已成功**后删源。删源属清理、不属迁移关键路径：源被顽固锁住
  /// （删不掉）时**不判迁移失败**——校验过的完整数据已在新根、pref 随后照写、重启读
  /// 新根；旧根残留留待后续清理（TODO-935 授权的次级降级，避免「整库已复制完却因删源
  /// 被占用而回滚、位置没变」）。先做有界退避重试吃掉瞬态锁；仍是锁码则吞并记日志，非锁
  /// 错误照常上抛（真实的 IO 故障不该被掩盖）。
  static Future<void> _deleteSourceAfterVerifiedCopy(
    FileSystemEntity src,
  ) async {
    try {
      await _withLockRetry(() => src.delete(recursive: true));
    } on FileSystemException catch (e) {
      if (_isWindowsLockCode(e.osError?.errorCode)) {
        debugPrint(
          'DataRootMigrator: 跨盘复制已校验完成但源删除被占用，保留旧根残留继续'
          '（数据已在新根）: ${src.path}: $e',
        );
        return;
      }
      rethrow;
    }
  }

  /// 源根 [root] **顶层**里需要留在原地的 prefs 文件基名集合（基名前缀命中
  /// [_prefsFileNamePrefixes]）。默认根迁移时命中 `shared_preferences.json`（及可能的
  /// sidecar）；自定义根 support（`<root>/support`，顶层无 prefs）→ 返回空集，搬移逻辑
  /// 自然走原子 rename 快路径。root 不存在 → 空集。只看顶层文件，不递归、不含目录。
  static Set<String> _prefsFileNamesToPreserveAt(Directory root) {
    if (!root.existsSync()) return const <String>{};
    final Set<String> names = <String>{};
    for (final FileSystemEntity e
        in root.listSync(recursive: false, followLinks: false)) {
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
        in oldSupportRoot.listSync(recursive: false, followLinks: false)) {
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

  /// 新根切换成功（pref 已写）后删旧根，删不掉只记日志不抛（数据已在新根）。
  static Future<void> _deleteOldRootAfterSwitch(Directory dir) async {
    try {
      await _deleteIfPresent(dir);
    } catch (e) {
      debugPrint('DataRootMigrator: 新根已切换，旧根清理失败 ${dir.path}: $e');
    }
  }

  /// TODO-1324：**异步** list（非 listSync）——绝不在主 isolate 上同步递归列大目录（冻结 UI）。
  ///
  /// BUG-1188：[ignoreTopLevelNames] 里的**顶层**项整棵跳过（用于忽略目标 support 根里
  /// 刻意不参与搬移的 `shared_preferences.json` 族）。只忽略顶层同名项，子目录里的同名文件
  /// 照常算数据。
  static Future<bool> _hasAnyFileAsync(
    Directory dir, {
    Set<String> ignoreTopLevelNames = const <String>{},
  }) async {
    // followLinks: false —— 同 [_countFilesAsync]：不追 junction/symlink（TODO-1226）。
    await for (final FileSystemEntity e
        in dir.list(recursive: false, followLinks: false)) {
      if (ignoreTopLevelNames.contains(p.basename(e.path))) continue;
      if (e is File) return true;
      if (e is Directory && await _hasAnyFileAsync(e)) return true;
    }
    return false;
  }

  /// 目录是否**存在且含任何顶层项**（文件/目录/链接都算）。BUG-1188 用它判定目标 support
  /// 根需不需要走「合并搬入」——目标已有内容时整目录 rename 在 Windows 上必失败。
  static Future<bool> _hasAnyEntryAsync(Directory dir) async {
    if (!await dir.exists()) return false;
    await for (final FileSystemEntity _
        in dir.list(recursive: false, followLinks: false)) {
      return true;
    }
    return false;
  }

  /// 在 [dbDirectory] 的 `hibiki.db` 上把所有数据根内绝对路径从旧根 rebase 到新根。
  ///
  /// 覆盖清单的**单一真相源**是 `path_rebase_coverage.dart`（[kPathRebaseColumns] /
  /// [kPathRebasePrefs]），守卫测试 `path_rebase_coverage_guard_test.dart` 双向比对
  /// 源码与声明——新增一列存路径而忘了这里，CI 会红。
  ///
  /// 三条 BUG-1174 的铁律：
  ///  1. **作用域谓词 = 搬移作用域**（[DocumentsPathRebaser]）。判据不是「以旧根开头」
  ///     而是「相对旧根的首段命中本次真正会被搬走的顶层项集合」。新根落在旧根内部
  ///     （`<Documents>` → `<Documents>/Hibiki/data`）时，已改写过的路径首段是
  ///     `Hibiki`（不在白名单里）→ 天然跳过，函数**本质幂等**，跑几遍结果一样。
  ///  2. **单事务**：整段改写包在 `db.transaction()` 里，中途失败整体回滚，绝不留
  ///     「一半指新根、一半指旧根」的半状态（外层回滚只搬文件，救不了半改的 DB）。
  ///  3. **prefs 与 profile_settings 共用同一个改写函数**（[rebaseMigratedPrefValue]）。
  ///     `profile_settings` 是每 Profile 的 pref 全量副本，只改 `preferences` 的话用户
  ///     切一次 Profile 就把旧根路径整体写回来。
  ///
  /// `MediaSources.rootPath` / `Galgames.exePath` 等**外部**路径不改写（理由逐列写在
  /// [kPathRebaseColumns] 里）。
  Future<void> _rebaseDatabasePaths({
    required String dbDirectory,
    required String oldDocumentsRoot,
    required String newDocumentsRoot,
    required String newSupportRoot,
    required Set<String>? documentsScopeEntries,
  }) async {
    final DocumentsPathRebaser docs = DocumentsPathRebaser(
      oldRoot: oldDocumentsRoot,
      newRoot: newDocumentsRoot,
      scopeTopLevelNames: documentsScopeEntries,
    );
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      await db.transaction(() async {
        await _rebaseEpubBooks(db, docs);
        await _rebaseAudiobooks(db, docs);
        await _rebaseSrtBooks(db, docs);
        await _rebaseVideoBooks(db, docs);
        if (debugFailMidRebase) {
          throw StateError('debugFailMidRebase');
        }
        await _rebaseGalgames(db, docs);
        await _rebaseMediaCollections(db, docs);
        await _rebaseCollectionScrapeMeta(db, docs);
        await _rebaseMediaItems(db, docs);
        await _rebasePreferences(db, docs, newSupportRoot);
        await _rebaseProfileSettings(db, docs, newSupportRoot);
      });
      // checkpoint 必须在事务**外**：SQLite 不允许在活动事务里 wal_checkpoint。
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// epub_books：epubPath / extractDir / coverPath。前者与 coverPath 按声明其实不是
  /// 数据根内路径（裸文件名 / 相对 href），改写是防御性 no-op，保留调用与历史行为一致。
  static Future<void> _rebaseEpubBooks(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final EpubBookRow b in await db.getAllEpubBooks()) {
      await db.updateEpubBookContentPaths(
        b.bookKey,
        epubPath: docs.rebase(b.epubPath),
        extractDir: docs.rebase(b.extractDir),
        coverPath: docs.rebaseNullable(b.coverPath),
      );
    }
  }

  /// audiobooks：audioRoot / audioPathsJson（列表）/ alignmentPath。
  static Future<void> _rebaseAudiobooks(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final AudiobookRow a in await db.getAllAudiobooks()) {
      await db.updateAudiobookPaths(
        a.bookKey,
        audioRoot: docs.rebaseNullable(a.audioRoot),
        audioPathsJson: _rebaseJsonStringList(a.audioPathsJson, docs),
        alignmentPath: docs.rebase(a.alignmentPath),
      );
    }
  }

  /// srt_books（独立 SRT/有声书，无 epub 背书）：四列都在 documents 根下。
  static Future<void> _rebaseSrtBooks(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final SrtBookRow s in await db.getAllSrtBooks()) {
      await db.customStatement(
        'UPDATE srt_books SET '
        'audio_root = ?, audio_paths_json = ?, srt_path = ?, cover_path = ? '
        'WHERE id = ?',
        <Object?>[
          docs.rebaseNullable(s.audioRoot),
          _rebaseJsonStringList(s.audioPathsJson, docs),
          docs.rebase(s.srtPath),
          docs.rebaseNullable(s.coverPath),
          s.id,
        ],
      );
    }
  }

  /// video_books：video_path / playlist_json / cover_path / subtitle_source ×2。
  ///
  /// - cover_path 是应用自有资产（`<documents>/video_covers`），TODO-1255 补的漏项。
  /// - **subtitle_source / secondary_subtitle_source 是 BUG-1174 补的漏项**：四态编码
  ///   里只有「外挂绝对路径」态该改写，`embedded:<n>` / `off:` 两个哨兵显式判掉。
  ///   `video_subtitles/` 在搬移白名单里，不改写 = 所有外挂字幕失联。
  static Future<void> _rebaseVideoBooks(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final VideoBookRow v in await db.allVideoBooks()) {
      final String newVideoPath = docs.rebase(v.videoPath);
      final String? newPlaylist = _rebasePlaylistJson(v.playlistJson, docs);
      final String? newCover = docs.rebaseNullable(v.coverPath);
      final String? newSubtitle = rebaseSubtitleSource(v.subtitleSource, docs);
      final String? newSecondary =
          rebaseSubtitleSource(v.secondarySubtitleSource, docs);
      if (newVideoPath == v.videoPath &&
          newPlaylist == v.playlistJson &&
          newCover == v.coverPath &&
          newSubtitle == v.subtitleSource &&
          newSecondary == v.secondarySubtitleSource) {
        continue;
      }
      await db.customStatement(
        'UPDATE video_books SET video_path = ?, playlist_json = ?, '
        'cover_path = ?, subtitle_source = ?, secondary_subtitle_source = ? '
        'WHERE book_uid = ?',
        <Object?>[
          newVideoPath,
          newPlaylist,
          newCover,
          newSubtitle,
          newSecondary,
          v.bookUid,
        ],
      );
    }
  }

  /// galgames：cover_path（`<documents>/game_covers/<id>.<ext>`）。BUG-1174 漏项，与
  /// TODO-1255 的 video_books.cover_path 完全同型 —— 不改写 = 整个游戏库封面退化成默认
  /// 手柄图标。exe_path / workdir / launch_args 是用户外部安装位置，**绝不**改写。
  static Future<void> _rebaseGalgames(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final GalgameRow g in await db.getAllGalgames()) {
      final String? newCover = docs.rebaseNullable(g.coverPath);
      if (newCover == g.coverPath) continue;
      await db.customStatement(
        'UPDATE galgames SET cover_path = ? WHERE id = ?',
        <Object?>[newCover, g.id],
      );
    }
  }

  /// media_collections：cover_path（`<documents>/video_covers/collections/<id>.jpg`）。
  /// BUG-1211 合集自有封面，与 video_books.cover_path / galgames.cover_path 同型 ——
  /// 不改写 = 换过封面的合集在换数据根后全部退回「借成员封面」，用户看到封面自己变了。
  /// cover_source 是成员引用不是路径，绝不改写。
  static Future<void> _rebaseMediaCollections(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
      final String? newCover = docs.rebaseNullable(c.coverPath);
      if (newCover == c.coverPath) continue;
      await db.customStatement(
        'UPDATE media_collections SET cover_path = ? WHERE id = ?',
        <Object?>[newCover, c.id],
      );
    }
  }

  /// collection_scrape_meta：backdrop_path
  /// （`<documents>/video_covers/collections/<id>_backdrop.jpg`）。BUG-1310 合集横版
  /// 背景，与上面的 media_collections.cover_path 同目录同型 —— 不改写 = 换数据根后
  /// 详情页 hero 背景变死链，静默退回海报模糊垫底，用户看到背景「自己没了」。
  /// source / tags_json / infobox_json / detail_url 不是本机路径，绝不改写。
  static Future<void> _rebaseCollectionScrapeMeta(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
      final CollectionScrapeMetaRow? meta =
          await db.getCollectionScrapeMeta(c.id);
      if (meta == null) continue;
      final String? newBackdrop = docs.rebaseNullable(meta.backdropPath);
      if (newBackdrop == meta.backdropPath) continue;
      await db.customStatement(
        'UPDATE collection_scrape_meta SET backdrop_path = ? '
        'WHERE collection_id = ?',
        <Object?>[newBackdrop, c.id],
      );
    }
  }

  /// media_items：image_url（本地书封面存 `file://<绝对路径>` URI）。BUG-1174 漏项 ——
  /// 不改写 = 书架/首页「最近」卡片封面全空白，直到该书被重新打开刷新。远端源的
  /// http(s) URL scheme 非 file，[DocumentsPathRebaser.rebaseFileUri] 原样返回。
  static Future<void> _rebaseMediaItems(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
  ) async {
    for (final MediaItemRow m in await db.getAllMediaItems()) {
      final String? url = m.imageUrl;
      if (url == null) continue;
      final String rebased = docs.rebaseFileUri(url);
      if (rebased == url) continue;
      await db.customStatement(
        'UPDATE media_items SET image_url = ? WHERE id = ?',
        <Object?>[rebased, m.id],
      );
    }
  }

  /// preferences：按 [kPathRebasePrefs] 声明逐 key 改写（字体目录 / 本地发音库 /
  /// 游戏库 legacy JSON / 远端字幕 map / 下载根与历史）。
  static Future<void> _rebasePreferences(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
    String newSupportRoot,
  ) async {
    final Map<String, String> prefs = await db.getAllPrefs();
    for (final PathRebasePref spec in kPathRebasePrefs) {
      if (!spec.mustRebase) continue;
      final String? raw = prefs[spec.key];
      if (raw == null) continue;
      final String rebased = rebaseMigratedPrefValue(
        spec.key,
        raw,
        documents: docs,
        newSupportRoot: newSupportRoot,
      );
      if (rebased != raw) await db.setPref(spec.key, rebased);
    }
  }

  /// profile_settings：每个 Profile 的 pref 快照副本。**必须覆盖所有 Profile**，用与
  /// [_rebasePreferences] 完全相同的改写函数。
  ///
  /// 为什么选「迁移时一起改」而不是「让路径 pref 不进快照」：后者会改掉 Profile 的既有
  /// 语义（字体目录、发音库配置现在确实是**每 Profile** 的），等于为了修迁移去动一个与
  /// 迁移无关的功能契约——爆炸半径大得多，且会破坏已按 Profile 分别配字体的用户。
  /// 迁移时一起改是纯增量、零语义变更。
  static Future<void> _rebaseProfileSettings(
    HibikiDatabase db,
    DocumentsPathRebaser docs,
    String newSupportRoot,
  ) async {
    final List<QueryRow> rows = await db.customSelect(
      'SELECT id, key, value FROM profile_settings WHERE category = ?',
      variables: <Variable<Object>>[
        Variable<String>(ProfileKeys.categoryPref),
      ],
    ).get();
    for (final QueryRow row in rows) {
      final String key = row.read<String>('key');
      final String value = row.read<String>('value');
      final String rebased = rebaseMigratedPrefValue(
        key,
        value,
        documents: docs,
        newSupportRoot: newSupportRoot,
      );
      if (rebased == value) continue;
      await db.customStatement(
        'UPDATE profile_settings SET value = ? WHERE id = ?',
        <Object?>[rebased, row.read<int>('id')],
      );
    }
  }

  /// 仅供单测（BUG-1174 ③）：直接驱动 DB 路径改写，用来验证**幂等性**（同一改写连跑
  /// 两次，第二次必须是 no-op）。生产走 [migrate]，不经此入口。
  @visibleForTesting
  Future<void> rebaseDatabasePathsForTesting({
    required String dbDirectory,
    required String oldDocumentsRoot,
    required String newDocumentsRoot,
    required String newSupportRoot,
    required Set<String>? documentsScopeEntries,
  }) =>
      _rebaseDatabasePaths(
        dbDirectory: dbDirectory,
        oldDocumentsRoot: oldDocumentsRoot,
        newDocumentsRoot: newDocumentsRoot,
        newSupportRoot: newSupportRoot,
        documentsScopeEntries: documentsScopeEntries,
      );

  /// rebase 一个「JSON 字符串数组」里每个绝对路径（如 audioPathsJson）。非 JSON 列表
  /// 原样返回（一个坏行不该中断整次迁移）。
  static String? _rebaseJsonStringList(
    String? json,
    DocumentsPathRebaser docs,
  ) {
    if (json == null) return null;
    return rebaseJsonStringListWith(json, docs);
  }

  /// rebase 视频 playlist JSON 里每个 `path`。结构同 backup_service 的同名逻辑。
  static String? _rebasePlaylistJson(
    String? playlistJson,
    DocumentsPathRebaser docs,
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
        final String rebased = docs.rebase(path);
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
  _MovePlan(
    this.src,
    this.dst, {
    required this.includeTopLevelNames,
    required this.excludeTopLevelNames,
    this.mergeIntoDestination = false,
  });
  final Directory src;
  final Directory dst;

  /// BUG-1188：目标目录**已有内容**（归一化回默认位置时 = 平台固定落点里的 prefs 文件）。
  /// 为真 ⇒ 强制走逐顶层项搬移（整目录 rename 到非空 dst 在 Windows 上必失败），且回滚
  /// **绝不删除 dst 本体**——它先于本次迁移就存在，里面躺着用户的 prefs。
  final bool mergeIntoDestination;

  /// 本 plan 实际以 rename 搬进 dst 的顶层项基名。回滚只搬回这些项——merge 模式下 dst 里
  /// 还有先于迁移就存在的项（prefs），照 dst 列目录回滚会把它们一并搬进 src（= 把用户设置
  /// 挪进一个即将被删的目录）。跨盘 copy 分支不记：那条路径源未删、回滚整体跳过（见
  /// [deferredCopy]）。
  final List<String> movedTopLevelNames = <String>[];

  /// TODO-1226：只允许搬移的顶层项基名白名单；null = 全部可搬（Hibiki 专属根整树
  /// 语义）。非 null（共享用户 `Documents`）⇒ 白名单外的顶层项（用户文件、shell
  /// junction）绝不触碰，回滚同样走合并式搬回。
  final Set<String>? includeTopLevelNames;

  /// 搬移时需留在源根顶层的文件基名（prefs 文件）。非空 ⇒ 走选择性搬移（非整目录
  /// rename），回滚也走合并式（dst 顶层项逐个搬回 src，不能整目录 rename 覆盖 src——src
  /// 里还留着 prefs）。
  final Set<String> excludeTopLevelNames;

  /// TODO-1324：本 plan 走了「跨盘 copy 且源延迟到提交后才删」的路径。为 true 时源仍在
  /// 旧根完好无损 → 回滚无需搬回（跳过 _rollbackMoves 的搬回逻辑），只清新根半成品。
  bool deferredCopy = false;

  bool get isSelective =>
      includeTopLevelNames != null ||
      excludeTopLevelNames.isNotEmpty ||
      mergeIntoDestination;

  /// 顶层项 [name] 是否应被搬移：命中白名单（或无白名单）且不在排除集。
  bool shouldMoveTopLevel(String name) =>
      (includeTopLevelNames?.contains(name) ?? true) &&
      !excludeTopLevelNames.contains(name);
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

/// BUG-1174 ③：数据根迁移期的 documents 根路径改写器。**本质幂等**。
///
/// 旧写法的判据是 `startsWith(oldRoot)`。当新根落在旧根**内部**时（正是
/// `<Documents>` → `<Documents>/Hibiki/data` 这种形态），一条已经改写过的路径**仍然**
/// 以旧根开头，再跑一次就变成 `Documents/Hibiki/data/Hibiki/data/...` —— 全库路径当场
/// 作废、且不抛任何异常，**静默毁库**。同型的坑在 iOS 容器重定位上已经踩过一次
/// （BUG-1115）。
///
/// 这里不靠「保证只跑一次」的流程来回避（那是把正确性押在流程上），而是**把判据改对**：
/// 作用域谓词收窄为「相对旧根的**首段**命中 [scopeTopLevelNames]」，也就是**本次搬移
/// 真正会动的那些顶层项**。`Hibiki` 不在白名单里（`isSafeNestedTargetInSharedDocuments`
/// 靠的就是这一点），所以已改写过的路径首段是 `Hibiki` → 天然跳过。「跑没跑过」这个
/// 问题因此**消失**，而不是被判断掩盖。
///
/// [scopeTopLevelNames] 必须与 `DataRootMigrationRequest.documentsTopLevelIncludeNames`
/// **同源**：改写作用域与搬移作用域一旦漂开，就会出现「文件搬走了但路径没改」或反过来
/// 「路径改了但文件还在旧位置」。`null`（Hibiki 专属根的整树搬移语义）= 无首段限制；
/// 那条路径上 `_validateTarget` 已禁止新根落在旧根内部，故同样幂等。
@immutable
class DocumentsPathRebaser {
  const DocumentsPathRebaser({
    required this.oldRoot,
    required this.newRoot,
    required this.scopeTopLevelNames,
  });

  final String oldRoot;
  final String newRoot;

  /// 本次搬移真正会动的顶层项基名集合；null = 整树搬移（无首段限制）。
  final Set<String>? scopeTopLevelNames;

  static String _stripTrailingSeparator(String value) =>
      (value.endsWith('/') || value.endsWith('\\'))
          ? value.substring(0, value.length - 1)
          : value;

  /// [path] 是否落在本次改写的作用域内。分隔符归一与边界判据与
  /// `backup_service.dart` 的 `rebasePath` 逐字节一致（`/a/books_extra` 不算在
  /// `/a/books` 下）。首段比较**大小写不敏感**——`p.canonicalize` 在 Windows 上转小写，
  /// 原样比对会让 `hibikiExport` 漏网（它会被搬走、路径却不改 = 数据分家）。在 Linux 上
  /// 大小写不敏感只会更宽松几个名字，而那些名字下本来就没有别人写的 DB 路径。
  bool isInScope(String path) {
    final String root = _stripTrailingSeparator(oldRoot.replaceAll('\\', '/'));
    final String normalized = path.replaceAll('\\', '/');
    if (normalized == root) return true;
    if (!normalized.startsWith('$root/')) return false;
    final Set<String>? scope = scopeTopLevelNames;
    if (scope == null) return true;
    final String first =
        normalized.substring(root.length + 1).split('/').first.toLowerCase();
    return scope.any((String owned) => owned.toLowerCase() == first);
  }

  /// 作用域内 → rebase 到新根；作用域外（用户外部路径 / 已改写过的路径）→ 原样返回。
  String rebase(String path) =>
      isInScope(path) ? rebasePath(path, oldRoot, newRoot) : path;

  String? rebaseNullable(String? path) => path == null ? null : rebase(path);

  /// 改写 `file://<绝对路径>` URI（`media_items.image_url`）。必须先解码成文件路径再
  /// 改写、再重新编码：对 URI 字符串直接做前缀替换，分隔符与百分号编码都不对。
  /// 非 `file:` scheme（远端源的 http(s) 封面）原样返回。
  String rebaseFileUri(String value) {
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'file') return value;
    final String filePath;
    try {
      filePath = uri.toFilePath();
    } catch (_) {
      return value; // 畸形 file URI：不猜、不动。
    }
    final String rebased = rebase(filePath);
    if (rebased == filePath) return value;
    return Uri.file(rebased).toString();
  }
}

/// 改写一个 `subtitleSource` 四态编码值（`video_books.subtitle_source` /
/// `secondary_subtitle_source` 列，以及 `video_remote_subtitle` pref map 的 value）。
///
/// 只有「外挂绝对路径」态参与改写；`embedded:<n>` 与 `off:` 两个哨兵**显式**判掉。
/// 它们本来也不以旧根开头（作用域谓词天然跳过），但那是巧合——显式判掉才是契约。
String? rebaseSubtitleSource(String? stored, DocumentsPathRebaser docs) {
  if (stored == null || stored.isEmpty) return stored;
  if (SubtitleSource.isOff(stored)) return stored;
  if (SubtitleSource.isEmbeddedPersisted(stored)) return stored;
  return docs.rebase(stored);
}

/// 改写一个「JSON 字符串数组」里每个绝对路径。非 JSON 列表原样返回（一个坏值不该中断
/// 整次迁移）。
String rebaseJsonStringListWith(String json, DocumentsPathRebaser docs) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    return jsonEncode(decoded.whereType<String>().map(docs.rebase).toList());
  } catch (_) {
    return json;
  }
}

/// 改写一个 `{key: subtitleSource 四态编码}` JSON map（`video_remote_subtitle`）。
String rebaseSubtitleSourceMapJson(String json, DocumentsPathRebaser docs) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return json;
    return jsonEncode(decoded.map<String, String>((dynamic k, dynamic v) =>
        MapEntry<String, String>(
            k.toString(), rebaseSubtitleSource(v.toString(), docs)!)));
  } catch (_) {
    return json;
  }
}

/// 改写 v55 legacy `galgame_library` JSON 里每条的 `coverPath`。
/// 同条目的 `exePath` / `workdir` 是用户外部安装位置，**绝不**改写。
String rebaseLegacyGalgameLibraryJson(String json, DocumentsPathRebaser docs) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    bool changed = false;
    final List<dynamic> out = decoded.map<dynamic>((dynamic entry) {
      if (entry is! Map) return entry;
      final Map<String, dynamic> row = Map<String, dynamic>.from(entry);
      final Object? cover = row['coverPath'];
      if (cover is! String) return row;
      final String rebased = docs.rebase(cover);
      if (rebased != cover) {
        row['coverPath'] = rebased;
        changed = true;
      }
      return row;
    }).toList();
    return changed ? jsonEncode(out) : json;
  } catch (_) {
    return json;
  }
}

/// BUG-1174 ②：给定 (pref key, 原始值) 返回改写后的值。**纯函数**。
///
/// `preferences` 与 `profile_settings` 两条路都必须调它。历史教训：把改写逻辑抄两份
/// （备份恢复侧与迁移侧）迟早漂开，`srt_books` 四列与 `video_books.cover_path` 就是这么
/// 漂开的。这里只留一份。
///
/// 未登记（[pathRebasePrefFor] 返回 null）或登记为不改写的 key 一律原样返回——
/// `profile_settings` 里躺着**全部**非排除 pref，绝不能对不认识的 key 乱动。
String rebaseMigratedPrefValue(
  String key,
  String value, {
  required DocumentsPathRebaser documents,
  required String newSupportRoot,
}) {
  final PathRebasePref? spec = pathRebasePrefFor(key);
  if (spec == null || !spec.mustRebase) return value;
  switch (spec.shape) {
    // 字体 JSON 复用 backup_service 的遍历器，但**必须注入作用域改写器**：那两个函数
    // 默认走裸 rebasePath（startsWith 判据），新根落在旧根内部时会把已改写过的 path 再
    // 改一遍 → `.../Hibiki/data/Hibiki/data/custom_fonts/a.ttf`。这是本次被幂等测试
    // **真实抓到**的旁路（BUG-1174 ③）。备份恢复侧不传 rewritePath，行为逐字节不变。
    case PathValueShape.fontCatalogJson:
      return rebaseFontCatalogJson(
        value,
        documents.oldRoot,
        documents.newRoot,
        rewritePath: documents.rebase,
      );
    case PathValueShape.fontListJson:
      return rebaseFontListJson(
        value,
        documents.oldRoot,
        documents.newRoot,
        rewritePath: documents.rebase,
      );
    case PathValueShape.localAudioDbsJson:
      return normalizeLocalAudioDbsJson(value, newSupportRoot);
    case PathValueShape.audioSourceConfigsJson:
      return normalizeAudioSourceConfigsJson(value, newSupportRoot);
    case PathValueShape.legacyGalgameLibraryJson:
      return _withPrefTag(value,
          (String body) => rebaseLegacyGalgameLibraryJson(body, documents));
    case PathValueShape.subtitleSourceMapJson:
      return _withPrefTag(
          value, (String body) => rebaseSubtitleSourceMapJson(body, documents));
    case PathValueShape.jsonStringList:
      return _withPrefTag(
          value, (String body) => rebaseJsonStringListWith(body, documents));
    case PathValueShape.bare:
      // support 根下的旧单库路径按**文件名**重挂（与 local_audio_dbs 同款、天然幂等）；
      // documents 根下的裸路径走作用域改写器。
      return _withPrefTag(
        value,
        (String body) => spec.kind == PathRebaseKind.supportRooted
            ? LocalAudioManager.resolveInternalPath(body, newSupportRoot)
            : documents.rebase(body),
      );
    case PathValueShape.none:
      return value;
  }
}

/// 剥掉 PrefCodec tag（`s:` / `j:`）改写 body 再贴回去。低层 `db.setPref` 写的裸值
/// tag 为空，[joinPrefTag] 原样返回，两种写法都安全。空值直接返回（空串 = 未设置）。
String _withPrefTag(String raw, String Function(String body) rewrite) {
  if (raw.isEmpty) return raw;
  final ({String tag, String body}) split = splitPrefTag(raw);
  if (split.body.isEmpty) return raw;
  return joinPrefTag(split.tag, rewrite(split.body));
}
