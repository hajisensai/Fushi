/// 冷启动阶段计时：从 `main()` 入口到主窗显示之间每一段各花了多少毫秒。
///
/// 只有主入口调 [begin]；弹窗词典 / 悬浮词典入口不调，[mark] 在那边是空操作。
/// 主窗显示后 [seal] 一次，之后的 [mark] 不再记，结果经 [describe] 写进诊断日志
/// （随反馈上传），用户报「启动慢」时能直接读出慢在哪一段。
class StartupTimeline {
  StartupTimeline._();

  static final Stopwatch _watch = Stopwatch();
  static final List<StartupMark> _marks = <StartupMark>[];
  static DateTime? _startedAt;
  static bool _sealed = false;
  static NativeStartupTrace? _native;

  /// `main()` 的第一条语句调用。重复调用无效。
  static void begin() {
    if (_watch.isRunning || _sealed) return;
    _startedAt = DateTime.now();
    _watch.start();
  }

  /// 记「[phase] 这一段刚结束」。
  static void mark(String phase) {
    if (!_watch.isRunning || _sealed) return;
    _marks.add(StartupMark(phase, _watch.elapsedMicroseconds));
  }

  /// 停止记录并返回可读结果；没 [begin] 过或已经 seal 过返回 null。
  ///
  /// [native] 是原生侧经 `app.fushi.reader/startup_trace` 报上来的那一段（进程创建到 Dart
  /// `main()` 之前），没实现该通道的平台传 null。
  static String? seal({NativeStartupTrace? native}) {
    if (!_watch.isRunning || _sealed) return null;
    _sealed = true;
    _watch.stop();
    _native = native;
    return describe();
  }

  static List<StartupMark> get marks => List<StartupMark>.unmodifiable(_marks);

  /// `total=1234ms start=<墙钟> | phase=12 | phase=340 | …`，每段是相对上一个标记的毫秒数。
  static String describe() {
    final StringBuffer out = StringBuffer();
    final int dartUs = _marks.isEmpty ? 0 : _marks.last.elapsedMicros;
    final DateTime? startedAt = _startedAt;
    final NativeStartupTrace? native = _native;
    if (native != null && startedAt != null) {
      // 进程创建 → Dart main()：原生各段 + 最后一个原生标记到 main() 的空档
      // （引擎起 Dart VM / 装载 AOT 快照，不在 runner 代码里）。
      final int preDartUs =
          startedAt.microsecondsSinceEpoch - native.processStartMicros;
      out.write(
        'total=${((preDartUs + dartUs) / 1000).round()}ms '
        'pre-dart=${(preDartUs / 1000).round()}ms '
        'dart=${(dartUs / 1000).round()}ms',
      );
      out.write(' start=${startedAt.toIso8601String()} | native[');
      int previousNativeUs = native.processStartMicros;
      for (final StartupMark mark in native.marks) {
        final int deltaUs = mark.elapsedMicros - previousNativeUs;
        previousNativeUs = mark.elapsedMicros;
        out.write('${mark.phase}=${(deltaUs / 1000).round()} ');
      }
      out.write(
        'to-dart-main='
        '${((startedAt.microsecondsSinceEpoch - previousNativeUs) / 1000).round()}]',
      );
    } else {
      out.write('total=${(dartUs / 1000).round()}ms');
      if (startedAt != null) {
        out.write(' start=${startedAt.toIso8601String()}');
      }
    }
    int previousUs = 0;
    for (final StartupMark mark in _marks) {
      final int deltaUs = mark.elapsedMicros - previousUs;
      previousUs = mark.elapsedMicros;
      out.write(' | ${mark.phase}=${(deltaUs / 1000).round()}');
    }
    return out.toString();
  }

  /// 把 [describe] 的一行按段界（` | `）折成每行不超过 [maxLength] 的若干行，给控制台用。
  ///
  /// Android 的 logcat 一条日志只留约 1 KB，整行打出去后半截（`home-build` /
  /// `first-frame-raster` 这些最要看的段）直接被截掉。单段超长时该段独占一行、不拆。
  static List<String> consoleLines(String timeline, {int maxLength = 900}) {
    const String separator = ' | ';
    final List<String> lines = <String>[];
    final StringBuffer current = StringBuffer();
    for (final String segment in timeline.split(separator)) {
      if (current.isNotEmpty &&
          current.length + separator.length + segment.length > maxLength) {
        lines.add(current.toString());
        current.clear();
      }
      if (current.isNotEmpty) current.write(separator);
      current.write(segment);
    }
    if (current.isNotEmpty) lines.add(current.toString());
    return lines;
  }

  /// 仅测试用：清空状态。
  static void debugReset() {
    _watch
      ..stop()
      ..reset();
    _marks.clear();
    _startedAt = null;
    _sealed = false;
    _native = null;
  }
}

/// 原生侧（Windows runner / Android MainActivity / iOS AppDelegate）记下的启动阶段。
///
/// [marks] 里的 [StartupMark.elapsedMicros] 是 **Unix epoch 微秒**（不是相对值），
/// 这样才能和 Dart 侧 `main()` 的墙钟对上。
class NativeStartupTrace {
  const NativeStartupTrace({
    required this.processStartMicros,
    required this.marks,
  });

  /// 解析 `app.fushi.reader/startup_trace` 的 `get` 返回值；形状不对返回 null。
  static NativeStartupTrace? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? processStart = raw['processStartMicros'];
    final Object? rawMarks = raw['marks'];
    if (processStart is! int || processStart <= 0 || rawMarks is! List) {
      return null;
    }
    final List<StartupMark> marks = <StartupMark>[];
    for (final Object? entry in rawMarks) {
      if (entry is! List || entry.length != 2) return null;
      final Object? phase = entry[0];
      final Object? at = entry[1];
      if (phase is! String || at is! int) return null;
      marks.add(StartupMark(phase, at));
    }
    return NativeStartupTrace(processStartMicros: processStart, marks: marks);
  }

  final int processStartMicros;
  final List<StartupMark> marks;
}

class StartupMark {
  const StartupMark(this.phase, this.elapsedMicros);

  final String phase;

  /// Dart 段：自 [StartupTimeline.begin] 起的累计微秒；原生段：Unix epoch 微秒。
  final int elapsedMicros;
}
