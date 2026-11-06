// 应用数据目录的存储分项（BUG-4075）：启动后在后台 isolate 走一遍 App 自己的数据根，
// 把各层目录大小与大文件记进诊断日志，随反馈 / 闪退报告上传。
//
// 起因：同一 profile 手机端 App Data 15.6 GB、桌面 srs.db 只有 2.68 GB，却不知道手机上
// 是库本体、WAL、媒体、备份快照还是缓存在胀；让用户跑 adb run-as 不现实。只记大小与
// App 数据根下的相对路径（不含用户名 / 外部存储），不读文件内容。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path_provider/path_provider.dart';

/// 日志 source 标签（不是 i18n key）。
const String kStorageFootprintSource = 'Storage.footprint';

/// 启动后多久开始量：避开首屏与启动期 IO 高峰，又赶在常见的「启动后几分钟内存耗尽」之前。
const Duration kStorageFootprintDelay = Duration(seconds: 20);

/// 列出的目录深度（根下第 1、2 层）与门槛：小于门槛的目录不单列。
const int kStorageFootprintDirDepth = 2;
const int kStorageFootprintDirMinBytes = 50 << 20;

/// 单列的大文件门槛与条数。
const int kStorageFootprintBigFileBytes = 100 << 20;
const int kStorageFootprintBigFileLimit = 15;

/// 一次测量的结果（纯数据，可跨 isolate 发送）。
@immutable
class StorageFootprint {
  const StorageFootprint({
    required this.totalBytes,
    required this.fileCount,
    required this.unreadable,
    required this.dirs,
    required this.bigFiles,
  });

  final int totalBytes;
  final int fileCount;

  /// 列不了 / stat 不了的目录项个数（权限、竞态删除）。
  final int unreadable;

  /// 深度 ≤ [kStorageFootprintDirDepth] 且不小于门槛的目录：相对路径 → 字节，按大小降序。
  final List<(String, int)> dirs;

  /// 不小于 [kStorageFootprintBigFileBytes] 的文件：相对路径 → 字节，按大小降序、最多
  /// [kStorageFootprintBigFileLimit] 条。
  final List<(String, int)> bigFiles;

  /// 日志正文。
  String describe(String rootLabel) {
    final StringBuffer b = StringBuffer()
      ..write('root=$rootLabel total=${formatFootprintBytes(totalBytes)} ')
      ..write('files=$fileCount');
    if (unreadable > 0) b.write(' unreadable=$unreadable');
    if (dirs.isNotEmpty) {
      b.write(
        '\ndirs (≥${formatFootprintBytes(kStorageFootprintDirMinBytes)}):',
      );
      for (final (String path, int bytes) in dirs) {
        b.write('\n  $path ${formatFootprintBytes(bytes)}');
      }
    }
    if (bigFiles.isNotEmpty) {
      b.write(
        '\nbig files (≥${formatFootprintBytes(kStorageFootprintBigFileBytes)}):',
      );
      for (final (String path, int bytes) in bigFiles) {
        b.write('\n  $path ${formatFootprintBytes(bytes)}');
      }
    }
    return b.toString();
  }
}

/// `1.2GB` / `340MB` / `12KB` / `7B`。
String formatFootprintBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
  if (bytes >= 1 << 20) return '${bytes >> 20}MB';
  if (bytes >= 1 << 10) return '${bytes >> 10}KB';
  return '${bytes}B';
}

/// 同步走一遍 [root]（不跟随符号链接）。在后台 isolate 调（[logStorageFootprint]）。
StorageFootprint measureStorageFootprint(Directory root) {
  final String sep = Platform.pathSeparator;
  final int base = root.path.endsWith(sep)
      ? root.path.length
      : root.path.length + 1;
  final Map<String, int> dirSizes = <String, int>{};
  final List<(String, int)> big = <(String, int)>[];
  int files = 0;
  int unreadable = 0;

  // 返回 [dir] 的总字节；[depth] 是它在根下的层数（根 = 0）。
  int walk(Directory dir, int depth) {
    int sum = 0;
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      unreadable++;
      return 0;
    }
    for (final FileSystemEntity e in entries) {
      if (e is Directory) {
        sum += walk(e, depth + 1);
      } else if (e is File) {
        final int len;
        try {
          len = e.lengthSync();
        } on FileSystemException {
          unreadable++;
          continue;
        }
        files++;
        sum += len;
        if (len >= kStorageFootprintBigFileBytes) {
          big.add((_relative(e.path, base, sep), len));
        }
      }
    }
    if (depth >= 1 && depth <= kStorageFootprintDirDepth) {
      dirSizes[_relative(dir.path, base, sep)] = sum;
    }
    return sum;
  }

  final int total = walk(root, 0);
  // 大小降序；同样大（父目录只含一个子目录）按路径升序，父目录在前——`List.sort` 不稳定。
  int bySizeDesc((String, int) a, (String, int) b) {
    final int bySize = b.$2.compareTo(a.$2);
    return bySize != 0 ? bySize : a.$1.compareTo(b.$1);
  }

  final List<(String, int)> dirs = <(String, int)>[
    for (final MapEntry<String, int> e in dirSizes.entries)
      if (e.value >= kStorageFootprintDirMinBytes) (e.key, e.value),
  ]..sort(bySizeDesc);
  big.sort(bySizeDesc);
  return StorageFootprint(
    totalBytes: total,
    fileCount: files,
    unreadable: unreadable,
    dirs: dirs,
    bigFiles: big.length > kStorageFootprintBigFileLimit
        ? big.sublist(0, kStorageFootprintBigFileLimit)
        : big,
  );
}

String _relative(String path, int base, String sep) =>
    (path.length > base ? path.substring(base) : path).replaceAll(sep, '/');

/// App 自己的数据根：Android = `/data/user/<u>/<包名>`（`files/` 的上一层，含 `app_flutter`、
/// `databases`、`cache`、`app_webview`…）；iOS = 沙盒容器（`Documents/` 的上一层）；桌面 =
/// Application Support 目录。
Future<(Directory, String)> resolveStorageFootprintRoot() async {
  if (Platform.isAndroid) {
    return ((await getApplicationSupportDirectory()).parent, 'android-data');
  }
  if (Platform.isIOS) {
    return ((await getApplicationDocumentsDirectory()).parent, 'ios-container');
  }
  return (await getApplicationSupportDirectory(), 'support');
}

/// 量一次 [root] 并记进诊断日志。走目录在后台 isolate（大库下几万个媒体文件也不卡 UI）。
Future<void> logStorageFootprint({
  required Directory root,
  required String rootLabel,
}) async {
  try {
    final StorageFootprint footprint = await Isolate.run(
      () => measureStorageFootprint(root),
      debugName: 'storage-footprint',
    );
    ErrorLogService.instance.logDiagnostic(
      kStorageFootprintSource,
      footprint.describe(rootLabel),
    );
  } on Object catch (e, st) {
    ErrorLogService.instance.log(kStorageFootprintSource, e, st);
  }
}

/// 生产启动时调一次：[kStorageFootprintDelay] 后量 App 数据根（[resolveStorageFootprintRoot]）。
void scheduleStorageFootprintLog() {
  Timer(kStorageFootprintDelay, () async {
    try {
      final (Directory root, String label) =
          await resolveStorageFootprintRoot();
      await logStorageFootprint(root: root, rootLabel: label);
    } on Object catch (e, st) {
      ErrorLogService.instance.log(kStorageFootprintSource, e, st);
    }
  });
}
