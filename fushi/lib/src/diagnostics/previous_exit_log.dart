// 上次进程「怎么没的」取证：启动时把各平台留下的原生退出 / 崩溃记录摘要折进
// [ErrorLogService]（`log` 落盘，随反馈日志上传）。
//
// 为什么要它：分诊里约一半闪退反馈卡在「Dart 日志无栈」——进程在原生侧崩溃、被系统
// 按内存杀掉、或在裸 Java 线程上抛了未捕获异常时，Dart 的 `FlutterError.onError` /
// `runZonedGuarded` 一概接不到，错误日志里只剩下一次冷启动。这里把系统本来就记着的
// 证据读回来：
//
// - 全平台：本模块自己的会话标记（`session_marker.json`）。启动时写入、每次生命周期
//   变化同步覆写、正常退出（`exitApp` / `detached`）时标 clean；下次启动发现上次没
//   标 clean，就记一条「上次未正常退出」+ 最后的生命周期状态与内存压力时刻——API < 30
//   的 Android（没有 ApplicationExitInfo）靠的就是它。
// - Android 11+：`ActivityManager.getHistoricalProcessExitReasons`（原生
//   `ProcessExitChannel.java`）：reason / description / importance / pss / rss / 时间，
//   native crash 与 ANR 附 trace 摘要；外加进程级 `onTrimMemory` 级别记录。
// - Windows：`crash_dump.cpp` 的未处理异常过滤器在写 minidump 的同时追加一行
//   `crash_summary.log`（异常码、模块+偏移、线程、x64 栈前若干帧）。不上传 minidump。
// - macOS：`~/Library/Logs/DiagnosticReports/<进程名>-*.ips`（系统崩溃报告）。
// - iOS：MetricKit `MXCrashDiagnostic`（`AppDelegate.swift` 订阅，JSON 落
//   `Documents/metrickit/`）。
//
// 隐私：所有摘要都过 [redactExitReportPaths]，把路径里的用户名换成 `<user>`；不带
// 完整 dump / 完整 tombstone，只带有限长度的摘要。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 日志 source 标签（不是 i18n key）。
const String kPreviousExitUncleanSource = 'Process.previousExitUnclean';
const String kAndroidExitInfoSource = 'Process.androidExitInfo';
const String kAndroidTrimMemorySource = 'Process.androidTrimMemory';
const String kWindowsCrashSummarySource = 'Process.windowsCrashSummary';
const String kMacCrashReportSource = 'Process.macCrashReport';
const String kIosCrashDiagnosticSource = 'Process.iosCrashDiagnostic';
const String kMemoryPressureSource = 'Process.memoryPressure';

/// 单条摘要的字符上限（摘要不是原文，够定位即可）。
const int kExitSummaryMaxChars = 4000;

/// 首次启用时只回看这么久以内的系统记录，免得把几个月前的旧崩溃全倒进日志。
const Duration kExitReportLookback = Duration(days: 7);

/// 单次启动最多折入的系统崩溃记录条数（每个来源）。
const int kExitReportMaxPerSource = 5;

/// 把路径里的用户名脱敏：`C:\Users\<名>`、`/Users/<名>`、`/home/<名>` → `<user>`。
String redactExitReportPaths(String text) => text
    .replaceAllMapped(
      RegExp(r'([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\s"]+', caseSensitive: false),
      (Match m) => '${m.group(1)}<user>',
    )
    .replaceAllMapped(
      RegExp(r'(/(?:Users|home)/)[^/\s"]+'),
      (Match m) => '${m.group(1)}<user>',
    );

String _cap(String text, [int max = kExitSummaryMaxChars]) => text.length <= max
    ? text
    : '${text.substring(0, max)}…[truncated ${text.length - max} chars]';

String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

/// 上次进程「怎么没的」的分类（[classifyPreviousExit] 的结论）。声明顺序就是优先级：
/// 同一次启动收到多份证据时取最靠前的那种——平台给的明确原因（崩溃 / ANR / 内存 /
/// 用户强停）压过会话标记的推断（[unexpected] / [backgroundReclaim]）。
enum PreviousExitKind {
  /// 原生层崩溃：Android `CRASH_NATIVE`、Windows 未处理异常（`crash_summary.log`）。
  nativeCrash,

  /// 崩溃：Android `CRASH` / `INITIALIZATION_FAILURE`、macOS `.ips`、iOS MetricKit。
  crash,

  /// 应用无响应被系统结束（Android `ANR`）。
  anr,

  /// 被系统按内存 / 资源回收（Android `LOW_MEMORY` / `EXCESSIVE_RESOURCE_USAGE`）。
  memoryKill,

  /// 用户主动强停（Android `USER_REQUESTED` / `USER_STOPPED`：设置里强行停止等）。
  userStopped,

  /// 停在前台时没了、平台没给原因（会话标记推断，疑似闪退 / 卡死后被强杀）。
  unexpected,

  /// 停在后台时没了、平台没给原因（多半是系统回收；iOS / Android 划掉后台也在这里）。
  backgroundReclaim;

