/// 复习日志事件（铁律 A / B）。日志是唯一事实来源，每条日志自带「这次操作后」的完整排程结果。
library;

import 'algorithm.dart';
import 'fsrs_engine.dart';
import 'hlc.dart';
import 'field_edit.dart' show srsCanonicalJson;

/// 日志格式版本。不认识的字段原样保留（[SrsReviewLog.extra]），不认识的 kind 原样保留且不参与状态选取。
const int srsLogFormatVersion = 1;

/// 「恢复到备份时间点」写出的日志在 `extra` 里带这个键（值 = 备份 ID；持久化名冻结）。
/// 带它的 manual 日志是记忆状态的起点（见 native/fushi_fsrs/src/projection.rs `is_restore_state`）；旧版本原样保留。
const String srsRestoreLogExtraKey = 'restoreOf';

/// 恢复写出的「重放副本」在 `extra` 里带这个键（值 = 被重放的原日志 ID；持久化名冻结，只作追溯）。
const String srsReplayOfLogExtraKey = 'replayOf';

/// 日志种类（持久化名冻结）。
abstract final class SrsLogKind {
  static const String review = 'review';
  static const String manual = 'manual';
  static const String reschedule = 'reschedule';
  static const String importAnchor = 'importAnchor';
  static const String handOff = 'handOff';
  static const String undo = 'undo';

  static const Set<String> known = <String>{
    review,
    manual,
    reschedule,
    importAnchor,
    handOff,
    undo,
  };
}

/// 卡片队列（持久化名冻结）。
enum SrsQueue {
  newCard('new'),
  learning('learning'),
  review('review'),
  relearning('relearning');

  const SrsQueue(this.wire);

  final String wire;

  static SrsQueue parse(String? wire) {
    for (final SrsQueue q in values) {
      if (q.wire == wire) return q;
    }
    return SrsQueue.newCard;
  }
}

/// 复习类型 = 这次操作**之前**卡片所在的队列（对齐 Anki revlog 的 type）。
///
/// 第六轮审查第 6 条：修订版 8 只有导入日志带 ankiRevlogType，原生日志没有；
/// 「第一条是学习类评分」、导出 revlog 的 type 都需要它，靠「上一条有效日志的 queue」推导又会随 S(e)
/// 改变排序而变。所以**每条日志在创建时把它写进事件内容**，之后不再推导。
abstract final class SrsReviewType {
  static const String learn = 'learn';
  static const String review = 'review';
  static const String relearn = 'relearn';
  static const String filtered = 'filtered';
  static const String manual = 'manual';
  static const String rescheduled = 'rescheduled';

  /// 评分类（参与导入等价判定与 S/D 历史）。
  static const Set<String> rating = <String>{learn, review, relearn};

  /// 原生评分：由复习前的队列确定。
  static String ofQueue(SrsQueue before) => switch (before) {
    SrsQueue.newCard || SrsQueue.learning => learn,
    SrsQueue.review => review,
    SrsQueue.relearning => relearn,
  };

  /// Anki revlog.type（0 learn, 1 review, 2 relearn, 3 filtered, 4 manual, 5 rescheduled）。
  static String fromAnki(int type) => switch (type) {
    0 => learn,
    1 => review,
    2 => relearn,
    3 => filtered,
    4 => manual,
    5 => rescheduled,
    _ => manual,
  };

  static int toAnki(String type) => switch (type) {
    learn => 0,
    review => 1,
    relearn => 2,
    filtered => 3,
    rescheduled => 5,
    _ => 4,
  };
}

/// 谁在排这张卡。
abstract final class SrsScheduler {
  static const String fushi = 'fushi';
  static const String anki = 'anki';
}

/// 日志来源。
abstract final class SrsLogOrigin {
  static const String fushi = 'fushi';
  static const String anki = 'anki';
}

/// 「这次操作后」的完整排程状态。
class SrsScheduleResult {
  const SrsScheduleResult({
    required this.queue,
    this.dueDay,
    this.dueAt,
    this.scheduledDays = 0,
    this.learningStep = 0,
    this.memory,
    this.lastReviewedAt,
    this.reps = 0,
    this.lapses = 0,
    this.scheduler = SrsScheduler.fushi,
    this.ease,
  });

