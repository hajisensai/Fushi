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

  factory MediaDedupDeletion.fromJson(Map<String, dynamic> json) =>
      MediaDedupDeletion(
        filename: json['filename']?.toString() ?? '',
        canonical: json['canonical']?.toString() ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );

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
/// 每批的判定（拉命中笔记的字段）与落地（改字段、复核、删文件）都被打成
/// AnkiConnect 批量请求，所以这个数字直接决定「往返数 ≈ 副本数 ÷ 它」。
///
/// 取 50 的取舍：
/// - **收益**：AnkiConnect 的 HTTP 服务是 25 ms QTimer 协作轮询、每 tick 只
///   accept 一条连接、无 keep-alive（见 `AnkiConnectService.kMultiBatchSize`
///   的注释），每个请求的地板成本与请求大小无关。940 个副本从 ~4700 次往返降
///   到 ~95 次，量级差别就是这个常数。
/// - **代价**：**取消粒度变粗**——取消只在批边界生效，一批之内不可中断。
///
/// 一批里**没有**按文件名的全库检索：谁引用了哪个副本查的是规划前建好的本地
/// 对照表（见 [MediaNameMatcher]），复核也只发一条限定在「本轮改过的笔记」上
/// 的检索（见 [mediaDedupRecheckQuery]）。BUG-2824 之前每个副本要两次全库
/// `findNotes "<文件名>"`，大库上单次 4 秒以上，一批 100 次必然超时。
const int kAnkiMediaDedupBatchSize = 50;

/// 建本地引用对照表时一次 `notesInfo` 读多少条笔记。
///
/// 释义字段十万字级的库里，一条笔记的字段正文就有上百 KB；100 条一批让单次
/// 响应停在 10 MB 量级，Anki 主线程每次只被占几秒，进度也能持续推进。
const int kAnkiMediaDedupIndexBatchSize = 100;

/// 在笔记字段正文里找出引用了哪些媒体文件名——本地对照表的匹配核心。
///
/// **语义与 Anki 的 `findNotes "<文件名>"` 对齐**：大小写不敏感的朴素子串，
/// 不判文件名边界。宽于真实引用是刻意的：命中却改写不动（引用形态不认识、或
/// 恰是别的更长文件名的子串）的笔记会让这份副本整个跳过——与旧的全库检索
/// 同一个保守口径，只是不再让 Anki 对每个文件名扫一遍全库。
///
/// 多模式匹配的做法：每个文件名都以它的扩展名（最后一个 `.` 起的后缀）结尾，
/// 所以只需在正文里定位各扩展名的出现处，再按「同扩展名的文件名有哪些长度」
/// 回切子串查表。成本 ≈ 扩展名种类 × 正文长度，与文件名个数（实测上万）无关。
/// 没有 `.` 的文件名没有锚点，逐个 `contains`（实际极少）。
class MediaNameMatcher {
  MediaNameMatcher(Iterable<String> names) {
    for (final String name in names) {
      final String lower = name.toLowerCase();
      if (lower.isEmpty) continue;
      (_byLower[lower] ??= <String>[]).add(name);
      final int dot = lower.lastIndexOf('.');
      if (dot < 0) {
        _unanchored.add(lower);
        continue;
      }
      (_lengthsBySuffix[lower.substring(dot)] ??= <int>{}).add(lower.length);
    }
  }

  /// 小写文件名 → 原文件名（大小写不同的同名文件在大小写敏感的文件系统上
  /// 可以并存，都要报出来）。
  final Map<String, List<String>> _byLower = <String, List<String>>{};

  /// 小写扩展名（含 `.`）→ 以它结尾的文件名的全部长度。
  final Map<String, Set<int>> _lengthsBySuffix = <String, Set<int>>{};

  /// 没有扩展名、无法锚定的文件名（小写）。
  final Set<String> _unanchored = <String>{};

