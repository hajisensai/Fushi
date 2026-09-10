/// 目录真实占用测量。
///
/// 存在的理由（BUG-1732）：凡是「这块功能占了多少磁盘、删掉能释放多少」的
/// 展示，只要改成按静态清单/预期值累加，就必然和用户 `du` 出来的数字对不上——
/// 中断留下的临时档、上游换档后的遗留档、失败重试的半成品都不在任何清单里。
/// 唯一不会骗人的真相源是目录本身，所以统一走这个函数量，别再各处手写累加。
library;

import 'dart:io';

/// [dir] 的递归字节占用；目录不存在返回 0。
///
/// - 只统计常规文件（[File]）：符号链接不跟随（[Directory.list] 默认
///   `followLinks: true` 会把链接目标算成本目录的占用，甚至在环形链接上打转），
///   故显式关掉。
/// - 单个条目 stat 失败（并发删除、权限不足）跳过而不是整体抛错：量占用是
///   展示用途，为一个读不到的文件让整页报错不划算。
Future<int> measureDirectoryBytes(Directory dir) async {
  if (!await dir.exists()) {
    return 0;
  }
  int total = 0;
  try {
    await for (final FileSystemEntity entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      try {
        total += await entity.length();
      } catch (_) {
        // 条目在遍历途中消失/不可读：跳过。
      }
    }
  } on FileSystemException {
    // 目录在遍历途中被删：已累计的部分照常返回。
  }
  return total;
}
