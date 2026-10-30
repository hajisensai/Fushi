/// 可编辑字段的修改记录与合并结果（铁律 H）。
///
/// 每次修改一个字段键产生一条不可变记录：dot = (writerId, seq)，ctx = 修改时本机已应用的因果上下文
/// （含闭包，见 causal_context.dart）。记录 b 支配 a ⇔ b.ctx 含 a.dot。每个字段键保留没被支配的记录
/// （多值寄存器）：只剩一条或值都相同 = 无冲突；多条且值不同 = 并发冲突，当前生效值取 sortKey 较大者，
/// 候选全部留在集合里，按字段类别决定要不要用户处理。
///
/// 合并规则（支配、排序键与钳位、「值相同」、删除优先、冲突候选）只在 Rust 里写一份
/// （native/fushi_fsrs/src/registers.rs，见 register_kernel.dart）；这里的 [SrsRegister] 只是结果视图。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'causal_context.dart';
import 'hlc.dart';
import 'ids.dart';

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

  /// 字段说明（字符串；空串 = 清空）。与 [fieldDef] 分开：改名 / 调序与改说明互不冲突，
  /// 不认识它的旧版本只是不显示，不会在改名时把它抹掉。
  static String fieldDescription(String fieldId) =>
      '$fieldDescriptionPrefix$fieldId';
  static const String fieldDescriptionPrefix = 'fieldDesc/';
  static String templateDef(String templateId) => 'tmplDef/$templateId';
  static const String css = 'css';
  static const String termField = 'termField';

  /// 词频序字段（fieldId；null = 按字段名 `FreqSort` 认）：制卡占位符 `{frequency-harmonic-rank}`
  /// 写进的那个字段。牌组「新卡顺序 = 按词频」时，新卡按这个字段里的名次出卡。
  static const String freqField = 'freqField';

  // card
  static const String suspended = 'suspended';
  static const String buriedUntilDay = 'buried';
  static const String flag = 'flag';
  static const String cardDeck = 'deck';

  /// 新卡在出卡队列里的位置（int；null / 没有记录 = 没排过，按笔记创建时刻出卡）。
  /// 「按词频重排新卡」写它，对应 Anki 新卡的 `due`（队列位置）。只影响新卡的出卡
  /// 顺序：学过的卡排程只来自日志，这个值留着也不起作用。
  static const String cardNewPosition = 'newPos';

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

  /// 牌组在同级里的手动排序位（num，小的在前；缺省 = 排在有位置的之后、按名字排）。
  /// Anki 没有这一项（它只按名字排），导出时不带。
  static const String deckPosition = 'position';

  /// 复习时自动播放卡面音频（bool，缺省 = true；对应 Anki 预设的 autoplay /
  /// disable_autoplay）。随参数继承走 own 祖先。
  static const String deckAutoplay = 'autoplay';

  /// 答案面重播时先播问题音频（bool，缺省 = true；对应 Anki 的 replayq /
  /// skip_question_when_replaying_answer 取反）。随参数继承走 own 祖先。
  static const String deckReplayQuestion = 'replayQuestion';

  /// RWKV-Instant 排队设置（Map，三项一起写、一起合并，见 [SrsRwkvQueueSettings]）：
  /// `minReviews` 每天最少复习数、`repeatReviews` / `repeatSeconds` 同日重复的间隔守卫。
  /// 对应上游 kuma3 的 RWKV 牌组选项；缺省 = 上游默认。随参数继承走 own 祖先。
  static const String deckRwkvQueue = 'rwkvQueue';

  /// 新卡出卡顺序（[SrsNewCardOrder.wire]；缺省 = 按词频）。随参数继承走 own 祖先。
  static const String deckNewOrder = 'newOrder';

  /// 新卡计划（Map，见 [SrsNewCardPlan]）：`week` 每周新卡任务、`auto` 按复习量自动调整、
  /// `budget` 复习预算百分比、`boost` 复习少时多出新卡的百分比。一起写、一起合并；
  /// 与 [deckLimits] 一样是牌组自己的值，不随参数继承。
  static const String deckNewPlan = 'newPlan';

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
      // 词条字段 / 词频序字段都是「指向哪个字段」的设置：最后修改生效，不按内容冲突处理。
      if (fieldKey == SrsFieldKeys.name ||
          fieldKey == SrsFieldKeys.termField ||
          fieldKey == SrsFieldKeys.freqField) {
        return SrsFieldClass.setting;
      }
      return SrsFieldClass.content;
    case SrsEntityKind.card:
      // 新卡位置是一整批机械重排的产物：两台设备各自重排同一牌组是常态，每张卡都进
      // 「同步冲突记录」只会刷屏，所以同折叠状态一样按界面状态处理（最后修改生效）。
      if (fieldKey == SrsFieldKeys.cardNewPosition) {
        return SrsFieldClass.viewState;
      }
      return SrsFieldClass.flag;
    case SrsEntityKind.deck:
      if (fieldKey == SrsFieldKeys.deckCollapsed ||
          fieldKey == SrsFieldKeys.deckPosition) {
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

  SrsFieldEdit._verified({
    required this.id,
    required this.profileUid,
    required this.entityKind,
    required this.entityId,
    required this.fieldKey,
    required this.dot,
    required this.ctx,
    required this.value,
    required this.hlc,
    required this.timeSource,
    required this.machine,
  });

  /// 原生内核已校验过的落库原文（kind 认识、必填键齐全、ID 与 dot 相符）：ID 直接取原文里的，
  /// 不再逐条派生（派生要一次 FFI）。
  static SrsFieldEdit _fromVerifiedJson(Map<String, Object?> json) {
    final String writer = json['w']! as String;
    final int seq = json['s']! as int;
    final Object? id = json['id'];
    return SrsFieldEdit._verified(
      id: id is String ? id : SrsIds.fieldEdit(writer, seq),
      profileUid: json['p']! as String,
      entityKind: SrsEntityKind.tryParse(json['k'] as String?)!,
      entityId: json['e']! as String,
      fieldKey: json['f']! as String,
      dot: SrsDot(writer, seq),
      ctx: SrsCausalContext.fromJson(json['ctx']),
      value: json['v'],
      hlc: Hlc.decode(json['hlc']! as String),
      timeSource: SrsTimeSource.parse(json['ts'] as String?),
      machine: json['m'] == true,
    );
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

/// 一条修改记录在原生内核批次里的形态：落库原文（canonical JSON 的 UTF-8）与 S(e)。
/// 内存里已有对象的（[SrsFieldEdit] 直接构造 / 刚解析的）带着对象；落库原文按需才在 Dart 侧解析
/// （缓存刷新只用物化视图，不解析修改记录）。
final class SrsEditItem {
  /// 落库原文。
  SrsEditItem.stored(this.json, this.serverTime) : _edit = null;

  /// 内存里的记录（规范编码后交给内核）。
  SrsEditItem.of(SrsFieldEdit edit, this.serverTime)
    : json = utf8.encode(edit.canonical()),
      _edit = edit;

  final Uint8List json;
  final int? serverTime;
  SrsFieldEdit? _edit;

  /// 解析好的记录。只对内核已校验过的批次调用（见 register_kernel.dart）。
  SrsFieldEdit get edit => _edit ??= SrsFieldEdit._fromVerifiedJson(
    (jsonDecode(utf8.decode(json)) as Map).cast<String, Object?>(),
  );
}

/// 一个字段键的合并结果（原生内核算好的视图）。
class SrsRegister {
  /// 由内核结果构造：[liveIndices] 是没被支配的记录（按 sortKey 从大到小）在 [items] 里的下标，
  /// [loserIndices] 是要进「同步冲突记录」/「待裁决」的被覆盖候选。
  SrsRegister.fromKernel(
    this.key,
    List<SrsEditItem> items,
    List<int> liveIndices, {
    required this.conflicted,
    required List<int> loserIndices,
  }) : _items = items,
       _live = liveIndices,
       _losers = loserIndices;

  final String key;
  final List<SrsEditItem> _items;
  final List<int> _live;
  final List<int> _losers;

  /// 没被支配的记录，按 sortKey 从大到小。第一条是当前生效值。
  late final List<SrsFieldEdit> live = List<SrsFieldEdit>.unmodifiable(
    <SrsFieldEdit>[for (final int i in _live) _items[i].edit],
  );

  bool get isEmpty => _live.isEmpty;

  SrsFieldEdit? get winner => _live.isEmpty ? null : _items[_live.first].edit;

  Object? get value => winner?.value;

  /// 并发且值不同（「值相同」的口径见 registers.rs `same_value`：字段文本按释义样式去重的规范形比较）。
  final bool conflicted;

  /// 要进「同步冲突记录」/「待裁决」的被覆盖候选：值与生效值不同、且不全是机器产出。
  List<SrsFieldEdit> get visibleLosers => <SrsFieldEdit>[
    for (final int i in _losers) _items[i].edit,
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
