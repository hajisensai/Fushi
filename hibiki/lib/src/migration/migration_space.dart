/// 迁移导出的**存储空间闸门**。
///
/// 为什么必须有：导出把书 / 词典 / 有声书 / 字体（可选还有本地发音库）整份复制
/// 到公共 Documents 下的中转目录 —— 迁移期间同一份数据在磁盘上存在**两份**。
/// 原实现直接开导且开头就 `deleteSync` 旧中转目录，空间不足的结局是「导到一半
/// 炸 + 旧中转目录已被删」，用户两头落空。
///
/// 判据与测量**刻意分离**：[MigrationSpaceVerdict.decide] 是纯函数（可单测所有
/// 边界），目录测量走 [measureBatchBytes]（真 IO）。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:hibiki/src/migration/migration_exporter.dart';
import 'package:path/path.dart' as p;

/// 压缩留量系数。
///
/// 归档是 zip，但迁移的大头（词典资源 / 有声书音频 / 已压缩的 epub 内含图）几乎
/// 不可压，按 1:1 估算；再留 10% 给 manifest、zip 目录区和文件系统块对齐。
/// **有意不按「zip 会变小」乐观打折** —— 估少了就是炸，估多了只是多提醒一次。
const double kMigrationSizeHeadroom = 1.10;

/// 迁移**峰值**占用相对「单份导出量」的倍数。
///
/// 迁移不是「导出完就结束」：Fushi 导入时要把归档解压进自己的数据目录，而中转
/// 文件在导入成功前**绝不删除**（导入侧红线：任一批校验不符就保留原件供重传）。
/// 所以迁移期间磁盘上新增的是**两份**——中转归档 + Fushi 侧副本——而不是一份。
///
/// 只算中转那一份，后果不是「提示不准」而是**用户白跑一次十几 GB 的导出**：
/// 闸门放行 → 导出全部成功 → 到 Fushi 那边解压时磁盘满 → 导入失败，用户回到
/// 原点还多占了一份中转空间。宁可在开始前就拦下并告诉他关掉发音库能省多少。
const double kMigrationPeakCopies = 2.0;

/// Fushi 安装包留量（字节）。
///
/// 一键迁移会先下载 Fushi APK 再导出，APK 也落在同一块存储上。实测 debug 包
/// ~246 MB，取 400 MB 留量覆盖后续增长与 split-ABI 差异。
const int kFushiApkReserveBytes = 400 * 1024 * 1024;

/// 单批体积估算结果。
class MigrationSpaceEstimate {
  const MigrationSpaceEstimate({
    required this.perBatchBytes,
    required this.databaseBytes,
  });

  /// 每批**内容树**的磁盘占用（不含 DB；DB 每批都带，另计）。
  final Map<MigrationBatch, int> perBatchBytes;

  /// 主库文件大小。每个批次的归档都整库带一份，故按批数乘。
  final int databaseBytes;

  /// 计划内全部批次导出后，中转目录的预估总占用。
  int totalBytesFor(List<MigrationBatch> batches) {
    int total = 0;
    for (final MigrationBatch batch in batches) {
      total += perBatchBytes[batch] ?? 0;
      total += databaseBytes;
    }
    return total;
  }
}

/// 空间闸门裁决。
class MigrationSpaceVerdict {
  const MigrationSpaceVerdict({
    required this.requiredBytes,
    required this.freeBytes,
    required this.measurable,
    required this.sufficient,
    required this.shortfallBytes,
  });

  /// 本次导出预计需要的字节（已含留量系数与 APK 预留）。
  final int requiredBytes;

  /// 中转目录所在卷的可用字节；[measurable] 为 false 时无意义。
  final int freeBytes;

  /// 是否测得出可用空间。测不出 → [sufficient] 恒 false（硬拦）。
  final bool measurable;

  /// 是否放行。
  final bool sufficient;

  /// 还差多少字节；充足时为 0。
  final int shortfallBytes;

  /// 纯函数判据。
  ///
  /// [freeBytes] 传 null 表示**测不出**（非 Android、StatFs 失败、老宿主没有
  /// 该通道方法）。此时一律不放行：把「不知道」当「够用」正是要防的那次炸。
  static MigrationSpaceVerdict decide({
    required int estimatedBytes,
    required int? freeBytes,
    bool includeApkReserve = true,
    double headroom = kMigrationSizeHeadroom,
    int apkReserveBytes = kFushiApkReserveBytes,
    double peakCopies = kMigrationPeakCopies,
  }) {
    // 峰值是「中转归档 + Fushi 侧解压副本」两份同时在盘上，不是一份。
    final int required = (estimatedBytes * peakCopies * headroom).ceil() +
        (includeApkReserve ? apkReserveBytes : 0);
    if (freeBytes == null) {
      return MigrationSpaceVerdict(
        requiredBytes: required,
        freeBytes: 0,
        measurable: false,
        sufficient: false,
        shortfallBytes: required,
      );
    }
    final bool ok = freeBytes >= required;
    return MigrationSpaceVerdict(
      requiredBytes: required,
      freeBytes: freeBytes,
      measurable: true,
      sufficient: ok,
      shortfallBytes: ok ? 0 : required - freeBytes,
    );
  }
}