  /// 这种退出值得问用户要不要把日志发给开发者。内存回收只在发生在前台时算（用户眼里
  /// 就是闪退，且多半是 Fushi 自己吃内存）；用户强停与后台回收不算。
  bool worthReporting({required bool foreground}) => switch (this) {
    nativeCrash || crash || anr || unexpected => true,
    memoryKill => foreground,
    userStopped || backgroundReclaim => false,
  };
}

/// 一条要折进错误日志的摘要。[severe] 为 true 走 `log`（落盘、用户可见），否则走
/// `logDiagnostic`（本次运行的诊断段，同样随反馈上传）。
///
/// [kind] 非空 = 这条证据说明了上次进程怎么没的（[classifyPreviousExit] 据此判定）；
/// 内存 trim 记录、活动面包屑这类旁证为 null。
@immutable
class ExitReportEntry {
  const ExitReportEntry(
    this.source,
    this.text, {
    required this.severe,
    this.kind,
    this.foreground = true,
    this.duringStartup = false,
    this.atMs,
  });

  final String source;
  final String text;
  final bool severe;
  final PreviousExitKind? kind;

  /// 没的时候在不在前台（平台没说时按 true：崩溃本身不看前后台）。
  final bool foreground;

  /// 上次进程死在启动初始化完成之前（会话标记推断）。
  final bool duringStartup;

  /// 证据里的退出时刻（毫秒）；拿不到为 null。
  final int? atMs;
}

// ───────────────────────── 会话标记（全平台） ─────────────────────────

/// 上次会话标记里读出来的状态。
@immutable
class PreviousSession {
  const PreviousSession({
    required this.pid,
    required this.startedAt,
    required this.version,
    required this.lifecycle,
    required this.lifecycleAt,
    required this.clean,
    this.initialised = true,
    this.awaitingCrashReportDecision = false,
    this.memoryPressureAt,
    this.memoryPressureCount = 0,
  });

  final int pid;
  final int startedAt;
  final String version;
  final String lifecycle;
  final int lifecycleAt;
  final bool clean;

  /// 上次进程走到过「初始化完成、首页出来」（[SessionMarker.recordInitialised]）。旧版本
  /// 写的标记没有这个字段，按 true 处理（不知道就不当成启动即闪退）。
  final bool initialised;

  /// 上次进程没的时候停在启动前的闪退报告提示上、等用户选择
  /// （[SessionMarker.recordAwaitingCrashReportDecision]）：那时初始化还没开始跑，
  /// 没了多半是用户直接关掉 / 杀掉了 app，不是又一次启动即闪退。
  final bool awaitingCrashReportDecision;
  final int? memoryPressureAt;
  final int memoryPressureCount;

  /// 最后停在前台（resumed / inactive / 还在启动）时没了——比后台被回收可疑得多。
  bool get diedInForeground =>
      lifecycle == 'resumed' ||
      lifecycle == 'inactive' ||
      lifecycle == 'launching';

  static PreviousSession? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      int asInt(Object? v) => v is int ? v : 0;
      return PreviousSession(
        pid: asInt(decoded['pid']),
        startedAt: asInt(decoded['startedAt']),
        version: '${decoded['version'] ?? ''}',
        lifecycle: '${decoded['lifecycle'] ?? 'unknown'}',
        lifecycleAt: asInt(decoded['lifecycleAt']),
        clean: decoded['clean'] == true,
        initialised: decoded['initialised'] != false,
        awaitingCrashReportDecision:
            decoded['awaitingCrashReportDecision'] == true,
        memoryPressureAt: decoded['memoryPressureAt'] is int
            ? decoded['memoryPressureAt'] as int
            : null,
        memoryPressureCount: asInt(decoded['memoryPressureCount']),
      );
    } on FormatException {
      return null;
    }
  }
}

/// 会话标记文件：每次状态变化**同步**整份覆写（几十字节），进程下一刻被杀也已落盘。
class SessionMarker {
  SessionMarker(this.file, {required this.pid, required this.version});

  final File file;
  final int pid;
  final String version;

  int _startedAt = 0;
  String _lifecycle = 'launching';
  int _lifecycleAt = 0;
  bool _clean = false;
  bool _initialised = false;
  bool _awaitingCrashReportDecision = false;
  int? _memoryPressureAt;
  int _memoryPressureCount = 0;

  /// 读出上次会话（没有 / 损坏返回 null），然后写入本次会话的初始标记。
  PreviousSession? start({required int nowMs}) {
    PreviousSession? previous;
    try {
      if (file.existsSync()) {
        previous = PreviousSession.tryParse(file.readAsStringSync());
      }
    } on FileSystemException {
      previous = null;
    }
    _startedAt = nowMs;
    _lifecycleAt = nowMs;
    _write();
    return previous;
  }

  void recordLifecycle(String state, {required int nowMs}) {
    _lifecycle = state;
    _lifecycleAt = nowMs;
    if (state == 'detached') _clean = true;
    _write();
  }

  /// 本次启动初始化完成（首页出来了）：之后再没了就不算「启动即闪退」。
  void recordInitialised() {
    if (_initialised) return;
    _initialised = true;
    _write();
  }

