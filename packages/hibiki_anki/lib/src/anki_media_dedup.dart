/// Anki 媒体字节级去重的纯函数层：分组规划、规范名选择、引用改写、周期判定。
///
/// 范围（用户拍板）：**只去重、只删字节完全相同的多余副本**——引用全部改指
/// 到保留的那一份之后再删副本，零信息损失。**绝不重编码/压缩任何文件**
/// （画质一个字节都不动），也不做按年龄的清理。
///
/// 「重复代码」也天然覆盖：模板资产（`_` 前缀的 js/css/字体）同样按字节去重，
/// 模板/styling 里的引用一并改写。
///
/// IO 编排（扫描媒体目录 / 改笔记 / 删文件）在 AnkiConnectRepository；本文件
/// 全部纯函数，可单测。
library;

/// 一组字节完全相同的媒体文件：保留 [canonical]，[duplicates] 在引用改写
/// 干净后删除。
class MediaDedupGroup {
  const MediaDedupGroup({required this.canonical, required this.duplicates});

  final String canonical;
  final List<String> duplicates;
}

/// 从「文件名 → 内容哈希」规划去重组（哈希相同 = 字节相同；调用方只对
/// 「大小相同的候选」计算哈希，这里不关心怎么算的）。单文件组不产出。
/// 组内与组间均按文件名排序，输出确定性可测。
List<MediaDedupGroup> planMediaDedupGroups(Map<String, String> nameToHash) {
  final Map<String, List<String>> byHash = <String, List<String>>{};
  for (final MapEntry<String, String> e in nameToHash.entries) {
    byHash.putIfAbsent(e.value, () => <String>[]).add(e.key);
  }
  final List<MediaDedupGroup> groups = <MediaDedupGroup>[];
  for (final List<String> names in byHash.values) {
    if (names.length < 2) continue;
    final String canonical = chooseCanonicalMediaName(names);
    final List<String> dupes = (names.toList()..remove(canonical))..sort();
    groups.add(MediaDedupGroup(canonical: canonical, duplicates: dupes));
  }
  groups.sort((MediaDedupGroup a, MediaDedupGroup b) =>
      a.canonical.compareTo(b.canonical));
  return groups;
}

/// 选保留哪一份：
/// 1. `_` 前缀优先——Anki 的「检查媒体」不会把 `_` 前缀文件当未使用清掉，
///    模板资产（js/css/字体）只有保留 `_` 名才安全；
/// 2. 其余取最短文件名（内容寻址的长哈希名与人类命名并存时留人类可读性
///    不重要，短名减少字段体积）；
/// 3. 平手取字典序最小，保证确定性。
String chooseCanonicalMediaName(List<String> names) {
  assert(names.isNotEmpty);
  final List<String> sorted = names.toList()
    ..sort((String a, String b) {
      final bool ua = a.startsWith('_');
      final bool ub = b.startsWith('_');
      if (ua != ub) return ua ? -1 : 1;
      if (a.length != b.length) return a.length - b.length;
      return a.compareTo(b);
    });
  return sorted.first;
}

/// 把文本（笔记字段 / 卡模板 / styling）里对 [from] 的引用改写为 [to]。
///
/// 只在**文件名边界**上替换：前后不能紧邻文件名合法字符（字母/数字/./_/-），
/// 否则 `a.jpg` 会误伤 `ba.jpg` / `a.jpg.bak` 这类名字。覆盖
/// `src="a.jpg"`、`[sound:a.jpg]`、`url(a.jpg)` 等全部引用形态（它们的边界
/// 字符都不在文件名字符集里）。
String rewriteMediaReferences(String text, String from, String to) {
  if (from == to || !text.contains(from)) return text;
  final RegExp pattern = RegExp(
    '(?<![A-Za-z0-9._-])${RegExp.escape(from)}(?![A-Za-z0-9._-])',
  );
  return text.replaceAll(pattern, to);
}

/// 周期去重的到期判定（默认每 7 天）。[lastRunMs] null = 从未跑过 → 到期。
bool shouldRunPeriodicMediaDedup({
  required int? lastRunMs,
  required int nowMs,
  Duration interval = const Duration(days: 7),
}) {
  if (lastRunMs == null) return true;
  return nowMs - lastRunMs >= interval.inMilliseconds;
}

/// 一轮去重的结果汇总（UI 报告 + 日志）。
class AnkiMediaDedupReport {
  const AnkiMediaDedupReport({
    required this.dryRun,
    required this.groupCount,
    required this.duplicatesRemoved,
    required this.bytesSaved,
    required this.notesRewritten,
    required this.modelsRewritten,
    required this.skipped,
  });

  /// true = 只扫描规划，没有改写/删除任何东西。
  final bool dryRun;

  /// 重复组数（每组 ≥2 个字节相同的文件）。
  final int groupCount;

  /// 实际删除（dryRun 时 = 将会删除）的多余副本数。
  final int duplicatesRemoved;

  /// 删除副本释放（dryRun 时 = 将会释放）的字节数。
  final int bytesSaved;

  /// 引用被改写的笔记数（去重计数）。
  final int notesRewritten;

  /// 模板/styling 被改写的 note type 数。
  final int modelsRewritten;

  /// 因引用清不干净等原因跳过删除的副本数（宁可留着也不冒险）。
  final int skipped;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dryRun': dryRun,
        'groupCount': groupCount,
        'duplicatesRemoved': duplicatesRemoved,
        'bytesSaved': bytesSaved,
        'notesRewritten': notesRewritten,
        'modelsRewritten': modelsRewritten,
        'skipped': skipped,
      };
}
