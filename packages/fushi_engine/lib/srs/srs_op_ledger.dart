/// SRS 重活账本（BUG-4075 取证）：内核命令、srs.db 上的 Drift 查询、Dart 侧整库装载各记一笔
/// 次数 / 用时 / 交回字节，内存采样（`PreviousExitLog.startMemorySampling`）每 30 s 取走一个窗口的
/// 汇总，并列出正在跑、已超过 [kSrsOpBusyAfter] 的操作。
///
/// 为什么要它：移动端「停在复习页不动、内存 3 分钟涨到 3 GB 闪退」时，SRS 原生计数（库数 / 连接数 /
/// SQLite 堆）全程不变——经 mmap 读的页不进 SQLite 页缓存，那个读数看不出库是不是一直在被大块地读。
/// 这里按操作名把「谁在跑、跑了几遍、读回多少」直接记下来，下一份崩溃报告就能点名。
///
/// 只在当前 isolate 记（store、Drift 连接、页面 provider 都在 UI isolate）；开销是每次操作两次
/// 时钟读 + 一次 Map 更新，查询的字节数按结果行逐值累加（与解码同量级，取证期间接受）。
library;

import 'dart:math' as math;

/// 单次操作超过这个时长或交回超过 [kSrsOpHeavyBytes]：另记一条诊断日志（[SrsOpLedger.onHeavy]）。
const Duration kSrsOpHeavyAfter = Duration(seconds: 3);

/// 单次操作交回的字节超过这个数：另记一条诊断日志。
const int kSrsOpHeavyBytes = 32 << 20;

/// 正在跑的操作超过这个时长才进汇总的 `busy=` 段。
const Duration kSrsOpBusyAfter = Duration(seconds: 2);

/// 汇总里最多列几项（按总用时排序）。
const int kSrsOpSummaryTop = 6;

final class _OpStat {
  int count = 0;
  int totalUs = 0;
  int maxUs = 0;
  int bytes = 0;
  int rows = 0;
}

/// 进程级账本（静态）。
abstract final class SrsOpLedger {
  static final Stopwatch _clock = Stopwatch()..start();
  static Map<String, _OpStat> _window = <String, _OpStat>{};
  static final Map<int, (String, int)> _inflight = <int, (String, int)>{};
  static final Map<String, int> _marks = <String, int>{};
  static int _next = 0;

  /// 单次重操作（超过 [kSrsOpHeavyAfter] / [kSrsOpHeavyBytes]）的回调：app 接到诊断日志。
  static void Function(String line)? onHeavy;

  /// 开始一项操作，返回给 [end] 的令牌。
  static int begin(String op) {
    final int token = _next++;
    _inflight[token] = (op, _clock.elapsedMicroseconds);
    return token;
  }

  /// 结束 [begin] 开的操作；[bytes] / [rows] 是交回的数据量（不知道给 0）。
  static void end(int token, {int bytes = 0, int rows = 0}) {
    final (String, int)? started = _inflight.remove(token);
    if (started == null) return;
    final (String op, int startUs) = started;
    final int us = _clock.elapsedMicroseconds - startUs;
    final _OpStat s = _window.putIfAbsent(op, _OpStat.new)
      ..count += 1
      ..totalUs += us
      ..bytes += bytes
      ..rows += rows;
    s.maxUs = math.max(s.maxUs, us);
    if (us >= kSrsOpHeavyAfter.inMicroseconds || bytes >= kSrsOpHeavyBytes) {
      final void Function(String line)? sink = onHeavy;
      if (sink != null) {
        try {
          sink(
            '$op ${_ms(us)} ${_mb(bytes)}'
            '${rows > 0 ? ' rows=$rows' : ''}',
          );
        } on Object {
          // 取证不能反过来变成故障源。
        }
      }
    }
  }

  /// 撤销 [begin] 开的操作、不记账（这次操作改由别的入口记，免得重复）。
  static void cancel(int token) => _inflight.remove(token);

  /// 包一段异步操作：[measure] 从结果算 (字节, 行数)。抛异常也记（用时照算，数据量 0）。
  static Future<T> track<T>(
    String op,
    Future<T> Function() body, {
    (int, int) Function(T result)? measure,
  }) async {
    final int token = begin(op);
    T result;
    try {
      result = await body();
    } on Object {
      end(token);
      rethrow;
    }
    int bytes = 0;
    int rows = 0;
    if (measure != null) {
      try {
        (bytes, rows) = measure(result);
      } on Object {
        // 量不出来就不记数据量。
      }
    }
    end(token, bytes: bytes, rows: rows);
    return result;
  }

