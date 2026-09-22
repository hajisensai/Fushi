import 'package:fushi/src/diagnostics/video_diag_log.dart';

/// 一次查词的分阶段计时（形态对齐 `ReaderOpenTrace`，落点换成 [VideoDiagLog]）。
///
/// ## 要回答的问题
///
/// 用户 2026-09-22：「查词为什么卡；小内存模式可以解决（视频卡顿）但是小内存会查词
/// 很慢、会闪」。这两句话指向的是**同一条链路的两端**：
///
/// * 常驻热槽（屏外隐藏的查词 WebView）让查词只需「注入 + renderPopup」，几十毫秒；
///   代价是一个 WebView2 常驻内存、和视频渲染抢 GPU / 显存。
/// * 小内存模式把热槽整个关掉（`DictionaryPopupController.seedWarmSlot` 早退），
///   于是每次查词都要**冷建** InAppWebView：解析约 300KB 内联 HTML/CSS/JS、等
///   `onLoadStop`、全量重发静态设置段，然后才轮到 `renderPopup`。慢就慢在这。
/// * 「闪」则来自冷建太慢撞上 `markPendingReveal` 的 1800ms 兜底定时器——弹窗被
///   强制翻可见时内容还没渲染好，先露一下空壳/占位再重画。
///
/// 这些都是**假设**。本类的意义是把它们变成每一段的真实毫秒数：到底是 FFI 查询慢、
/// 还是 WebView 冷建慢、还是注入慢、还是 JS 渲染慢，以及 reveal 是正常翻的还是被
/// 兜底定时器强制翻的。没有这条流水，只能继续猜。
///
/// ## 阶段
///
/// `begin → span → warm(hit|miss) → search → fill → webview(reuse|create) →
/// loadStop → push → rendered → reveal(normal|forced)`
///
/// 不是每次都全齐：命中热槽就没有 `create`/`loadStop`，空结果直显就没有 `rendered`。
/// 缺哪段本身就是结论，所以 [summary] 按实际到达的阶段输出，不补零。
class LookupPerfTrace {
  LookupPerfTrace({
    required this.term,
    required this.host,
    required this.lowMemory,
  }) : _startedAtMs = VideoDiagLog.instance.uptimeMs;

  /// 当前在途的查词。弹窗 WebView 的阶段（`loadStop` / `push` / `rendered`）发生在
  /// 另一个 State 对象里，拿不到本次 trace 的引用，故走这个进程级游标。
  ///
  /// **已知边界**：嵌套查词（弹窗里再点词）会把游标覆盖成新的一条，旧的那条剩余
  /// 阶段就归不了位。故每一行都带 `term=`——串台时人眼一看便知，不会被静默算进
  /// 错误的账。查词是用户逐次触发的，实践中重叠窗口极短。
  static LookupPerfTrace? current;

  /// 查的词。
  final String term;

  /// 宿主页（`video` / `reader` / `home` …），同一份流水里区分来源。
  final String host;

  /// 触发时的小内存模式状态——这条流水的全部意义就是对照两种模式。
  final bool lowMemory;

  final int _startedAtMs;
  final List<({String stage, int atMs})> _marks =
      <({String stage, int atMs})>[];
  bool _finished = false;

  /// 相对本次查词起点的毫秒数。
  int get elapsedMs => VideoDiagLog.instance.uptimeMs - _startedAtMs;

  List<({String stage, int atMs})> get marks => List.unmodifiable(_marks);

  bool get isFinished => _finished;

  /// 开一条新流水并装上游标。诊断关着时返回 null（调用方一路 `?.`，零成本）。
  static LookupPerfTrace? begin({
    required String term,
    required String host,
    required bool lowMemory,
  }) {
    if (!videoDiagEnabledFor(VideoDiagCategory.lookup, VideoDiagLevel.v)) {
      return null;
    }
    final LookupPerfTrace trace = LookupPerfTrace(
      term: term,
      host: host,
      lowMemory: lowMemory,
    );
    current = trace;
    videoDiag(
      VideoDiagCategory.lookup,
      VideoDiagLevel.v,
      'begin term=${trace._redactedTerm} host=$host low-memory=$lowMemory',
    );
    return trace;
  }

  /// 记一个阶段（同名只记第一次，幂等）。[detail] 是该阶段特有的信息，比如
  /// `warm` 的 `hit`/`miss`、`search` 的命中缓存与否、`push` 的注入字节数。
  void mark(String stage, {String? detail}) {
    if (_finished) return;
    if (_marks.any((m) => m.stage == stage)) return;
    final int atMs = elapsedMs;
    _marks.add((stage: stage, atMs: atMs));
    videoDiag(
      VideoDiagCategory.lookup,
      VideoDiagLevel.debug,
      'stage term=$_redactedTerm $stage@${atMs}ms${detail == null ? '' : ' $detail'}',
    );
  }

  /// 收尾并打一行汇总。[outcome] 形如 `revealed` / `forced-reveal` / `empty` /
  /// `abandoned`。被兜底定时器强制翻可见（用户看到的「闪」）提级到 warn。
  void finish(String outcome) {
    if (_finished) return;
    _finished = true;
    if (identical(current, this)) current = null;
    final bool suspicious = outcome.contains('forced');
    videoDiag(
      VideoDiagCategory.lookup,
      suspicious ? VideoDiagLevel.warn : VideoDiagLevel.info,
      summary(outcome),
    );
  }

  /// 纯函数化的汇总行：各阶段相对**上一阶段**的增量（找瓶颈看这个），末尾给总时长。
  String summary(String outcome) {
    final StringBuffer sb = StringBuffer(
      'done term=$_redactedTerm host=$host low-memory=$lowMemory '
      'outcome=$outcome',
    );
    sb.write(' ${formatDeltas(_marks)}');
    sb.write(' total=${elapsedMs}ms');
    return sb.toString();
  }

  /// 纯函数：阶段表 → `a=+1ms b=+23ms`（相对上一阶段的增量）。
  static String formatDeltas(List<({String stage, int atMs})> marks) {
    final StringBuffer sb = StringBuffer();
    int prev = 0;
    for (final ({String stage, int atMs}) m in marks) {
      if (sb.isNotEmpty) sb.write(' ');
      sb.write('${m.stage}=+${m.atMs - prev}ms');
      prev = m.atMs;
    }
    return sb.toString();
  }

  /// 查询词在日志里截断——诊断日志会被用户导出/上传，整句原文不该无节制外流。
  /// 保留前 8 个字符足以对齐同一次查词的各行。
  String get _redactedTerm => redactTerm(term);

  /// 纯函数：日志用的词形（超长截断 + 压平空白）。
  static String redactTerm(String term, {int maxChars = 8}) {
    final String flat = term.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '(empty)';
    if (flat.length <= maxChars) return flat;
    return '${flat.substring(0, maxChars)}…(${flat.length})';
  }
}