/// 递归求目录占用；目录不存在返回 0。
///
/// 用 `stat().size` 而非 `length()`：符号链接不跟随（跟随会把同一份数据算两遍，
/// 有声书目录里存在指向共享媒体的链接）。单个条目读失败按 0 计并继续 —— 估算
/// 宁可少算一个文件，也不能因为一个不可读条目就让整个闸门抛异常放行。
int measureDirectoryBytes(Directory dir) {
  if (!dir.existsSync()) return 0;
  int total = 0;
  for (final FileSystemEntity entity
      in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    try {
      total += entity.statSync().size;
    } on FileSystemException {
      continue;
    }
  }
  return total;
}

/// 本地发音库文件名规则。
///
/// 与 `BackupService._collectLocalAudioFiles` **同规则**：`local_audio_*.db` 及其
/// `-wal`/`-shm` 兄弟文件，只扫 DB 目录**一层**（非递归）。主库 `hibiki.db` 和其它
/// 支持文件不在此列——估算必须与导出打包的是同一批字节，否则闸门是假的。
final RegExp kLocalAudioFileNamePattern =
    RegExp(r'^local_audio_.*\.db(-wal|-shm)?$');

/// 本地发音库占用：DB 目录一层里匹配 [kLocalAudioFileNamePattern] 的文件之和。
int measureLocalAudioBytes(Directory dbDirectory) {
  if (!dbDirectory.existsSync()) return 0;
  int total = 0;
  for (final FileSystemEntity entity
      in dbDirectory.listSync(followLinks: false)) {
    if (entity is! File) continue;
    if (!kLocalAudioFileNamePattern.hasMatch(p.basename(entity.path))) continue;
    try {
      total += entity.statSync().size;
    } on FileSystemException {
      continue;
    }
  }
  return total;
}

/// 各批内容的**测量方式**。
///
/// 刻意不是「每批一个根目录」：localAudio 不是一棵树，而是 DB 目录一层里按文件名
/// 匹配的若干 `.db`。用「批 → 测量函数」表达，把这个差异收进构造期，调用方那边没有
/// 特殊分支。各根必须与 `MigrationPage` 构造 `BackupService` 时用的**同源**，否则估
/// 的和导的不是同一批字节。
class MigrationContentRoots {
  const MigrationContentRoots({
    required this.databaseFilePath,
    required this.databaseDirectoryPath,
    required this.dictionaryResourceDirectoryPath,
    required this.booksRootDirectoryPath,
    required this.audiobooksRootDirectoryPath,
    required this.fontsRootDirectoryPath,
  });

  final String databaseFilePath;

  /// 主库所在目录，同时也是本地发音库 `.db` 的落地目录
  /// （`BackupService` 里 `localAudioRoot` 就取 `_dbDirectory`）。
  final String databaseDirectoryPath;
  final String dictionaryResourceDirectoryPath;
  final String booksRootDirectoryPath;
  final String audiobooksRootDirectoryPath;
  final String fontsRootDirectoryPath;

  /// 该批内容树的根；[MigrationBatch.core] 无文件树，[MigrationBatch.localAudio]
  /// 不是整棵树（见 [measurerForBatch]），两者都返回 null。
  String? rootPathForBatch(MigrationBatch batch) => switch (batch) {
        MigrationBatch.core => null,
        MigrationBatch.dictionaries => dictionaryResourceDirectoryPath,
        MigrationBatch.books => booksRootDirectoryPath,
        MigrationBatch.audiobooks => audiobooksRootDirectoryPath,
        MigrationBatch.fonts => fontsRootDirectoryPath,
        MigrationBatch.localAudio => null,
      };

  /// 该批的测量函数（core 恒 0：只带 DB 行，无文件树）。
  int Function() measurerForBatch(MigrationBatch batch) {
    if (batch == MigrationBatch.localAudio) {
      return () => measureLocalAudioBytes(Directory(databaseDirectoryPath));
    }
    final String? root = rootPathForBatch(batch);
    if (root == null) return () => 0;
    return () => measureDirectoryBytes(Directory(root));
  }
}

/// 实测各批体积（真 IO）。
MigrationSpaceEstimate measureBatchBytes(
  MigrationContentRoots roots,
  List<MigrationBatch> batches,
) {
  final Map<MigrationBatch, int> perBatch = <MigrationBatch, int>{};
  for (final MigrationBatch batch in batches) {
    perBatch[batch] = roots.measurerForBatch(batch)();
  }
  int dbBytes = 0;
  final File dbFile = File(roots.databaseFilePath);
  if (dbFile.existsSync()) {
    try {
      dbBytes = dbFile.statSync().size;
    } on FileSystemException {
      dbBytes = 0;
    }
  }
  return MigrationSpaceEstimate(
    perBatchBytes: perBatch,
    databaseBytes: dbBytes,
  );
}

/// 后台 isolate 实测。
///
/// 大书库/词典树递归 `stat` 实测可达数秒，跑在主 isolate 上会**卡死 UI**——而这
/// 段恰好发生在用户刚点下「迁移」之后，正是最不能掉帧的时刻。[MigrationContentRoots]
/// 刻意只持有 String 路径（不是 `Directory`/`File`）就是为了能安全跨 isolate 传递。
Future<MigrationSpaceEstimate> measureBatchBytesInBackground(
  MigrationContentRoots roots,
  List<MigrationBatch> batches,
) =>
    Isolate.run(() => measureBatchBytes(roots, batches));

/// 人类可读体积（闸门文案用；1024 进制，与 Android 设置里的「存储」口径一致）。
String formatMigrationBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
