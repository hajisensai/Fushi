// 闪退报告：上次进程崩溃 / 异常退出后，下次启动时帮用户把日志提交成一条反馈。
//
// 为什么要它：闪退反馈大半没带日志（用户说「没报错日志」），日志里的崩溃证据
// （previous_exit_log.dart 折进错误日志的那些）只有用户自己去反馈页上传才到得了开发者
// 手里。这里把「上次怎么没的」的判定（[PreviousExitLog.verdict]）接到现有的反馈提交
// 管线上：
//
// - 判定只用已有证据（[classifyPreviousExit]）；用户强停、后台被系统回收不报。
// - 待报的闪退落盘在错误日志目录的 `crash_report_state.json`（不进 Drift：启动即闪退时
//   数据库可能根本没打开，「以后自动发送」开关也必须在开库前读得到）。
// - 去重：每份证据本来就只被读一次（会话标记覆写、Windows 摘要读后清空、Android 退出
//   原因按时间消费），落盘时再按「种类 + 时刻」去一次重；同一份待报只提交一次——第一次
//   尝试提交时把这批待报连同新生成的幂等键（[FeedbackDraft.submissionKey]）一起挪进
//   「提交中」（[CrashReportBatch]），重试只发、成功只清这一批，回执没收到就重试也拿回
//   同一条反馈；两次尝试之间新来的闪退留在待报里，进下一份报告（不会顶着旧键被服务端
//   当成重复请求吞掉又被本机清掉）。
// - 合并：提交后 [kCrashReportMergeWindow] 内再闪退，先攒着不再问 / 不再自动发；窗口
//   过后的第一次启动把攒下的几次合成一条报告（标题带次数），不刷屏。
// - 自动发送默认关：日志会离开设备，第一次必须由用户点「发送」或「以后自动发送」，
//   或在设置里打开。
//
// 启动即闪退：上次死在初始化完成之前（会话标记的 `initialised`）时，提示在本次
// `AppModel.initialise()` **之前**出现、等用户选完再初始化（见
// `pages/implementations/feedback/crash_report_prompt.dart` 的
// `runCrashReportStartupGate`）；开着自动发送时不问也不等网络，提交在后台
// （[CrashReporter.submitInBackground]）跟初始化并行跑。那时数据库还没开，提交落在
// [CrashReporter.spoolDir]，初始化完成后由 [FeedbackService.adoptSpool] 并入反馈中心。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:path/path.dart' as p;

/// 状态文件名（错误日志目录下）。
const String kCrashReportStateFileName = 'crash_report_state.json';

/// 启动即闪退时提前提交的落脚目录名（错误日志目录下，结构同 `<数据根>`）。
const String kCrashReportSpoolDirName = 'crash_report_spool';

/// 提交后这么久之内再闪退，攒着合并到下一份报告，不再问 / 不再自动发。
const Duration kCrashReportMergeWindow = Duration(minutes: 30);

/// 待报清单最多留几条（更早的只计数，见 [CrashReportState.droppedCount]）。
const int kCrashReportMaxOccurrences = 10;

/// 一次待报的异常退出（由一次启动的 [PreviousExitVerdict] 而来）。
@immutable
class CrashOccurrence {
  const CrashOccurrence({
    required this.kind,
    required this.count,
    required this.atMs,
    required this.version,
    required this.foreground,
    required this.duringStartup,
    required this.summary,
  });

  factory CrashOccurrence.fromVerdict(PreviousExitVerdict v) => CrashOccurrence(
    kind: v.kind,
    count: v.count,
    atMs: v.atMs,
    version: v.version,
    foreground: v.foreground,
    duringStartup: v.duringStartup,
    summary: v.summary,
  );

