/// Anki 媒体字节级去重的纯函数层：分组规划、规范名选择、引用改写/探测。
///
/// 范围（用户拍板方案 A）：**默认不跑、手动触发、先出干跑报告让用户确认**；
/// 只删字节完全相同的多余副本——引用全部改指到保留的那一份之后再删，零信息
/// 损失。**绝不重编码/压缩任何文件**（画质一个字节都不动），也不做按年龄的
/// 清理，更没有任何后台自动删除路径。
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

/// 一条「删除某个多余副本」的计划/结果：干跑时 = 将要删，实跑时 = 已删。
///
/// 用户确认弹窗直接渲染这个列表——「删哪些文件、各占多少空间、保留的是哪
/// 一份」三样都在这里，用户点确认前心里有数。
class MediaDedupDeletion {
  const MediaDedupDeletion({
    required this.filename,
    required this.canonical,
    required this.bytes,
  });

  /// 被删除（或将被删除）的多余副本文件名。
  final String filename;

  /// 保留下来的那一份文件名——所有引用都会改指到它。
  final String canonical;

  /// [filename] 占用的字节数（= 释放的空间）。
  final int bytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'filename': filename,
        'canonical': canonical,
        'bytes': bytes,
      };
}

/// 从「文件名 → 内容哈希」+「文件名 → 字节数」规划去重组。
///
/// 分组键是 **(字节数, 内容哈希)** 而不是裸哈希：调用方只对「大小相同的候选」
/// 算哈希，长度本就是判等的一部分；把它显式并进分组键，即使调用方哪天喂进
/// 跨大小的哈希表、或哈希被截断，也不可能把不同长度的文件归成一组。单文件组
/// 不产出。组内与组间均按文件名排序，输出确定性可测。
///
/// [sizes] 必须覆盖 [nameToHash] 的每个键；缺失的条目直接丢弃（宁可不去重，
/// 也不在长度未知的情况下判等）。
List<MediaDedupGroup> planMediaDedupGroups(
  Map<String, String> nameToHash, {
  required Map<String, int> sizes,
}) {
  final Map<String, List<String>> byIdentity = <String, List<String>>{};
  for (final MapEntry<String, String> e in nameToHash.entries) {
    final int? size = sizes[e.key];
    if (size == null) continue;
    byIdentity.putIfAbsent('$size:${e.value}', () => <String>[]).add(e.key);
  }
  final List<MediaDedupGroup> groups = <MediaDedupGroup>[];
  for (final List<String> names in byIdentity.values) {
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

/// 文件名边界安全的引用匹配正则：[filename] 前后都不能紧邻文件名合法字符
/// （字母/数字/`.`/`_`/`-`），否则 `a.jpg` 会误伤 `ba.jpg` / `a.jpg.bak`。
///
/// 覆盖 `src="a.jpg"`、`[sound:a.jpg]`、`url(a.jpg)`、`url("./a.jpg")`、
/// `@import 'a.css'` 等全部引用形态——它们的边界字符（引号/括号/斜杠/冒号/
/// 空白）都不在文件名字符集里。
RegExp mediaReferencePattern(String filename) => RegExp(
      '(?<![A-Za-z0-9._-])${RegExp.escape(filename)}(?![A-Za-z0-9._-])',
    );

/// 把文本（笔记字段 / 卡模板 / styling / 媒体文件正文）里对 [from] 的引用
/// 改写为 [to]。只在文件名边界上替换，见 [mediaReferencePattern]。
String rewriteMediaReferences(String text, String from, String to) {
  if (from == to || !text.contains(from)) return text;
  return text.replaceAll(mediaReferencePattern(from), to);
}

/// [text] 里是否存在对 [filename] 的引用（边界安全，与 [rewriteMediaReferences]
/// 同一判据——凡是会被改写的形态都能被探到）。
bool textReferencesMediaName(String text, String filename) =>
    text.contains(filename) && mediaReferencePattern(filename).hasMatch(text);

/// 会在**媒体文件内部**携带对其它媒体文件引用的文本格式。
///
/// 必须扫这一层的根因：本模块优先保留 `_` 前缀的模板资产（见
/// [chooseCanonicalMediaName]），而 `_x.css` 里的 `url(_font.woff2)` /
/// `@import` 既不在笔记字段里、也不在卡模板/styling 里——只扫那三处会判定
/// 「无引用」而把仍在用的字体静默删掉。
///
/// 只列真正会引用别的资源的文本格式：图片/音频/字体不引用别人，无需读盘；
/// 这个集合直接决定去重要多读多少字节。
const Set<String> kReferencingMediaExtensions = <String>{
  'css',
  'less',
  'scss',
  'js',
  'mjs',
  'html',
  'htm',
  'xhtml',
  'svg',
};

/// [filename] 是否属于 [kReferencingMediaExtensions]（大小写不敏感）。
bool isReferencingMediaFile(String filename) {
  final int dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return false;
  return kReferencingMediaExtensions
      .contains(filename.substring(dot + 1).toLowerCase());
}

/// 真删/干跑的 resolving 阶段一次处理多少个副本。
///
/// 每个副本的判定（查引用、拉字段）与落地（改字段、复核、删文件）都被打成
/// AnkiConnect `multi` 批量请求，所以这个数字直接决定「往返数 ≈ 副本数 ÷ 它」。
///
/// 取 50 的取舍：
/// - **收益**：AnkiConnect 的 HTTP 服务是 25 ms QTimer 协作轮询、每 tick 只
///   accept 一条连接、无 keep-alive（见 `AnkiConnectService.kMultiBatchSize`
///   的注释），每个请求的地板成本与请求大小无关。940 个副本从 ~4700 次往返降
///   到 ~95 次，量级差别就是这个常数。
/// - **代价**：**取消粒度变粗**——取消只在批边界生效，一批之内不可中断。50 个
///   副本一批 = 5 次往返 + Anki 主线程上约 100 次全库检索，取消延迟在秒级而不
///   是瞬时。再调大就该让用户觉得「取消按钮没反应」了。
const int kAnkiMediaDedupBatchSize = 50;

/// 去重进行到哪个阶段（进度回调用）。
///
/// 940 个副本的真删 = 数千次串行 AnkiConnect 请求，分钟级长任务；没有阶段化
/// 进度，UI 只能给用户一个「假死」。阶段顺序固定：scanning → hashing →
/// resolving。
enum AnkiMediaDedupStage {
  /// 枚举媒体目录、记录每个文件的字节数。
  scanning,

  /// 对「大小撞车」的候选算全文件哈希（读文件内容）。
  hashing,

  /// 逐个副本判定引用并（真跑时）改写/删除。
  resolving,
}

/// 一次进度快照。[total] == 0 表示该阶段总量未知（只报「活着 + 已处理数」）。
class AnkiMediaDedupProgress {
  const AnkiMediaDedupProgress({
    required this.stage,
    this.done = 0,
    this.total = 0,
    this.currentFile,
    this.bytesFreed = 0,
  });

  final AnkiMediaDedupStage stage;

  /// 当前阶段已完成的条目数。
  final int done;

  /// 当前阶段总条目数（0 = 未知）。
  final int total;

  /// 正在处理的文件名（hashing / resolving 阶段有值）。
  final String? currentFile;

  /// 已释放（干跑 = 将释放）的累计字节数。
  final int bytesFreed;
}

/// 进度回调：每个文件/副本边界同步触发一次，实现必须轻量（UI 侧只该更新一个
/// ValueNotifier）。
typedef AnkiMediaDedupOnProgress = void Function(
    AnkiMediaDedupProgress progress);

/// 一轮去重的结果汇总（UI 报告 + 日志）。
class AnkiMediaDedupReport {
  const AnkiMediaDedupReport({
    required this.dryRun,
    required this.groupCount,
    required this.deletions,
    required this.notesRewritten,
    required this.modelsRewritten,
    required this.skipped,
    this.cancelled = false,
  });

  /// true = 只扫描规划，没有改写/删除任何东西。
  final bool dryRun;

  /// 重复组数（每组 ≥2 个字节相同的文件）。
  final int groupCount;

  /// 实际删除（[dryRun] 时 = 将会删除）的多余副本逐条明细。
  final List<MediaDedupDeletion> deletions;

  /// 引用被改写的笔记数（去重计数）。
  final int notesRewritten;

  /// 模板/styling 被改写的 note type 数。
  final int modelsRewritten;

  /// 因引用清不干净等原因跳过删除的副本数（宁可留着也不冒险）。
  final int skipped;

  /// true = 用户中途取消，数字只统计取消前已完成的部分；已做的改写/删除
  /// 保留（引用永远先改指保留份，任何时刻停下都不会出现悬空引用）。
  final bool cancelled;

  /// 实际删除（[dryRun] 时 = 将会删除）的多余副本数。
  int get duplicatesRemoved => deletions.length;

  /// 删除副本释放（[dryRun] 时 = 将会释放）的字节数。
  int get bytesSaved =>
      deletions.fold<int>(0, (int sum, MediaDedupDeletion d) => sum + d.bytes);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dryRun': dryRun,
        'groupCount': groupCount,
        'duplicatesRemoved': duplicatesRemoved,
        'bytesSaved': bytesSaved,
        'notesRewritten': notesRewritten,
        'modelsRewritten': modelsRewritten,
        'skipped': skipped,
        'cancelled': cancelled,
        'deletions': deletions
            .map((MediaDedupDeletion d) => d.toJson())
            .toList(growable: false),
      };
}