  /// [text] 里出现过的全部文件名（原大小写）。
  Set<String> namesIn(String text) {
    final Set<String> hits = <String>{};
    if (text.isEmpty) return hits;
    final String lower = text.toLowerCase();
    _lengthsBySuffix.forEach((String suffix, Set<int> lengths) {
      for (
        int at = lower.indexOf(suffix);
        at >= 0;
        at = lower.indexOf(suffix, at + 1)
      ) {
        _collectEndingAt(lower, at + suffix.length, lengths, hits);
      }
    });
    for (final String name in _unanchored) {
      if (lower.contains(name)) hits.addAll(_byLower[name]!);
    }
    return hits;
  }

  /// 一条笔记全部字段里出现过的文件名。
  Set<String> namesInAll(Iterable<String> texts) => <String>{
    for (final String text in texts) ...namesIn(text),
  };

  void _collectEndingAt(
    String lower,
    int end,
    Set<int> lengths,
    Set<String> hits,
  ) {
    for (final int length in lengths) {
      final int start = end - length;
      if (start < 0) continue;
      final List<String>? names = _byLower[lower.substring(start, end)];
      if (names != null) hits.addAll(names);
    }
  }
}

/// 删除前复核要回看多少天内被改过的笔记（Anki `edited:N`）。
///
/// 本地对照表是本轮开头的快照；之后能变的只有「本轮期间被改过的笔记」。
/// `edited:1` 只到今天的日界线，任务跨过日界线就会漏掉日界线前的改动，所以
/// 在已过天数上再多看一天。
int mediaDedupRecheckEditedDays(Duration sinceIndexed) =>
    sinceIndexed.inDays + 2;

/// 删除前的复核检索式：在「本轮期间改过的笔记 + 本批写过的笔记」里找
/// 仍然包含 [names] 任一文件名的笔记。
///
/// 一批只发**一条**检索。`edited:` 只比修改时间，未改过的笔记不必做文本匹配，
/// 代价远小于一次全库文本检索。显式带上 [noteIds]：写失败、或 Anki 没有刷新
/// 修改时间的笔记也照样被复核到，不依赖 `edited:` 的实现细节。
String mediaDedupRecheckQuery(
  Iterable<String> names, {
  required int editedDays,
  Iterable<int> noteIds = const <int>[],
}) {
  final List<int> ids = noteIds.toList()..sort();
  final String scope = ids.isEmpty
      ? 'edited:$editedDays'
      : '(edited:$editedDays OR nid:${ids.join(',')})';
  final String terms = names.map((String n) => '"$n"').join(' OR ');
  return '$scope ($terms)';
}

/// 去重进行到哪个阶段（进度回调用）。
///
/// 940 个副本的真删 = 数千次串行 AnkiConnect 请求，分钟级长任务；没有阶段化
/// 进度，UI 只能给用户一个「假死」。阶段顺序固定：scanning → hashing →
/// indexing → resolving。
enum AnkiMediaDedupStage {
  /// 枚举媒体目录、记录每个文件的字节数。
  scanning,

  /// 对「大小撞车」的候选算全文件哈希（读文件内容）。
  hashing,

  /// 分批读出全部笔记字段，建「文件名 → 引用它的笔记」本地对照表。
  /// [AnkiMediaDedupProgress.done] / [AnkiMediaDedupProgress.total] 按笔记计。
  indexing,

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

  /// 从 [toJson] 的产物还原（互联「制卡到已配对设备」时主机端跑完把报告发回
  /// 客户端）。`duplicatesRemoved` / `bytesSaved` 是 [deletions] 的派生值，
  /// 这里**不读**它们——两份数字各自还原迟早对不上，派生值只该有一个来源。
  factory AnkiMediaDedupReport.fromJson(Map<String, dynamic> json) =>
      AnkiMediaDedupReport(
        dryRun: json['dryRun'] == true,
        groupCount: (json['groupCount'] as num?)?.toInt() ?? 0,
        deletions: ((json['deletions'] as List?) ?? const <dynamic>[])
            .map((dynamic e) =>
                MediaDedupDeletion.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
        notesRewritten: (json['notesRewritten'] as num?)?.toInt() ?? 0,
        modelsRewritten: (json['modelsRewritten'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        cancelled: json['cancelled'] == true,
      );

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