  /// 启动前的闪退报告提示出现（true）/ 用户选完（false）。停在提示上没了 = 用户结束。
  void recordAwaitingCrashReportDecision(bool awaiting) {
    if (_awaitingCrashReportDecision == awaiting) return;
    _awaitingCrashReportDecision = awaiting;
    _write();
  }

  void recordMemoryPressure({required int nowMs}) {
    _memoryPressureAt = nowMs;
    _memoryPressureCount++;
    _write();
  }

  void markCleanExit({required int nowMs}) {
    _clean = true;
    _lifecycle = 'exit';
    _lifecycleAt = nowMs;
    _write();
  }

  void _write() {
    try {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'pid': pid,
          'startedAt': _startedAt,
          'version': version,
          'lifecycle': _lifecycle,
          'lifecycleAt': _lifecycleAt,
          'clean': _clean,
          'initialised': _initialised,
          'awaitingCrashReportDecision': _awaitingCrashReportDecision,
          'memoryPressureAt': _memoryPressureAt,
          'memoryPressureCount': _memoryPressureCount,
        }),
        flush: true,
      );
    } on FileSystemException catch (e) {
      debugPrint('[PreviousExitLog] session marker write failed: $e');
    }
  }
}

/// 上次会话没标 clean 时的摘要；标了 clean / 没有上次会话返回 null。
ExitReportEntry? describeUncleanPreviousSession(PreviousSession? previous) {
  if (previous == null || previous.clean) return null;
  final StringBuffer b = StringBuffer()
    ..write('上次进程没有走正常退出（崩溃、被系统杀、或被强杀）：')
    ..write('pid=${previous.pid} version=${previous.version} ')
    ..write('started=${_iso(previous.startedAt)} ')
    ..write(
      'lastLifecycle=${previous.lifecycle}@${_iso(previous.lifecycleAt)}',
    );
  if (previous.memoryPressureAt != null) {
    b.write(
      ' memoryPressure=${previous.memoryPressureCount}x '
      'last@${_iso(previous.memoryPressureAt!)}',
    );
  }
  if (!previous.initialised) b.write(' 启动初始化未完成');
  if (previous.awaitingCrashReportDecision) {
    // 停在闪退报告提示上（初始化还没开始跑）时没了：用户直接关掉 / 杀掉了 app。
    // 平台另有崩溃证据（Windows 摘要、Android CRASH…）时由 [classifyPreviousExit] 按
    // 优先级压过这条。
    b.write('（停在闪退报告提示上等用户选择时没了，按用户结束处理）');
    return ExitReportEntry(
      kPreviousExitUncleanSource,
      b.toString(),
      severe: false,
      kind: PreviousExitKind.userStopped,
      foreground: previous.diedInForeground,
      duringStartup: !previous.initialised,
      atMs: previous.lifecycleAt,
    );
  }
  b.write(previous.diedInForeground ? '（停在前台时没了，疑似闪退）' : '（停在后台时没了，多半是系统回收）');
  return ExitReportEntry(
    kPreviousExitUncleanSource,
    b.toString(),
    severe: previous.diedInForeground,
    kind: previous.diedInForeground
        ? PreviousExitKind.unexpected
        : PreviousExitKind.backgroundReclaim,
    foreground: previous.diedInForeground,
    duringStartup: !previous.initialised,
    atMs: previous.lifecycleAt,
  );
}

// ───────────────────────── Android ─────────────────────────

/// 这些退出原因说明进程是「非正常」没的，走 `log`；其余（用户划掉、自行退出、
/// 包更新…）走诊断段。名字与 `ProcessExitChannel.reasonName` 一致。
const Set<String> kSevereAndroidExitReasons = <String>{
  'CRASH',
  'CRASH_NATIVE',
  'ANR',
  'LOW_MEMORY',
  'SIGNALED',
  'EXCESSIVE_RESOURCE_USAGE',
  'INITIALIZATION_FAILURE',
  'DEPENDENCY_DIED',
  'FREEZER',
};

/// Android 退出原因 → [PreviousExitKind]；不说明问题的原因（自行退出、包更新、
/// `SIGNALED`——lmkd 与 `Process.killProcess` 重启都报它，分不清）返回 null，交给会话标记。
PreviousExitKind? androidExitKind(String reason) => switch (reason) {
  'CRASH_NATIVE' => PreviousExitKind.nativeCrash,
  'CRASH' || 'INITIALIZATION_FAILURE' => PreviousExitKind.crash,
  'ANR' => PreviousExitKind.anr,
  'LOW_MEMORY' || 'EXCESSIVE_RESOURCE_USAGE' => PreviousExitKind.memoryKill,
  'USER_REQUESTED' || 'USER_STOPPED' => PreviousExitKind.userStopped,
  _ => null,
};

/// `RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE`：重要性数值不大于它 = 用户看得见。
const int kAndroidForegroundImportance = 125;