  static CrashOccurrence? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? kind = raw['kind'];
    final Object? at = raw['atMs'];
    if (kind is! String || at is! int) return null;
    final PreviousExitKind? k = PreviousExitKind.values
        .where((PreviousExitKind e) => e.name == kind)
        .firstOrNull;
    if (k == null) return null;
    final Object? count = raw['count'];
    return CrashOccurrence(
      kind: k,
      count: count is int && count > 0 ? count : 1,
      atMs: at,
      version: '${raw['version'] ?? ''}',
      foreground: raw['foreground'] != false,
      duringStartup: raw['duringStartup'] == true,
      summary: '${raw['summary'] ?? ''}',
    );
  }

  final PreviousExitKind kind;
  final int count;
  final int atMs;
  final String version;
  final bool foreground;
  final bool duringStartup;
  final String summary;

  /// 去重键：同一份证据（同种类、同时刻）只记一次。
  String get identity => '${kind.name}@$atMs';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'count': count,
    'atMs': atMs,
    'version': version,
    'foreground': foreground,
    'duringStartup': duringStartup,
    'summary': summary,
  };
}

List<CrashOccurrence> _parseOccurrences(Object? raw) => raw is List
    ? <CrashOccurrence>[
        for (final Object? o in raw)
          if (CrashOccurrence.tryParse(o) case final CrashOccurrence c) c,
      ]
    : const <CrashOccurrence>[];

/// 已经开始提交的一批待报：幂等键与它覆盖的那几次退出**一起**落盘。重试只发这一批、
/// 提交成功只清这一批；之后新来的闪退不进来（进下一份报告）。
@immutable
class CrashReportBatch {
  const CrashReportBatch({
    required this.submissionKey,
    required this.occurrences,
    this.droppedCount = 0,
  });

  static CrashReportBatch? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? key = raw['submissionKey'];
    final Object? dropped = raw['droppedCount'];
    final List<CrashOccurrence> occurrences = _parseOccurrences(
      raw['occurrences'],
    );
    if (key is! String || key.isEmpty || occurrences.isEmpty) return null;
    return CrashReportBatch(
      submissionKey: key,
      occurrences: occurrences,
      droppedCount: dropped is int && dropped > 0 ? dropped : 0,
    );
  }

  /// 这批的提交幂等键（第一次尝试提交时生成）。
  final String submissionKey;

  /// 这批覆盖的退出，旧的在前，非空。
  final List<CrashOccurrence> occurrences;

  /// 挪进这批时已被挤掉的更早几次的次数合计（随这批一起报、一起清）。
  final int droppedCount;

  CrashReportOffer get offer =>
      CrashReportOffer(occurrences, droppedCount: droppedCount);

  Map<String, Object?> toJson() => <String, Object?>{
    'submissionKey': submissionKey,
    'occurrences': <Object?>[
      for (final CrashOccurrence c in occurrences) c.toJson(),
    ],
    'droppedCount': droppedCount,
  };
}

/// 落盘的闪退报告状态。
@immutable
class CrashReportState {
  const CrashReportState({
    this.autoSend = false,
    this.pending = const <CrashOccurrence>[],
    this.droppedCount = 0,
    this.inFlight,
    this.lastSubmittedAt = 0,
    this.lastTicketId,
  });

  factory CrashReportState.fromJson(Object? raw) {
    if (raw is! Map) return const CrashReportState();
    final Object? dropped = raw['droppedCount'];
    final Object? last = raw['lastSubmittedAt'];
    final Object? legacyKey = raw['submissionKey'];
    final Object? ticket = raw['lastTicketId'];
    List<CrashOccurrence> pending = _parseOccurrences(raw['pending']);
    int droppedCount = dropped is int && dropped > 0 ? dropped : 0;
    CrashReportBatch? inFlight = CrashReportBatch.tryParse(raw['inFlight']);
    // 早期格式只落了一个顶层幂等键、没记它覆盖哪几次：那时的待报全部算进这一批。
    if (inFlight == null &&
        legacyKey is String &&
        legacyKey.isNotEmpty &&
        pending.isNotEmpty) {
      inFlight = CrashReportBatch(
        submissionKey: legacyKey,
        occurrences: pending,
        droppedCount: droppedCount,
      );
      pending = const <CrashOccurrence>[];
      droppedCount = 0;
    }
    return CrashReportState(
      autoSend: raw['autoSend'] == true,
      pending: pending,
      droppedCount: droppedCount,
      inFlight: inFlight,
      lastSubmittedAt: last is int ? last : 0,
      lastTicketId: ticket is String && ticket.isNotEmpty ? ticket : null,
    );
  }

  /// 用户同意过「以后自动发送」（设置里也能改，默认关）。
  final bool autoSend;