  /// 新卡初始状态。
  static const SrsScheduleResult initial = SrsScheduleResult(
    queue: SrsQueue.newCard,
  );

  final SrsQueue queue;

  /// review 队列：日历日序号（1970-01-01 起的天数，铁律 G）。
  final int? dueDay;

  /// learning / relearning：毫秒时间戳。
  final int? dueAt;
  final int scheduledDays;
  final int learningStep;
  final SrsMemory? memory;

  /// 最近一次真实评分的时刻（与本条日志的操作时刻分离）。
  final int? lastReviewedAt;
  final int reps;
  final int lapses;
  final String scheduler;

  /// SM-2 ease（千分比，只在导入锚点上有，用于历史不完整时的 SM-2 换算）。
  final int? ease;

  SrsScheduleResult copyWith({
    SrsQueue? queue,
    int? dueDay,
    int? dueAt,
    bool clearDue = false,
    int? scheduledDays,
    int? learningStep,
    SrsMemory? memory,
    int? lastReviewedAt,
    bool clearLastReviewed = false,
    int? reps,
    int? lapses,
    String? scheduler,
  }) => SrsScheduleResult(
    queue: queue ?? this.queue,
    dueDay: clearDue ? dueDay : (dueDay ?? this.dueDay),
    dueAt: clearDue ? dueAt : (dueAt ?? this.dueAt),
    scheduledDays: scheduledDays ?? this.scheduledDays,
    learningStep: learningStep ?? this.learningStep,
    memory: memory ?? this.memory,
    lastReviewedAt: clearLastReviewed
        ? lastReviewedAt
        : (lastReviewedAt ?? this.lastReviewedAt),
    reps: reps ?? this.reps,
    lapses: lapses ?? this.lapses,
    scheduler: scheduler ?? this.scheduler,
    ease: ease,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'queue': queue.wire,
    if (dueDay != null) 'dueDay': dueDay,
    if (dueAt != null) 'dueAt': dueAt,
    'ivl': scheduledDays,
    'step': learningStep,
    if (memory != null) 'mem': memory!.toJson(),
    if (lastReviewedAt != null) 'lastReviewedAt': lastReviewedAt,
    'reps': reps,
    'lapses': lapses,
    'scheduler': scheduler,
    if (ease != null) 'ease': ease,
  };

