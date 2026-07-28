/// Lapis 模板备份的保留策略（纯函数层）。
///
/// 用户拍板（PR#457 审查 §10-5a 方案乙）：**保留 90 天，但至少留最近 10 份**
/// ——两个条件同时成立才删。删除不可逆，所以这里只做「规划」，真正删文件与
/// 逐条日志在 `LapisTemplateService.pruneBackups`。
///
/// 保守边界（刻意）：
/// - 最近 [kLapisBackupKeepMinimum] 份**永远**不参与判定，哪怕早就过期；
/// - 年龄用 `>` 严格比较：正好 90 天的备份留着；
/// - 文件名解析不出时刻的一律保留（宁可留着，也不在年龄未知时删）。
library;

/// 备份最长保留时长。超过这个年龄**且**排在最近 [kLapisBackupKeepMinimum]
/// 份之外才会被删。
const Duration kLapisBackupMaxAge = Duration(days: 90);

/// 无论多旧都要保留的最近备份份数。
const int kLapisBackupKeepMinimum = 10;

/// 从备份文件名解析 UTC 时刻。
///
/// 文件名格式 `lapis-<ISO8601，冒号替换成 '-'>.json`（见
/// `LapisTemplateService._writeBackupFile`：Windows 文件名不允许冒号）。解析
/// 不出返回 `null`——调用方必须把它当「年龄不可判定」= 永不删除。
DateTime? parseLapisBackupTimestamp(String filename) {
  if (!filename.startsWith('lapis-') || !filename.endsWith('.json')) {
    return null;
  }
  final String raw =
      filename.substring('lapis-'.length, filename.length - '.json'.length);
  // 时间部分的三个 '-' 还原成 ':'；日期部分的 '-' 本就是 ISO 分隔符，不能动。
  final String iso = raw.replaceFirstMapped(
    RegExp(r'T(\d{2})-(\d{2})-(\d{2})'),
    (Match m) => 'T${m[1]}:${m[2]}:${m[3]}',
  );
  return DateTime.tryParse(iso);
}

/// 规划要删除的备份条目。
///
/// [newestFirst] 必须按**新 → 旧**排序（`LapisTemplateService.listBackups`
/// 的契约）。返回的就是可以删的那些，顺序与输入一致。
///
/// 判据（两个条件同时满足）：
/// 1. 排在最近 [keepMinimum] 份之外；
/// 2. `now - 时刻` **严格大于** [maxAge]。
///
/// [timestampOf] 返回 `null` 表示时刻不可判定 → 该条目一律保留。
List<T> planLapisBackupPrune<T>(
  List<T> newestFirst, {
  required DateTime? Function(T item) timestampOf,
  required DateTime now,
  int keepMinimum = kLapisBackupKeepMinimum,
  Duration maxAge = kLapisBackupMaxAge,
}) {
  if (newestFirst.length <= keepMinimum) return <T>[];
  final List<T> doomed = <T>[];
  for (int i = keepMinimum; i < newestFirst.length; i++) {
    final T item = newestFirst[i];
    final DateTime? at = timestampOf(item);
    if (at == null) continue;
    if (now.difference(at) > maxAge) doomed.add(item);
  }
  return doomed;
}