  /// 还没开始报的异常退出，旧的在前（不含 [inFlight] 里的）。
  final List<CrashOccurrence> pending;

  /// [pending] 超过 [kCrashReportMaxOccurrences] 被挤掉的更早几次的次数合计。
  final int droppedCount;

  /// 已经开始提交、还没确认交上去的那一批（带幂等键）；提交成功才清掉。
  final CrashReportBatch? inFlight;

  /// 上一份闪退报告提交成功的时刻（合并窗口从这里算）。
  final int lastSubmittedAt;

  /// 上一份闪退报告的反馈 id（「查看」跳转用）。
  final String? lastTicketId;

  CrashReportState copyWith({
    bool? autoSend,
    List<CrashOccurrence>? pending,
    int? droppedCount,
    CrashReportBatch? Function()? inFlight,
    int? lastSubmittedAt,
    String? lastTicketId,
  }) => CrashReportState(
    autoSend: autoSend ?? this.autoSend,
    pending: pending ?? this.pending,
    droppedCount: droppedCount ?? this.droppedCount,
    inFlight: inFlight != null ? inFlight() : this.inFlight,
    lastSubmittedAt: lastSubmittedAt ?? this.lastSubmittedAt,
    lastTicketId: lastTicketId ?? this.lastTicketId,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'autoSend': autoSend,
    'pending': <Object?>[for (final CrashOccurrence c in pending) c.toJson()],
    'droppedCount': droppedCount,
    'inFlight': inFlight?.toJson(),
    'lastSubmittedAt': lastSubmittedAt,
    'lastTicketId': lastTicketId,
  };
}

/// 状态文件读写：几百字节，**同步**读写（设置页开关要同步读；进程下一刻没了也已落盘），
/// 写走「临时文件 + rename」。
class CrashReportStore {
  CrashReportStore(this.file);

  final File file;

  CrashReportState read() {
    try {
      if (!file.existsSync()) return const CrashReportState();
      return CrashReportState.fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException catch (e, st) {
      ErrorLogService.instance.log('CrashReport.state_corrupt', e, st);
      return const CrashReportState();
    } on FileSystemException catch (e, st) {
      ErrorLogService.instance.log('CrashReport.state_read', e, st);
      return const CrashReportState();
    }
  }

  void write(CrashReportState state) {
    final File tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    tmp.renameSync(file.path);
  }
}

/// 一份要问 / 要发的闪退报告（可能合并了几次）。
@immutable
class CrashReportOffer {
  const CrashReportOffer(this.occurrences, {this.droppedCount = 0});

  /// 旧的在前，非空。
  final List<CrashOccurrence> occurrences;
  final int droppedCount;

  CrashOccurrence get latest => occurrences.last;

  /// 合计几次（含被挤掉的更早几次）。
  int get totalCount =>
      droppedCount +
      occurrences.fold<int>(0, (int sum, CrashOccurrence c) => sum + c.count);

  /// 最严重的那种（[PreviousExitKind] 声明顺序）。
  PreviousExitKind get kind => occurrences
      .map((CrashOccurrence c) => c.kind)
      .reduce(
        (PreviousExitKind a, PreviousExitKind b) => a.index <= b.index ? a : b,
      );

  /// 最近一次死在启动初始化之前：下一次初始化多半还会死，提示要赶在它之前。
  bool get duringStartup => latest.duringStartup;