/// `ComponentCallbacks2.TRIM_MEMORY_*` 的可读名。
String androidTrimLevelName(int level) => switch (level) {
  5 => 'RUNNING_MODERATE',
  10 => 'RUNNING_LOW',
  15 => 'RUNNING_CRITICAL',
  20 => 'UI_HIDDEN',
  40 => 'BACKGROUND',
  60 => 'MODERATE',
  80 => 'COMPLETE',
  _ => 'LEVEL_$level',
};

/// 把 `ProcessExitChannel.consumeExitReports` 的返回值整理成摘要。
List<ExitReportEntry> formatAndroidExitReports(Map<Object?, Object?> payload) {
  final List<ExitReportEntry> out = <ExitReportEntry>[];
  final Object? reasons = payload['reasons'];
  if (reasons is List) {
    for (final Object? r in reasons.take(kExitReportMaxPerSource)) {
      if (r is! Map) continue;
      final String reason = '${r['reason'] ?? 'UNKNOWN'}';
      final StringBuffer b = StringBuffer()
        ..write('reason=$reason status=${r['status']} ')
        ..write('process=${r['processName']} pid=${r['pid']} ')
        ..write('importance=${r['importance']} ')
        ..write('pss=${r['pssKb']}KB rss=${r['rssKb']}KB ')
        ..write(
          'at=${r['timestamp'] is int ? _iso(r['timestamp'] as int) : r['timestamp']}',
        );
      final Object? description = r['description'];
      if (description is String && description.isNotEmpty) {
        b.write('\ndescription: $description');
      }
      final Object? trace = r['trace'];
      if (trace is String && trace.isNotEmpty) {
        b.write('\ntrace summary:\n$trace');
      }
      final Object? importance = r['importance'];
      final Object? timestamp = r['timestamp'];
      out.add(
        ExitReportEntry(
          kAndroidExitInfoSource,
          _cap(redactExitReportPaths(b.toString())),
          severe: kSevereAndroidExitReasons.contains(reason),
          kind: androidExitKind(reason),
          foreground:
              importance is! int || importance <= kAndroidForegroundImportance,
          atMs: timestamp is int ? timestamp : null,
        ),
      );
    }
  }
  final Object? trims = payload['trims'];
  if (trims is List && trims.isNotEmpty) {
    final String lines = trims
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> t) {
          final Object? level = t['level'];
          final Object? at = t['timestamp'];
          return '${level is int ? androidTrimLevelName(level) : level}'
              '@${at is int ? _iso(at) : at} pid=${t['pid']}';
        })
        .join('; ');
    // RUNNING_CRITICAL / COMPLETE 是「快被杀了」的信号，值得落盘。
    final bool severe = trims.whereType<Map<Object?, Object?>>().any((
      Map<Object?, Object?> t,
    ) {
      final Object? level = t['level'];
      return level is int && (level == 15 || level >= 80);
    });
    out.add(
      ExitReportEntry(
        kAndroidTrimMemorySource,
        _cap('onTrimMemory（最近若干次，含上次进程）：$lines'),
        severe: severe,
      ),
    );
  }
  return out;
}

// ───────────────────────── Windows ─────────────────────────

/// `%LOCALAPPDATA%\Fushi\crashdumps\crash_summary.log`（与 `crash_dump.cpp` 硬钉同一路径）。
File? resolveWindowsCrashSummaryFile({
  required bool isWindows,
  required String? localAppData,
}) {
  if (!isWindows || localAppData == null || localAppData.isEmpty) return null;
  return File('$localAppData\\Fushi\\crashdumps\\crash_summary.log');
}

/// 读出并清空摘要文件；不存在 / 空返回 null。
String? readAndClearTextFile(File file) {
  try {
    if (!file.existsSync()) return null;
    final String content = file.readAsStringSync().trim();
    if (content.isEmpty) return null;
    file.writeAsStringSync('', flush: true);
    return content;
  } on FileSystemException {
    return null;
  }
}

List<ExitReportEntry> formatWindowsCrashSummary(String content) {
  final List<String> lines = content
      .split(RegExp(r'\r?\n'))
      .where((String l) => l.trim().isNotEmpty)
      .toList();
  final Iterable<String> recent = lines.skip(
    math.max(0, lines.length - kExitReportMaxPerSource),
  );
  return <ExitReportEntry>[
    for (final String line in recent)
      ExitReportEntry(
        kWindowsCrashSummarySource,
        _cap(
          '上次运行 native 未处理异常（minidump 在「诊断 → 崩溃转储」，未上传）：'
          '${redactExitReportPaths(line)}',
        ),
        severe: true,
        kind: PreviousExitKind.nativeCrash,
      ),
  ];
}

// ───────────────────────── macOS ─────────────────────────

