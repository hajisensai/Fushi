/// 封面回填失败记账（BUG-1564 ②）：抽帧失败的**会话级负缓存**。
///
/// 旧账本是视频页 State 里的 `_coverBackfillAttempted`（`Set<String>` per-State）：
/// 页面 State 一重建（切库页视图 / 重进页面 / 重启）记账清零，对同一个抽不出帧的
/// 文件每轮都重烧一次 ffmpeg（最长 30s/次）+ 刷一条错误日志。本账本是 **app 进程
/// 级单例**，跨页面 State 存活；按 `videoPath` 记「失败时的 mtime/size + 原因」，
/// [shouldAttempt] 只在**同一文件没变**（mtime/size 均相同）时拦截重试——文件被
/// 替换/重灌后自动放行，无需任何手动失效。
///
/// 为什么不落库持久化：失败是可自愈状态（用户换文件 / 装上 ffmpeg / 修好数据根），
/// 每次冷启动最多为每个坏条目付一次探测成本，换来零 schema 迁移与零陈旧账本；
/// 会话内（真正的刷屏来源）已完全拦住。用户显式「下拉刷新」是现有的重新获取入口，
/// 视频页在那里调 [clearAll] 主动清账（用户明示要最新 → 允许再试一轮）。
///
/// 只记**失败**：成功的行下轮被「已有封面」短路，无需记账；同一路径服务多行
/// （去重导入）时失败对每行同样成立，故键是路径而非 bookUid。
library;

import 'dart:io';

import 'package:meta/meta.dart';

/// 一次抽帧失败的记录：失败原因 + 失败时刻的文件身份（mtime 毫秒 / 字节数；
/// 文件当时不存在则两者为 null）。
@immutable
class CoverBackfillFailure {
  const CoverBackfillFailure({
    required this.reason,
    required this.mtimeMs,
    required this.sizeBytes,
  });

  /// 失败原因（诊断用，如 `extract-failed` / `file-missing`）。
  final String reason;

  /// 失败时文件的最后修改时刻（epoch 毫秒）；文件不存在为 null。
  final int? mtimeMs;

  /// 失败时文件的字节数；文件不存在为 null。
  final int? sizeBytes;
}

/// 会话级封面回填失败账本（进程单例 [CoverBackfillLedger.instance]）。
class CoverBackfillLedger {
  CoverBackfillLedger._();

  /// 生产单例：跨页面 State 存活，进程结束即清。
  static final CoverBackfillLedger instance = CoverBackfillLedger._();

  /// 测试用独立实例（不污染生产单例）。
  @visibleForTesting
  CoverBackfillLedger.forTesting();

  final Map<String, CoverBackfillFailure> _failures =
      <String, CoverBackfillFailure>{};

  /// 是否应对 [videoPath] 发起一次抽帧：无失败记录 → 试；有记录但文件身份
  /// （mtime/size）已变 → 试（并丢弃陈旧记录）；身份未变 → 拦。
  bool shouldAttempt(String videoPath) {
    final CoverBackfillFailure? failure = _failures[videoPath];
    if (failure == null) return true;
    final (int?, int?) now = _statIdentity(videoPath);
    if (now.$1 == failure.mtimeMs && now.$2 == failure.sizeBytes) return false;
    _failures.remove(videoPath); // 文件变了：旧账作废，放行重试。
    return true;
  }

  /// 记一次失败：连同当前文件身份一起存，供 [shouldAttempt] 判「同一文件不变」。
  void recordFailure(String videoPath, {required String reason}) {
    final (int?, int?) identity = _statIdentity(videoPath);
    _failures[videoPath] = CoverBackfillFailure(
      reason: reason,
      mtimeMs: identity.$1,
      sizeBytes: identity.$2,
    );
  }

  /// 清单条记账（该路径下轮重试）。
  void clear(String videoPath) => _failures.remove(videoPath);

  /// 清全部记账。接在用户显式「重新获取」入口（视频页下拉刷新）。
  void clearAll() => _failures.clear();

  /// [videoPath] 当前记账的失败原因；无记账返回 null。诊断/测试用。
  String? failureReason(String videoPath) => _failures[videoPath]?.reason;

  /// 当前记账条数（测试用）。
  @visibleForTesting
  int get debugFailureCount => _failures.length;

  /// 读文件身份 (mtimeMs, sizeBytes)；不存在/不可 stat 返回 (null, null)。
  static (int?, int?) _statIdentity(String path) {
    try {
      final FileStat stat = File(path).statSync();
      if (stat.type == FileSystemEntityType.notFound) return (null, null);
      return (stat.modified.millisecondsSinceEpoch, stat.size);
    } catch (_) {
      return (null, null);
    }
  }
}