  String get version => latest.version;
}

/// 组一份闪退报告反馈（分类 bug，附日志与设备信息）。[title] / [header] 由界面按语言给出。
/// 正文 = 说明 + 每次退出的摘要（新的在前），截到 [FeedbackLimits.bodyMax]。
FeedbackDraft buildCrashReportDraft(
  CrashReportOffer offer, {
  required String title,
  required String header,
  required String submissionKey,
}) {
  final StringBuffer body = StringBuffer(header);
  if (offer.droppedCount > 0) {
    body.write('\n(+${offer.droppedCount} earlier exits not listed)');
  }
  for (final CrashOccurrence c in offer.occurrences.reversed) {
    body
      ..write('\n\n---- ${c.kind.name}')
      ..write(c.count > 1 ? ' x${c.count}' : '')
      ..write(
        ' at=${DateTime.fromMillisecondsSinceEpoch(c.atMs).toIso8601String()}',
      )
      ..write(' version=${c.version}')
      ..write(' foreground=${c.foreground}')
      ..write(' duringStartup=${c.duringStartup}')
      ..write('\n${c.summary}');
  }
  String text = body.toString();
  if (text.length > FeedbackLimits.bodyMax) {
    text = '${text.substring(0, FeedbackLimits.bodyMax - 1)}…';
  }
  return FeedbackDraft(
    category: FeedbackCategory.bug,
    title: title.length > FeedbackLimits.titleMax
        ? title.substring(0, FeedbackLimits.titleMax)
        : title,
    body: text,
    submissionKey: submissionKey,
  );
}

/// 闪退报告的状态与流程（全应用一份，[instance]）。界面在
/// `pages/implementations/feedback/crash_report_prompt.dart`。
class CrashReporter extends ChangeNotifier {
  CrashReporter({int Function()? nowMs, String Function()? newKey})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
      _newKey = newKey ?? newFeedbackSubmissionKey;

  static final CrashReporter instance = CrashReporter();

  final int Function() _nowMs;
  final String Function() _newKey;

  CrashReportStore? _store;
  Directory? _dir;
  CrashReportState _state = const CrashReportState();
  bool _enabled = false;
  bool _handledThisSession = false;

  /// 启动时（[ErrorLogService.init] 之后）接上状态文件。[enabled] = false 时只保留
  /// 「自动发送」开关的读写，不记录、不问、不发（debug 构建、集成测试根下）。
  void attach(Directory dir, {required bool enabled}) {
    _dir = dir;
    _store = CrashReportStore(
      File(p.join(dir.path, kCrashReportStateFileName)),
    );
    _state = _store!.read();
    _enabled = enabled;
    notifyListeners();
  }

  bool get enabled => _enabled;

  /// 用户同意过「以后自动发送」。
  bool get autoSend => _state.autoSend;

  String? get lastTicketId => _state.lastTicketId;

  /// 待报的次数（含提交中的那批与被挤掉的）。
  int get pendingCount =>
      (_state.inFlight?.offer.totalCount ?? 0) +
      (_state.pending.isEmpty
          ? 0
          : CrashReportOffer(
              _state.pending,
              droppedCount: _state.droppedCount,
            ).totalCount);

  /// 启动即闪退时提前提交的落脚目录。
  Directory? get spoolDir => _dir == null
      ? null
      : Directory(p.join(_dir!.path, kCrashReportSpoolDirName));

  void _save(CrashReportState next) {
    _state = next;
    try {
      _store?.write(next);
    } on FileSystemException catch (e, st) {
      ErrorLogService.instance.log('CrashReport.state_write', e, st);
    }
    notifyListeners();
  }

  void setAutoSend(bool value) {
    if (value == _state.autoSend) return;
    _save(_state.copyWith(autoSend: value));
  }

  /// 把本次启动的判定记进待报清单（不值得报的、关着时、同一份证据重复的都不记）。
  void recordVerdict(PreviousExitVerdict? verdict) {
    if (!_enabled || verdict == null || !verdict.worthReporting) return;
    final CrashOccurrence next = CrashOccurrence.fromVerdict(verdict);
    if (<CrashOccurrence>[
      ..._state.pending,
      ...?_state.inFlight?.occurrences,
    ].any((CrashOccurrence c) => c.identity == next.identity)) {
      return;
    }
    final List<CrashOccurrence> pending = <CrashOccurrence>[
      ..._state.pending,
      next,
    ];
    int dropped = _state.droppedCount;
    while (pending.length > kCrashReportMaxOccurrences) {
      dropped += pending.removeAt(0).count;
    }
    _save(_state.copyWith(pending: pending, droppedCount: dropped));
  }

  /// 现在该问 / 该发的报告；没有待报、关着、或还在上一份报告的合并窗口里返回 null。
  /// 有没交上去的那批（[CrashReportState.inFlight]）时先是它（[submit] 发的也是它），
  /// 之后新来的待报等它交上去后另成一份。
  CrashReportOffer? currentOffer() {
    if (!_enabled) return null;
    final CrashReportOffer? offer = _nextOffer();
    if (offer == null) return null;
    final int sinceLast = _nowMs() - _state.lastSubmittedAt;
    if (_state.lastSubmittedAt > 0 &&
        sinceLast >= 0 &&
        sinceLast < kCrashReportMergeWindow.inMilliseconds) {
      return null;
    }
    return offer;
  }