/// 把一份 `.ips`（第一行头部 JSON + 正文 JSON）摘成一段：异常类型 / 信号、终止原因、
/// 崩溃线程前若干帧。解析不了返回 null。
String? summarizeMacIpsReport(String content, {int maxFrames = 12}) {
  final int newline = content.indexOf('\n');
  if (newline <= 0) return null;
  final Map<Object?, Object?> header;
  final Map<Object?, Object?> body;
  try {
    final Object? h = jsonDecode(content.substring(0, newline));
    final Object? b = jsonDecode(content.substring(newline + 1));
    if (h is! Map || b is! Map) return null;
    header = h;
    body = b;
  } on FormatException {
    return null;
  }
  final StringBuffer out = StringBuffer()
    ..write('app=${header['app_name']} version=${header['app_version']} ')
    ..write('bug_type=${header['bug_type']} at=${header['timestamp']}');
  final Object? exception = body['exception'];
  if (exception is Map) {
    out.write(
      '\nexception: type=${exception['type']} signal=${exception['signal']} '
      'codes=${exception['codes']} subtype=${exception['subtype'] ?? ''}',
    );
  }
  final Object? termination = body['termination'];
  if (termination is Map) {
    out.write(
      '\ntermination: ${termination['namespace']} '
      'code=${termination['code']} ${termination['indicator'] ?? ''}',
    );
  }
  final Object? asi = body['asi'];
  if (asi is Map && asi.isNotEmpty) out.write('\nasi: ${jsonEncode(asi)}');
  final Object? images = body['usedImages'];
  final Object? threads = body['threads'];
  final Object? faulting = body['faultingThread'];
  if (threads is List && faulting is int && faulting < threads.length) {
    final Object? thread = threads[faulting];
    if (thread is Map) {
      out.write('\nfaulting thread #$faulting ${thread['queue'] ?? ''}:');
      final Object? frames = thread['frames'];
      if (frames is List) {
        for (final Object? f in frames.take(maxFrames)) {
          if (f is! Map) continue;
          final Object? idx = f['imageIndex'];
          String image = '?';
          if (images is List && idx is int && idx < images.length) {
            final Object? img = images[idx];
            if (img is Map) image = '${img['name'] ?? '?'}';
          }
          final Object? symbol = f['symbol'];
          out.write(
            '\n  $image+0x${(f['imageOffset'] is int ? f['imageOffset'] as int : 0).toRadixString(16)}'
            '${symbol != null ? ' $symbol' : ''}',
          );
        }
      }
    }
  }
  return _cap(redactExitReportPaths(out.toString()));
}

/// 列出 [dir] 里 [processName] 在 [sinceMs] 之后的 `.ips`，按修改时间升序。
List<File> listMacCrashReports(
  Directory dir, {
  required String processName,
  required int sinceMs,
}) {
  if (!dir.existsSync()) return <File>[];
  final String prefix = '${processName.toLowerCase()}-';
  final List<(File, int)> hits = <(File, int)>[];
  try {
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final String name = e.uri.pathSegments.last.toLowerCase();
      if (!name.startsWith(prefix) || !name.endsWith('.ips')) continue;
      final int modified = e.statSync().modified.millisecondsSinceEpoch;
      if (modified > sinceMs) hits.add((e, modified));
    }
  } on FileSystemException {
    return <File>[];
  }
  hits.sort(((File, int) a, (File, int) b) => a.$2.compareTo(b.$2));
  return <File>[for (final (File, int) h in hits) h.$1];
}

// ───────────────────────── iOS ─────────────────────────

/// 把 `MXCrashDiagnostic.jsonRepresentation()` 摘成一段：元数据 + 归属线程的调用链
/// 前若干帧（binaryName + 偏移）。解析不了返回 null。
String? summarizeMetricKitCrash(String json, {int maxFrames = 12}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final StringBuffer out = StringBuffer();
  final Object? meta = decoded['diagnosticMetaData'];
  if (meta is Map) {
    out.write(
      'app=${meta['appVersion']}(${meta['appBuildVersion']}) '
      'os=${meta['osVersion']} device=${meta['deviceType']} '
      'exceptionType=${meta['exceptionType']} code=${meta['exceptionCode']} '
      'signal=${meta['signal']}',
    );
    final Object? reason = meta['terminationReason'];
    if (reason != null) out.write('\ntermination: $reason');
    final Object? vm = meta['virtualMemoryRegionInfo'];
    if (vm != null) out.write('\nvm region: $vm');
  }
  final Object? tree = decoded['callStackTree'];
  if (tree is Map && tree['callStacks'] is List) {
    final List<Object?> stacks = tree['callStacks'] as List<Object?>;
    final Map<Object?, Object?>? attributed = stacks
        .whereType<Map<Object?, Object?>>()
        .where((Map<Object?, Object?> s) => s['threadAttributed'] == true)
        .firstOrNull;
    Object? frames = attributed?['callStackRootFrames'];
    int n = 0;
    if (frames is List && frames.isNotEmpty) out.write('\ncrashed thread:');
    while (frames is List && frames.isNotEmpty && n < maxFrames) {
      final Object? f = frames.first;
      if (f is! Map) break;
      out.write('\n  ${f['binaryName']}+${f['offsetIntoBinaryTextSegment']}');
      n++;
      frames = f['subFrames'];
    }
  }
  if (out.isEmpty) return null;
  return _cap(redactExitReportPaths(out.toString()));
}

// ───────────────────────── 活动面包屑 ─────────────────────────

const String kActivityCrashRecoveredSource = 'Process.activityCrashRecovered';
const String _kActivityBreadcrumbPrefix = 'activity_';
const String _kActivityBreadcrumbSuffix = '.breadcrumb';

