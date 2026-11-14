/// 有效日志选取（铁律 B）的 Dart 视图。规则只在 Rust 里写一份（native/fushi_fsrs/src/history.rs）；S/D 输入收集
/// （铁律 A，src/projection.rs `memory_input`）只在内核内部用（排程、复习重放、优化器训练集），Dart 不再调。
/// 不做状态机重放。
library;

import 'history_kernel.dart';
import 'review_log.dart';

/// 一张卡的日志视图。[serverTimeOf] 给出事件的 S(e)。
///
/// 排序与有效日志选取（撤销、等价导入、排程归属）只在 Rust 里写一份
/// （native/fushi_fsrs/src/history.rs，见 history_kernel.dart）；这里只是选取结果的视图。
/// 一次构造一次 FFI 调用，成批构造用 [SrsCardHistory.many]（一批一次）。
class SrsCardHistory {
  /// 一份历史（一次 FFI 调用；空历史不进原生侧）。
  factory SrsCardHistory(
    Iterable<SrsReviewLog> logs, {
    int? Function(String eventId)? serverTimeOf,
  }) => many(<SrsHistoryInput>[(logs.toList(), serverTimeOf)]).single;

  SrsCardHistory._(List<SrsReviewLog> logs, SrsHistorySelection sel)
    : all = <SrsReviewLog>[for (final int i in sel.order) logs[i]],
      lastEffective = sel.lastEffective < 0 ? null : logs[sel.lastEffective],
      _schedulerFrom = sel.schedulerFrom < 0 ? null : logs[sel.schedulerFrom] {
    for (int k = 0; k < all.length; k++) {
      _position[all[k].id] = k;
      if (sel.status[k] & srsHistoryClamped != 0) _clamped.add(all[k].id);
    }
    effective = <SrsReviewLog>[
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEffective != 0) all[k],
    ];
    revoked = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryRevoker != 0) all[k].revokesId!,
      // 同一事件的副本里撤销的是被并掉的那份时，留下的那份也算被撤销（history.rs `EventKey`）。
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryRevoked != 0) all[k].id,
    };
    equivalentImports = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEquivalentImport != 0) all[k].id,
    };
  }

  /// 从 [toWire] 的线格式还原（远程复习库：历史在主机上选取好，客户端只还原视图，不重选）。
  SrsCardHistory._decoded(
    this.all,
    Set<String> effectiveIds,
    Set<String> clamped,
    this.lastEffective,
    this._schedulerFrom,
    Set<String> revoked,
    Set<String> equivalentImports,
  ) {
    this.revoked = revoked;
    this.equivalentImports = equivalentImports;
    for (int k = 0; k < all.length; k++) {
      _position[all[k].id] = k;
    }
    _clamped.addAll(clamped);
    effective = <SrsReviewLog>[
      for (final SrsReviewLog l in all)
        if (effectiveIds.contains(l.id)) l,
    ];
  }

  /// [toWire] 的逆。
  factory SrsCardHistory.fromWire(Map<String, Object?> json) {
    final List<SrsReviewLog> all = <SrsReviewLog>[
      for (final Object? l in json['all']! as List<Object?>)
        SrsReviewLog.fromJson((l! as Map).cast<String, Object?>()),
    ];
    SrsReviewLog? byId(Object? id) =>
        id == null ? null : all.firstWhere((SrsReviewLog l) => l.id == id);
    Set<String> ids(String key) => <String>{
      for (final Object? id
          in (json[key] as List<Object?>?) ?? const <Object?>[])
        id! as String,
    };
    return SrsCardHistory._decoded(
      all,
      ids('eff'),
      ids('clamped'),
      byId(json['last']),
      byId(json['sched']),
      ids('rev'),
      ids('eq'),
    );
  }

  /// 选取结果的线格式（远程复习库把主机上的历史带给客户端）。
  Map<String, Object?> toWire() => <String, Object?>{
    'all': <Map<String, Object?>>[for (final SrsReviewLog l in all) l.toJson()],
    'eff': <String>[for (final SrsReviewLog l in effective) l.id],
    'clamped': _clamped.toList(),
    'last': lastEffective?.id,
    'sched': _schedulerFrom?.id,
    'rev': revoked.toList(),
    'eq': equivalentImports.toList(),
  };

  /// 一批历史，与输入同序；整批一次 FFI 调用。
  static List<SrsCardHistory> many(List<SrsHistoryInput> inputs) {
    final List<SrsHistorySelection> sel = srsSelectHistories(inputs);
    return <SrsCardHistory>[
      for (int i = 0; i < inputs.length; i++)
        SrsCardHistory._(inputs[i].$1, sel[i]),
    ];
  }

  /// 全部日志（含 undo、被撤销的、不认识的；同 ID 只留最后一条；同一事件的多 ID 副本每一份都在，ID 不是组里
  /// 最小的那几份标 [srsHistoryDuplicate]、不算有效，见 history.rs `EventKey`），按 sortKey 升序。
  final List<SrsReviewLog> all;

  /// 有效日志（kind 已知且不是 undo、没被撤销、不是被判等价的导入日志、不是同一事件里非代表的副本），按 sortKey 升序。
  late final List<SrsReviewLog> effective;

  /// 被 undo 撤销的日志 ID（undo 的目标；目标不在本历史里也算；同一事件的副本被撤销时，[all] 里留下的那份也算）。
  late final Set<String> revoked;

  /// 被判与原生日志等价、因此不算有效的导入日志 ID。
  late final Set<String> equivalentImports;

  /// 最后一条有结果的有效日志；没有 = 新卡。
  final SrsReviewLog? lastEffective;

  /// 决定排程归属的那条 handOff（最后一条有结果的有效 handOff）。
  final SrsReviewLog? _schedulerFrom;

  final Map<String, int> _position = <String, int>{};
  final Set<String> _clamped = <String>{};

  /// [a] 在排序里是否在 [b] 之后（两条都得是本历史 [all] 里的日志）。排序键只在 Rust 里算。
  bool isAfter(SrsReviewLog a, SrsReviewLog b) =>
      _position[a.id]! > _position[b.id]!;

  /// [log] 的排序键被钳位（HLC 物理时间超过它所在批次的 S + 10 分钟）。
  bool isClamped(SrsReviewLog log) => _clamped.contains(log.id);

  /// 卡片当前排程状态 = 最后一条有效日志的结果；scheduler 另由 [scheduler] 决定。
  SrsScheduleResult get state {
    final SrsScheduleResult base =
        lastEffective?.result ?? SrsScheduleResult.initial;
    final String owner = scheduler;
    return base.scheduler == owner ? base : base.copyWith(scheduler: owner);
  }

  /// 卡片归谁排程：最后一条有效 handOff 事件（移交 / 收回）的方向；没有 = fushi。
  /// 导入锚点、评分都不改归属，同一个导入操作永远同一种结果。
  String get scheduler =>
      _schedulerFrom?.result!.scheduler ?? SrsScheduler.fushi;

  /// 进统计 / 优化器训练集的评分日志（被撤销、被判等价的都已排除）。
  List<SrsReviewLog> get effectiveRatings => <SrsReviewLog>[
    for (final SrsReviewLog l in effective)
      if (l.isRatingReview && l.rating != null) l,
  ];
}