  static SrsScheduleResult fromJson(Map<String, Object?> json) =>
      SrsScheduleResult(
        queue: SrsQueue.parse(json['queue'] as String?),
        dueDay: json['dueDay'] as int?,
        dueAt: json['dueAt'] as int?,
        scheduledDays: (json['ivl'] as int?) ?? 0,
        learningStep: (json['step'] as int?) ?? 0,
        memory: SrsMemory.fromJson(json['mem']),
        lastReviewedAt: json['lastReviewedAt'] as int?,
        reps: (json['reps'] as int?) ?? 0,
        lapses: (json['lapses'] as int?) ?? 0,
        scheduler: (json['scheduler'] as String?) ?? SrsScheduler.fushi,
        ease: json['ease'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is SrsScheduleResult &&
      srsCanonicalJson(other.toJson()) == srsCanonicalJson(toJson());

  @override
  int get hashCode => srsCanonicalJson(toJson()).hashCode;

  @override
  String toString() => 'Result${toJson()}';
}

/// 一条复习日志（事件，创建即不可变，同 ID 内容必须相同）。
class SrsReviewLog {
  const SrsReviewLog({
    required this.id,
    required this.profileUid,
    required this.cardId,
    required this.kind,
    required this.hlc,
    required this.occurredAt,
    required this.timeSource,
    required this.origin,
    required this.reviewType,
    this.rating,
    this.revokesId,
    this.durationMs = 0,
    this.paramsHash,
    this.algorithm,
    this.utcOffsetMin = 0,
    this.dayRolloverHour = 4,
    this.result,
    this.ankiRevlogId,
    this.extra = const <String, Object?>{},
    this.formatVersion = srsLogFormatVersion,
  });

  final String id;
  final String profileUid;
  final String cardId;

  /// [SrsLogKind] 之一，或本机不认识的值（原样保留）。
  final String kind;
  final int? rating;
  final String? revokesId;
  final Hlc hlc;

  /// 可信时间（毫秒）。
  final int occurredAt;
  final SrsTimeSource timeSource;
  final String origin;

  /// [SrsReviewType] 之一。
  final String reviewType;
  final int durationMs;
  final String? paramsHash;

  /// 实际用来排这一次的算法（fsrs6 / fsrs7）；导入的 Anki revlog 记 'anki'。
  final String? algorithm;

  /// 设备当时的 UTC 偏移与翻日时刻（统计按小时 / 按天时不受旅行影响，#2062）。
  final int utcOffsetMin;
  final int dayRolloverHour;

  /// 「这次操作后」的结果；undo 与不认识的 kind 没有。
  final SrsScheduleResult? result;

  /// 导入日志：Anki revlog id（= 复习毫秒时刻）。
  final int? ankiRevlogId;

  /// 不认识的字段原样保留、原样转写。
  final Map<String, Object?> extra;
  final int formatVersion;

  String get writerId => hlc.writerId;

  bool get isKnownKind => SrsLogKind.known.contains(kind);

  bool get isRatingReview =>
      kind == SrsLogKind.review && SrsReviewType.rating.contains(reviewType);

  SrsAlgorithm? get algorithmEnum => SrsAlgorithm.tryParse(algorithm);

  Map<String, Object?> toJson() => <String, Object?>{
    ...extra,
    'id': id,
    'p': profileUid,
    'card': cardId,
    'kind': kind,
    if (rating != null) 'rating': rating,
    if (revokesId != null) 'revokes': revokesId,
    'hlc': hlc.encode(),
    'at': occurredAt,
    'ts': timeSource.wire,
    'origin': origin,
    'rtype': reviewType,
    if (durationMs != 0) 'dur': durationMs,
    if (paramsHash != null) 'params': paramsHash,
    if (algorithm != null) 'alg': algorithm,
    'utcOff': utcOffsetMin,
    'rollover': dayRolloverHour,
    if (result != null) 'res': result!.toJson(),
    if (ankiRevlogId != null) 'ankiId': ankiRevlogId,
    'fv': formatVersion,
  };

  static const Set<String> _knownKeys = <String>{
    'id',
    'p',
    'card',
    'kind',
    'rating',
    'revokes',
    'hlc',
    'at',
    'ts',
    'origin',
    'rtype',
    'dur',
    'params',
    'alg',
    'utcOff',
    'rollover',
    'res',
    'ankiId',
    'fv',
  };

  static SrsReviewLog fromJson(Map<String, Object?> json) {
    final Object? res = json['res'];
    return SrsReviewLog(
      id: json['id']! as String,
      profileUid: json['p']! as String,
      cardId: json['card']! as String,
      kind: json['kind']! as String,
      rating: json['rating'] as int?,
      revokesId: json['revokes'] as String?,
      hlc: Hlc.decode(json['hlc']! as String),
      occurredAt: json['at']! as int,
      timeSource: SrsTimeSource.parse(json['ts'] as String?),
      origin: (json['origin'] as String?) ?? SrsLogOrigin.fushi,
      reviewType: (json['rtype'] as String?) ?? SrsReviewType.manual,
      durationMs: (json['dur'] as int?) ?? 0,
      paramsHash: json['params'] as String?,
      algorithm: json['alg'] as String?,
      utcOffsetMin: (json['utcOff'] as int?) ?? 0,
      dayRolloverHour: (json['rollover'] as int?) ?? 4,
      result: res is Map
          ? SrsScheduleResult.fromJson(res.cast<String, Object?>())
          : null,
      ankiRevlogId: json['ankiId'] as int?,
      extra: <String, Object?>{
        for (final MapEntry<String, Object?> e in json.entries)
          if (!_knownKeys.contains(e.key)) e.key: e.value,
      },
      formatVersion: (json['fv'] as int?) ?? srsLogFormatVersion,
    );
  }

  String canonical() => srsCanonicalJson(toJson());

  @override
  String toString() => 'Log($kind $id r=$rating ${hlc.encode()})';
}