/// 「进程没的时候正在做什么」：长活动（复习同步一轮等）开始时**同步**写一个小文件、
/// 阶段变化时覆写、结束时删掉。下次启动还在 = 进程死在这次活动里（Dart 接不到的
/// 原生崩溃 / 被系统杀），[PreviousExitLog] 把内容折成
/// [kActivityCrashRecoveredSource]。与查词 / 导入面包屑同一范式，但不再一事一文件
/// 一段恢复代码：[activity] 只能是 `[a-z0-9_]`。
abstract final class ActivityBreadcrumb {
  /// 面包屑目录；默认错误日志目录（未 init 时为 null，此时记录是空操作）。
  @visibleForTesting
  static Directory? Function() directoryResolver = () =>
      ErrorLogService.instance.appDirectory;

  static File? _file(String activity) {
    assert(RegExp(r'^[a-z0-9_]+$').hasMatch(activity), activity);
    final Directory? dir = directoryResolver();
    if (dir == null) return null;
    return File(
      '${dir.path}${Platform.pathSeparator}'
      '$_kActivityBreadcrumbPrefix$activity$_kActivityBreadcrumbSuffix',
    );
  }

  static void mark(String activity, String detail) {
    final File? f = _file(activity);
    if (f == null) return;
    try {
      f.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $detail',
        flush: true,
      );
    } on FileSystemException catch (e) {
      debugPrint('[ActivityBreadcrumb] mark $activity failed: $e');
    }
  }

  static void clear(String activity) {
    final File? f = _file(activity);
    if (f == null) return;
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException catch (e) {
      debugPrint('[ActivityBreadcrumb] clear $activity failed: $e');
    }
  }
}

/// 读出并删除 [dir] 里上次进程留下的活动面包屑。
List<ExitReportEntry> collectActivityBreadcrumbs(Directory dir) {
  final List<ExitReportEntry> out = <ExitReportEntry>[];
  if (!dir.existsSync()) return out;
  for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    final String name = e.uri.pathSegments.last;
    if (!name.startsWith(_kActivityBreadcrumbPrefix) ||
        !name.endsWith(_kActivityBreadcrumbSuffix)) {
      continue;
    }
    final String activity = name.substring(
      _kActivityBreadcrumbPrefix.length,
      name.length - _kActivityBreadcrumbSuffix.length,
    );
    try {
      final String detail = e.readAsStringSync().trim();
      e.deleteSync();
      out.add(
        ExitReportEntry(
          kActivityCrashRecoveredSource,
          _cap(
            redactExitReportPaths(
              '上次进程在「$activity」进行中没了（原生崩溃 / 被系统杀 / 强杀）：$detail',
            ),
          ),
          severe: true,
        ),
      );
    } on FileSystemException catch (err) {
      debugPrint('[ActivityBreadcrumb] recover $activity failed: $err');
    }
  }
  return out;
}

// ───────────────────────── 判定 ─────────────────────────

/// 单份崩溃报告正文里证据摘要的总长上限（反馈正文上限 8000，留出头部说明）。
const int kExitVerdictSummaryMaxChars = 6000;

/// 一次启动对「上次怎么没的」的结论（[classifyPreviousExit]）。
@immutable
class PreviousExitVerdict {
  const PreviousExitVerdict({
    required this.kind,
    required this.count,
    required this.foreground,
    required this.duringStartup,
    required this.atMs,
    required this.version,
    required this.summary,
  });

  final PreviousExitKind kind;

  /// 这次启动收到的同类证据条数（连续崩溃时 > 1，例如 Windows 摘要里有几行）。
  final int count;
  final bool foreground;

  /// 死在启动初始化完成之前：提示必须赶在下一次初始化之前出现。
  final bool duringStartup;
  final int atMs;

  /// 出事那次进程的版本（会话标记里记的；没有时为本次版本）。
  final String version;

  /// 全部证据的摘要文本（已脱敏、限长），作为崩溃报告正文的主体。
  final String summary;

  bool get worthReporting => kind.worthReporting(foreground: foreground);
}

/// 用 [PreviousExitLog.collect] 收到的证据判定上次进程怎么没的；没有任何说明退出方式的
/// 证据（上次正常退出、首次启动）返回 null。
///
/// 规则（[PreviousExitKind] 的声明顺序即优先级）：
/// - 平台明确原因压过会话标记推断：Android 说 `USER_REQUESTED` 时，即使标记显示停在
///   前台也算用户强停，不算闪退；Windows 有崩溃摘要时，标记的「疑似闪退」升级为原生崩溃。
/// - 「启动即闪退」只看会话标记（只有它知道初始化走没走完），与选中的种类无关。
PreviousExitVerdict? classifyPreviousExit(
  List<ExitReportEntry> entries, {
  required String version,
  required int nowMs,
}) {
  final List<ExitReportEntry> classified = <ExitReportEntry>[
    for (final ExitReportEntry e in entries)
      if (e.kind != null) e,
  ];
  if (classified.isEmpty) return null;
  final PreviousExitKind kind = classified
      .map((ExitReportEntry e) => e.kind!)
      .reduce(
        (PreviousExitKind a, PreviousExitKind b) => a.index <= b.index ? a : b,
      );
  final List<ExitReportEntry> chosen = <ExitReportEntry>[
    for (final ExitReportEntry e in classified)
      if (e.kind == kind) e,
  ];
  final int at = chosen
      .map((ExitReportEntry e) => e.atMs ?? 0)
      .fold<int>(0, math.max);
  final String summary = entries
      .map((ExitReportEntry e) => '[${e.source}] ${e.text}')
      .join('\n\n');
  return PreviousExitVerdict(
    kind: kind,
    count: chosen.length,
    foreground: chosen.any((ExitReportEntry e) => e.foreground),
    duringStartup: entries.any((ExitReportEntry e) => e.duringStartup),
    atMs: at > 0 ? at : nowMs,
    version: version,
    summary: _cap(summary, kExitVerdictSummaryMaxChars),
  );
}

