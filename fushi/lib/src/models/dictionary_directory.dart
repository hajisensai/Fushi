import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as path;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 删不掉的词典目录改名后的落脚点（词典资源根下），由
/// [purgePendingDictionaryDeletes] 在启动时统一清理。
const String kDictionaryPendingDeleteDirName = '.pending_delete';

/// [deleteDictionaryDirectory] 的落地方式。
enum DictDirDeleteOutcome {
  /// 目录本来就不存在。
  absent,

  /// 目录已从磁盘删除。
  deleted,

  /// 删不掉（外部句柄），已改名挪进 [kDictionaryPendingDeleteDirName] 隔离区，
  /// 等下次启动清理。词典名已经空出来，重导同名词典不受影响。
  quarantined,

  /// 删不掉且改名也失败，目录原地残留。meta 已经撤掉，用户看到的是「删掉了」；
  /// 残留目录会被下一次同名导入或整库清空顺手带走。
  leftBehind,
}

/// 删除一本词典的磁盘目录。
///
/// 为什么不是一句 `dir.deleteSync(recursive: true)`（BUG-1756）：
/// 词典加载时 native 引擎把 `hash.table` / `bloom.filter` / `blobs.bin` /
/// `media.bin` / `media.idx` 全部 `MapViewOfFile` 常驻映射
/// （`native/fushidicts/fushidicts_src/query.cpp` 的 `add_dict` →
/// `memory/memory.cpp` 的 `map_rd`）。Windows 上只要那份 view 还活着，
/// `DeleteFileW` 一律返回 ERROR_USER_MAPPED_FILE(1224)，删除必抛
/// [FileSystemException]。
///
/// 也就是说「删词典目录」天生是两步、顺序不可交换：**先让引擎释放映射，再删目录**。
/// 四个删除入口（手动删除 / 覆盖更新导入 / 清空全部 / 互联 host 删除）原先各写各的
/// `deleteSync`，四处全把顺序写反 —— 用户侧就是「点删除提示删除失败、关掉软件再开
/// 词典却没了」（meta 已落库删除、目录残留）和「词典更新只能每次重新导入」（覆盖
/// 导入第一步删旧目录就抛）。两步收进这一个原语，调用方无从写错顺序。
///
/// 释放映射用 [FushiDicts.releaseAllMappings]，它是把引擎重建成**空**的核弹——
/// 别的词典也一起掉出去了。所以 [reloadEngine] 是**必填**参数而不是「调用方记得
/// 补一句」：删完必须把剩下的词典装回引擎，否则删一本会连带让其余词典查不出词。
/// 编译器替我们兜住这一步，不靠守卫测试去查每个调用点写对没有。
///
/// 调用约定：撤 meta（[DictionaryRepository.deleteDictionaryMeta] 或等价的
/// DB 删除 + cache 重载）必须发生在本函数**之前** —— 否则 [reloadEngine] 会把刚
/// 删掉的那本重新映射回来。
Future<DictDirDeleteOutcome> deleteDictionaryDirectory(
  Directory directory, {
  required FutureOr<void> Function() reloadEngine,
}) async {
  if (!directory.existsSync()) return DictDirDeleteOutcome.absent;
  FushiDicts.releaseAllMappings();
  final DictDirDeleteOutcome outcome = await deleteDictionaryDirectoryCore(
    delete: () => directory.delete(recursive: true),
    quarantine: () => _quarantineDictionaryDirectory(directory),
    sleep: (int ms) => Future<void>.delayed(Duration(milliseconds: ms)),
    isWindows: Platform.isWindows,
  );
  await reloadEngine();
  return outcome;
}

/// [deleteDictionaryDirectory] 的纯逻辑核心，依赖全部注入便于测试。
///
/// 仅当 [isWindows] 且 OS 错误码是瞬时/占用类（5 ACCESS_DENIED、
/// 32 SHARING_VIOLATION、1224 USER_MAPPED_FILE）时才重试——AV 扫描和索引器会在
/// 文件刚被访问后短暂持有句柄（与 `publishImportedDir` 同款外部不可控行为）。
/// 用尽 [maxAttempts] 后改名隔离，绝不把「删不掉」升级成「词典删了一半」。
/// 其余错误（非 Windows、或非占用码）原样抛出，交调用方报错。
@visibleForTesting
Future<DictDirDeleteOutcome> deleteDictionaryDirectoryCore({
  required Future<void> Function() delete,
  required Future<void> Function() quarantine,
  required Future<void> Function(int delayMs) sleep,
  required bool isWindows,
  int maxAttempts = 5,
}) async {
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await delete();
      return DictDirDeleteOutcome.deleted;
    } on FileSystemException catch (e) {
      final int? code = e.osError?.errorCode;
      final bool occupied =
          isWindows && (code == 5 || code == 32 || code == 1224);
      if (!occupied) rethrow;
      if (attempt == maxAttempts) {
        try {
          await quarantine();
          return DictDirDeleteOutcome.quarantined;
        } catch (qe, stack) {
          ErrorLogService.instance.log('dictDir.quarantine', qe, stack);
          return DictDirDeleteOutcome.leftBehind;
        }
      }
      await sleep(50 * attempt); // 退避 50/100/150/200ms，给 AV 扫描窗口让路
    }
  }
  return DictDirDeleteOutcome.deleted; // 不可达：循环内必返回或抛出
}

/// 把删不掉的 [directory] 改名挪进资源根下的隔离区，空出词典名。
Future<void> _quarantineDictionaryDirectory(Directory directory) async {
  final Directory pending = Directory(
      path.join(directory.parent.path, kDictionaryPendingDeleteDirName));
  await pending.create(recursive: true);
  final String base = path.basename(directory.path);
  for (int n = 0; n < 1000; n++) {
    final String dest = path.join(pending.path, n == 0 ? base : '$base-$n');
    if (Directory(dest).existsSync() || File(dest).existsSync()) continue;
    await directory.rename(dest);
    return;
  }
  throw FileSystemException('quarantine slots exhausted', directory.path);
}

/// 清理上一次运行留下的隔离区（进程重启后映射早已随进程消失，此时必能删掉）。
/// 尽力而为：删不掉就留到下次启动，绝不阻断初始化。
Future<void> purgePendingDictionaryDeletes(Directory resourceRoot) async {
  final Directory pending =
      Directory(path.join(resourceRoot.path, kDictionaryPendingDeleteDirName));
  if (!pending.existsSync()) return;
  try {
    await pending.delete(recursive: true);
  } catch (e, stack) {
    ErrorLogService.instance.log('dictDir.purgePending', e, stack);
  }
}