  CrashReportOffer? _nextOffer() =>
      _state.inFlight?.offer ??
      (_state.pending.isEmpty
          ? null
          : CrashReportOffer(
              _state.pending,
              droppedCount: _state.droppedCount,
            ));

  /// 本次启动已经问过 / 发过（启动前的提示处理过，首页出来后就不再问一遍）。
  bool get handledThisSession => _handledThisSession;

  void markHandledThisSession() => _handledThisSession = true;

  /// 用户点了「不用了」：给他看的那批（[currentOffer]）作废。
  void decline() {
    if (_state.inFlight != null) {
      _save(_state.copyWith(inFlight: () => null));
      return;
    }
    _save(_state.copyWith(pending: const <CrashOccurrence>[], droppedCount: 0));
  }

  /// 提交一份报告（[buildDraft] 按语言组标题与说明）：有没交上去的那批就重发它（同一个
  /// 幂等键）；否则把当前待报连同新幂等键挪进「提交中」并落盘，再发。成功只清这一批并
  /// 记下时刻与反馈 id；正文没交上去原样抛（这批与幂等键都留着，下次重试拿回的是同一条
  /// 反馈）。两次尝试之间新记的闪退留在待报里，不进这一批。
  Future<FeedbackSubmitResult> submit(
    FeedbackService service,
    FeedbackDraft Function(CrashReportOffer offer, String submissionKey)
    buildDraft,
  ) async {
    CrashReportBatch? batch = _state.inFlight;
    if (batch == null) {
      if (_state.pending.isEmpty) throw StateError('no pending crash report');
      final CrashReportBatch created = CrashReportBatch(
        submissionKey: _newKey(),
        occurrences: _state.pending,
        droppedCount: _state.droppedCount,
      );
      _save(
        _state.copyWith(
          inFlight: () => created,
          pending: const <CrashOccurrence>[],
          droppedCount: 0,
        ),
      );
      batch = created;
    }
    final FeedbackSubmitResult result = await service.submit(
      buildDraft(batch.offer, batch.submissionKey),
    );
    final CrashReportBatch sent = batch;
    _save(
      _state.copyWith(
        // 等待期间用户「不用了」/ 另一处提交已经清掉或换了批次时不动它。
        inFlight: () =>
            identical(_state.inFlight, sent) ? null : _state.inFlight,
        lastSubmittedAt: _nowMs(),
        lastTicketId: result.ticket.id,
      ),
    );
    return result;
  }

  Future<void>? _backgroundSubmission;

  /// 在后台提交当前报告、不等它（启动即闪退且开着自动发送时：初始化不能等网络）。
  /// 失败只记日志——这批与幂等键都留在状态文件里，下次启动再发、拿回同一条反馈。
  /// [adoptSpool] 会先等它跑完，免得把还在写的 [spoolDir] 并走 / 删掉。
  void submitInBackground(
    FeedbackService service,
    FeedbackDraft Function(CrashReportOffer offer, String submissionKey)
    buildDraft,
  ) {
    final Future<void>? previous = _backgroundSubmission;
    _backgroundSubmission = () async {
      if (previous != null) await previous;
      try {
        await submit(service, buildDraft);
      } on Object catch (e, st) {
        ErrorLogService.instance.log('CrashReport.background_send', e, st);
      }
    }();
  }

  /// 把启动前提交在 [spoolDir] 里的回执并进反馈中心（[FeedbackService.adoptSpool]）。
  /// 后台提交（[submitInBackground]）还在跑时先等它跑完。
  Future<void> adoptSpool(FeedbackService service) async {
    final Future<void>? running = _backgroundSubmission;
    if (running != null) await running;
    final Directory? spool = spoolDir;
    if (spool == null || !spool.existsSync()) return;
    try {
      await service.adoptSpool(spool);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('CrashReport.adopt_spool', e, st);
    }
  }
}