// ───────────────────────── 装配 ─────────────────────────

/// 跨运行的去重状态（macOS 看到哪份 `.ips` 了），放在应用文档目录。
class _ExitReportState {
  _ExitReportState(this.file);

  final File file;

  int readMacSeenAt() {
    try {
      if (!file.existsSync()) return 0;
      final Object? d = jsonDecode(file.readAsStringSync());
      return d is Map && d['macIpsSeenAt'] is int
          ? d['macIpsSeenAt'] as int
          : 0;
    } on Object {
      return 0;
    }
  }

  void writeMacSeenAt(int ms) {
    try {
      file.writeAsStringSync(jsonEncode(<String, Object?>{'macIpsSeenAt': ms}));
    } on FileSystemException catch (e) {
      debugPrint('[PreviousExitLog] state write failed: $e');
    }
  }
}

class _ExitEvidenceObserver with WidgetsBindingObserver {
  _ExitEvidenceObserver(this.marker);

  final SessionMarker marker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    marker.recordLifecycle(
      state.name,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  void didHaveMemoryPressure() {
    marker.recordMemoryPressure(nowMs: DateTime.now().millisecondsSinceEpoch);
    ErrorLogService.instance.logDiagnostic(
      kMemoryPressureSource,
      'system memory pressure; rss=${(ProcessInfo.currentRss / (1 << 20)).round()}MB '
      'maxRss=${(ProcessInfo.maxRss / (1 << 20)).round()}MB',
    );
  }
}

/// 启动时调用一次（[ErrorLogService.init] 之后）。
abstract final class PreviousExitLog {
  static SessionMarker? _marker;
  static _ExitEvidenceObserver? _observer;
  static PreviousSession? _previous;
  static PreviousExitVerdict? _verdict;

  /// 本次启动对上次退出的判定（[foldIntoErrorLog] 之后可读；没有异常退出为 null）。
  static PreviousExitVerdict? get verdict => _verdict;

  /// 本次启动初始化完成（首页出来了）时调用：之后再没了不算「启动即闪退」。
  static void markInitialised() => _marker?.recordInitialised();

  /// 启动前的闪退报告提示出现（true）/ 用户选完（false）时调用：停在提示上没了的那次
  /// 下次启动按用户结束处理，不算又一次启动即闪退。
  static void markAwaitingCrashReportDecision(bool awaiting) =>
      _marker?.recordAwaitingCrashReportDecision(awaiting);

  /// 正常退出路径（`exitApp` / 重启）在退进程前调用：本次会话标 clean。
  static void markCleanExit() {
    _marker?.markCleanExit(nowMs: DateTime.now().millisecondsSinceEpoch);
  }

