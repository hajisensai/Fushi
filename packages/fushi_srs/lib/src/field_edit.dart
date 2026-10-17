/// 可编辑字段的修改记录与合并（铁律 H）。
///
/// 每次修改一个字段键产生一条不可变记录：dot = (writerId, seq)，ctx = 修改时本机已应用的因果上下文
/// （含闭包，见 causal_context.dart）。记录 b 支配 a ⇔ b.ctx 含 a.dot。每个字段键保留没被支配的记录
/// （多值寄存器）：只剩一条或值都相同 = 无冲突；多条且值不同 = 并发冲突，当前生效值取 sortKey 较大者，
/// 候选全部留在集合里，按字段类别决定要不要用户处理。
library;

import 'dart:convert';

import 'causal_context.dart';
import 'hlc.dart';
import 'ids.dart';
import 'ordering.dart';
import 'style_dedup.dart';

/// 被修改的实体种类。持久化名冻结。
enum SrsEntityKind {
  profile('profile'),
  deck('deck'),
  noteType('notetype'),
  note('note'),
  card('card');

  const SrsEntityKind(this.wire);

  final String wire;

  static SrsEntityKind? tryParse(String? wire) {
    for (final SrsEntityKind k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// 字段类别：只决定冲突时要不要用户处理（铁律 H 三级）。
enum SrsFieldClass {
  /// 笔记字段值、笔记类型的字段 / 模板定义与 CSS：并发不同值 = 「待裁决」，必须由用户定。
  content,

  /// 卡片的 suspended / buried / 旗标 / deckId：最后修改生效，被覆盖的进冲突记录、可一键改回。
  flag,

  /// 牌组设置、算法、参数组、profile 设置：同 [flag]。
  setting,

  /// 界面状态（牌组列表的折叠）：同样随同步、最后修改生效，但被覆盖的候选不进
  /// 「同步冲突记录」——两台设备各自开合同一棵牌组树是常态，不是需要用户裁决的冲突。
  viewState,
}

/// 字段键约定（冻结）。
abstract final class SrsFieldKeys {
  /// 行删除时刻（毫秒；null = 未删 / 已恢复）。删除优先。
  static const String deleted = 'deleted';

  // note
  static String noteField(String fieldId) => 'f/$fieldId';
  static const String noteTags = 'tags';
  static const String noteSource = 'source';

  /// 笔记的「首选牌组」：按需生成的卡片的初始 deckId 由它确定（第六轮审查第 14 条）。
  static const String noteDeck = 'deck';

  /// 笔记的当前笔记类型（「更改笔记类型」写它；没有记录时取身份记录里的创建类型）。
  /// 身份记录不可变，所以换类型是一条修改记录，不是改身份记录。
  static const String noteType = 'noteType';

  // notetype
  static const String name = 'name';
  static String fieldDef(String fieldId) => 'fieldDef/$fieldId';
  static String templateDef(String templateId) => 'tmplDef/$templateId';
  static const String css = 'css';
  static const String termField = 'termField';

  // card
  static const String suspended = 'suspended';
  static const String buriedUntilDay = 'buried';
  static const String flag = 'flag';
  static const String cardDeck = 'deck';

  /// 卡片的「前身」：更改笔记类型时新卡继承旧卡的复习历史与标志（值恒为 true）。
  /// 每个前身一个键（集合语义）：两台设备各自加同一个前身是同值，不冲突。
  static String cardHistoryFrom(String predecessorCardId) =>
      '$cardHistoryFromPrefix$predecessorCardId';
  static const String cardHistoryFromPrefix = 'historyFrom/';

  // deck
  static const String deckParent = 'parent';
  static const String deckParamsMode = 'paramsMode';
  static const String deckLimits = 'limits';
  static const String deckSteps = 'steps';
  static const String deckRetention = 'retention';

  /// algorithm 与 algorithmAuto 合成一个键，一起写、一起合并。
  static const String deckAlgorithm = 'algorithm';
  static const String deckFsrs6Params = 'fsrs6Params';
  static const String deckFsrs7Params = 'fsrs7Params';
  static const String deckAutoOptimize = 'autoOptimize';
  static const String deckOptimizeBaseline = 'optimizeBaseline';
  static const String deckMaxInterval = 'maxInterval';

  /// 牌组列表里是否收起子牌组（对应 Anki deck 的 `collapsed` / Deck.Common.study_collapsed）。
  static const String deckCollapsed = 'collapsed';

  /// 复习时自动播放卡面音频（bool，缺省 = true；对应 Anki 预设的 autoplay /
  /// disable_autoplay）。随参数继承走 own 祖先。
  static const String deckAutoplay = 'autoplay';

  /// 答案面重播时先播问题音频（bool，缺省 = true；对应 Anki 的 replayq /
  /// skip_question_when_replaying_answer 取反）。随参数继承走 own 祖先。
  static const String deckReplayQuestion = 'replayQuestion';

  // profile
  static const String dayRolloverHour = 'dayRolloverHour';
  static const String utcOffsetMin = 'utcOffsetMin';
}

/// 字段类别表（只在这里写一次）。
SrsFieldClass srsFieldClassOf(SrsEntityKind kind, String fieldKey) {
  switch (kind) {
    case SrsEntityKind.note:
      if (fieldKey == SrsFieldKeys.noteDeck) return SrsFieldClass.setting;
      // 换类型：最后修改生效，被覆盖的进同步冲突记录、可一键改回（字段值另按内容类处理）。
      if (fieldKey == SrsFieldKeys.noteType) return SrsFieldClass.setting;
      if (fieldKey == SrsFieldKeys.deleted) return SrsFieldClass.content;
      return SrsFieldClass.content;
    case SrsEntityKind.noteType:
      if (fieldKey == SrsFieldKeys.name || fieldKey == SrsFieldKeys.termField) {
        return SrsFieldClass.setting;
      }
      return SrsFieldClass.content;
    case SrsEntityKind.card:
      return SrsFieldClass.flag;
    case SrsEntityKind.deck:
      if (fieldKey == SrsFieldKeys.deckCollapsed) {
        return SrsFieldClass.viewState;
      }
      return SrsFieldClass.setting;
    case SrsEntityKind.profile:
      return SrsFieldClass.setting;
  }
}

/// 一条修改记录。创建即不可变；ID 由 dot 决定。
class SrsFieldEdit {
  SrsFieldEdit({
    required this.profileUid,
    required this.entityKind,
    required this.entityId,
    required this.fieldKey,
    required this.dot,
    required this.ctx,
    required this.value,
    required this.hlc,
    required this.timeSource,
    this.machine = false,
  }) : id = SrsIds.fieldEdit(dot.writerId, dot.seq);

  final String id;
  final String profileUid;
  final SrsEntityKind entityKind;
  final String entityId;
  final String fieldKey;
  final SrsDot dot;
  final SrsCausalContext ctx;

  /// JSON 值（null 合法：例如 deleted = null 表示恢复）。
  final Object? value;
  final Hlc hlc;
  final SrsTimeSource timeSource;

  /// 机器产出（自动优化写的参数组）。它与别的记录并发时不进「同步冲突记录」列表
  /// （第六轮审查第 10 条：两台设备各自自动优化，否则会经常出现「同步时有 N 处冲突」）。
  final bool machine;

  String get registerKey => '${entityKind.wire}/$entityId/$fieldKey';

  /// b 支配 a ⇔ b 的作者修改时已经看见了 a。
  bool dominates(SrsFieldEdit other) =>
      other.dot != dot && ctx.contains(other.dot);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'p': profileUid,
    'k': entityKind.wire,
    'e': entityId,
    'f': fieldKey,
    'w': dot.writerId,
    's': dot.seq,
    'ctx': ctx.toJson(),
    'v': value,
    'hlc': hlc.encode(),
    'ts': timeSource.wire,
    if (machine) 'm': true,
  };

  static SrsFieldEdit fromJson(Map<String, Object?> json) {
    final SrsEntityKind? kind = SrsEntityKind.tryParse(json['k'] as String?);
    if (kind == null) {
      throw FormatException('unknown entity kind ${json['k']}');
    }
    final SrsFieldEdit edit = SrsFieldEdit(
      profileUid: json['p']! as String,
      entityKind: kind,
      entityId: json['e']! as String,
      fieldKey: json['f']! as String,
      dot: SrsDot(json['w']! as String, json['s']! as int),
      ctx: SrsCausalContext.fromJson(json['ctx']),
      value: json['v'],
      hlc: Hlc.decode(json['hlc']! as String),
      timeSource: SrsTimeSource.parse(json['ts'] as String?),
      machine: json['m'] == true,
    );
    final Object? id = json['id'];
    if (id is String && id != edit.id) {
      throw FormatException('field edit id mismatch: $id vs ${edit.id}');
    }
    return edit;
  }

  /// 规范编码（内容哈希 / 逐字节比较用）。
  String canonical() => srsCanonicalJson(toJson());

  @override
  String toString() => 'Edit($registerKey=$value @${dot})';
}

/// 键排序的 JSON 编码：同内容逐字节相同。
String srsCanonicalJson(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) => '$k').toList()
      ..sort();
    return <String, Object?>{
      for (final String k in keys) k: _canonicalize(value[k]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

/// 「值相同」的唯一口径（冲突判定、no-op 判定都用它）。字段文本按去重规范形比较：
/// 内联 `<style>` 与它的共享样式引用行是同一内容（见 style_dedup.dart），所以同一份内容
/// 无论哪台设备、去没去重写下，都不会被判成并发冲突。
bool _sameValue(Object? a, Object? b) {
  if (a is String && b is String) return srsSameFieldText(a, b);
  return srsCanonicalJson(a) == srsCanonicalJson(b);
}

/// 一个字段键的合并结果。
class SrsRegister {
  SrsRegister._(this.key, this.live);

  final String key;

  /// 没被支配的记录，按 sortKey 从大到小。第一条是当前生效值。
  final List<SrsFieldEdit> live;

  bool get isEmpty => live.isEmpty;

  SrsFieldEdit? get winner => live.isEmpty ? null : live.first;

  Object? get value => winner?.value;

  /// 并发且值不同。
  bool get conflicted {
    for (int i = 1; i < live.length; i++) {
      if (!_sameValue(live[i].value, live.first.value)) return true;
    }
    return false;
  }

  /// 要进「同步冲突记录」/「待裁决」的被覆盖候选：值与生效值不同、且不全是机器产出。
  List<SrsFieldEdit> get visibleLosers {
    final SrsFieldEdit? w = winner;
    if (w == null) return const <SrsFieldEdit>[];
    final List<SrsFieldEdit> losers = <SrsFieldEdit>[
      for (int i = 1; i < live.length; i++)
        if (!_sameValue(live[i].value, w.value)) live[i],
    ];
    if (losers.isEmpty) return losers;
    if (w.machine && losers.every((SrsFieldEdit e) => e.machine)) {
      return const <SrsFieldEdit>[];
    }
    return losers;
  }
}

/// 合并一个字段键上的全部记录（顺序无关、幂等）。
///
/// [serverTimeOf] 返回事件的 S(e)（未知 = null），只影响生效值的选取，不影响支配关系。
SrsRegister srsResolveRegister(
  String key,
  Iterable<SrsFieldEdit> edits, {
  int? Function(String eventId)? serverTimeOf,
}) {
  final Map<String, SrsFieldEdit> byId = <String, SrsFieldEdit>{
    for (final SrsFieldEdit e in edits) e.id: e,
  };
  final List<SrsFieldEdit> all = byId.values.toList();
  final List<SrsFieldEdit> live = <SrsFieldEdit>[
    for (final SrsFieldEdit a in all)
      if (!all.any((SrsFieldEdit b) => b.dominates(a))) a,
  ];
  SrsSortKey keyOf(SrsFieldEdit e) =>
      srsSortKey(e.hlc, e.id, serverTimeOf?.call(e.id));
  live.sort((SrsFieldEdit a, SrsFieldEdit b) => keyOf(b).compareTo(keyOf(a)));
  return SrsRegister._(key, List<SrsFieldEdit>.unmodifiable(live));
}

/// 「删除优先」：删除寄存器里只要有一条没被支配的记录值非空，行就是已删。
/// 返回生效的删除时刻（非空候选里 sortKey 最大的那条的值），未删返回 null。
int? srsEffectiveDeletedAt(SrsRegister deleted) {
  for (final SrsFieldEdit e in deleted.live) {
    final Object? v = e.value;
    if (v is int) return v;
  }
  return null;
}

/// 与删除记录并发（谁也没看见谁）的内容修改：删除优先，但这些修改留在行里，
/// 作为一条内容类待裁决项「另一台设备删除了这条笔记，这里有未同步的修改：恢复 / 确认删除」。
List<SrsFieldEdit> srsEditsConcurrentWithDelete(
  SrsRegister deleted,
  Iterable<SrsFieldEdit> contentLive,
) {
  final List<SrsFieldEdit> deletes = <SrsFieldEdit>[
    for (final SrsFieldEdit e in deleted.live)
      if (e.value is int) e,
  ];
  if (deletes.isEmpty) return const <SrsFieldEdit>[];
  return <SrsFieldEdit>[
    for (final SrsFieldEdit c in contentLive)
      if (deletes.any(
        (SrsFieldEdit d) => !d.ctx.contains(c.dot) && !c.ctx.contains(d.dot),
      ))
        c,
  ];
}

/// 本机写入者：分配 dot、维护已应用的因果上下文（闭包）。
class SrsEditWriter {
  SrsEditWriter({
    required this.writerId,
    int lastSeq = 0,
    SrsCausalContext? applied,
  }) : _lastSeq = lastSeq,
       _applied = applied ?? SrsCausalContext.empty();

  final String writerId;
  int _lastSeq;
  SrsCausalContext _applied;

  int get lastSeq => _lastSeq;

  /// 本机已应用（含闭包）的上下文。持久化它与 [lastSeq]。
  SrsCausalContext get applied => _applied;

  /// 应用一条记录（本机或对端；备份 / 快照带来的也一样）：dot 与它的 ctx 一起并入。
  void apply(SrsFieldEdit edit) {
    _applied = _applied.merge(edit.ctx).add(edit.dot);
  }

  /// 并入整个上下文（与事件存储的 seenContext 对齐）。
  void adopt(SrsCausalContext context) {
    _applied = _applied.merge(context);
  }

  /// 新建一条本机修改记录并立即应用。ctx 覆盖本机已应用的全部记录，
  /// 所以「改回 / 确认」天然支配全部候选，冲突在所有设备上随之消失。
  SrsFieldEdit create({
    required String profileUid,
    required SrsEntityKind entityKind,
    required String entityId,
    required String fieldKey,
    required Object? value,
    required Hlc hlc,
    required SrsTimeSource timeSource,
    bool machine = false,
  }) {
    _lastSeq += 1;
    final SrsFieldEdit edit = SrsFieldEdit(
      profileUid: profileUid,
      entityKind: entityKind,
      entityId: entityId,
      fieldKey: fieldKey,
      dot: SrsDot(writerId, _lastSeq),
      ctx: _applied,
      value: value,
      hlc: hlc,
      timeSource: timeSource,
      machine: machine,
    );
    apply(edit);
    return edit;
  }
}

/// 值没变且没有冲突的编辑不产生记录（no-op 不递增 seq，避免云盘文件被无意义刷新）。
bool srsEditIsNoop(SrsRegister current, Object? newValue) =>
    !current.isEmpty &&
    !current.conflicted &&
    _sameValue(current.value, newValue);