  /// 记一次事件（不计时，例如修订号 +1）。
  static void mark(String event) =>
      _marks.update(event, (int n) => n + 1, ifAbsent: () => 1);

  /// 取走当前窗口的汇总并清零：`srsops=[op N× 总ms max=ms 字节 …; …] marks=[rev:local+1 rev:pulled+2] busy=[op 12.3s]`；
  /// 窗口里什么都没有时为 null。正在跑的操作不清（跨窗口照样列在 busy 里）。
  static String? takeSummary() {
    final Map<String, _OpStat> window = _window;
    _window = <String, _OpStat>{};
    final Map<String, int> marks = Map<String, int>.of(_marks);
    _marks.clear();
    final int nowUs = _clock.elapsedMicroseconds;
    final List<(String, int)> busy = <(String, int)>[
      for (final (String op, int startUs) in _inflight.values)
        if (nowUs - startUs >= kSrsOpBusyAfter.inMicroseconds)
          (op, nowUs - startUs),
    ]..sort(((String, int) a, (String, int) b) => b.$2.compareTo(a.$2));
    if (window.isEmpty && marks.isEmpty && busy.isEmpty) return null;
    final List<MapEntry<String, _OpStat>> top = window.entries.toList()
      ..sort(
        (MapEntry<String, _OpStat> a, MapEntry<String, _OpStat> b) =>
            b.value.totalUs.compareTo(a.value.totalUs),
      );
    final StringBuffer b = StringBuffer();
    if (top.isNotEmpty) {
      b.write('srsops=[');
      b.write(
        top
            .take(kSrsOpSummaryTop)
            .map((MapEntry<String, _OpStat> e) {
              final _OpStat s = e.value;
              return '${e.key} ${s.count}x ${_ms(s.totalUs)}'
                  '${s.count > 1 ? ' max=${_ms(s.maxUs)}' : ''}'
                  '${s.bytes > 0 ? ' ${_mb(s.bytes)}' : ''}'
                  '${s.rows > 0 ? ' rows=${s.rows}' : ''}';
            })
            .join('; '),
      );
      if (top.length > kSrsOpSummaryTop) {
        b.write('; +${top.length - kSrsOpSummaryTop}');
      }
      b.write(']');
    }
    if (marks.isNotEmpty) {
      if (b.isNotEmpty) b.write(' ');
      b.write(
        'marks=[${marks.entries.map((MapEntry<String, int> e) => '${e.key}+${e.value}').join(' ')}]',
      );
    }
    if (busy.isNotEmpty) {
      if (b.isNotEmpty) b.write(' ');
      b.write(
        'busy=[${busy.take(kSrsOpSummaryTop).map(((String, int) e) => '${e.$1} ${(e.$2 / 1e6).toStringAsFixed(1)}s').join('; ')}]',
      );
    }
    return b.toString();
  }

  /// 测试收尾：清空全部状态。
  static void reset() {
    _window = <String, _OpStat>{};
    _inflight.clear();
    _marks.clear();
    onHeavy = null;
  }

  static String _ms(int us) => '${(us / 1000).round()}ms';

  static String _mb(int bytes) => bytes >= 1 << 20
      ? '${(bytes / (1 << 20)).toStringAsFixed(1)}MB'
      : '${(bytes / 1024).ceil()}KB';
}

/// 一条 SQL 的账本名：`sql:<动词> <首个表>`（如 `sql:SELECT <表>`、`sql:PRAGMA`），不带参数与字面量。
///
/// 表名只从经过 srs.db 连接的语句文本里取，本文件不写任何 SRS 表名（表名与 SQL 归 SrsDatabase /
/// SrsDbStore，见 `fushi/test/build/srs_store_ownership_guard_test.dart`）。
String srsSqlLedgerName(String statement) {
  final String s = statement.trimLeft();
  final RegExpMatch? verb = RegExp(r'^(\w+)').firstMatch(s);
  final RegExpMatch? table = RegExp(
    r'\b(?:FROM|INTO|UPDATE)\s+"?(\w+)',
    caseSensitive: false,
  ).firstMatch(s);
  return 'sql:${(verb?.group(1) ?? '?').toUpperCase()}'
      '${table == null ? '' : ' ${table.group(1)}'}';
}