  /// 生产入口：按平台收集上次退出证据并折进错误日志，再开始记录本次会话。
  ///
  /// [collector] 只给测试替换收集实现（免得在开发机上读走真实的崩溃摘要文件）。
  static Future<void> foldIntoErrorLog({
    @visibleForTesting
    Future<List<ExitReportEntry>> Function(Directory appDir)? collector,
  }) async {
    try {
      final Directory? appDir = ErrorLogService.instance.appDirectory;
      if (appDir == null) return;
      final List<ExitReportEntry> entries = collector != null
          ? await collector(appDir)
          : await collect(
              appDir: appDir,
              version: fushiRunningCodeVersion ?? 'unknown',
            );
      final String? previousVersion = _previous?.version;
      _verdict = classifyPreviousExit(
        entries,
        version: previousVersion != null && previousVersion.isNotEmpty
            ? previousVersion
            : fushiRunningCodeVersion ?? 'unknown',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      for (final ExitReportEntry e in entries) {
        if (e.severe) {
          ErrorLogService.instance.log(e.source, e.text);
        } else {
          ErrorLogService.instance.logDiagnostic(e.source, e.text);
        }
      }
      final SessionMarker? marker = _marker;
      if (marker != null && _observer == null) {
        _observer = _ExitEvidenceObserver(marker);
        WidgetsBinding.instance.addObserver(_observer!);
      }
    } on Object catch (e, st) {
      ErrorLogService.instance.log('PreviousExitLog.fold', e, st);
    }
  }

  /// 可注入的收集实现（测试缝）。平台开关与各来源的位置都可替换。
  @visibleForTesting
  static Future<List<ExitReportEntry>> collect({
    required Directory appDir,
    required String version,
    bool? isAndroid,
    bool? isWindows,
    bool? isMacOS,
    bool? isIOS,
    MethodChannel? androidChannel,
    String? localAppData,
    Directory? macReportsDir,
    String? macProcessName,
    Directory? iosMetricKitDir,
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final List<ExitReportEntry> out = <ExitReportEntry>[];

    // 启动早期（复习同步等长活动开跑之前）收走上次进程留下的活动面包屑。
    out.addAll(collectActivityBreadcrumbs(appDir));

    final SessionMarker marker = SessionMarker(
      File('${appDir.path}${Platform.pathSeparator}session_marker.json'),
      pid: pid,
      version: version,
    );
    final PreviousSession? previous = marker.start(nowMs: now);
    _previous = previous;
    final ExitReportEntry? unclean = describeUncleanPreviousSession(previous);
    if (unclean != null) out.add(unclean);
    _marker = marker;

    if (isAndroid ?? Platform.isAndroid) {
      try {
        final Map<Object?, Object?>? payload =
            await (androidChannel ?? FushiChannels.processExit)
                .invokeMapMethod<Object?, Object?>(
                  'consumeExitReports',
                  <String, Object?>{
                    'lookbackMs': kExitReportLookback.inMilliseconds,
                  },
                );
        if (payload != null) out.addAll(formatAndroidExitReports(payload));
      } on MissingPluginException {
        // :popup 等没注册通道的引擎：没有可读的。
      } on PlatformException catch (e, st) {
        ErrorLogService.instance.log('PreviousExitLog.android', e, st);
      }
    }

    if (isWindows ?? Platform.isWindows) {
      final File? file = resolveWindowsCrashSummaryFile(
        isWindows: true,
        localAppData: localAppData ?? Platform.environment['LOCALAPPDATA'],
      );
      final String? content = file == null ? null : readAndClearTextFile(file);
      if (content != null) out.addAll(formatWindowsCrashSummary(content));
    }

    if (isMacOS ?? Platform.isMacOS) {
      final String home = Platform.environment['HOME'] ?? '';
      final Directory dir =
          macReportsDir ?? Directory('$home/Library/Logs/DiagnosticReports');
      final String processName =
          macProcessName ??
          File(Platform.resolvedExecutable).uri.pathSegments.last;
      final _ExitReportState state = _ExitReportState(
        File('${appDir.path}/previous_exit_state.json'),
      );
      final int seen = state.readMacSeenAt();
      final int since = math.max(
        seen,
        now - kExitReportLookback.inMilliseconds,
      );
      final List<File> reports = listMacCrashReports(
        dir,
        processName: processName,
        sinceMs: since,
      );
      int newest = seen;
      for (final File f in reports.skip(
        math.max(0, reports.length - kExitReportMaxPerSource),
      )) {
        try {
          final String raw = f.readAsStringSync();
          final String? summary = summarizeMacIpsReport(raw);
          out.add(
            summary != null
                ? ExitReportEntry(
                    kMacCrashReportSource,
                    summary,
                    severe: true,
                    kind: PreviousExitKind.crash,
                  )
                : ExitReportEntry(
                    kMacCrashReportSource,
                    'crash report ${f.uri.pathSegments.last} '
                    '(${raw.length} chars) could not be parsed',
                    severe: true,
                    kind: PreviousExitKind.crash,
                  ),
          );
        } on FileSystemException catch (e) {
          ErrorLogService.instance.logDiagnostic(
            kMacCrashReportSource,
            'cannot read crash report: $e',
          );
        }
      }
      for (final File f in reports) {
        newest = math.max(newest, f.statSync().modified.millisecondsSinceEpoch);
      }
      if (newest > seen) state.writeMacSeenAt(newest);
    }

    if (isIOS ?? Platform.isIOS) {
      final Directory dir =
          iosMetricKitDir ?? Directory('${appDir.path}/metrickit');
      if (dir.existsSync()) {
        final List<File> files =
            dir
                .listSync()
                .whereType<File>()
                .where((File f) => f.path.endsWith('.json'))
                .toList()
              ..sort((File a, File b) => a.path.compareTo(b.path));
        for (final File f in files) {
          try {
            if (files.indexOf(f) >= files.length - kExitReportMaxPerSource) {
              final String raw = f.readAsStringSync();
              final String? summary = summarizeMetricKitCrash(raw);
              out.add(
                ExitReportEntry(
                  kIosCrashDiagnosticSource,
                  summary ??
                      'MetricKit crash payload (${raw.length} chars, likely '
                          'truncated) could not be parsed',
                  severe: true,
                  kind: PreviousExitKind.crash,
                ),
              );
            }
            f.deleteSync();
          } on FileSystemException catch (e) {
            ErrorLogService.instance.logDiagnostic(
              kIosCrashDiagnosticSource,
              'cannot read MetricKit payload: $e',
            );
          }
        }
      }
    }
    return out;
  }
}
