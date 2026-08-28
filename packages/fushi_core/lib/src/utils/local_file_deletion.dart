/// 删除**用户自己的本机原始文件**（不是 app 复制进自己目录的副本）的共用原语。
///
/// 有声书原始音频与视频原件走同一条实现：删的范围必须逐条可解释，失败必须逐条
/// 回传。删除失败在这里是**常态**而不是异常——Windows 上正在播放的文件句柄被占用
/// 就会 errno 32，用户必须被告知「这 N 个没删掉」，而不是看到「删除成功」再回去
/// 发现盘上一个文件没少。所以本原语不吞异常、也不只打 debugPrint。
library;

import 'dart:io';

/// 一个文件没删掉的原因。
class LocalFileDeleteFailure {
  const LocalFileDeleteFailure(this.path, this.error);

  final String path;
  final Object error;

  @override
  String toString() => '$path: $error';
}

/// 一次本机原件删除的逐条结果。
class LocalFileDeleteReport {
  const LocalFileDeleteReport({
    this.removed = const <String>[],
    this.failures = const <LocalFileDeleteFailure>[],
  });

  /// 真的从磁盘消失的路径（原样，未归一化）。
  final List<String> removed;

  /// 尝试删除但失败的路径 + 错误。**不含**本来就不存在的路径（那不是失败）。
  final List<LocalFileDeleteFailure> failures;

  bool get isEmpty => removed.isEmpty && failures.isEmpty;

  Set<String> get removedSet => removed.toSet();

  /// 合并两次删除的结果（一条记录可能同时挂有声书与配对字幕书两份原件）。
  LocalFileDeleteReport merge(LocalFileDeleteReport other) =>
      LocalFileDeleteReport(
        removed: <String>[...removed, ...other.removed],
        failures: <LocalFileDeleteFailure>[...failures, ...other.failures],
      );

  @override
  String toString() => 'LocalFileDeleteReport(removed: ${removed.length}, '
      'failed: ${failures.length})';
}

/// 删除 [paths] 中真实存在的**文件**（含符号链接），返回逐条结果。
///
/// - 目录一律跳过：原件删除只删文件，绝不递归删目录（`audioRoot` 可能就是用户的
///   音乐文件夹，`videoPath` 也不该是目录）；
/// - 不存在的路径既不算删掉也不算失败，直接跳过；
/// - 单条失败不中断后续，也绝不上抛。
Future<LocalFileDeleteReport> deleteLocalFiles(Iterable<String> paths) async {
  final List<String> removed = <String>[];
  final List<LocalFileDeleteFailure> failures = <LocalFileDeleteFailure>[];
  for (final String path in paths) {
    try {
      final FileSystemEntityType type = await FileSystemEntity.type(
        path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        continue;
      }
      removed.add(path);
    } on Object catch (error) {
      failures.add(LocalFileDeleteFailure(path, error));
    }
  }
  return LocalFileDeleteReport(removed: removed, failures: failures);
}
