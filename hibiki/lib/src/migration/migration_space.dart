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

import 'package:hibiki/src/migration/migration_exporter.dart';

/// 压缩留量系数。
///
/// 归档是 zip，但迁移的大头（词典资源 / 有声书音频 / 已压缩的 epub 内含图）几乎
/// 不可压，按 1:1 估算；再留 10% 给 manifest、zip 目录区和文件系统块对齐。
/// **有意不按「zip 会变小」乐观打折** —— 估少了就是炸，估多了只是多提醒一次。
const double kMigrationSizeHeadroom = 1.10;

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
  }) {
    final int required = (estimatedBytes * headroom).ceil() +
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

/// 各批内容树的根目录（[MigrationBatch.core] 无文件树）。
///
/// 与 `MigrationPage` 构造 `BackupService` 时用的根**必须同源**，否则估的和导的
/// 不是同一批字节。
class MigrationContentRoots {
  const MigrationContentRoots({
    required this.databaseFile,
    required this.dictionaryResourceDirectory,
    required this.booksRootDirectory,
    required this.audiobooksRootDirectory,
    required this.fontsRootDirectory,
    required this.localAudioRootDirectory,
  });

  final File databaseFile;
  final Directory dictionaryResourceDirectory;
  final Directory booksRootDirectory;
  final Directory audiobooksRootDirectory;
  final Directory fontsRootDirectory;
  final Directory localAudioRootDirectory;

  Directory? rootForBatch(MigrationBatch batch) => switch (batch) {
        MigrationBatch.core => null,
        MigrationBatch.dictionaries => dictionaryResourceDirectory,
        MigrationBatch.books => booksRootDirectory,
        MigrationBatch.audiobooks => audiobooksRootDirectory,
        MigrationBatch.fonts => fontsRootDirectory,
        MigrationBatch.localAudio => localAudioRootDirectory,
      };
}

/// 实测各批体积（真 IO，可能耗时数秒，调用方自行放到 loading 态里）。
MigrationSpaceEstimate measureBatchBytes(
  MigrationContentRoots roots,
  List<MigrationBatch> batches,
) {
  final Map<MigrationBatch, int> perBatch = <MigrationBatch, int>{};
  for (final MigrationBatch batch in batches) {
    final Directory? root = roots.rootForBatch(batch);
    perBatch[batch] = root == null ? 0 : measureDirectoryBytes(root);
  }
  int dbBytes = 0;
  if (roots.databaseFile.existsSync()) {
    try {
      dbBytes = roots.databaseFile.statSync().size;
    } on FileSystemException {
      dbBytes = 0;
    }
  }
  return MigrationSpaceEstimate(
    perBatchBytes: perBatch,
    databaseBytes: dbBytes,
  );
}

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
