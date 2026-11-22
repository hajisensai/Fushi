/// Fushi SRS 的数据库副本：事件落 Rust 独占的 srs.db（读写都是内核命令），行为与
/// fushi_srs 的 SrsMemoryReplica / SrsEventStore 一致（同一套合并函数），外加本机缓存与 app 用的查询 / 操作 API。
///
/// - 同步的只有三种事件：身份记录、修改记录、复习日志（另有不认识的事件原样保留）。
/// - 卡片行与笔记缓存只在本机，可随时由事件重建（[rebuildCaches]）。
/// - 事件创建即不可变；任何环节都不改事件内容。唯一的表示层例外是释义样式去重（[styles]）：
///   笔记字段值里够大的内联 `<style>` 在落库时换成共享样式文件的引用行，修改记录的身份、因果、
///   排序字段一律不动，合并时两种表示按同一内容比较（fushi_srs style_dedup.dart）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate' show TransferableTypedData;
import 'dart:typed_data' show TypedData, Uint8List;
import 'dart:math';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_collection_binding.dart';
import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_edit_undo.dart';
import 'package:fushi_engine/srs/srs_entity_views.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';

export 'package:fushi_engine/srs/srs_edit_undo.dart';
export 'package:fushi_engine/srs/srs_entity_views.dart' show SrsEntityView;

/// 本进程（isolate）的身份：持久化的校时读数（服务器时间 + 开机时钟读数）只在写下它的进程里接着用。
/// 同一进程里重开 profile / 副本时它不变，校时不丢；进程重启（含重新开机，开机时钟归零）后换新。
final String _srsProcessBootId =
    '${DateTime.now().millisecondsSinceEpoch}_'
    '${Random.secure().nextInt(1 << 30)}';

/// 本机时间（[SrsTrustedClock]）：校时那一刻的服务器时间 + 原生开机时钟（含睡眠、不受改系统时间影响，
/// [SrsCore.bootTimeMs]）之后走过的量。进程重启后到下一次校时前按墙钟 + 上一个进程留下的偏移估算。
SrsTrustedClock srsProcessTrustedClock(SrsCore core) => SrsTrustedClock(
  wallClockMs: () => DateTime.now().millisecondsSinceEpoch,
  bootClockMs: core.bootTimeMs,
  bootId: _srsProcessBootId,
);

/// 条件写笔记字段的一项（见 [SrsDbStore.editNoteFieldsIf]）：字段现值仍是 [expect] 才写成 [value]。
typedef SrsNoteFieldWrite = ({
  String noteId,
  String fieldId,
  String expect,
  String value,
});

/// [SrsDbStore.answerAndStudy] 给了基准（`expectBase`）而基准不成立：出题之后这张卡又被作答 / 撤销过、或已经不在
/// 了。什么都没落库。
class SrsStaleCardError implements Exception {
  const SrsStaleCardError(this.cardId);

  final String cardId;

  @override
  String toString() =>
      'SrsStaleCardError: card $cardId changed since it was shown';
}

/// 批量写的一项：某实体的某字段改成 [value]（见 [SrsDbStore.editFieldsBatch]）。
class SrsFieldChange {
  const SrsFieldChange(this.kind, this.entityId, this.key, this.value);

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
}

/// 「按词频重排新卡」读到的一张新卡（[SrsDbStore.newCardsInDeck]）。
class SrsNewCardEntry {
  const SrsNewCardEntry({
    required this.card,
    required this.note,
    required this.noteType,
    required this.ord,
    required this.position,
  });

  final SrsCardCacheRow card;
  final SrsNoteView note;
  final SrsNoteTypeView noteType;

  /// 同一笔记的第几张卡（标准类型 = 模板序号，填空 = cN - 1），与 AnkiConnect `ord` 同口径。
  final int ord;

  /// 此刻在出卡队列里的位置：排过的卡是它的 [SrsCardCacheRow.newPosition]；没排过的卡
  /// 按出卡顺序接在已排的最大位置后面编号（只供比较与撤销，不落库）。与
  /// [SrsDbStore.compareNewCardOrder] 的顺序一致、严格递增。
  final int position;
}

/// [SrsDbStore.moveDeck] 的结果。
enum SrsDeckMoveResult {
  moved,

  /// 本来就在那里。
  unchanged,

  /// 牌组或目标牌组不存在（已删）。
  missing,

  /// 目标是它自己或它的子孙。
  intoOwnSubtree,

  /// 目标下已有同名牌组。
  nameTaken,
}

/// 牌组列表的一行。
class SrsDeckSummary {
  const SrsDeckSummary({
    required this.deck,
    required this.fullName,
    required this.depth,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    required this.newBudget,
    required this.totalCards,
    this.parentId,
    this.rwkvPending = false,
    this.rwkvScheduled = false,
    this.reviewMinutesLeft,
  });

  final SrsDeckView deck;
  final String fullName;
  final int depth;

  /// 牌组树里解析后的父牌组（成环已打破；顶层 = null）。列表的折叠按它找后代。
  final String? parentId;
  final int newCount;
  final int learnCount;
  final int reviewCount;
  final SrsNewCardBudget newBudget;
  final int totalCards;

  /// 牌组按分钟计每日复习上限（[SrsLimitUnit.minutes]）时今天还剩的复习分钟（内核按同一份已用量算，不足一分钟
  /// 记一分钟，用满为 0）；其余单位 / 这一层忽略复习上限时为 null。分钟单位下 [reviewCount] 是没用满就不截的
  /// 全部到期 / 合格卡（可能成千），界面的到期一格改显示这个剩余量（[SrsReviewCell]）。
  final int? reviewMinutesLeft;

  /// 子树里有 RWKV 牌组而 RWKV 还没准备好（下载 / 回放 / 出错）：这些牌组的复习卡这一次一张没算进
  /// [reviewCount]（也不出），所以 [reviewCount] 不是「今天没有到期」。界面据此显示「准备中」，不显示 0。
  final bool rwkvPending;

  /// 子树里有按 RWKV-Instant 排队的牌组（就绪与否都算）：这些牌组的复习卡不看存下的到期日，按 RWKV 预测的
  /// 今天结束时的回忆率挑（降到目标保留率以下的就是今天到期；今天已答过的卡按此刻的回忆率，[_instantInput]），
  /// 已算进 [reviewCount]。
  final bool rwkvScheduled;
}

/// 今天（[SrsDbStore.dayContext] 的日界）已做的复习：首页复习条的「今日」一行。口径与复习统计页
/// 「今天」一节（内核 `stats_report` 的 `todayStats`，不按牌组筛选）相同：有效复习投影里的评分复习。
class SrsTodayReviewSummary {
  const SrsTodayReviewSummary({
    required this.count,
    required this.durationMs,
    required this.again,
  });

  static const SrsTodayReviewSummary empty = SrsTodayReviewSummary(
    count: 0,
    durationMs: 0,
    again: 0,
  );

  /// 评分复习次数。
  final int count;

  /// 作答用时之和（毫秒）。
  final int durationMs;

  /// 其中评「重来」的次数。
  final int again;

  /// 正确率（非「重来」的占比）；今天还没复习时为 null。
  double? get correctRate => count == 0 ? null : (count - again) / count;

  @override
  bool operator ==(Object other) =>
      other is SrsTodayReviewSummary &&
      other.count == count &&
      other.durationMs == durationMs &&
      other.again == again;

  @override
  int get hashCode => Object.hash(count, durationMs, again);
}

/// 复习页一张卡的全部信息。
class SrsCardDetail {
  const SrsCardDetail({
    required this.card,
    required this.note,
    required this.noteType,
    required this.template,
    required this.deckName,
  });

  final SrsCardCacheRow card;
  final SrsNoteView note;
  final SrsNoteTypeView noteType;
  final SrsTemplateDef? template;
  final String deckName;
}

/// 渲染好的卡面。
class SrsRenderedCard {
  const SrsRenderedCard({
    required this.question,
    required this.answer,
    required this.css,
    required this.isEmpty,
    this.fields = const <String, String>{},
    this.fushiCardDefinitions,
    this.fushiCardFront = const <FushiCardItem>[],
    this.fushiCardBack = const <FushiCardItem>[],
    this.nativeFallback,
  });

  final String question;
  final String answer;
  final String css;
  final bool isEmpty;

  /// 笔记字段（按字段名）。
  final Map<String, String> fields;

  /// 内置「Fushi 卡片」能原生画时（样式没改、正背面认得出区块布局，见
  /// [srsFushiCardNative]）：只含释义区的背面（见 [kFushiCardDefinitionsTemplate]），复习页
  /// 据此走原生 + 释义 WebView 的混合渲染。其它类型、或模板改到原生画不了的 Fushi 卡片为
  /// null（整面 WebView，与 Anki 一致）。
  final String? fushiCardDefinitions;

  /// 原生 Fushi 卡面正面 / 背面的区块布局（[fushiCardLayoutOf]，自上而下；删掉的区块不在
  /// 里面；HTML 区块已按笔记字段展开）。只在 [fushiCardDefinitions] 非 null 时有意义。
  final List<FushiCardItem> fushiCardFront;
  final List<FushiCardItem> fushiCardBack;

  /// [fushiCardDefinitions] 为 null（引擎判定原生 Fushi 卡面画不了）时卡在哪一道
  /// （[srsFushiCardNative]）；能原生画时为 null。非 Fushi 卡片是
  /// [SrsCardNativeFallbackCode.notBuiltin]，远程老主机没带原因时是
  /// [SrsCardNativeFallbackCode.remoteUnknown]。app 侧再判的区块 / HTML 子集原因不在这里。
  final SrsCardNativeFallback? nativeFallback;
}

/// [SrsDbStore.writeEdits] 的一项：给某实体的某个字段键写一个值。
class SrsEditSpec {
  const SrsEditSpec(this.kind, this.entityId, this.key, this.value);

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
}

/// [SrsDbStore.notes] 单次调用物化的笔记数的最大值（测试核对一次操作在 Dart 侧同时持有的笔记视图有上界，BUG-5176）。
/// 按 isolate 计；测试自己清零。
@visibleForTesting
int srsDebugMaxNotesPerRead = 0;

/// [SrsDbStore.writeRetype] 的类型层面计划：内核据此逐条笔记换类型 / 补迁（native/fushi_fsrs/src/store/gen4/cmd/
/// writes_retype.rs 文件头「请求 `retype`」）。逐条笔记的判定与 Dart 的 `srsPlanNoteTypeChange` / `srsPlanLapisFieldFill`
/// 相同，只是在内核里做，宿主不物化笔记。
class SrsRetypePlan {
  const SrsRetypePlan({
    required this.noteIds,
    required this.from,
    required this.to,
    this.fieldMap = const <String, String?>{},
    this.templateMap = const <String, String?>{},
    this.fill = const <String, List<String>>{},
  });

  final List<String> noteIds;

  /// 源类型；null = 只补迁不换类型（当前不是 [to] 类型的笔记、已删除的笔记跳过）。给了就要求每条笔记都是它。
  final SrsNoteTypeView? from;
  final SrsNoteTypeView to;

  /// 目标 fieldId → 源 fieldId（null = 写空）。
  final Map<String, String?> fieldMap;

  /// 目标 templateId → 源 templateId（null = 新卡从头学）。
  final Map<String, String?> templateMap;

  /// 补迁：目标 fieldId → 候选源 fieldId（按优先顺序；取第一个有内容的）。
  final Map<String, List<String>> fill;

  static Map<String, Object?> _type(SrsNoteTypeView t) => <String, Object?>{
    'id': t.id,
    'cloze': t.isCloze,
    'templates': <String>[for (final SrsTemplateDef x in t.templates) x.id],
    'fields': <String>[for (final SrsFieldDef f in t.fields) f.id],
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'notes': noteIds,
    'from': from == null ? null : _type(from!),
    'to': _type(to),
    'fieldMap': fieldMap,
    'templateMap': templateMap,
    'fill': fill,
  };
}

/// 内核缓存刷新的配置（内核命令的 `caches`；[SrsDbStore] 打开时注册一次，`cache_config_set`）：[profileUid] 的默认
/// 牌组与各内置笔记类型（代码默认值 + 读音字段，readingKey 的来源）。只由 profile 的 uid 决定；换代迁移
/// （[SrsGen4Migration.run] 的 `caches`）给库里每个 profile 各算一份。
Map<String, Object?> srsCacheConfigFor(String profileUid) => <String, Object?>{
  'defaultDeck': SrsKernelIds(profileUid).defaultDeck,
  'builtins': <String, Object?>{
    for (final SrsBuiltinNoteTypeSpec spec in kSrsBuiltinNoteTypes)
      spec.key: <String, Object?>{
        'b': srsBuiltinNoteTypeKernelValue(
          srsBuiltinNoteType(profileUid, spec),
        ),
        'reading': srsBuiltinReadingFieldId(profileUid, spec.key),
      },
  },
};

/// [SrsDbStore.importDrafts] 的结果。
final class SrsImportDraftsResult {
  const SrsImportDraftsResult(this.existed, this.foreignNotes);

  /// 这批身份记录里**落库前就已存在**的实体 ID（内核回包 `existed`）。
  final Set<String> existed;

  /// 身份记录被实体归属闸拒掉的笔记 ID（内核回包 `foreign` 指向的笔记身份记录草稿，
  /// native/fushi_fsrs/src/store/gen4/cmd/writes_owner.rs）：同一个库里别的集合（另一份 profile）已有这个 ID、身份
  /// 结构不同——同一个 guid 落到了另一个笔记类型（`.apkg` 不合并笔记模板时的副本、文本导入用户选的类型）。这条笔记
  /// 连同同批写给它的字段 / 牌组 / 标签一条都没落，导入路径要记冲突、不算新增（BUG-5005 复核：以前不读，报告照记
  /// 「已添加」，卡片实际不存在）。
  final Set<String> foreignNotes;
}

/// 本机事件的草稿（[SrsDbStore.importDrafts]）：修改记录只记「给哪个实体的哪个字段键写什么值」，
/// 写入者序号与 HLC 等到落库的同一个独占区里才分配；其余事件（身份记录、来源给定 HLC 的日志）
/// 已定稿，原样带上。
sealed class SrsEventDraft {
  const SrsEventDraft();
}

/// 已定稿的事件（身份记录、日志、不认识的事件）。
final class SrsReadyDraft extends SrsEventDraft {
  const SrsReadyDraft(this.event);

  final SrsEvent event;
}

/// 一条待分配序号的本机修改记录。
final class SrsEditDraft extends SrsEventDraft {
  const SrsEditDraft(
    this.kind,
    this.entityId,
    this.key,
    this.value, {
    this.machine = false,
    this.initial = false,
    this.ifChanged = false,
  }) : assert(!(initial && ifChanged), 'initial and ifChanged are exclusive');

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
  final bool machine;

  /// 新建实体的初值：攒草稿时以为本机还没有这个实体的记录（[SrsDbStore.newEditDrafts] 不给
  /// current）。落库时（[SrsDbStore.importDrafts] 的独占区里）若这个键已经有修改记录——攒批
  /// 期间同步把对端的同一实体（ID 由 guid / 全名确定性派生）应用进来了——这条初值就不落：
  /// 它在落库时才分配 HLC 与因果上下文，会支配对端的编辑、把用户的新值盖成源里的旧值。
  final bool initial;

  /// 只有会改变现值时才落（值没变且无冲突的键不产生记录）：由内核在落库的那一笔里读现值判（`apply` / `change`
  /// 输入项的 `chg`，native/fushi_fsrs/src/store/sync2/changing.rs）——判定与写入之间插不进别的写入，Dart 不为它
  /// 预读修改记录。同一批里同一个键出现多次时按顺序判。导入的一批（[SrsDbStore.importDrafts]）不认它。
  final bool ifChanged;
}

/// 长操作（删牌组）的进度：已完成 / 总数（同一单位，例如张卡）。
typedef SrsProgress = void Function(int done, int total);

/// 墓碑能不能物理清除：[deleted] 是笔记的删除寄存器（已确认是「已删除」），[serverTimeOf] 给出
/// 事件的服务器时间 S（未知 = null）。策略见 srs_purge.dart 的 `srsTombstoneExpired`。
typedef SrsTombstonePredicate =
    bool Function(
      SrsRegister deleted,
      int? Function(String eventId) serverTimeOf,
    );

/// [SrsDbStore.purgeDeletedNotes] 一块的结果。
class SrsPurgeChunk {
  const SrsPurgeChunk({
    required this.notes,
    required this.cardIds,
    required this.events,
    required this.mediaRefs,
  });

  static const SrsPurgeChunk empty = SrsPurgeChunk(
    notes: <String>[],
    cardIds: <String>[],
    events: 0,
    mediaRefs: <String>{},
  );

  /// 真被清除的笔记。
  final List<String> notes;

  /// 随之清除的卡。
  final List<String> cardIds;
  int get cards => cardIds.length;

  /// 删掉的事件行数（身份记录 + 修改记录 + 复习日志）。
  final int events;

  /// 被清除笔记的字段值引用过的媒体文件名（未核对存活引用）。
  final Set<String> mediaRefs;
}

/// [SrsDbStore.nativeRatingLogsNear] 粗筛的时间窗（毫秒）。须不小于卡片历史内核判「导入日志与原生日志是同一次复习」
/// 的时刻容差（native/fushi_fsrs/src/history.rs `IMPORT_EQUIVALENCE_TOLERANCE_MS`）：窗只决定取哪些候选，判定在内核。
const int srsImportEquivalenceWindowMs = 1000;

/// 一条 Anki 导入的复习日志（[SrsDbStore.ankiImportedLogsAt]）：在哪张卡、对应哪条 revlog、内容，以及那张卡此刻
/// 所属的笔记与是否可见（卡没有缓存行——笔记换了类型后不再属于它的旧卡——时 [noteId] 为 null、不可见）。
class SrsAnkiLogAt {
  const SrsAnkiLogAt({
    required this.cardId,
    required this.revlogId,
    required this.rating,
    required this.reviewType,
    required this.durationMs,
    required this.noteId,
    required this.visible,
  });

  final String cardId;
  final int revlogId;
  final int? rating;

  /// `SrsReviewType` 的持久化名。
  final String reviewType;
  final int durationMs;
  final String? noteId;
  final bool visible;
}

/// 副本被 [SrsDbStore.retire] 作废之后，排着的与以后再来的写入抛它。[store] 是被作废的那份副本：在跑的同步 / 维护
/// 据此认出「我用的副本被换掉了」（与写失败重读也失败的作废区分开，那种仍是普通 [StateError]）。
class SrsStoreRetiredError extends StateError {
  SrsStoreRetiredError(this.store, super.message);

  final SrsDbStore store;
}

/// 辅助进程（查词弹窗等只读打开的库）里，这个 profile 还没有本机身份：集合、绑定与身份只由主进程在打开 profile 时
/// 建（[SrsDbStore.open] → 内核 `identity`），辅助进程不写库。不是坏库、也不是要迁移：页面给「先在主窗口打开一次
/// 复习」的等待状态，主进程建好之后重试即可。
final class SrsProfileIdentityPending implements Exception {
  const SrsProfileIdentityPending(this.profile);

  final String profile;

  @override
  String toString() =>
      'SrsProfileIdentityPending: profile $profile has no identity yet '
      '(the main process creates it when it opens the profile)';
}

/// 一个 profile 的绑定代号（[SrsDbStore.bindingKey]）：集合标识、同步目录名、盐集合（升序）的 SHA-256 前 16 个十六进制位。
/// 只是 Dart 侧「库换没换」的比较值（RWKV 分数表的清空键），不进同步、不落内核。
String srsBindingKey({
  required String collection,
  required String dir,
  required List<String> salts,
}) => sha256
    .convert(utf8.encode(<String>[collection, dir, ...salts].join('\n')))
    .toString()
    .substring(0, 16);

/// profile 里显式写过的翻日时刻与生效的那条修改记录 ID（[SrsDbStore.syncedDayRollover]）。
typedef SrsDayRollover = ({int hour, String editId});

class SrsDbStore implements SrsSync2Host {
  SrsDbStore._({
    required this.core,
    required this.profileUid,
    required this.deviceId,
    required FsrsEngine? engine,
    required SrsTrustedClock trustedClock,
    required int Function() fallbackRolloverHour,
    required int Function() localOffsetMin,
    this.styles,
  }) : _engine = engine,
       _trusted = trustedClock,
       _fallbackRollover = fallbackRolloverHour,
       _localOffset = localOffsetMin;

  /// 打开（或首次初始化）某 profile 的 SRS 副本。
  ///
  /// [localOffsetMin]：本机此刻的 UTC 偏移（分钟），「今天」的时区只取它（见 [dayContext]）；缺省读系统时区。
  static Future<SrsDbStore> open({
    required SrsCore core,
    required String profileUid,
    required String deviceId,
    FsrsEngine? engine,
    SrsTrustedClock? trustedClock,
    int Function()? fallbackRolloverHour,
    int Function()? localOffsetMin,
    SrsStyleStore? styles,
  }) async {
    final SrsDbStore s = SrsDbStore._(
      core: core,
      profileUid: profileUid,
      deviceId: deviceId,
      engine: engine,
      trustedClock: trustedClock ?? srsProcessTrustedClock(core),
      fallbackRolloverHour:
          fallbackRolloverHour ?? () => SrsDayContext.defaultRolloverHour,
      localOffsetMin: localOffsetMin ?? SrsDayContext.localOffsetMin,
      styles: styles,
    );
    // 本机状态行（`local_state`）不要集合绑定，可以在身份之前读。
    final ({bool exists, bool epochStored}) local = await s._loadLocal();
    // 身份必须在第一条按集合的命令之前：全新安装 / 新建的 profile 在这里（主进程）建集合、绑定与本机身份，之后的
    // `cache_config_set` 等才有集合可用（交接说明「G9-4」「G7-5b」）。辅助进程只读：主进程还没建时抛
    // [SrsProfileIdentityPending]。
    await s._sync2Open();
    if (core.mode == SrsOpenMode.primary) {
      // 注册本 profile 的缓存配置（只有 Dart 知道的内置笔记类型默认值与默认牌组，派生层的输入）：内核与库里存的
      // 比，变了就整层重建（`cache_config_set`，native/fushi_fsrs/src/store/gen4/dispatch.rs）。
      await s._registerCacheConfig();
      // 新代的派生层是真相的纯函数、随写入维护：本机状态行不在（迁移不带协议 3 的那一行，交接说明 §8.2）不代表缓存
      // 过期，不再按「有事件却没有本机状态」整层重建。行没落盘时当场落下，否则每次打开都是新纪元、指纹每次都「变了」。
      // 本机第一次跑懂每日上限单位的版本的时刻（[limitUnitLegacyDecks]）同样在这里落下，只落一次。
      if (!local.epochStored || s._limitUnitSince == null) {
        await s._ensureLocalState();
      }
      await s.ensureBuiltins();
    }
    // 只读打开（查词弹窗等辅助进程）：注册类写入都是主进程的事，这里只读。
    // 根上 ID 的规范形最后读（内置实体建好之后；辅助进程上由主进程建过）。
    await s._loadRootIds();
    return s;
  }

  /// 本机在这个 profile 集合里的身份（内核 `identity`，native/fushi_fsrs/src/store/gen4/cmd/identity.rs）：设备 ID、
  /// 集合标识、同步目录名都取自回包，不再按 profile uid 拼。
  ///
  /// 主进程上没有就建（全新 profile：集合 = 按 uid 派生、目录名 = uid；建了时回包带 `bindingChanged`，由
  /// [_sync2Raw] 接）。辅助进程只读：已有身份照常读；没有时内核报只读（[SrsCoreReadOnlyException]），这里换成
  /// [SrsProfileIdentityPending]（等主进程开一次这个 profile），不当成打不开的库。
  ///
  /// 协议 3 的 `identity` 还顺带并旧库（`migrate`）与回旧版写入者（`legacyWriter`）：新代里迁移在开库之前整库做完
  /// （[SrsGen4Migration]），旧版写入者状态不迁移（设计 §2.4），请求不再带 `legacyDevice`。
  Future<void> _sync2Open() async {
    final Map<String, Object?> id;
    try {
      id = await _sync2(<String, Object?>{'op': 'identity', 'now': now().$1});
    } on SrsCoreReadOnlyException catch (_, stack) {
      Error.throwWithStackTrace(SrsProfileIdentityPending(profileUid), stack);
    }
    final String collection = id['collection']! as String;
    final String dir = id['dir']! as String;
    // 盐集合不在 identity 回包里：补盐不换集合也不换目录，却会改别名表（规范 ID 可能变），所以绑定代号要带上它。
    final List<String> salts =
        ((await _sync2(<String, Object?>{'op': 'collection_info'}))['salts']!
                as List<Object?>)
            .cast<String>()
            .toList()
          ..sort();
    _sync2Device = id['device']! as String;
    _sync2Collection = collection;
    _sync2Dir = dir;
    _bindingKey = srsBindingKey(collection: collection, dir: dir, salts: salts);
  }

  /// 绑定代号（[srsBindingKey]：集合 + 目录 + 盐集合的摘要）。打开之后恒非空；补盐 / 并入 / 认领之后会变。
  /// RWKV 分数表的清空键带着它（[rwkvScoresClearKey]）：换库不只发生在迁移之后重开（那时纪元会变），进程内的绑定
  /// 变化不重建本机状态行、纪元不变，只靠这一段让落库键与换之前不同。
  String? get bindingKey => _bindingKey;
  String? _bindingKey;

  /// 重新取一次身份（[_sync2Open]）：辅助进程（查词弹窗）每次重新激活这个 profile 时调。`bindingChanged` 只随
  /// 引起它的那条命令的回包回到发命令的进程（主进程），别的进程看不到：这里按绑定代号（集合 / 目录 / 盐）变没变自己判，
  /// 变了走同一条 [onBindingChanged]。主进程上调也无妨（已有身份时是一次读；这次 `identity` 自己建了身份、回包带
  /// `bindingChanged` 时 [_sync2Raw] 已经报过，这里不重复报）。
  Future<void> refreshIdentity() async {
    final String? before = _bindingKey;
    final int reportedBefore = _bindingChangeCount;
    await _sync2Open();
    final bool reported = _bindingChangeCount != reportedBefore;
    final bool changed = before != null && before != _bindingKey;
    if (changed && !reported) onBindingChanged();
    if (changed || reported) await _loadRootIds();
  }

  /// 本机在这个 profile 集合里的同步 v2 设备 ID（换身份后会变）。打开之后恒非空（[_sync2Open]）。
  String? get sync2Device => _sync2Device;
  String? _sync2Device;

  /// 这个 profile 绑定的集合标识（`identity` 的 `collection`）。打开之后恒非空；并入 / 认领之后会变。
  String? get sync2Collection => _sync2Collection;
  String? _sync2Collection;

  /// 这个 profile 的同步目录名（`identity` 的 `dir`，设计 §5.1：向内核要，不按 uid 拼）。打开之后恒非空。
  String? get sync2Dir => _sync2Dir;
  String? _sync2Dir;

  /// 绑定变化（内核回包的 `bindingChanged`，或辅助进程重取身份时发现集合 / 目录换了）的通知：按「库换了」处理，
  /// 订阅方（app 的 store provider）整份重建依赖这份库的东西——RWKV 服务按 `srsAttachRwkv` 的契约关旧挂新。
  Stream<void> get bindingChanges => _bindingChanges.stream;
  final StreamController<void> _bindingChanges =
      StreamController<void>.broadcast();

  /// 绑定变了：本对象按库内容记的缓存（根上 ID 的请求形、派生层缓存日志、笔记类型、牌组树、RWKV 候选）全部作废、
  /// 下次整份重读，再通知 [bindingChanges]。根上 ID 的规范形由调用方随后重读（[_loadRootIds]：要发命令，这里是同步的）。
  /// 由 [_sync2Raw]（回包带 `bindingChanged`）与 [refreshIdentity] 调。
  @visibleForTesting
  void onBindingChanged() {
    _kernelIds = null;
    _invalidateDerivedCaches();
    _noteTypeCache = null;
    _rwkvCandidateCache = null;
    _bindingChangeCount++;
    // 副本作废（[retire]）时控制器已关：作废之后还在途的读命令回包不再广播（订阅方也已随 provider 释放）。
    if (!_bindingChanges.isClosed) _bindingChanges.add(null);
  }

  /// 收到过几次绑定变化（[onBindingChanged]）。
  int _bindingChangeCount = 0;

  /// 收到过几次绑定变化（[onBindingChanged]）：测试用。
  @visibleForTesting
  int get debugBindingChanges => _bindingChangeCount;

  /// srs.db 的 Rust 句柄：全部读写都是它的命令（写命令在内核里读、算、写完；读命令见 srs_reads.dart），
  /// 表结构与 SQL 只在内核里（docs/specs/2026-10-23-srs-rust-store.md）。
  final SrsCore core;

  /// 本 profile 的一条只读查询（内核 `read`，native/fushi_fsrs/src/store/reads.rs）。
  Future<SrsReadResult> _read(
    String q, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    await _freshBinding(null);
    return srsRead(core, profileUid, q, args);
  }

  /// 同 [_read]，只要它的那一张表。
  Future<SrsColumns> _readTable(
    String q, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async => (await _read(q, args)).table;

  /// 身份记录（`read` 的 `entities`，不带 `bare` 时三列都在）。
  List<_EntityRow> _entityRowsOf(SrsColumns c) {
    final SrsStringColumn id = c.strings('id');
    final SrsStringColumn kind = c.strings('kind');
    final SrsStringColumn payload = c.strings('payload_json');
    return <_EntityRow>[
      for (int i = 0; i < c.rows; i++)
        (id: id[i], kind: kind[i], payloadJson: payload[i]),
    ];
  }

  /// 一类实体（或 [ids] 里的那些）的 ID（`read` 的 `entities` + `bare`）。
  Future<List<String>> _entityIdsWhere({
    SrsEntityKind? kind,
    Iterable<String>? ids,
  }) async => (await _readTable('entities', <String, Object?>{
    'bare': true,
    'kind': ?kind?.wire,
    if (ids != null) 'ids': ids.toList(),
  })).strings('id').toList();

  /// 卡片缓存行（`read` 的 `cards` / `card_columns`：全部列）。
  List<SrsCardCacheRow> _cardRowsOf(SrsColumns c) {
    final SrsStringColumn id = c.strings('id');
    final SrsStringColumn note = c.strings('note_id');
    final SrsStringColumn template = c.strings('template_id');
    final SrsIntColumn ord = c.ints('cloze_ord');
    final SrsStringColumn deck = c.strings('deck_id');
    final SrsIntColumn suspended = c.ints('suspended');
    final SrsIntColumn buried = c.ints('buried_until_day');
    final SrsIntColumn flag = c.ints('flag');
    final SrsIntColumn hidden = c.ints('hidden');
    final SrsStringColumn queue = c.strings('queue');
    final SrsIntColumn dueDay = c.ints('due_day');
    final SrsIntColumn dueAt = c.ints('due_at');
    final SrsIntColumn days = c.ints('scheduled_days');
    final SrsIntColumn reps = c.ints('reps');
    final SrsIntColumn lapses = c.ints('lapses');
    final SrsDoubleColumn stability = c.doubles('stability');
    final SrsDoubleColumn difficulty = c.doubles('difficulty');
    final SrsIntColumn last = c.ints('last_reviewed_at');
    final SrsStringColumn lastLog = c.strings('last_log_id');
    final SrsStringColumn scheduler = c.strings('scheduler');
    final SrsIntColumn created = c.ints('note_created_at');
    final SrsIntColumn position = c.ints('new_position');
    final SrsIntColumn freq = c.ints('freq_rank');
    return <SrsCardCacheRow>[
      for (int i = 0; i < c.rows; i++)
        SrsCardCacheRow(
          id: id[i],
          profileUid: profileUid,
          noteId: note[i],
          templateId: template[i],
          clozeOrd: ord[i],
          deckId: deck[i],
          suspended: suspended.flag(i),
          buriedUntilDay: buried.at(i),
          flag: flag[i],
          hidden: hidden.flag(i),
          queue: queue[i],
          dueDay: dueDay.at(i),
          dueAt: dueAt.at(i),
          scheduledDays: days[i],
          reps: reps[i],
          lapses: lapses[i],
          stability: stability.at(i),
          difficulty: difficulty.at(i),
          lastReviewedAt: last.at(i),
          lastLogId: lastLog.at(i),
          scheduler: scheduler[i],
          noteCreatedAt: created[i],
          newPosition: position.at(i),
          freqRank: freq.at(i),
        ),
    ];
  }

  /// 笔记缓存行（`read` 的 `notes`：全部列）。
  List<SrsNoteCacheRow> _noteRowsOf(SrsColumns c) {
    final SrsStringColumn id = c.strings('id');
    final SrsStringColumn type = c.strings('note_type_id');
    final SrsStringColumn guid = c.strings('guid');
    final SrsIntColumn created = c.ints('created_at');
    final SrsStringColumn deck = c.strings('deck_id');
    final SrsIntColumn deleted = c.ints('deleted_at');
    final SrsStringColumn term = c.strings('term_key');
    final SrsStringColumn reading = c.strings('reading_key');
    final SrsStringColumn sort = c.strings('sort_field');
    final SrsStringColumn tags = c.strings('tags_json');
    final SrsIntColumn pending = c.ints('pending_decision');
    final SrsIntColumn updated = c.ints('updated_at');
    final SrsStringColumn media = c.strings('media_refs');
    return <SrsNoteCacheRow>[
      for (int i = 0; i < c.rows; i++)
        SrsNoteCacheRow(
          id: id[i],
          profileUid: profileUid,
          noteTypeId: type[i],
          guid: guid[i],
          createdAt: created[i],
          deckId: deck.at(i),
          deletedAt: deleted.at(i),
          termKey: term[i],
          readingKey: reading[i],
          sortField: sort[i],
          tagsJson: tags[i],
          pendingDecision: pending.flag(i),
          updatedAt: updated[i],
          mediaRefs: media[i],
        ),
    ];
  }

  /// 笔记缓存行（`read` 的 `notes`，参数见 native/fushi_fsrs/src/store/reads.rs `notes`）。
  Future<List<SrsNoteCacheRow>> noteRows([
    Map<String, Object?> query = const <String, Object?>{},
  ]) async => _noteRowsOf(await _readTable('notes', query));

  /// 一列笔记缓存（`read` 的 `notes` + `fields: [column]`，其余参数同 [noteRows]）。
  Future<SrsColumns> noteColumns(
    List<String> columns, [
    Map<String, Object?> query = const <String, Object?>{},
  ]) => _readTable('notes', <String, Object?>{...query, 'fields': columns});

  /// 卡片缓存行（`read` 的 `cards`，参数见 native/fushi_fsrs/src/store/reads.rs `cards`）。
  Future<List<SrsCardCacheRow>> cardRowsWhere(
    Map<String, Object?> query,
  ) async => _cardRowsOf(await _readTable('cards', query));

  /// 几列卡片缓存（`read` 的 `cards` + `fields`，其余参数同 [cardRowsWhere]）。
  Future<SrsColumns> cardColumnsWhere(
    List<String> columns,
    Map<String, Object?> query,
  ) => _readTable('cards', <String, Object?>{...query, 'fields': columns});

  /// 只要 ID 列的卡片查询。
  Future<List<String>> _cardIdsWhere(Map<String, Object?> query) async =>
      (await cardColumnsWhere(const <String>[
        'id',
      ], query)).strings('id').toList();

  /// 本 profile 的一条只读查询的那一张表（给本文件之外的 store 扩展用：srs_note_type_store.dart 等）。
  Future<SrsColumns> readTable(
    String q, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => _readTable(q, args);

  /// 本 profile 的一条只读查询（含回包 JSON；参数见 native/fushi_fsrs/src/store/reads.rs）。
  Future<SrsReadResult> read(
    String q, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => _read(q, args);

  /// 笔记字段修改里含 [needle] 的笔记 ID（去重；`read` 的 `source_note_candidates`）。
  Future<List<String>> sourceNoteCandidates(String needle) async =>
      (await _readTable('source_note_candidates', <String, Object?>{
        'needle': needle,
      })).strings('id').toList();

  /// 未删除笔记按笔记类型的计数（`read` 的 `note_type_counts`：列 t、c）。
  Future<SrsColumns> readNoteTypeCounts() => _readTable('note_type_counts');

  @override
  final String profileUid;
  final String deviceId;

  /// 排程内核；null = 原生库不可用（只能浏览 / 编辑，不能复习）。
  FsrsEngine? get engine => _engine;
  FsrsEngine? _engine;

  /// RWKV-Instant 排队时「此刻回忆率」的来源（app 装配 `SrsRwkvService`，见 [_instantInput]）。它没准备好时
  /// RWKV 牌组的复习卡一张都不出（[SrsStudyState.rwkvPending]），**不**退回按 FSRS-7 存下的到期日排队。
  /// null = 这个宿主根本没有 RWKV 运行时（无头引擎 / 测试），RWKV 牌组按到期日排。
  SrsRwkvScheduling? rwkv;

  /// 释义样式去重的共享样式文件库；null = 不去重（字段值原样落库）。见 [compactStoredStyles]。
  final SrsStyleStore? styles;
  final SrsTrustedClock _trusted;
  int Function() _fallbackRollover;
  final int Function() _localOffset;

  /// 同一个 profile 重新激活时就地换上打开参数（[engine]、统计日界回退），不另开副本：同一个 uid 只该有一份活
  /// 副本，交接会作废在跑的同步 / 维护（srs_profile_stores.dart `activate`）。连接、uid、设备 ID 不在此列——
  /// 它们变了就不是同一份副本。
  void rebind({
    required FsrsEngine? engine,
    required int Function() fallbackRolloverHour,
  }) {
    _engine = engine;
    _fallbackRollover = fallbackRolloverHour;
  }

  /// 库的变化修订号：任何事件真正落库（本机产生或对端来的）+1（见 [changeFingerprint]）。内核持有（本机状态行的
  /// `revision`，native/fushi_fsrs/src/store/local_state.rs）：这里只由内核的回包赋值（[_loadLocal] /
  /// [_absorbLocalWrite]），Dart 自己不加。
  int _revision = 0;

  /// 当前修订号（同步可读；与 [changeFingerprint] 同一个数，不含纪元）。牌组列表据此判断一份重读
  /// 结果是不是在某次写入之后取的。收段通道自己做完的片推进的修订号要等下一条改投影命令的回包才到这里；要「任何
  /// 落库都变」的判据读 [landedFingerprint]。
  int get revision => _revision;

  /// 刷新键（[SrsCore.refreshKeys]）。每次现读：主进程是一次只读内存的同步 FFI（内核 `refresh_keys`，
  /// native/fushi_fsrs/src/store/gen4/refresh.rs），一次取回五个键；计数由内核按 profile、按类别持有，写命令提交之后
  /// 推进，Dart 不存镜像。各键「什么不让它变」与协议 3 相同（作答只动 [statsFingerprint] / [landedFingerprint]，
  /// 界面状态类修改只动结构键与 [landedFingerprint]）。辅助进程（Secondary）分不清别的进程写的是哪一类，五个键同值，
  /// 随主进程的任何写入变（只会多重读）。
  ///
  /// 库关了之后不会再有任何变化：读到的是关之前最后读到的那一组（[_keysAtClose]），按键记的缓存照旧命中——关库后
  /// 收尾的读者（RWKV 服务关闭时存快照要 [dayContext]）不必再去读已关的库。一次都没读到过时是 [_closedKey]。
  SrsRefreshKeys? get _refreshKeys {
    final SrsRefreshKeys? k = core.refreshKeys(profileUid);
    if (k == null) return _keysAtClose;
    return _keysAtClose = k;
  }

  /// 最后一次从内核读到的刷新键；只在库关了之后用（见 [_refreshKeys]），不是计数的镜像。
  SrsRefreshKeys? _keysAtClose;

  /// 库关了、且之前一次都没读到过键时的指纹（与任何开着时的值都不等：开着时的键形如 `<纪元>:<修订号>` 或
  /// `unstored:<修订号>`）。
  static const String _closedKey = 'closed';

  /// 统计指纹：统计页据此判断 [srsRevisionProvider] 的一跳要不要重读（见 `loadSrsStats`）。只随会改变统计结果的
  /// 落库变（界面状态类修改记录、同步簿记不算）。
  String get statsFingerprint => _refreshKeys?.stats ?? _closedKey;

  /// 内容指纹：同步冲突 / 待裁决 / 迁移提醒这类「整库扫一遍」的角标据此判断要不要重扫。评分只落日志时不变。
  String get contentFingerprint => _refreshKeys?.content ?? _closedKey;

  /// RWKV-Instant 分数表的全量刷新信号：只在牌组 / 配置类事件落库（预设归属、排队设置可能变了）、应用一批对端事件、
  /// 重读本机状态、派生层整层重建时变，复习日志与卡片自己的修改不动它——整表重查跟着每题走会与作答抢内存（以前
  /// 35 万条日志的 iPhone 收尾 OOM），排队设置里的「每答几题刷新」也靠它不随作答变。见 `SrsRwkvService` 文件头。
  String get rwkvScoresKey => _refreshKeys?.rwkv ?? _closedKey;

  /// 任何事件落库或可见性变化都变：与落盘修订号同口径，但不必等下一条回包。RWKV 服务据此判断「有没有新日志」
  /// （不变就不扫日志表）。
  String get landedFingerprint => _refreshKeys?.landed ?? _closedKey;

  /// 正在进行的收段会话；完成 = 会话结束。RWKV 回放（[rwkvReplayBytes]，整 profile 扫一遍日志）等它结束才跑，
  /// 会话开始前等在途的回放跑完（[_rwkvReplaysIdle]）：两者都随日志总量线性占内存，不能叠在一起。
  Completer<void>? _ingestSession;

  /// 在途的 [rwkvReplayBytes] 个数与「全部跑完」信号（收段会话开始时等它）。
  int _rwkvReplaysInFlight = 0;
  Completer<void>? _rwkvReplaysIdle;

  /// 正在收段（[sync2IngestBegin] 之后、[sync2IngestEnd] 之前）。RWKV 对齐据此把要整 profile 重放的那一步
  /// 推到会话结束之后（`SrsRwkvService`）。
  bool get sync2Ingesting => _ingestSession != null;

  /// 当前没有收段会话时立即完成，否则在会话（及紧接着的下一场）结束后完成。
  Future<void> sync2IngestSettled() async {
    for (Completer<void>? s = _ingestSession; s != null; s = _ingestSession) {
      await s.future;
    }
  }

  void _endIngestSession(Completer<void> session) {
    if (!identical(_ingestSession, session)) return;
    _ingestSession = null;
    session.complete();
  }

  /// 纪元 + 绑定代号：变了 = 分数表清空、按历史重算。纪元在本机状态行重建（覆盖恢复、迁移之后重开）时变；绑定代号
  /// （[bindingKey]）在进程内换库（补盐、并入、认领）时变——那时本机状态行不重建、纪元不变，只看纪元的话新挂上的
  /// RWKV 服务会把旧库的分数表当成仍有效（交接说明「G7-5b 复核修复」）。
  String get rwkvScoresClearKey => '$_epoch|${_bindingKey ?? ''}';

  /// 本机状态的随机纪元：本机状态被清空重建（覆盖恢复）后换一个，修订号从 0 重数也不会撞上旧指纹。内核生成并
  /// 持有（本机状态行的 `epoch`），这里只由内核的回包赋值。
  String _epoch = '';

  /// [writer]（修改记录 / HLC 的写入者）是不是本机：新代的本机设备 ID（[sync2Device]）。
  ///
  /// 新代没有旧版写入者（设计 §2.4 删旧写入者状态；`identity` 的 `legacyWriter` 归 G9-4 且新代没有对应物）：迁移进来的、
  /// 本机旧身份写的修改记录这里认不出是本机（只影响「谁改的」的显示，不影响合并）。
  bool isOwnWriter(String writer) => writer == _sync2Device;
  SrsTrustedClock get trustedClock => _trusted;
  bool get canSchedule => engine != null;

  // ------------------------------------------------------------------ 写锁

  /// 本机写入的独占区：「读现值 → 落库（内核分配修改记录序号 / HLC）→ 刷新缓存 → 存本机状态」
  /// 必须一气呵成，别的写入排在后面。
  ///
  /// 「读现值、算出要写哪些键」与「落库」之间若插进别的写入，这次写入是按过期的现值判的（值没变的键不写、导入的
  /// 初值该不该落）。序号、HLC、因果上下文都由内核在落库的命令里分配（`apply`，旧版 HLC 时钟见
  /// native/fushi_fsrs/src/store/legacy_clock.rs），Dart 不在内存里预分配——以前预分配时还有「后分配的先落库」的
  /// 窗口（BUG-3545）。
  ///
  /// 可重入：独占区里再调别的写方法直接执行（按 Zone 认）。
  ///
  /// 这把锁只排**本副本对象**的写入：它保护的是本对象的「读 → 算 → 一条内核命令」不被本对象的另一笔写入插进来、
  /// 以及本对象内存状态（缓存变更日志、修订号、收段会话）按回包的顺序推进。库本身的原子性不靠它——每条内核命令一次
  /// 持写锁、一个 SAVEPOINT，别的副本对象（别的 profile、同一 profile 的另一个对象）的命令在内核的写锁上排队。以前
  /// 还有一把套在外面、跨副本的锁（App 当前 profile 的副本的独占区）：那是因为写入经 Drift 事务跨多个 await 占着
  /// 共用的写连接，别的副本的语句会落进那笔事务；Drift 只读、没有跨调用的事务之后那把锁没有要保护的东西，删了。
  Future<T> runExclusive<T>(Future<T> Function() body) async {
    final StateError? unusable = _unusable;
    if (unusable != null) throw unusable;
    if (identical(Zone.current[_writeZoneKey], this)) return body();
    return _runExclusiveOwn(body);
  }

  Future<T> _runExclusiveOwn<T>(Future<T> Function() body) async {
    final Future<void>? prev = _writeTail;
    final Completer<void> mine = Completer<void>();
    _writeTail = mine.future;
    try {
      if (prev != null) await prev;
      // 排队期间前面那位把副本作废了（写失败重读也失败 / [retire]）：排着的也不再写。
      final StateError? retired = _unusable;
      if (retired != null) throw retired;
      return await runZoned(
        body,
        zoneValues: <Object, Object>{_writeZoneKey: this},
      );
    } finally {
      mine.complete();
      if (identical(_writeTail, mine.future)) _writeTail = null;
    }
  }

  /// 这个 profile 被删除：等本副本在途的写入做完，在独占区里跑 [body]（删它的数据），之后本副本作废——
  /// 还排着的、以后再来的写入一律明确失败（[_unusable]），不会把行写回一个已删的 uid。[body] 失败也作废。
  ///
  /// [reason]：作废原因（写进之后写入的报错）；缺省是「profile 被删除」。
  ///
  /// 一调用就置上 [isWindingDown]（排队等独占区之前）：在跑的同步 / 维护在下一个检查点收手，不再排新的写入。
  /// 最后一段独占区里先放掉本副本开着的收段会话（内核 `ingest_end`），再跑 [body]：之后同一 uid 的新副本才开得了
  /// 自己的会话，本副本那一轮 finally 里的 [sync2IngestEnd] 也不必（不能）再进独占区。
  Future<T> retire<T>(Future<T> Function() body, {String? reason}) {
    _retireRequested = true;
    return runExclusive(() async {
      try {
        final Completer<void>? session = _ingestSession;
        if (session != null) {
          _endIngestSession(session);
          await _sync2Raw(const <String, Object?>{'op': 'ingest_end'});
        }
        return await body();
      } finally {
        _unusable ??= SrsStoreRetiredError(
          this,
          'SRS store is unusable: '
          '${reason ?? 'profile $profileUid was deleted'}',
        );
        // 副本到此为止：绑定变化的通知不会再有，关掉控制器（订阅方的 done 随之触发）。
        unawaited(_bindingChanges.close());
      }
    });
  }

  /// [retire] 已被调用（可能还排在在途写入后面）。
  bool _retireRequested = false;

  /// 在跑的长任务（同步一轮、样式去重、媒体回收）该在下一个检查点收手：副本已作废，或作废已发起。
  bool get isWindingDown => _retireRequested || _unusable != null;

  /// 大批量写入（Anki 迁移 / .apkg 导入 / 同步收段）期间调高写连接的 WAL 自动 checkpoint 阈值、批与批之间留着页缓存，
  /// 结束后在另开的连接上把 WAL 并回一次再恢复原值。可嵌套。
  ///
  /// 深度、原值与阈值都由内核持有（`bulk_cache`，native/fushi_fsrs/src/store/mod.rs `bulk_begin` / `bulk_end`）：按库计数
  /// （几个 profile 的副本共用一个写连接），只有最外层改 / 恢复阈值并在恢复前并回 WAL。开始与结束各一条内核命令，
  /// Dart 不再经执行器发 PRAGMA。
  Future<T> bulkWrites<T>(Future<T> Function() body) async {
    await _bulkCache(true);
    try {
      return await body();
    } finally {
      await _bulkCache(false);
    }
  }

  /// 批量写入开始 / 结束（`bulk_cache`）：不针对 profile、不进 Dart 写锁。
  Future<void> _bulkCache(bool on) async {
    debugCoreCommands++;
    await _coreSync2(core.address, core.libraryPath, <String, Object?>{
      'op': 'bulk_cache',
      'on': on,
    }, const <Uint8List>[]);
  }

  /// 排在最后的写入完成时完成（只会正常完成）。
  Future<void>? _writeTail;

  /// 每个副本一把锁（嵌套打开的另一个副本不会误认成持锁）。
  final Object _writeZoneKey = Object();

  /// [withDeviceOffset] 的 Zone 键（每个副本一个：只换本副本的时区）。
  final Object _deviceOffsetZoneKey = Object();

  // ------------------------------------------------------------------ 本机状态

  /// 读本机状态（内核 `local_state`，只读：不建行、不补纪元）。`exists`：库里有没有这一行；`epochStored`：行里有没有
  /// 纪元（没有时 [_epoch] 是内核现给的、没落盘的一个）。
  ///
  /// 重读路径（[reloadLocal]、命令失败后的 [_commandOrReload]）也走这里，所以不能顺手建行：这个 profile 的数据可能
  /// 刚被整份删掉（`profile_purge` / 并入收尾），建回一行它就又被当成有数据的 profile。
  Future<({bool exists, bool epochStored})> _loadLocal() async {
    // `reload`：内核按「这个 profile 按刷新键记的缓存全部作废」推进一次键（store/refresh.rs）——开库（新的副本对象）、
    // [reloadLocal]、命令失败后的重读都是这个意思。
    final Map<String, Object?> j = await _sync2(const <String, Object?>{
      'op': 'local_state',
      'reload': true,
    });
    _absorbLocalState(j);
    _absorbLimitUnitSince(j);
    final Object? anchor = j['anchor'];
    // `{o, b, s?, t?}`：o = 可信时间 − 墙钟，s / t = 校时时的服务器时间与开机时钟读数（只在写下它的进程 b 里接着
    // 用，见 [SrsTrustedClock.restoreAnchor]）。更旧的 `{s, m, b}`（服务器时间 + Stopwatch 读数）没有 o，不认。
    if (anchor is Map && anchor['o'] is int && anchor['b'] is String) {
      final Object? server = anchor['s'];
      final Object? boot = anchor['t'];
      _trusted.restoreAnchor(
        offsetMs: anchor['o']! as int,
        bootId: anchor['b']! as String,
        serverTimeMs: server is int ? server : null,
        bootTimeMs: boot is int ? boot : null,
      );
    }
    return (
      exists: j['exists']! as bool,
      epochStored: j['epochStored']! as bool,
    );
  }

  /// 把本机状态行落下（内核 `local_state_ensure`：没有行就建、没有纪元就补；行里还没有 `limitUnitSince` 时记下此刻）。
  /// 只在开库时调（见 [open]）。
  Future<void> _ensureLocalState() async {
    final Map<String, Object?> j = await _sync2(<String, Object?>{
      'op': 'local_state_ensure',
      'limitUnitSince': now().$1,
    });
    _absorbLocalState(j);
    _absorbLimitUnitSince(j);
  }

  /// 本机第一次跑懂「每日上限单位」的版本的时刻（本机状态行的 `limitUnitSince`，native/fushi_fsrs/src/store/gen4/local.rs）：
  /// 在它之前做的复习是旧版按卡片数计上限时做的（[limitUnitLegacyDecks]）。按设备记、不同步；开库时没有就当场记下
  /// （[open]），只读打开的辅助进程上可能还没有。
  int? _limitUnitSince;

  void _absorbLimitUnitSince(Map<String, Object?> j) {
    final Object? since = j['limitUnitSince'];
    _limitUnitSince = since is int ? since : null;
  }

  /// `local_state` / `local_state_ensure` 的回包 → 内存里的修订号、纪元。
  void _absorbLocalState(Map<String, Object?> j) {
    _revision = j['revision']! as int;
    _epoch = j['epoch']! as String;
  }

  /// 回包带回的修订号与纪元（内核写下 / 读到的）接进内存。同一纪元里修订号只增不减：回包按到达顺序吸收，而不排
  /// 独占区的命令（[kSrsSync2LockFreeOps]）的回包可能比它之后提交的写命令的回包晚到，带着更旧的值。纪元不同 =
  /// 本机状态行重建过，整体换成新的。
  void _adoptRevision(int revision, String epoch) {
    if (epoch != _epoch) {
      _epoch = epoch;
      _revision = revision;
    } else if (revision > _revision) {
      _revision = revision;
    }
  }

  /// 此刻的校时状态（`{o, b, s?, t?}`，见 [_loadLocal]）；没校过时为 null。改投影的命令随请求带上（`anchor`），内核
  /// 在命令的同一笔事务里写进本机状态行——o 是「可信时间 − 墙钟」，每次现算，内核算不出来。没带的命令不动行里的值。
  Map<String, Object?>? _anchorArg() => switch (_trusted.anchorState) {
    final SrsClockAnchorState a => <String, Object?>{
      'o': a.offsetMs,
      'b': a.bootId,
      if (a.serverTimeMs case final int server) 's': server,
      if (a.bootTimeMs case final int boot) 't': boot,
    },
    null => null,
  };

  (int, SrsTimeSource) now() => _trusted.now();

  /// [deckTree] 与 profile 修改记录的缓存（作答一次以前要物化牌组树 / 日界 8–10 次）。键是
  /// [_structureKey]（[SrsRefreshKeys.structure]）：复习日志不让它变，作答之间一直命中。
  ({String key, SrsDeckTree tree})? _deckTreeCache;
  ({String key, SrsEntityEdits edits})? _profileEditsCache;
  String get _structureKey => _refreshKeys?.structure ?? _closedKey;

  Future<SrsEntityEdits> _profileEdits() async {
    final String key = _structureKey;
    final ({String key, SrsEntityEdits edits})? cached = _profileEditsCache;
    if (cached != null && cached.key == key) return cached.edits;
    final SrsEntityEdits p = await _entityEdits(
      SrsEntityKind.profile,
      profileUid,
    );
    if (_structureKey == key) _profileEditsCache = (key: key, edits: p);
    return p;
  }

  /// 「今天」的口径。
  ///
  /// - 翻日时刻：profile 的 [SrsFieldKeys.dayRolloverHour]（用户改日界时写下、随同步传到别的设备，多设备的「今天」
  ///   一致）；没写过就用宿主给的回落值（App = 本机统计日界，服务端 / CLI = 各自的配置）。
  /// - 时区：恒为本机此刻的偏移（[SrsDayContext.localOffsetMin]）。时区不随同步：人带着设备换时区时「今天」跟着
  ///   本机走；每条复习日志自带作答时的偏移与翻日时刻，重放不读这里。旧版本库里可能有的 profile 键
  ///   `utcOffsetMin` 从没有写入方，现在也不再读。
  ///   「本机」是用户手上那台设备：远程复习时主机替另一台设备跑这次调用，时区取那台设备报来的偏移
  ///   （[withDeviceOffset]）。
  Future<SrsDayContext> dayContext() async {
    final int rollover =
        (await syncedDayRollover())?.hour ?? _fallbackRollover().clamp(0, 23);
    final Object? device = Zone.current[_deviceOffsetZoneKey];
    return SrsDayContext(
      utcOffsetMin: device is int ? device : _localOffset(),
      rolloverHour: rollover,
    );
  }

  /// 在 [body] 这条异步调用链里，本副本「今天」的时区改取 [utcOffsetMin]（分钟），翻日时刻不变。
  ///
  /// 远程复习用（[SrsRemoteStoreService]）：手机连电脑上的库复习时，主机上的这次调用替手机执行，每日上限 /
  /// 到期计数 / 作答日志记下的偏移都应按手机所在的时区算，而不是主机的。只作用于本副本，别的副本与 [body]
  /// 之外的调用照旧取宿主给的 `localOffsetMin`。偏移的合法性由调用方先校验（远程端点只放行现实时区范围）。
  Future<T> withDeviceOffset<T>(int utcOffsetMin, Future<T> Function() body) =>
      runZoned(
        body,
        zoneValues: <Object, Object>{_deviceOffsetZoneKey: utcOffsetMin},
      );

  /// profile 里显式写过的翻日时刻（0–23）与生效的那条修改记录 ID；从没写过为 null（[dayContext] 用宿主的回落值）。
  /// 修改记录 ID 让宿主分辨「同步带来了新的修改」与「还是本机见过的那条」。
  Future<SrsDayRollover?> syncedDayRollover() async {
    final SrsFieldEdit? winner =
        (await _profileEdits())[SrsFieldKeys.dayRolloverHour]?.winner;
    final Object? v = winner?.value;
    return winner != null && v is int
        ? (hour: v.clamp(0, 23), editId: winner.id)
        : null;
  }

  /// 用户改了日界：写成 profile 的一条普通字段修改（同步 v2 传到别的设备；与现值相同不产生记录）。返回写完后
  /// 生效的值（[syncedDayRollover]）。
  Future<SrsDayRollover?> setDayRolloverHour(int hour) async {
    await editField(
      SrsEntityKind.profile,
      profileUid,
      SrsFieldKeys.dayRolloverHour,
      hour.clamp(0, 23),
    );
    return syncedDayRollover();
  }

  // ------------------------------------------------------------------ 事件落库

  /// 一个实体的全部修改记录（只读；导入按记录时刻判断本机改动是否比来源新）。
  Future<SrsEntityEdits> entityEdits(SrsEntityKind kind, String id) =>
      _entityEdits(kind, id);

  /// 一组实体各自的全部修改记录（[entityEdits] 的成批版本：按 ID 分块预读，每块两三次往返）。
  Future<Map<String, SrsEntityEdits>> entityEditsMany(
    SrsEntityKind kind,
    Iterable<String> ids,
  ) => _entityEditsMany(kind, ids);

  /// 一组笔记**一个字段键**（如 [SrsFieldKeys.noteSource]）的生效值：只读这个键的修改记录、只把它们交给
  /// 字段寄存器内核（一块一次 FFI 调用），不物化整条笔记。没有这个键的记录（或笔记不存在）的 ID 不出现在
  /// 结果里。
  ///
  /// 只要一个键的批量读者（全景的作品出处）不能走 [notes]：那会把每条笔记的全部字段原文、全部修改记录读进
  /// 调用方 isolate 再整批过一次内核——字段里带整段释义 HTML 的 2 万卡大库这是上 GB 的原文，主 isolate 上
  /// 直接 ANR / OOM（反馈 lGXA8zC1A2 / i8qNDs_V_D：启动时主线程卡在 `ffsrs_materialize`，PSS 1.58 GB）。
  /// 寄存器按键独立合并（支配 / 排序键 / 冲突都只看同一个键上的记录），所以只给一个键的记录与整条物化后
  /// 取同一个键逐值相同。
  Future<Map<String, Object?>> noteFieldKeyValues(
    Iterable<String> ids,
    String fieldKey,
  ) async {
    final Map<String, Object?> out = <String, Object?>{};
    final String kind = SrsEntityKind.note.wire;
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final Map<String, List<SrsEditItem>> byId = await _editItemsById(
        <String, Object?>{'kind': kind, 'ids': chunk, 'key': fieldKey},
      );
      if (byId.isEmpty) continue;
      final List<String> order = byId.keys.toList();
      final List<SrsEntityEdits> edits = srsEntityEditsOf(<List<SrsEditItem>>[
        for (final String id in order) byId[id]!,
      ]);
      for (int i = 0; i < order.length; i++) {
        final SrsRegister? r = edits[i][fieldKey];
        if (r != null) out[order[i]] = r.value;
      }
    }
    return out;
  }

  /// 一组笔记里字段键以 [prefix] 开头（如「不是重复」的 `notDup/`）的那些键的生效值：
  /// `笔记 ID → (键 → 值)`。与 [noteFieldKeyValues] 同理，只读这些键的修改记录、只把它们交给字段寄存器内核，
  /// 不读笔记字段正文。没有这类键的笔记不出现在结果里。
  ///
  /// 条件是 `profile_uid = ? AND entity_kind = ? AND entity_id IN (…) AND field_key` 的前缀区间，正好落在
  /// `idx_srs_field_edits_profile_register (profile_uid, entity_kind, entity_id, field_key)` 上：逐 ID 定位到
  /// 这段键，读回的行数只等于真有的这类记录数，与笔记有多少字段、字段多长无关（BUG-4187）。
  Future<Map<String, Map<String, Object?>>> noteFieldKeyPrefixValues(
    Iterable<String> ids,
    String prefix,
  ) async {
    if (prefix.isEmpty) {
      throw ArgumentError.value(prefix, 'prefix', 'must not be empty');
    }
    final Map<String, Map<String, Object?>> out =
        <String, Map<String, Object?>>{};
    final String kind = SrsEntityKind.note.wire;
    int rowsRead = 0;
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final Map<String, List<SrsEditItem>> byId = await _editItemsById(
        <String, Object?>{'kind': kind, 'ids': chunk, 'prefix': prefix},
      );
      for (final List<SrsEditItem> items in byId.values) {
        rowsRead += items.length;
      }
      if (byId.isEmpty) continue;
      final List<String> order = byId.keys.toList();
      final List<SrsEntityEdits> edits = srsEntityEditsOf(<List<SrsEditItem>>[
        for (final String id in order) byId[id]!,
      ]);
      for (int i = 0; i < order.length; i++) {
        final SrsEntityEdits e = edits[i];
        out[order[i]] = <String, Object?>{
          for (final String key in e.keys)
            if (key.startsWith(prefix)) key: e.value(key),
        };
      }
    }
    debugKeyPrefixRowsRead = rowsRead;
    return out;
  }

  /// 最近一次 [noteFieldKeyPrefixValues] 从库里读回的修改记录条数（测试核对没把字段正文读回来）。
  @visibleForTesting
  int debugKeyPrefixRowsRead = 0;

  /// 修改记录原文 + 服务器时刻按**请求里的**实体 ID 分组（`read` 的 `edits`，参数见 store/reads.rs `edits`）。没有
  /// 记录的 ID 不出现。
  ///
  /// 内核的行按规范 ID 出（一个别名类一份）；请求里是别名成员的 ID 时，回包的 `canon` 表给出它的规范 ID
  /// （native/fushi_fsrs/src/store/gen4/cmd/reads.rs `single_echo`），这里按它把行对回请求 ID（[srsRowsByRequest]）——
  /// 调用方按自己给的 ID 预建槽、按自己给的 ID 取（[_prefetchEdits] 等），不另发 `canonical_ids`。
  ///
  /// [keyCanon] 给了：请求的 `keys`（调用方接下来要取值的字段键）里归一后不同的「请求键 → 规范键」（回包 `keyCanon`）
  /// 记进去（[_currentValues]）。
  Future<Map<String, List<SrsEditItem>>> _editItemsById(
    Map<String, Object?> query, {
    Map<String, String>? keyCanon,
  }) async {
    final SrsReadResult res = await _read('edits', query);
    if (keyCanon != null) {
      final Object? echoed = res.json['keyCanon'];
      if (echoed is Map) {
        for (final MapEntry<Object?, Object?> e in echoed.entries) {
          if (e.key case final String k) {
            if (e.value case final String c) keyCanon[k] = c;
          }
        }
      }
    }
    final SrsColumns c = res.table;
    final SrsStringColumn e = c.strings('e');
    final SrsStringColumn j = c.strings('j');
    final SrsIntColumn st = c.ints('st');
    final Map<String, List<SrsEditItem>> byId = <String, List<SrsEditItem>>{};
    for (int i = 0; i < c.rows; i++) {
      (byId[e[i]] ??= <SrsEditItem>[]).add(
        SrsEditItem.stored(j.bytes(i), st.at(i)),
      );
    }
    return srsRowsByRequest(byId, query['ids'], res.json);
  }

  Future<SrsEntityEdits> _entityEdits(SrsEntityKind kind, String id) async =>
      srsEntityEditsOf(<List<SrsEditItem>>[await _editItems(kind, id)]).single;

  /// 一个实体的修改记录原文 + 服务器时刻（先查预读；没预读的同一条 JOIN 查库，见 [_prefetchEdits]）。
  Future<List<SrsEditItem>> _editItems(SrsEntityKind kind, String id) async {
    final String key = '${kind.wire}/$id';
    final List<SrsEditItem>? hit = _RefreshPrefetch.current?.edits[key];
    if (hit != null) return hit;
    final _RefreshPrefetch one = _RefreshPrefetch();
    await _prefetchEdits(one, kind, <String>[id]);
    return one.edits[key]!;
  }

  /// 笔记字段值里的内联样式换成共享样式引用（表示层，见库注释）。只动 `f/<fieldId>` 的字符串值；
  /// 其余字段键、没有可换的块、没装样式库时原样返回。本机写、导入、对端事件都经这里落库。
  ///
  /// 没有 `<style>` 块（绝大多数记录）时同步返回，不进异步流程：批量落库时逐条 await 本身
  /// 就是秒级开销（迁移 1.5 万笔记约 28 万条修改记录）。判据与 [srsDedupStyles] 的快速
  /// 判断相同，结果不变。
  FutureOr<SrsFieldEdit> _compactEdit(SrsFieldEdit e) =>
      switch (_compactValue(e.entityKind, e.fieldKey, e.value)) {
        final Future<Object?> f => f.then(
          (Object? v) => identical(v, e.value) ? e : _withValue(e, v),
        ),
        final Object? v => identical(v, e.value) ? e : _withValue(e, v),
      };

  /// [_compactEdit] 的按值形态（修改记录草稿还没有记录对象）：[value] 没有可换的块时原样（同一个对象）返回。
  FutureOr<Object?> _compactValue(
    SrsEntityKind kind,
    String fieldKey,
    Object? value,
  ) {
    final SrsStyleStore? st = styles;
    if (st == null ||
        kind != SrsEntityKind.note ||
        value is! String ||
        !fieldKey.startsWith(_noteFieldPrefix) ||
        !value.contains('<style>')) {
      return value;
    }
    return st.compact(value);
  }

  static final String _noteFieldPrefix = SrsFieldKeys.noteField('');

  static SrsFieldEdit _withValue(SrsFieldEdit e, Object? value) => SrsFieldEdit(
    profileUid: e.profileUid,
    entityKind: e.entityKind,
    entityId: e.entityId,
    fieldKey: e.fieldKey,
    dot: e.dot,
    ctx: e.ctx,
    value: value,
    hlc: e.hlc,
    timeSource: e.timeSource,
    machine: e.machine,
  );

  /// 展开共享样式引用（对外的读：导出、AnkiConnect、制卡回读、卡面渲染）。没装样式库时原样返回。
  /// [dropMissing] 见 [srsExpandStyles]。
  Future<String> expandStyles(String html, {bool dropMissing = false}) async {
    final SrsStyleStore? st = styles;
    if (st == null) return html;
    return st.expand(html, dropMissing: dropMissing);
  }

  /// [expandStyles] 的成批版本（与输入同序；样式文件每个只读一次，见 [SrsStyleStore.expandAll]）。
  Future<List<String>> expandStylesAll(
    List<String> htmls, {
    bool dropMissing = false,
  }) async {
    final SrsStyleStore? st = styles;
    if (st == null) return htmls;
    return st.expandAll(htmls, dropMissing: dropMissing);
  }

  /// [expandStyles] 逐值作用于一组字段（键不变）。
  Future<Map<String, String>> expandFields(
    Map<String, String> fields, {
    bool dropMissing = false,
  }) async => <String, String>{
    for (final MapEntry<String, String> f in fields.entries)
      f.key: await expandStyles(f.value, dropMissing: dropMissing),
  };

  /// 本机产生一批草稿：落库、进发件箱、刷新缓存（内核在 `apply` 的同一次调用里刷新）。调用方在独占区
  /// （[runExclusive]）里、紧接着读完现值之后调它：读现值与落库之间不插进别的写入。
  ///
  /// 修改记录草稿（[SrsEditDraft]）的序号 / 因果上下文 / HLC 由内核在落库时分配，旧版 HLC 时钟每条走一步（同一时刻、
  /// 逐条）。[receive]：已定稿的事件带着来源给的 HLC（导入的日志 / 记录）——旧版时钟按收到对端事件的规则推进（先钳位），
  /// 整批先收、再走修改记录草稿的那几步。时钟在内核里（native/fushi_fsrs/src/store/legacy_clock.rs）。
  ///
  /// [stamps]：返回这批修改记录草稿落库后的修改记录（按草稿顺序；内核没写出操作的草稿——标签列表与现值相同——不在
  /// 其中）。不要返回值的调用方不给，省掉内核逐条拼投影行。
  ///
  /// [existed]：给了就按导入的一批草稿落（内核 `import_drafts`，见 [importDrafts]）——「初值」草稿里键已有记录的不落，
  /// 这批身份记录里落库前就已存在的实体 ID 加进这个集合。
  ///
  /// [cardNotes]：卡片 → 笔记（调用方已知时给）：日志按它带上笔记（省一次读卡片行），卡片修改也带上（跟着笔记过实体归属闸，
  /// 见 [importDrafts]）；[study]：落库、刷新缓存后在同一次命令里排队
  /// （store/study.rs），结果交给 [onStudy]。
  ///
  /// [onEntities]：这批身份记录落下的规范实体 ID，按草稿下标（[srsEntityWritesByInput]，内核回包 `entityWrites`）。
  /// 建实体的入口返回的是它，不是请求里的 ID（请求 ID 是别名成员时两者不同）。
  Future<List<SrsFieldEdit>> _emit(
    List<SrsEventDraft> drafts, {
    bool receive = false,
    bool stamps = false,
    Set<String>? existed,
    Set<String>? foreignNotes,
    Map<String, String> cardNotes = const <String, String>{},
    Map<String, Object?>? study,
    void Function(Map<String, Object?> study)? onStudy,
    void Function(List<String?> entities)? onEntities,
  }) async {
    assert(
      identical(Zone.current[_writeZoneKey], this),
      '_emit outside runExclusive',
    );
    // 在 [undoable] 里：落库前读下这批要改的键的改前值，落库后记下内核分配的 dot（srs_edit_undo.dart）。
    final _SrsUndoRecorder? recorder = _undoRecorder;
    // 第 i 条草稿点名的 (种类, 实体, 字段键, 值)：回包 `edits` 按输入下标（= 草稿下标）认领（[_SrsUndoRecorder.noteWritten]）。
    final Map<int, (SrsEntityKind, String, String, Object?)> byInput =
        recorder == null
        ? const <int, (SrsEntityKind, String, String, Object?)>{}
        : <int, (SrsEntityKind, String, String, Object?)>{
            for (final (int i, SrsEventDraft d) in drafts.indexed)
              if (d is SrsEditDraft)
                i: (d.kind, d.entityId, d.key, d.value)
              else if (d case SrsReadyDraft(
                event: SrsEditEvent(:final SrsFieldEdit edit),
              ))
                i: (edit.entityKind, edit.entityId, edit.fieldKey, edit.value),
          };
    final Iterable<(SrsEntityKind, String, String, Object?)> recorded =
        byInput.values;
    if (recorded.isNotEmpty) {
      await recorder!.noteBefore(<(SrsEntityKind, String, String)>[
        for (final (SrsEntityKind k, String id, String f, Object? _)
            in recorded)
          (k, id, f),
      ]);
    }
    List<Object?> written = const <Object?>[];
    // 收（来源 HLC 的钳位）与走一步各自的「此刻」，以及修改记录草稿的时间来源：都在落库前这一刻取。
    final int recvNow = now().$1;
    final (int tickNow, SrsTimeSource source) = now();
    final List<Map<String, Object?>> input = await _applyInput(
      drafts,
      receive: receive,
      initials: existed != null,
      source: source,
      cardNotes: cardNotes,
    );
    late _Applied applied;
    await _commandOrReload(() async {
      // 同步 v2：操作落进 ops 就是「已备份、待发布」，没有单独的发件箱（发件按段，见 store/sync2/transport.rs）。
      // 本机状态行由内核在 `apply` 的同一笔事务里写下（[_absorbLocalWrite]）。
      applied = await _applyLocal(
        input,
        recvNow: receive ? recvNow : null,
        tickNow: tickNow,
        existed: existed,
        study: study,
        onStudy: onStudy,
        onEdits: (List<Object?> w) => written = w,
        editRows: stamps,
      );
    });
    if (recorded.isNotEmpty) {
      recorder!.noteWritten(
        written,
        byInput: <int, (SrsEntityKind, String, String)>{
          for (final MapEntry<int, (SrsEntityKind, String, String, Object?)> e
              in byInput.entries)
            e.key: (e.value.$1, e.value.$2, e.value.$3),
        },
      );
      // 整列表标签展开成了 OR-Set 的标签操作（内核不报 dot）：按差量撤，只记改后的列表。
      for (final (SrsEntityKind k, String id, String f, Object? v)
          in recorded) {
        if (k == SrsEntityKind.note && f == SrsFieldKeys.noteTags) {
          recorder.noteTags(id, v);
        }
      }
    }
    if (onEntities != null && !identical(applied, _Applied.stale)) {
      onEntities(srsEntityWritesByInput(drafts.length, applied.reply));
    }
    if (foreignNotes != null && !identical(applied, _Applied.stale)) {
      foreignNotes.addAll(_foreignNoteRecords(drafts, applied.reply));
    }
    if (!stamps || identical(applied, _Applied.stale)) {
      return const <SrsFieldEdit>[];
    }
    return _writtenEdits(drafts, applied.reply);
  }

  /// 回包 `foreign`（实体归属闸拒掉的项的输入下标，= 草稿下标：[_applyInput] 一条草稿一项）里的笔记身份记录草稿的
  /// 笔记 ID（[SrsImportDraftsResult.foreignNotes]）。下标越界是内核与 Dart 对不上。
  static Set<String> _foreignNoteRecords(
    List<SrsEventDraft> drafts,
    Map<String, Object?> reply,
  ) {
    final Set<String> out = <String>{};
    for (final Object? at
        in (reply['foreign'] as List<Object?>?) ?? const <Object?>[]) {
      final int i = at! as int;
      if (i < 0 || i >= drafts.length) {
        throw StateError(
          'srs: the `apply` reply has foreign index $i outside the '
          '${drafts.length} drafts (the native core and Dart do not match)',
        );
      }
      if (drafts[i] case SrsReadyDraft(
        event: SrsEntityEvent(:final SrsEntityRecord record),
      ) when record.kind == SrsEntityKind.note) {
        out.add(record.id);
      }
    }
    return out;
  }

  /// 一批草稿里修改记录草稿落库后的修改记录（按草稿顺序；内核没写出操作的草稿——值没变、标签列表与现值相同——不在
  /// 其中；被同批后面的草稿盖掉的也不在其中——同一个键只交回最后一条，它才是落库后活着的那条）。
  ///
  /// 协议 3 由内核在 `apply` 里交回逐项的落库投影行（`stamps`，旧版时钟的产物）；新代没有旧版时钟、明确拒绝
  /// `stamps`，改由回包按**输入下标**报写下的东西（native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」）：
  /// `edits` 每项第 7 列是它来自第几条输入（= 第几条草稿，[_applyInput] 一条草稿一项），整列表标签草稿展开成的标签
  /// 操作在 `tagWrites` 里报一项（[srsWrittenByInput]）。所以草稿直接按下标认领，不按 (种类, 实体, 字段键) 猜、不逐条
  /// 点查归一（别名类的非规范成员也对得上）。[_emit] 带 `stamps` 时请求里带 `editRows`，回包每项再带收尾之后那一行
  /// 落库修改行（与 `read edits` 的 `j` / `st` 同一个函数出的，cmd/mod.rs `edit_rows`；标签草稿是那条笔记合成的
  /// `tags` 行，值是标签 OR-Set 的当前值），这里直接拼，命令之后不再发一条 `read edits` 回读（T1
  /// `srs_write_preread_cost`）。返回值里带调用方给的原值（落库形态里内联样式已换成共享引用）。
  List<SrsFieldEdit> _writtenEdits(
    List<SrsEventDraft> drafts,
    Map<String, Object?> reply,
  ) {
    final List<SrsWrittenItem?> written = srsWrittenByInput(
      drafts.length,
      reply,
    );
    final List<SrsFieldEdit> out = <SrsFieldEdit>[];
    for (int i = 0; i < drafts.length; i++) {
      final SrsEventDraft d = drafts[i];
      final SrsWrittenItem? w = written[i];
      if (w == null || d is! SrsEditDraft) continue;
      // 内核明确标了「被同批后面的写入盖掉」：它没有落库后的行，后面那条草稿交回的才是。
      if (w.superseded) continue;
      final String? row = w.row;
      if (row == null) {
        throw StateError(
          'srs: ${w.tags ? 'the tags of ${w.entity}' : 'edit ${w.writer}/${w.seq}'} '
          'from the `apply` reply carries no stored row and is not marked '
          'superseded (the native core and Dart do not match)',
        );
      }
      final SrsFieldEdit edit = SrsEditItem.stored(
        Uint8List.fromList(utf8.encode(row)),
        w.serverTime,
      ).edit;
      out.add(_withValue(edit, d.value));
    }
    return out;
  }

  /// 一批草稿 → `apply` 的输入（native/fushi_fsrs/src/store/sync2/mod.rs `apply_local_on`）：每项
  /// `{e: 事件, note: 日志卡片的笔记, clk?: 旧版时钟指令}`。修改记录草稿只交内容（`clk: t`，时钟走一步）；[receive] 时
  /// 已定稿的事件 `clk: r`（按它带的 HLC 收）。[initials] 时「初值」草稿带 `init: true`（只有 `import_drafts` 看它）。
  /// 内联样式在这里换成共享样式引用（表示层，见 [_compactValue]）。
  Future<List<Map<String, Object?>>> _applyInput(
    List<SrsEventDraft> drafts, {
    required bool receive,
    bool initials = false,
    required SrsTimeSource source,
    Map<String, String> cardNotes = const <String, String>{},
  }) async {
    final Map<String, String> noteOf = await _logNotesOf(<SrsEvent>[
      for (final SrsEventDraft d in drafts)
        if (d case SrsReadyDraft(:final SrsEvent event)) event,
    ], cardNotes);
    final List<Map<String, Object?>> input = <Map<String, Object?>>[];
    for (final SrsEventDraft d in drafts) {
      switch (d) {
        case SrsReadyDraft(:final SrsEvent event):
          final SrsEvent stored = await _compactEvent(event);
          input.add(<String, Object?>{
            'e': stored.toJson(),
            'note': switch (stored) {
              SrsLogEvent(:final SrsReviewLog log) => noteOf[log.cardId],
              SrsEditEvent(:final SrsFieldEdit edit)
                  when edit.entityKind == SrsEntityKind.card =>
                cardNotes[edit.entityId],
              _ => null,
            },
            if (receive) 'clk': 'r',
          });
        case SrsEditDraft():
          input.add(<String, Object?>{
            'e': <String, Object?>{
              't': 'edit',
              'x': <String, Object?>{
                'p': profileUid,
                'k': d.kind.wire,
                'e': d.entityId,
                'f': d.key,
                'v': switch (_compactValue(d.kind, d.key, d.value)) {
                  final Future<Object?> f => await f,
                  final Object? v => v,
                },
                'ts': source.wire,
                if (d.machine) 'm': true,
              },
            },
            'note': d.kind == SrsEntityKind.card ? cardNotes[d.entityId] : null,
            'clk': 't',
            if (initials && d.initial) 'init': true,
            if (d.ifChanged) 'chg': true,
          });
      }
    }
    return input;
  }

  /// [events] 里日志的卡片 → 笔记：[known] 里没有的按卡片缓存行补。
  Future<Map<String, String>> _logNotesOf(
    Iterable<SrsEvent> events,
    Map<String, String> known,
  ) async {
    final Set<String> logCards = <String>{
      for (final SrsEvent e in events)
        if (e case SrsLogEvent(:final SrsReviewLog log))
          if (!known.containsKey(log.cardId)) log.cardId,
    };
    return <String, String>{
      ...known,
      if (logCards.isNotEmpty)
        for (final SrsCardCacheRow c in await cardRows(logCards))
          c.id: c.noteId,
    };
  }

  /// 表示层：事件里修改记录的内联样式换成共享样式引用（见 [_compactEdit]）。操作里带的就是落库形态（样式文件随媒体
  /// 同步）。
  FutureOr<SrsEvent> _compactEvent(SrsEvent e) {
    if (e case SrsEditEvent(:final SrsFieldEdit edit)) {
      return switch (_compactEdit(edit)) {
        final SrsFieldEdit c => identical(c, edit) ? e : SrsEditEvent(c),
        final Future<SrsFieldEdit> f => f.then<SrsEvent>(
          (SrsFieldEdit c) => SrsEditEvent(c),
        ),
      };
    }
    return e;
  }

  /// 落一批事件（幂等；本机产生、导入、对端来的都走这里）：已有的身份记录、日志、相关实体的
  /// 修改记录各按 ID 分块一次预读，写入合成一个 Drift batch。按事件顺序在内存视图上推进，
  /// 与逐条「先查再写」同结果（批内重复、批内互相支配都一样）：
  /// - 身份记录：同 ID 同内容不落；同 ID 异内容取规范编码较小的一份（确定性兜底，只可能是 bug 或损坏）；
  /// - 修改记录：同 ID 已在不落；被同一字段键上已有记录支配的丢掉，支配别人的把对方删掉；
  /// - 日志：同 ID 取规范编码较小的一份；不认识的事件原样保留。
  /// 每条真落库的事件修订号 +1（[changeFingerprint]）。返回真正新落的事件数。
  ///
  /// 指向**别的 profile** 的实体（同一份 srs.db 里记在另一个 uid 名下的笔记 / 卡片 / 牌组 / 笔记类型）的事件内核
  /// 不收（native/fushi_fsrs/src/store/sync2/ownership.rs）：不追加操作、不动对方的任何一行，回包里那一项没有
  /// 修改记录（[_emit] 只交回内核真写出的）。实体 ID 是整库主键，profile 之间互不干扰靠的就是这一条。
  ///
  /// 以前每条事件「先查再写」各两三次往返（库在后台 isolate，每次往返都是一次跨 isolate 消息），
  /// 导入一个几千条笔记的包、应用一批对端事件都要几万次往返（BUG-3549 / BUG-3543）。
  ///
  /// [input] 见 [_applyInput]。同步 v2：事件交给 Rust 的 `apply`——分配 OpId / HLC / 因果上下文、落唯一事实表
  /// （ops）、落投影、重放受影响的卡，一次 FFI（docs/specs/2026-10-25-srs-sync-v2-design.md §3、§4）。修改记录的
  /// dot / ID 由 Rust 按本机设备身份分配，这里只交内容；日志的结果由重放算，作者给的只是提示。旧版 HLC 时钟按各项的
  /// `clk` 在同一条命令里推进并写下（[recvNow] / [tickNow] 是收 / 走一步用的「此刻」）；本机状态行由内核在
  /// 同一笔事务里写下（[_absorbLocalWrite]）。[logHlcs]：回包按输入下标带写下的日志的 HLC（`logHlcs`，作答取它）。
  /// [editRows]：回包的 `edits` / `tagWrites` 每项带上落库修改行（[srsWrittenByInput]，[_writtenEdits] 用）。
  Future<_Applied> _applyLocal(
    List<Map<String, Object?>> input, {
    int? recvNow,
    int? tickNow,
    Set<String>? existed,
    Map<String, Object?>? study,
    void Function(Map<String, Object?> study)? onStudy,
    void Function(List<Object?> edits)? onEdits,
    Map<String, Object?>? expectLast,
    bool remote = false,
    bool logHlcs = false,
    bool editRows = false,
  }) async {
    final Map<String, Object?> r = await _sync2(
      <String, Object?>{
        'op': existed == null ? 'apply' : 'import_drafts',
        if (remote) 'remote': true,
        'now': now().$1,
        'legacyDevice': deviceId,
        'recvNow': ?recvNow,
        'tickNow': ?tickNow,
        'study': ?study,
        'expectLast': ?expectLast,
        if (logHlcs) 'logHlcs': true,
        if (editRows) 'editRows': true,
        'anchor': ?_anchorArg(),
      },
      blobs: <Uint8List>[utf8.encode(jsonEncode(input))],
    );
    // 前置条件不成立（[expectLast]，内核 `apply`）：什么都没落、本机状态行没动，回包里没有别的东西可接。
    if (expectLast != null && r['stale'] == true) return _Applied.stale;
    final int landed = _absorbLocalWrite(r);
    if (r['study'] case final Map<Object?, Object?> st) {
      onStudy?.call(st.cast<String, Object?>());
    }
    onEdits?.call((r['edits'] as List<Object?>?) ?? const <Object?>[]);
    if (existed != null) {
      final Object? ids = r['existed'];
      if (ids is! List) {
        throw StateError(
          'srs: `import_drafts` reply has no `existed` (the native core and '
          'Dart do not match)',
        );
      }
      existed.addAll(ids.cast<String>());
    }
    return _Applied(landed, r);
  }

  /// 把一次写命令的结果接进本机缓存的变更日志（[cacheChangesSince]）。修订号由内核写进本机状态行、回包带回
  /// （[_absorbLocalWrite]），这里不加。返回碰过的实体数（`changed` + `purged` + 写了日志的卡）。
  ///
  /// 新代的写命令回包统一带 `changed`（`[种类, 规范实体 ID]`）、`purged`、`replayed`（写了日志的卡）；协议 3 的
  /// `marks` / `cache`（内核写过哪些缓存行的清单）没有了（native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头）。
  /// 缓存行随写入在派生层里收尾，牵动面（笔记删了它的卡跟着隐藏、牌组 / 笔记类型 / 预设 / profile 的修改波及一批卡）
  /// 回包里看不全，所以只有「只碰了卡」的写入按卡记日志；碰了别的种类就整份作废日志（按日志增量读的常驻视图下次
  /// 整份重读），宁可多读、不读到旧行。
  int _absorbProjection(Map<String, Object?> r) {
    final List<Object?> changed = (r['changed'] as List?) ?? const <Object?>[];
    final List<Object?> purged = (r['purged'] as List?) ?? const <Object?>[];
    final List<Object?> replayed =
        (r['replayed'] as List?) ?? const <Object?>[];
    for (final Object? c in purged) {
      if (c is List && c.length == 2) {
        final SrsEntityKind? kind = SrsEntityKind.tryParse(c[0] as String?);
        if (kind != null) _purgedPending.add((kind, c[1]! as String));
      }
    }
    final List<String> cards = <String>[
      for (final Object? id in replayed)
        if (id is String) id,
    ];
    bool onlyCards = purged.isEmpty;
    for (final Object? c in changed) {
      if (c is List && c.length == 2 && c[0] == SrsEntityKind.card.wire) {
        cards.add(c[1]! as String);
      } else {
        onlyCards = false;
      }
    }
    if (!onlyCards) {
      _resetCacheJournal();
    } else if (cards.isNotEmpty) {
      _journalCacheWrite(const <String>[], cards);
    }
    return changed.length + purged.length + replayed.length;
  }

  /// 被彻底清除（本机或对端的 Purge）、还没通知派生表的实体。
  final Set<(SrsEntityKind, String)> _purgedPending =
      <(SrsEntityKind, String)>{};

  /// 把清除掉的卡交给 RWKV 分数表（HBK-AUDIT-020：否则分数表里一直留着它们的项）。写事务提交之后调；
  /// 笔记按它的卡展开（卡缓存行在清除后仍在，只是隐藏）。
  Future<void> _notifyPurged() async {
    if (_purgedPending.isEmpty) return;
    final List<(SrsEntityKind, String)> pending = _purgedPending.toList();
    _purgedPending.clear();
    final SrsRwkvScheduling? r = rwkv;
    if (r == null) return;
    final Set<String> cards = <String>{
      for (final (SrsEntityKind k, String id) in pending)
        if (k == SrsEntityKind.card) id,
    };
    final List<String> notes = <String>[
      for (final (SrsEntityKind k, String id) in pending)
        if (k == SrsEntityKind.note) id,
    ];
    if (notes.isNotEmpty) {
      cards.addAll(await _cardIdsWhere(<String, Object?>{'notes': notes}));
    }
    if (cards.isNotEmpty) await r.onCardsPurged(cards.toList());
  }

  // ------------------------------------------------------------------ 同步 v2（SrsSync2Host）

  /// 同步 v2 的命令（看 head / 发件 / 写 head / 身份 / 摘要……）与写事务互斥：内核与本机写入共用一条连接，
  /// 不排队的话 `outbox` / `head` / `plan` 会读到另一笔还没提交的 `apply` 事务里的操作——那笔回滚后同一个 seq
  /// 被重用、head 的代号回退，已经发出去的段与 head 让对端判本机分叉（P1-4）。不排队的只有 [kSrsSync2LockFreeOps]：
  /// 不碰库的纯计算，以及只读已提交快照的命令——排队等于让复习作答等它们跑完（状态摘要是全库扫描，手机上
  /// 一两秒，每轮同步都可能轮到）。
  ///
  /// 新代的 `plan`（内核 `gen4/cmd/sync.rs`）一律在写事务里记对端 / 位置上的 head / 取消停用，没有协议 3 的只读预演
  /// （`readOnly` → `needsWrite`，内核现在明确拒绝），和别的同步写命令一样进写锁。
  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    if (request['op'] == 'dedup' || request['op'] == 'digest_heal') {
      // 重复流收敛（内核 store/sync2/dedup.rs）改投影（删并存的修改记录行、解除扣留）、摘要不一致的自动重建
      // （store/sync2/heal.rs）重放改写日志：与冲突解决同一条路径，投影变化接进缓存。
      return SrsSync2Result(
        await _sync2Write(request),
        const <(String, Uint8List)>[],
      );
    }
    if (request['op'] == 'oldroot_ingest') {
      // 旧根接手的一批（内核 `gen4/cmd/sync_oldroot.rs`）：和收段一样落真相、推进本机修订号，回包按收段的一步接进
      // 本机缓存（[_sync2IngestStep]）。
      return SrsSync2Result(
        await _sync2IngestStep(request, blobs),
        const <(String, Uint8List)>[],
      );
    }
    if (kSrsSync2LockFreeOps.contains(request['op'])) {
      return _sync2Raw(request, blobs: blobs);
    }
    return runExclusive(() => _sync2Raw(request, blobs: blobs));
  }

  /// 卡片浏览的常驻会话命令（native/fushi_fsrs/src/store/browse.rs；srs_browse.dart 的 `SrsBrowseSession` 发）。
  /// 只读（读快照；写连接上有事务时在它的 SAVEPOINT 里读，看得见未提交的行），不进写锁，在后台 isolate 跑。
  ///
  /// 只接受 [kSrsBrowseOps] 里的命令：这个入口不进写锁、不走 [sync2Command] 的分流，且会被远程复习原样转给
  /// 已配对设备调用；放任意 op 进来等于把 `seal_file` / `open_file`（按请求给的路径读写文件）与改库命令都开放了。
  Future<SrsSync2Result> browseCommand(Map<String, Object?> request) {
    final Object? op = request['op'];
    if (!kSrsBrowseOps.contains(op)) {
      throw ArgumentError.value(op, 'op', 'not a browse command');
    }
    return _sync2Raw(request);
  }

  /// [browseCommand] 接受的命令：与内核 `store/gen4/dispatch.rs` 里分派到浏览会话的那一组相同。
  static const Set<String> kSrsBrowseOps = <String>{
    'browse_query',
    'browse_rows',
    'browse_ids',
    'browse_targets',
    'browse_close',
    'browse_stats',
    'browse_counts',
    'browse_sources',
    'anki_find',
    'anki_tags',
    'anki_dupes',
  };

  /// 不进写锁的 v2 命令（见 [sync2Command]）。判据：结果不依赖写连接上还没提交的行，也不在别的写入的
  /// 中途改本机状态。
  /// - 纯计算（`derive_key` / `seal` / `open`）：不碰库；Argon2 派生要上百毫秒。`seal_file` / `open_file` 同理
  ///   （媒体文件到文件的流式封 / 解，只读写调用方给的路径）。
  /// - 只走读连接（WAL 快照，只见已提交的行）：`status` / `media_known` / `conflicts` / `checkpoints` / `history`；
  ///   `media_hash`（本机媒体文件的 sha256，首次对账要把几万个文件各读一遍；结论交给进写锁的 `media_scan`）。
  /// - `digest`：新代读快照上算语义摘要（内核 `Index::digest`，派生层 `dg_ix` 增量维护；没有协议 3 的摘要桶与
  ///   `digest_buckets`），不写库。
  /// - 同步一轮里只读快照的几步（内核 `gen4/cmd/sync_oldroot.rs` / `media_sync.rs`）：`oldroot_scan`（旧根清单与已收的
  ///   比对）、`heritage_plan` / `heritage_outbox`（承袭对账与打包，读快照上做，迁移后第一轮可能要打几百个段）、
  ///   `media_manifests`（位置上还没收的清单）、`relay_outbox`（转发件按目标位置的钥匙重新封装，读快照上做）。
  @visibleForTesting
  static const Set<String> kSrsSync2LockFreeOps = <String>{
    'derive_key',
    'seal',
    'open',
    'status',
    'media_known',
    'media_hash',
    'conflicts',
    'checkpoints',
    'history',
    'digest',
    'seal_file',
    'open_file',
    'oldroot_scan',
    'heritage_plan',
    'heritage_outbox',
    'media_manifests',
    'relay_outbox',
  };

  /// 开一段收段：先登记（之后来的 [rwkvReplayBytes] 排到它结束），再等在途的回放跑完——收段的投递与整 profile 的
  /// RWKV 回放不同时在内存里。内核同时开收段会话（`ingest_begin`，gen4 `refresh.rs` `rwkv_held`）：会话里每批收段
  /// 不推进 RWKV 刷新键，[sync2IngestEnd] 时并成一次。每批仍是一个写事务，分叉点记在库里（`cmd/sync.rs`）。
  @override
  Future<void> sync2IngestBegin() async {
    final Completer<void> session = Completer<void>();
    await sync2IngestSettled();
    _ingestSession = session;
    await _sync2Raw(const <String, Object?>{'op': 'ingest_begin'});
    final Completer<void>? replays = _rwkvReplaysIdle;
    if (replays != null) await replays.future;
  }

  /// 测试：开着 [sync2IngestBegin] 的一段。
  @visibleForTesting
  bool get debugIngestOpen => _ingestSession != null;

  /// 测试：协议 3 收段会话走不走收段通道。新代没有收段通道，恒为 false。
  @visibleForTesting
  bool get debugIngestChannel => false;

  /// 结束 [sync2IngestBegin] 开的一段：等着的 RWKV 回放放行，内核攒着的 RWKV 推进放出一次（`ingest_end`）。
  @override
  Future<void> sync2IngestEnd() async {
    final Completer<void>? session = _ingestSession;
    if (session == null) return;
    _endIngestSession(session);
    await _sync2Raw(const <String, Object?>{'op': 'ingest_end'});
  }

  /// 收一批（内核 `ingest`，一个写事务：核对、按因果投递、派生层收尾；本机状态行的修订号在同一事务里推进）。收这一批
  /// 期间调高写连接的自动 checkpoint 阈值（[bulkWrites]）。协议 3 的「先预处理、再按片投递、有写入排队就收片」
  /// （`ingest_prepare` / `ingest_commit` / `ingest_yield`）在新代没有对应物：一批的事务只做这一批，字节预算由
  /// [srsSync2Round] 的切批（[kSrsSync2IngestBudgetBytes]）限住。
  ///
  /// 收段让路（G8-7b）：一批在内核里按 [kSrsSync2IngestSliceItems] 项新工作切成多个事务（`ingest` 的 `maxItems`，
  /// 回包 `rest` = 交完了的段数），每个事务各进一次写锁——两个事务之间排着的作答先写，复习不被一大批收段卡住。中途
  /// 停下的那一段下一个事务原样再交，已落的部分内核按本机已有跳过；收尾从等待缓冲投递同样按片（回包 `drainMore` 时
  /// 不带段再收）。各片的计数合成一份回包。
  ///
  /// 交回（第六波，回包 `requeue`）：一片被预算截断时，交完的部分里还在等同一批里 Purge 的重切件由内核点名交回
  /// （下标相对这一片）——接在剩下的段后面一起交下一片（等的 Purge 可能就在剩下的段里），不算没收。[location] 原样
  /// 带给内核（重切件的停放按位置记）。
  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
    String? location,
  }) async {
    final Map<String, Object?> merged = <String, Object?>{};
    await bulkWrites(() async {
      List<Uint8List> rest = segments;
      while (true) {
        final Map<String, Object?> r = await _sync2IngestStep(<String, Object?>{
          'op': 'ingest',
          'key': keyHex,
          'maxItems': kSrsSync2IngestSliceItems,
          'location': ?location,
        }, rest);
        _mergeIngestSlice(merged, r);
        final int done = (r['rest'] as int?) ?? rest.length;
        final int spent = (r['spent'] as int?) ?? 0;
        final List<Uint8List> back = srsIngestRequeued(rest, r['requeue']);
        if (done >= rest.length && back.isNotEmpty) {
          // 内核只在截断时交回；整片交完还交回 = 契约坏了，不原地打转。
          throw StateError('sync2 ingest requeued without truncating: $r');
        }
        if (done >= rest.length) {
          // 段都交完了，但收尾投等待缓冲时这一片的预算用完、还有接得上的（`drainMore`）：不带段再收一片接着投。
          // 投递片必有进展（内核只在确有一项接得上却没投时才报 drainMore）；没有就是契约坏了。
          if (r['drainMore'] != true) break;
          if (rest.isEmpty && spent == 0) {
            throw StateError('sync2 ingest drain made no progress: $r');
          }
          rest = const <Uint8List>[];
          continue;
        }
        if (done == 0 && spent == 0) {
          // 进展只认内核报的 `spent`（落库 + 新进等待缓冲的项）：依赖方的段排在前面时一片可能全停进等待缓冲、
          // `landed` 为 0，那也是进展。交完的段与新工作都是 0 = 契约坏了，不原地打转。
          throw StateError('sync2 ingest slice made no progress: $r');
        }
        rest = <Uint8List>[...rest.sublist(done), ...back];
      }
    });
    return merged;
  }

  /// 一片收段回包里交回的段（`requeue` = 相对 [slice] 的下标，第六波）：下标越界 / 不是整数 = 契约坏了，报错。
  @visibleForTesting
  static List<Uint8List> srsIngestRequeued(
    List<Uint8List> slice,
    Object? requeue,
  ) {
    if (requeue == null) return const <Uint8List>[];
    return <Uint8List>[
      for (final Object? i in requeue as List<Object?>)
        if (i is int && i >= 0 && i < slice.length)
          slice[i]
        else
          throw StateError('sync2 ingest requeue index out of range: $i'),
    ];
  }

  /// 收段每个事务最多做的新工作（落进日志 / 新进等待缓冲的项）。取值：内核测试
  /// `ingest_slices_a_large_batch_into_budgeted_transactions` 在桌面机上量过（quick profile，200 项一片最慢约 0.5 s，
  /// 其中大半是每片重新解开同一个段的开销），手机按慢 3～5 倍估，256 项让一次作答最多等 1～2 s。
  static const int kSrsSync2IngestSliceItems = 256;

  /// 把一片收段的回包并进 [merged]：计数相加、错误与分叉设备拼接、`fork` 取或、末态（`pending` / `waiting` 与本机
  /// 修订号）取最后一片的。
  static void _mergeIngestSlice(
    Map<String, Object?> merged,
    Map<String, Object?> r,
  ) {
    const List<String> sums = <String>[
      'segments',
      'landed',
      'delivered',
      'applied',
      'deferred',
      'rejected',
      'diverged',
      'conflicts',
      'voided',
      'kept',
      'spent',
    ];
    for (final MapEntry<String, Object?> e in r.entries) {
      if (sums.contains(e.key)) {
        merged[e.key] =
            ((merged[e.key] as int?) ?? 0) + ((e.value as int?) ?? 0);
      } else if (e.key == 'errors' || e.key == 'forked') {
        merged[e.key] = <Object?>[
          ...((merged[e.key] as List?) ?? const <Object?>[]),
          ...((e.value as List?) ?? const <Object?>[]),
        ];
      } else if (e.key == 'fork') {
        merged['fork'] = merged['fork'] == true || e.value == true;
      } else if (e.key == 'requeue') {
        // 片内的下标，片与片之间没有意义（[sync2IngestBatch] 已接回下一片）。
      } else {
        merged[e.key] = e.value;
      }
    }
  }

  /// 测试钩子：收一批拿到写锁、调内核之前调用。
  @visibleForTesting
  void Function()? debugOnIngestSlice;

  /// 收尾（内核 `ingest_finish`）：收段时记下过分叉点就换身份、分叉点之后的本机操作以新身份重签发。
  @override
  Future<Map<String, Object?>> sync2IngestFinish() =>
      _sync2IngestStep(const <String, Object?>{'op': 'ingest_finish'});

  /// 收段的一步（收一批 / 收尾换身份）：写锁里跑，投影变化接进本机缓存。
  ///
  /// 这一片由内核自己在一笔事务里提交（提交成功才推进内核的收段会话），本机状态行（这一步只会推进其中的修订号）由
  /// 内核在**同一笔事务**里写下并回报 `localRevision`（[_absorbLocalWrite]）——要么一起落盘、要么一起不落，内存在命令
  /// 成功之后才改。
  /// 命令失败时内存没动过，无需重读本机状态。
  Future<Map<String, Object?>> _sync2IngestStep(
    Map<String, Object?> request, [
    List<Uint8List> segments = const <Uint8List>[],
  ]) => runExclusive(() async {
    debugOnIngestSlice?.call();
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      ...request,
      'now': now().$1,
      'anchor': ?_anchorArg(),
    }, blobs: segments);
    _absorbLocalWrite(r);
    await _notifyPurged();
    return r;
  });

  /// 跑一个不改投影之外东西的 v2 写命令（冲突解决、清除、还原点、按时间点恢复、停用设备、信任设备、重复流收敛），投影变化接进
  /// 缓存。本机状态行由内核在命令的同一笔事务里写下（[_absorbLocalWrite]）。
  Future<Map<String, Object?>> _sync2Write(Map<String, Object?> request) =>
      runExclusive(() async {
        late Map<String, Object?> r;
        await _commandOrReload(() async {
          r = await _sync2(<String, Object?>{
            ...request,
            'now': now().$1,
            'anchor': ?_anchorArg(),
          });
          _absorbLocalWrite(r);
        });
        await _notifyPurged();
        return r;
      });

  /// 冲突中心（设计 §5.3）：待用户定的破坏性并发。
  Future<List<Map<String, Object?>>> sync2Conflicts() async =>
      <Map<String, Object?>>[
        for (final Object? c
            in (await _sync2Raw(<String, Object?>{'op': 'conflicts'})).json!
                as List<Object?>)
          (c! as Map).cast<String, Object?>(),
      ];

  /// 解决一项冲突：[delete] = 以删除为准，否则保留。在 [undoable] 里时把写下的删除 / 恢复记进撤销凭据。
  Future<void> sync2Resolve(String conflictId, {required bool delete}) =>
      runExclusive(() async {
        final _SrsUndoRecorder? recorder = _undoRecorder;
        if (recorder != null) {
          for (final Map<String, Object?> c in await sync2Conflicts()) {
            final SrsEntityKind? kind = SrsEntityKind.tryParse(
              c['entityKind'] as String?,
            );
            if (c['id'] == conflictId && kind != null) {
              await recorder.noteBefore(<(SrsEntityKind, String, String)>[
                (kind, c['entity']! as String, SrsFieldKeys.deleted),
              ]);
            }
          }
        }
        final Map<String, Object?> r = await _sync2Write(<String, Object?>{
          'op': 'resolve',
          'conflict': conflictId,
          'delete': delete,
        });
        recorder?.noteWritten(
          (r['edits'] as List<Object?>?) ?? const <Object?>[],
        );
      });

  /// 彻底清除一批同类实体（设计 §10.5；界面已二次确认）：内核的一条命令、一笔——每个实体仍是「删除 + 清除」
  /// 两条操作，按 [entityIds] 的顺序。空的一批不发命令。一笔的大小由调用方定（[srsPurgeNotesNow] 分块）。
  Future<void> sync2PurgeMany(
    SrsEntityKind kind,
    List<String> entityIds,
  ) async {
    if (entityIds.isEmpty) return;
    await _sync2Write(<String, Object?>{
      'op': 'purge',
      'kind': kind.wire,
      'entities': entityIds,
    });
  }

  /// 打一个还原点（设计 §10.2：批量删除 / 导入 / 改笔记类型 / 重训参数之前自动打）。[reason] 是稳定短码：
  /// `bulk_delete` / `import` / `note_type` / `fsrs_params` / `manual`（`restore` 由内核自己打）。
  Future<void> sync2Checkpoint(String name, String reason) => _sync2Write(
    <String, Object?>{'op': 'checkpoint', 'name': name, 'reason': reason},
  );

  /// 还原点列表（新的在前）。
  Future<List<Map<String, Object?>>> sync2Checkpoints() async =>
      <Map<String, Object?>>[
        for (final Object? c
            in (await _sync2Raw(<String, Object?>{'op': 'checkpoints'})).json!
                as List<Object?>)
          (c! as Map).cast<String, Object?>(),
      ];

  /// 预览恢复到 [atMs]：会改回多少字段 / 复活 / 删除多少实体 / 改多少标签 / 撤回多少次复习。给了
  /// [checkpoint]（还原点的 `{device, seq}`）就按那个还原点的因果截断，不按墙钟（同一毫秒的删除不会被算进去）。
  ///
  /// 不进写锁（只读；通道没做完时内核会先收通道，见 [kSrsSync2ProjectingOps] 的说明）。
  Future<Map<String, Object?>> sync2PlanRestore(
    int atMs, {
    required bool retractReviews,
    ({String device, int seq})? checkpoint,
  }) => _sync2(<String, Object?>{
    'op': 'plan_restore',
    'at': atMs,
    'checkpoint': ?_checkpointJson(checkpoint),
    'retract': retractReviews,
    'now': now().$1,
  });

  static Map<String, Object?>? _checkpointJson(({String device, int seq})? c) =>
      c == null ? null : <String, Object?>{'device': c.device, 'seq': c.seq};

  /// 恢复到 [atMs]（先自动打还原点，再追加补偿操作；恢复本身也可再恢复回去）。
  Future<void> sync2Restore(
    int atMs, {
    required bool retractReviews,
    ({String device, int seq})? checkpoint,
  }) => _sync2Write(<String, Object?>{
    'op': 'restore',
    'at': atMs,
    'checkpoint': ?_checkpointJson(checkpoint),
    'retract': retractReviews,
  });

  /// `.fushisrs` 的操作部分（见 sync2/srs_fushisrs.dart）：内核把本集合的真相层写成 `FSRS4EXP` 流、直接写进 [path]
  /// （native/fushi_fsrs/src/store/gen4/cmd/fushisrs.rs，G11-3），回包是清单里归内核的几项（`collection` / `dir` /
  /// `salts` / `peers`）与计数。内核在一个读快照里导出（只含已提交的写入）；这里仍与写事务互斥，导出与紧随其后的
  /// 媒体清单读同一个状态。
  Future<Map<String, Object?>> sync2ExportOps(String path) async =>
      (await sync2Command(<String, Object?>{'op': 'export', 'path': path})).map;

  /// 导入 `.fushisrs` 之前的预检（G11-3）：内核只判「要不要用户确认、会不会被拒」，**什么都不写**（回包
  /// `{format, outcome: ready | needsConfirm, preflight: true, reason?, collection?, dir?, newSalts?, newPeers?}`；拒收照真导入
  /// 的口径抛错）。调用方据此在
  /// 用户确认之前不打还原点、不往媒体目录写文件。
  Future<Map<String, Object?>> sync2ImportPreflight({
    required String path,
    Map<String, Object?>? manifest,
  }) => runExclusive(
    () => _sync2(<String, Object?>{
      'op': 'import',
      'now': now().$1,
      'path': path,
      'manifest': ?manifest,
      'preflight': true,
    }),
  );

  /// 并入 `.fushisrs` 的操作部分（不覆盖）：内核按文件 [path] 流式读（G11-3）。[manifest] 是第 2 版清单里归内核的
  /// 几项（`collection` / `dir` / `salts` / `peers`；第 1 版不给）。文件来自另一个集合（`reason: join`），或同一个集合的
  /// 文件带来本机还不算数的盐 / 还不认识的设备公钥（`reason: identity`），且没有 [confirmed] 时内核回
  /// `{outcome: needsConfirm, reason, collection, dir, newSalts, newPeers}`、什么都不写；确认后先并入 / 落下再导入。包里本机身份的日志与本机分叉了时内核
  /// 先换身份（回包 `rotated`）。回包原样返回（`applied` = 并入条数）。
  Future<Map<String, Object?>> sync2ImportOps({
    required String path,
    Map<String, Object?>? manifest,
    bool confirmed = false,
  }) => runExclusive(() async {
    late Map<String, Object?> r;
    await _commandOrReload(() async {
      r = await _sync2(<String, Object?>{
        'op': 'import',
        'now': now().$1,
        'anchor': ?_anchorArg(),
        'path': path,
        'manifest': ?manifest,
        'confirmed': confirmed,
      });
      if (r['outcome'] == 'needsConfirm') return;
      _absorbLocalWrite(r);
      // 内核整份重建派生层、回包没有逐实体的变更清单：有改动就丢掉全部缓存日志。
      if (r['unchanged'] != true) _resetCacheJournal();
    });
    if (r['outcome'] == 'needsConfirm') return r;
    // 包里有本机身份的操作时内核先换身份（`rotated`）/ 认领改绑：重取身份（`identity`）。
    await _sync2Open();
    await _notifyPurged();
    return r;
  });

  /// v2 同步之前的 `.fushisrs` 事件备份（G11-4，D34）：内核 `legacy_backup_import {source: "events"}`
  /// （native/fushi_fsrs/src/store/gen4/cmd/backup.rs）先在 [scratch]（调用方给的空目录）里用冻结的协议 3 代码把 [path]
  /// （「外来、已盖戳」事件的 JSONL）落进一份临时协议 3 库，再在一个写事务里认领（G9-4）+ 旧备份读入。[backupProfile]
  /// 是事件所属的旧 profile。认领口径与 [sync2ImportOps] 相同：另一个集合 / 新盐 / 新设备公钥没 [confirmed] 时回
  /// `needsConfirm`、新代库什么都不写；[preflight] 只判断（副本照样备好，同一个 [scratch] 再来真导入时不重备）。
  Future<Map<String, Object?>> sync2LegacyEventsImport({
    required String path,
    required String scratch,
    required String backupProfile,
    bool confirmed = false,
    bool preflight = false,
  }) => runExclusive(() async {
    Map<String, Object?> request() => <String, Object?>{
      'op': 'legacy_backup_import',
      'now': now().$1,
      if (!preflight) 'anchor': ?_anchorArg(),
      'source': 'events',
      'path': path,
      'scratch': scratch,
      'backupProfile': backupProfile,
      'caches': srsCacheConfigFor(backupProfile),
      'confirmed': confirmed,
      'preflight': preflight,
    };
    if (preflight) return _sync2(request());
    late Map<String, Object?> r;
    await _commandOrReload(() async {
      r = await _sync2(request());
      if (r['outcome'] == 'needsConfirm') return;
      _absorbLocalWrite(r);
      // 旧备份读入整份重建派生层（同 [sync2ImportOps]）：有改动就丢掉全部缓存日志。
      if (r['unchanged'] != true) _resetCacheJournal();
    });
    if (r['outcome'] == 'needsConfirm') return r;
    await _sync2Open();
    await _notifyPurged();
    return r;
  });

  /// 同步状态（设计 §10.6）。
  Future<Map<String, Object?>> sync2Status() async =>
      (await sync2Command(<String, Object?>{'op': 'status'})).map;

  /// 彻底清除的字节层收尾（内核 `scrub_state`，`gen4/scrub.rs`；整个库一份，与 profile 无关）：`due` = 有清除提交了、
  /// 磁盘上的旧字节还没抹干净（等下一次写入或开库时收尾）；`error` = 上一次收尾没做成的原因（空间不够等），没有 = null。
  /// `error` 非空时同步 / 清除相关页面提示用户（`srs_scrub_error_notice`）。读快照，不写库。
  Future<SrsScrubState> scrubState() async {
    final Map<String, Object?> r = (await sync2Command(const <String, Object?>{
      'op': 'scrub_state',
    })).map;
    return (due: r['due'] == true, error: r['error'] as String?);
  }

  /// 本机设备信息（native/fushi_fsrs/src/store/sync2/devices.rs）：给了哪个改哪个，[nick] 给空串 = 清掉昵称、回到
  /// 型号。人读名 = 昵称或型号，随下一次写 head 发布（型号 / 版本 / 平台进 head 的扩展）。没变时内核不进写锁。
  Future<Map<String, Object?>> sync2DeviceInfo({
    String? model,
    String? app,
    String? platform,
    String? nick,
  }) async => (await sync2Command(<String, Object?>{
    'op': 'device_info',
    'now': now().$1,
    'model': ?model,
    'app': ?app,
    'platform': ?platform,
    'nick': ?nick,
  })).map;

  /// 给没有自报名字的设备 [device] 记一个补充名（互联 host 认出了直接写它的段的已配对对端）。
  Future<void> sync2DeviceHint(String device, String hint) => sync2Command(
    <String, Object?>{'op': 'device_hint', 'device': device, 'hint': hint},
  );

  /// 停用 / 取消停用一台别的设备（「这台设备不用了」）：停用后因等它的数据而卡在缓冲里的操作立即投递，同一次
  /// 调用里接进缓存。不删任何数据；它之后又同步过来会自动取消停用。
  Future<void> sync2Retire(String device, {required bool retire}) =>
      _sync2Write(<String, Object?>{
        'op': 'retire',
        'device': device,
        'retire': retire,
      });

  /// 信任 / 拒绝一台待确认的设备（native/fushi_fsrs/src/store/sync2/trust.rs）：本机库非空之后才第一次同步过来的
  /// 设备，它的删除与彻底清除扣到这里确认。信任 = 扣着的同一次调用里放行进投影并接进缓存；拒绝 = 继续扣着（它的
  /// 普通修改照常同步，之后仍可改为信任）。
  Future<void> sync2Trust(String device, {required bool trust}) => _sync2Write(
    <String, Object?>{'op': 'trust', 'device': device, 'trust': trust},
  );

  /// 算并记下状态摘要（写 head 时带上；两台设备在同一版本向量下摘要不同 = 确定性 bug）。
  Future<Map<String, Object?>> sync2Digest() async =>
      (await sync2Command(<String, Object?>{'op': 'digest'})).map;

  /// 一条同步 v2 命令（native/fushi_fsrs/src/store/ffi.rs `ffsrs_store_sync2`），在后台 isolate 跑。
  Future<Map<String, Object?>> _sync2(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async => (await _sync2Raw(request, blobs: blobs)).map;

  /// 一条交回列式表的只读内核命令（store/bulk.rs）：结果的每个文件是一张 [SrsColumns]，从 worker 以
  /// [TransferableTypedData] 交回，在本 isolate 上直接建视图。
  Future<({Object? json, Map<String, SrsColumns> tables})> _columnsCommand(
    Map<String, Object?> request,
  ) async {
    await _freshBinding(request['op']);
    debugCoreCommands++;
    final int token = SrsOpLedger.begin('core:${request['op']}');
    int bytes = 0;
    int rows = 0;
    try {
      final (
        Object? json,
        Map<String, TransferableTypedData> files,
      ) = await _coreColumns(core.address, core.libraryPath, <String, Object?>{
        ...request,
        'profile': profileUid,
      });
      final Map<String, SrsColumns> tables = <String, SrsColumns>{};
      for (final MapEntry<String, TransferableTypedData> f in files.entries) {
        final Uint8List b = f.value.materialize().asUint8List();
        bytes += b.length;
        final SrsColumns c = SrsColumns.decode(b);
        rows += c.rows;
        tables[f.key] = c;
      }
      return (json: json, tables: tables);
    } finally {
      SrsOpLedger.end(token, bytes: bytes, rows: rows);
    }
  }

  /// 发一条内核命令。收段通道在这条命令之前自己做完的片没有回包：内核在每片提交时推进刷新键（[contentFingerprint]
  /// 等现读），这里不用接。
  Future<SrsSync2Result> _sync2Raw(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    assert(
      !kSrsSync2ProjectingOps.contains(request['op']) || holdsExclusive,
      'sync2 `${request['op']}` changes the projection outside runExclusive',
    );
    await _freshBinding(request['op']);
    debugCoreCommands++;
    final SrsSync2Result r = await SrsOpLedger.track(
      'core:${request['op']}',
      () => _coreSync2(
        core.address,
        core.libraryPath,
        <String, Object?>{
          ...request,
          'profile': profileUid,
          if (_kSync2CacheOps.contains(request['op'])) 'caches': _cacheConfig,
        },
        blobs,
        lane: srsCoreLaneOf(request['op']),
      ),
      measure: (SrsSync2Result r) => (
        r.files.fold<int>(0, (int n, (String, Uint8List) f) => n + f.$2.length),
        0,
      ),
    );
    // 可能改绑定的命令（`identity` 第一次建、并入 / 补盐 / 认领）在提交成功之后把 `bindingChanged` 放进回包
    // （native/fushi_fsrs/src/store/gen4/dispatch.rs `write_binding`）：每条回包都看，内核没有另一条事件流。
    final Object? json = r.json;
    if (json is Map && json['bindingChanged'] != null) {
      onBindingChanged();
      // 打开途中（还没读过根上 ID）由 [open] 最后统一读；`identity` 自己的回包由发它的 [_sync2Open] /
      // [refreshIdentity] 接着读。其余的绑定变化在这条命令返回之前把身份、绑定代号与根上 ID 重读完。
      if (_rootIds != null && !_kBindingReloadOps.contains(request['op'])) {
        try {
          await _reloadBinding();
        } on Object {
          // 这条命令已经在内核提交了：重读失败不能让调用方把一次成功的写入当成失败（复核 nit）。绑定留着「过期」标记
          // （[_reloadBinding] 没走完就不清），下一条命令发出之前先重读（[_freshBinding]），再失败由那条命令报出来。
        }
      }
    }
    return r;
  }

  /// 重读绑定时自己发的命令：发它们之前不再查「绑定过期」，回包里的 `bindingChanged` 也不在 [_sync2Raw] 里递归重读。
  static const Set<String> _kBindingReloadOps = <String>{
    'identity',
    'collection_info',
    'canonical_ids',
  };

  /// 绑定变了之后还没重读成功（[_reloadBinding] 中途失败）：下一条命令之前先重读。
  bool _bindingStale = false;

  /// 绑定还没重读成功（[_bindingStale]）：测试用。
  @visibleForTesting
  bool get debugBindingStale => _bindingStale;

  /// 测试用：非空时下一次 [_reloadBinding] 一开始就抛它（只抛一次），模拟「命令已提交、重读身份 / 根上 ID 失败」。
  @visibleForTesting
  StateError? debugBindingReloadFailure;

  /// 绑定变了：身份（设备号 / 集合 / 目录 / 绑定代号，[_sync2Open]）与根上 ID 的规范形（[_loadRootIds]）整份重读。
  /// 走完才清 [_bindingStale]。
  Future<void> _reloadBinding() async {
    _bindingStale = true;
    final StateError? injected = debugBindingReloadFailure;
    if (injected != null) {
      debugBindingReloadFailure = null;
      throw injected;
    }
    await _sync2Open();
    await _loadRootIds();
    _bindingStale = false;
  }

  /// 发命令之前：上一次绑定变化没重读成功的话先重读（失败抛给这条命令，它还没发出去）。
  Future<void> _freshBinding(Object? op) async {
    if (_bindingStale && !_kBindingReloadOps.contains(op)) {
      await _reloadBinding();
    }
  }

  /// 内核命令走哪条 worker 道（srs_core_workers.dart [SrsCoreLane]，集成审查【中】）：复习页的作答 / 排队 / 预览
  /// 走交互道，不排在同步的成批命令与媒体文件加解密后面；本机手动排程（`sched`：复习页撤销、浏览页重置 / 改期、
  /// 立即重排）是从 `apply` 拆出来的同一类本机写入，同走交互道；编辑类撤销的裁决（`undo_check`，只读，紧接着写回）
  /// 同走交互道；媒体文件的流式加解密 / 哈希走专用的文件道（同步时按
  /// `kSrsSync2Concurrency` 并发，以前一来就占满整个池）；其余走默认道。
  @visibleForTesting
  static SrsCoreLane srsCoreLaneOf(Object? op) => switch (op) {
    'apply' ||
    'sched' ||
    'study' ||
    'preview' ||
    'undo_check' => SrsCoreLane.interactive,
    'seal_file' || 'open_file' || 'media_hash' => SrsCoreLane.file,
    _ => SrsCoreLane.bulk,
  };

  /// 改投影的 v2 命令（与内核 native/fushi_fsrs/src/store/gen4/dispatch.rs `PROJECTING_OPS` 同一组）：只能在本副本的独占区里发
  /// （[_sync2Raw] 断言）：回包要按顺序接进本对象的内存（缓存变更日志、修订号）。
  ///
  /// 不在这里、也不排写锁却可能顺带写库的：`digest`（记一行摘要缓存）、`media_hash`、`plan_restore`（只读，但通道没做完时
  /// 内核先收通道，收下的片在内核里推进刷新键）——见 [kSrsSync2LockFreeOps] 与 [sync2PlanRestore]。
  @visibleForTesting
  static const Set<String> kSrsSync2ProjectingOps = <String>{
    'apply',
    'import_drafts',
    'change',
    'note_fields_if',
    'merge_notes',
    'sched',
    'deck_delete',
    'retire',
    'ingest',
    'ingest_finish',
    'import',
    'resolve',
    'trust',
    'purge',
    'checkpoint',
    'restore',
    'dedup',
    'digest_heal',
  };

  /// 发出过的内核命令数（`ffsrs_store_sync2` 一次算一条）：复习路径的 FFI 次数守卫 / 基准用。
  @visibleForTesting
  int debugCoreCommands = 0;

  /// 改投影 / 刷新缓存的 v2 命令：内核在同一次调用里刷新本机缓存行（native/fushi_fsrs/src/store/caches.rs），
  /// 要带上只有 Dart 知道的缓存配置（[_cacheConfig]）。
  ///
  /// 协议 3 收段通道与存储表示的命令（`ingest_batch` / `ingest_commit` / `replay_pending` / `edits_rewrite_repr` /
  /// `backfill_dupe_norms`）新代没有（内核 `gen4/dispatch.rs` `wiring` 报 Removed），Dart 不再发，已从这里删去（G7-6）。
  static const Set<String> _kSync2CacheOps = <String>{
    'apply',
    'import_drafts',
    'change',
    'note_fields_if',
    'merge_notes',
    'sched',
    'deck_delete',
    'ingest',
    'ingest_finish',
    'import',
    'retire',
    'resolve',
    'trust',
    'purge',
    'checkpoint',
    'restore',
    'dedup',
    'digest_heal',
    'refresh_caches',
    'rebuild_caches',
    'cache_config_set',
    'media_gc_collect',
    'media_live_refs',
  };

  /// 缓存刷新的配置（[srsCacheConfigFor]）。
  late final Map<String, Object?> _cacheConfig = srsCacheConfigFor(profileUid);

  /// 按 SQLite 变量上限分块（IN 列表）。
  static Iterable<List<String>> _chunks(Iterable<String> ids) sync* {
    final List<String> all = ids.toList();
    for (int i = 0; i < all.length; i += 500) {
      yield all.sublist(i, min(i + 500, all.length));
    }
  }

  /// 导入（Anki 包 / fushi-ext）批量落一组事件：视同本机产生（进发件箱）、刷新缓存。幂等。
  ///
  /// 事件内容由调用方按铁律 C 只从来源算出（身份记录 / 复习日志）；本机 HLC 按收到对端事件的规则推进（先钳位，
  /// [_emit] 的 `receive`）。
  Future<void> importEvents(List<SrsEvent> events) async {
    if (events.isEmpty) return;
    await runExclusive(
      () => _emit(<SrsEventDraft>[
        for (final SrsEvent e in events) SrsReadyDraft(e),
      ], receive: true),
    );
  }

  /// 导入攒的一批草稿（[newNoteDrafts] / [newEditDrafts] + 已定稿的日志等）落库：同 [importEvents]，
  /// 修改记录的序号 / HLC 在落库的命令里才由内核分配——攒批期间（读包、解析、别的写入）不占序号，落库顺序 = 序号
  /// 顺序（BUG-3545，以前攒批时就分配，期间插进来的本机写入先落库）。
  ///
  /// 一条内核命令（`import_drafts`，native/fushi_fsrs/src/store/sync2/mod.rs `import_drafts_on`）：「初值」草稿
  /// （[SrsEditDraft.initial]）里键已有修改记录的不落，由内核在落库的同一笔里判。
  ///
  /// 返回这批身份记录里**落库前就已存在**的实体 ID（导入据此按实际新建数计数：攒批时以为是新
  /// 笔记、落库时已被同步 / 别处建好的，不算「新增」），与被实体归属闸拒掉的笔记
  /// （[SrsImportDraftsResult.foreignNotes]：没落，导入记冲突）。
  ///
  /// [cardNotes]：卡 → 笔记（这批里新建的笔记的卡还没有卡片缓存行，查不到笔记）。带上笔记的日志与卡片修改跟着笔记过
  /// 实体归属闸：笔记被拒时它的日志、它的卡片修改（新卡位置、牌组、暂停）一并不落，不留下指向不存在的卡、却照样进统计
  /// 的悬空复习，也不留下没有缓存行的悬空卡片修改（BUG-5005 复核；内核 `writes_owner.rs` 文件头「卡片修改带笔记」）。
  Future<SrsImportDraftsResult> importDrafts(
    List<SrsEventDraft> drafts, {
    Map<String, String> cardNotes = const <String, String>{},
  }) async {
    if (drafts.isEmpty) {
      return const SrsImportDraftsResult(<String>{}, <String>{});
    }
    return runExclusive(() async {
      final Set<String> existed = <String>{};
      final Set<String> foreign = <String>{};
      await _emit(
        drafts,
        receive: true,
        existed: existed,
        foreignNotes: foreign,
        cardNotes: cardNotes,
      );
      return SrsImportDraftsResult(existed, foreign);
    });
  }

  SrsEntityRecord _entityFromRow(_EntityRow r) => SrsEntityRecord(
    id: r.id,
    profileUid: profileUid,
    kind: SrsEntityKind.tryParse(r.kind) ?? SrsEntityKind.note,
    payload: (jsonDecode(r.payloadJson) as Map).cast<String, Object?>(),
  );

  // ------------------------------------------------------------------ 内置

  /// 内置默认牌组与内置笔记类型（Lapis、Fushi 卡片；确定性 ID，每台设备都生成同一份；没改过的内置定义不写修改记录）。
  ///
  /// 内置实体的 ID 是规范 ID（[srsBuiltinEntities] 向内核要，不带盐，G9-7），与 `entities` 读回的直接比：全新库里
  /// 就是它；迁移来的库里协议 3 按 uid 加盐的内置实体被派生层归到同一个规范 ID，读回的也是它，所以不会另建一份。
  ///
  /// 默认牌组是不变式：牌组树（[deckTree]）里恒有它，「有效牌组」与排程配置都回落到它。身份记录在、却带着删除标记
  /// 的（旧版删一个牌组时把挪进它子树的默认牌组连带删了，内核 `deck_delete` 已不再这样做）照样不在树里，这里复活它
  /// 并挂回顶层；修改记录随同步传到别的设备，那边也一起好。BUG-5209。
  Future<void> ensureBuiltins() => runExclusive(() async {
    final List<SrsEntityRecord> builtins = srsBuiltinEntities(profileUid);
    final Set<String> present = (await _entityIdsWhere(
      ids: <String>[for (final SrsEntityRecord r in builtins) r.id],
    )).toSet();
    final String defaultDeck = kernelIds.defaultDeck;
    final SrsEntityEdits deckEdits = present.contains(defaultDeck)
        ? await _entityEdits(SrsEntityKind.deck, defaultDeck)
        : SrsEntityEdits.empty();
    final List<SrsEventDraft> drafts = <SrsEventDraft>[
      for (final SrsEntityRecord r in builtins)
        if (!present.contains(r.id)) SrsReadyDraft(SrsEntityEvent(r)),
      if (deckEdits.deletedAt != null)
        ...newEditDrafts(SrsEntityKind.deck, defaultDeck, <String, Object?>{
          SrsFieldKeys.deleted: null,
          SrsFieldKeys.deckParent: null,
        }, current: deckEdits),
    ];
    if (drafts.isNotEmpty) await _emit(drafts);
  });

  /// [canonicalIds] 发过几次 `canonical_ids`（测试用：读路径按回包的 `canon` / `keyCanon` 对，不另发这条命令）。
  @visibleForTesting
  int debugCanonicalIdsCalls = 0;

  /// 一批 ID 的规范 ID（内核 `canonical_ids`，只读、一个读快照，逐项对应）。一次最多 `kSrsCanonicalIdsBatchMax`
  /// 条，多了由调用方分批（srs_canonical_ids.dart 的 `srsCanonicalIdMap`）；归一不到的 ID 原样返回。
  Future<List<String>> canonicalIds(List<String> ids) async {
    if (ids.isEmpty) return const <String>[];
    debugCanonicalIdsCalls++;
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      'op': 'canonical_ids',
      'ids': ids,
    });
    final List<String> out = (r['ids']! as List<Object?>).cast<String>();
    if (out.length != ids.length) {
      throw StateError(
        'canonical_ids answered ${out.length} ids for ${ids.length}',
      );
    }
    return out;
  }

  /// 根上的内置实体 ID（默认牌组、两个内置笔记类型）：开库最后一步与绑定变化之后（[_sync2Raw]）各取一次。内核按
  /// 规范规则答（[SrsKernelIds]，一次 FFI、不碰库，G9-7），就是读命令回的 ID；调用方拿它和读回的比（牌组树里找默认
  /// 牌组、笔记类型列表里找 Lapis……）。规范 ID 是不带盐的常量，补盐 / 并入不改变它。
  Future<void> _loadRootIds() async {
    final List<String> ids = kernelIds.ask(<List<Object?>>[
      const <Object?>['default_deck'],
      const <Object?>['builtin_notetype', kSrsBuiltinLapisKey],
      const <Object?>['builtin_notetype', kSrsBuiltinFushiCardKey],
    ]).cast<String>();
    _rootIds = (defaultDeck: ids[0], lapis: ids[1], fushiCard: ids[2]);
  }

  /// 根上 ID 的规范形（[_loadRootIds]）；打开完成之后恒非空。
  ({String defaultDeck, String lapis, String fushiCard})? _rootIds;

  ({String defaultDeck, String lapis, String fushiCard}) get _roots =>
      _rootIds ??
      (throw StateError('SrsDbStore: root ids are read when the store opens'));

  /// 本 profile 的根上 ID（向内核要，见 [SrsKernelIds]；规范 ID，不带盐）。绑定变了（[onBindingChanged]）作废重取。
  SrsKernelIds get kernelIds => _kernelIds ??= SrsKernelIds(profileUid);
  SrsKernelIds? _kernelIds;

  /// 内置默认牌组的规范 ID（[_loadRootIds]），与读命令回的 ID 同一种写法。绑定变了重读。
  String get defaultDeckId => _roots.defaultDeck;

  /// 内置 Lapis 笔记类型的规范 ID。同 [defaultDeckId]。
  String get lapisNoteTypeId => _roots.lapis;

  /// 内置 Fushi 卡片笔记类型的规范 ID。同 [defaultDeckId]。
  String get fushiCardNoteTypeId => _roots.fushiCard;

  // ------------------------------------------------------------------ 物化

  /// [noteType] / [noteTypes] 的物化缓存（卡片详情每次 [cardDetail]、制卡选项每次库版本变动都要物化，每次两三次
  /// 读命令往返 + 一次寄存器内核）。键是 [contentFingerprint]，与笔记类型的结构写入严格对应：
  /// - 笔记类型只由它的身份记录与修改记录决定；这两类记录落进投影（本机写入、收段、导入、恢复、冲突解决、清除，
  ///   全是内核命令）一律在提交之后推进内核的内容计数（store/refresh.rs；内核 `Marks::entity` / `Marks::edit`：笔记类型
  ///   上没有界面状态类字段键，见 `is_view_state`）。Dart 侧对这两张表的直写只有 [compactStoredStyles]（只动笔记的
  ///   修改记录、只换表示不换值）与 profile 合并删整个旧 profile 的行（之后按新 uid 重开），都碰不到本 profile 的
  ///   笔记类型；
  /// - 重读本机状态（开库、覆盖恢复后、写事务回滚后的 [_loadLocal]）推进它，纪元随覆盖恢复更换；
  /// - 复习日志与界面状态（牌组收起 / 排序位、新卡位置）不推进它——它们碰不到笔记类型，所以不在键里
  ///   （[_structureKey] 多出的界面状态计数只关牌组树）。
  /// 读的途中键变了就不存（同 [deckTree]）。缓存的视图是不可变的，[noteTypes] 返回副本列表。
  _NoteTypeCache? _noteTypeCache;

  _NoteTypeCache _noteTypeCacheAt(String key) {
    final _NoteTypeCache? c = _noteTypeCache;
    return c != null && c.key == key ? c : _NoteTypeCache(key);
  }

  Future<SrsNoteTypeView?> noteType(String id) async {
    final String key = contentFingerprint;
    final _NoteTypeCache cache = _noteTypeCacheAt(key);
    if (cache.byId.containsKey(id)) return cache.byId[id];
    final SrsNoteTypeView? v = (await _materializeNoteTypes(<String>[id]))[id];
    if (contentFingerprint == key) {
      cache.byId[id] = v;
      _noteTypeCache = cache;
    }
    return v;
  }

  /// 一组笔记类型的物化（身份记录 / 修改记录先查预读）：整组一次 FFI 调用（字段寄存器内核）。
  /// 不存在的 ID 映射到 null。
  Future<Map<String, SrsNoteTypeView?>> _materializeNoteTypes(
    List<String> ids,
  ) async {
    final Map<String, SrsNoteTypeView?> out = <String, SrsNoteTypeView?>{};
    final List<(SrsEntitySource, SrsBuiltinNoteType?)> src =
        <(SrsEntitySource, SrsBuiltinNoteType?)>[];
    for (final String id in ids) {
      out[id] = null;
      final _EntityRow? row = await _entityRow(id);
      if (row == null) continue;
      src.add((
        SrsEntitySource(
          id,
          row.payloadJson,
          await _editItems(SrsEntityKind.noteType, id),
        ),
        srsBuiltinNoteTypeForKey(
          profileUid,
          _entityFromRow(row).payload['builtin'] as String?,
        ),
      ));
    }
    final List<SrsNoteTypeView> views = srsMaterializeNoteTypes(src);
    for (int i = 0; i < src.length; i++) {
      out[src[i].$1.id] = views[i];
    }
    return out;
  }

  /// 未删除的笔记类型，按名字排（按 [contentFingerprint] 缓存，见 [_noteTypeCache]）。
  Future<List<SrsNoteTypeView>> noteTypes() async {
    final String key = contentFingerprint;
    final _NoteTypeCache cache = _noteTypeCacheAt(key);
    final List<SrsNoteTypeView>? cached = cache.all;
    if (cached != null) return List<SrsNoteTypeView>.of(cached);
    final Map<String, SrsNoteTypeView?> byId = await noteTypesById(
      await _entityIdsWhere(kind: SrsEntityKind.noteType),
    );
    final List<SrsNoteTypeView> out = <SrsNoteTypeView>[
      for (final SrsNoteTypeView? v in byId.values)
        if (v != null && v.deletedAt == null) v,
    ];
    out.sort(
      (SrsNoteTypeView a, SrsNoteTypeView b) => a.name.compareTo(b.name),
    );
    if (contentFingerprint == key) {
      // 同一个键下物化结果相同：已缓存的单个视图保留原对象（调用方可按 identical 判没变）。
      for (final MapEntry<String, SrsNoteTypeView?> e in byId.entries) {
        cache.byId.putIfAbsent(e.key, () => e.value);
      }
      cache.all = List<SrsNoteTypeView>.unmodifiable(out);
      _noteTypeCache = cache;
    }
    return out;
  }

  /// 一组笔记类型（含已删除的；不存在的 ID 映射到 null），按 ID 分块预读（每块几次往返）。
  Future<Map<String, SrsNoteTypeView?>> noteTypesById(
    Iterable<String> ids,
  ) async {
    final Map<String, SrsNoteTypeView?> out = <String, SrsNoteTypeView?>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, SrsEntityKind.noteType, chunk);
      out.addAll(await _readWith(pre, () => _materializeNoteTypes(chunk)));
    }
    return out;
  }

  Future<SrsNoteView?> note(String id) async =>
      (await _materializeNotes(<String>[id]))[id];

  /// 一组笔记的物化（身份记录 / 修改记录先查预读）：整组一次 FFI 调用（字段寄存器内核）。
  /// 不存在的 ID 映射到 null。
  Future<Map<String, SrsNoteView?>> _materializeNotes(List<String> ids) async {
    final Map<String, SrsNoteView?> out = <String, SrsNoteView?>{};
    final List<SrsEntitySource> src = <SrsEntitySource>[];
    for (final String id in ids) {
      out[id] = null;
      final _EntityRow? row = await _entityRow(id);
      if (row == null) continue;
      src.add(
        SrsEntitySource(
          id,
          row.payloadJson,
          await _editItems(SrsEntityKind.note, id),
        ),
      );
    }
    final List<SrsNoteView> views = srsMaterializeNotes(src);
    for (int i = 0; i < src.length; i++) {
      out[src[i].id] = views[i];
    }
    return out;
  }

  /// 一组笔记的物化视图（含已删除的；不存在的 ID 映射到 null；按输入顺序去重）。按 ID 分块
  /// 预读身份记录 / 修改记录 / 服务器时刻，每块几次往返——批量读笔记的地方（导出、改标签、
  /// 更改笔记类型、旧 Lapis 迁移）不再每条笔记各查三次（BUG-3543）。
  Future<Map<String, SrsNoteView?>> notes(Iterable<String> ids) async {
    final Map<String, SrsNoteView?> out = <String, SrsNoteView?>{};
    final Set<String> wanted = ids.toSet();
    srsDebugMaxNotesPerRead = max(srsDebugMaxNotesPerRead, wanted.length);
    for (final List<String> chunk in _chunks(wanted)) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, SrsEntityKind.note, chunk);
      out.addAll(await _readWith(pre, () => _materializeNotes(chunk)));
    }
    return out;
  }

  /// 一组实体的视图（内核 `entity_views`，native/fushi_fsrs/src/store/gen4/cmd/views.rs 文件头「线上形状」）：每块
  /// （至多 [kSrsEntityViewsBatchMax] 个 ID）一条命令、一个读快照。按请求顺序；同一个别名类只出一份（规范 ID）；不存在的
  /// 跳过。[ids] 为 null = 本 profile 该类的全部实体。远程复习 V2 的主机原样搬它（srs_remote_store.dart），解码只有
  /// srs_entity_views.dart 一份。
  Future<List<SrsEntityView>> entityViews(
    SrsEntityKind kind, {
    Iterable<String>? ids,
  }) async {
    final List<String> wanted =
        ids?.toSet().toList() ?? await _entityIdsWhere(kind: kind);
    final List<SrsEntityView> out = <SrsEntityView>[];
    final Set<String> seen = <String>{};
    for (int at = 0; at < wanted.length; at += kSrsEntityViewsBatchMax) {
      final Map<String, Object?> r = await _sync2(<String, Object?>{
        'op': 'entity_views',
        'kind': kind.wire,
        'ids': wanted.sublist(
          at,
          min(at + kSrsEntityViewsBatchMax, wanted.length),
        ),
      });
      for (final Object? v in r['views']! as List<Object?>) {
        if (v case {
          'id': final String id,
          'tag': final String tag,
          'v': final String json,
        }) {
          // 分块之间同一个类的另一份成员：只留第一次。
          if (seen.add(id)) out.add(SrsEntityView(id, tag, json));
        } else {
          throw StateError('entity_views: malformed view $v');
        }
      }
    }
    return out;
  }

  /// [deckTree] 缓存所认的键：键不变，牌组树不变。
  String get deckTreeKey => _structureKey;

  /// 库已关（底下的 Rust 句柄已释放）。
  bool get isClosed => core.isClosed;

  /// 牌组树：身份记录一次读、全部牌组的修改记录分块一次预读（以前每个牌组各查两次，
  /// 导入几百个牌组的包时每建一个牌组都重读一遍整棵树，BUG-3543）。
  Future<SrsDeckTree> deckTree() async {
    final String key = _structureKey;
    final ({String key, SrsDeckTree tree})? cached = _deckTreeCache;
    if (cached != null && cached.key == key) return cached.tree;
    final SrsDeckTree tree = await _loadDeckTree();
    // 读的途中又落了事件：这份可能是旧的，不缓存（落库在事务里，修订号在事务内推进，之后发出的
    // 读要等事务提交，所以「键没变」= 读到的就是这个键对应的数据）。
    if (_structureKey == key) _deckTreeCache = (key: key, tree: tree);
    return tree;
  }

  Future<SrsDeckTree> _loadDeckTree() async {
    final List<_EntityRow> rows = _entityRowsOf(
      await _readTable('entities', <String, Object?>{
        'kind': SrsEntityKind.deck.wire,
      }),
    );
    final List<SrsDeckView> views = <SrsDeckView>[];
    for (final List<String> chunk in _chunks(
      rows.map((_EntityRow r) => r.id),
    )) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEdits(pre, SrsEntityKind.deck, chunk);
      final Set<String> ids = chunk.toSet();
      // 整块一次 FFI 调用（字段寄存器内核）。
      views.addAll(
        srsMaterializeDecks(<SrsEntitySource>[
          for (final _EntityRow r in rows)
            if (ids.contains(r.id))
              SrsEntitySource(
                r.id,
                r.payloadJson,
                pre.edits['${SrsEntityKind.deck.wire}/${r.id}']!,
              ),
        ]),
      );
    }
    return SrsDeckTree(views);
  }

  /// 一组实体各自的修改记录（[_entityEdits] 的成批版本：按 ID 分块预读，每块两三次往返）。
  ///
  /// [keys] / [keyCanon]：见 [_editItemsById]（只对嵌着 ID 的键有意义）。
  Future<Map<String, SrsEntityEdits>> _entityEditsMany(
    SrsEntityKind kind,
    Iterable<String> ids, {
    List<String>? keys,
    Map<String, String>? keyCanon,
  }) async {
    final Map<String, SrsEntityEdits> out = <String, SrsEntityEdits>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEdits(pre, kind, chunk, keys: keys, keyCanon: keyCanon);
      // 整块一次 FFI 调用（字段寄存器内核）。
      final List<SrsEntityEdits> edits = srsEntityEditsOf(<List<SrsEditItem>>[
        for (final String id in chunk) pre.edits['${kind.wire}/$id']!,
      ]);
      for (int i = 0; i < chunk.length; i++) {
        out[chunk[i]] = edits[i];
      }
    }
    return out;
  }

  /// 在带预读 [pre] 的 Zone 里跑一段**只读**的物化（与缓存刷新同一套预读：[_entityRow] /
  /// [_entityEdits] / [_historyOf] / [_serverTimesFor] 先查预读、没预读的照常查库）。预读是开始
  /// 时刻的快照：body 里不得写库，也不得调会写库的方法。
  Future<T> _readWith<T>(_RefreshPrefetch pre, Future<T> Function() body) =>
      runZoned(
        body,
        zoneValues: <Object, Object>{_RefreshPrefetch.zoneKey: pre},
      );

  // ------------------------------------------------------------------ 缓存

  /// 批量读（历史、血统）每块的卡数：块内的读各合成几次往返。
  static const int _refreshChunk = 200;

  /// 身份记录行（刷新期间先查预读）。
  Future<_EntityRow?> _entityRow(String id) async {
    final _RefreshPrefetch? pre = _RefreshPrefetch.current;
    if (pre != null && pre.entities.containsKey(id)) return pre.entities[id];
    return _entityRowsOf(
      await _readTable('entities', <String, Object?>{
        'ids': <String>[id],
      }),
    ).firstOrNull;
  }

  /// 一组实体的身份记录，按**请求里的** ID 记进预读（不存在 = null）。行按规范 ID 出，请求里的别名成员经回包的
  /// `canon` 表对回去（同 [_editItemsById]）。
  Future<void> _prefetchEntities(
    _RefreshPrefetch pre,
    Iterable<String> ids,
  ) async {
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.entities[id] = null;
      }
      final SrsReadResult res = await _read('entities', <String, Object?>{
        'ids': chunk,
      });
      final Map<String, _EntityRow> byId = <String, _EntityRow>{
        for (final _EntityRow r in _entityRowsOf(res.table)) r.id: r,
      };
      pre.entities.addAll(srsRowsByRequest(byId, chunk, res.json));
    }
  }

  /// 一组实体的全部修改记录**原文**（canonical JSON 的 UTF-8 字节）+ 这些记录的服务器时刻（同一条
  /// 语句 LEFT JOIN 出来）：物化整块交给字段寄存器内核，修改记录不在 Dart 侧解析。
  ///
  /// [keys] / [keyCanon]：见 [_editItemsById]（键只问一次：第一块带上）。
  Future<void> _prefetchEdits(
    _RefreshPrefetch pre,
    SrsEntityKind kind,
    Iterable<String> ids, {
    List<String>? keys,
    Map<String, String>? keyCanon,
  }) async {
    bool keysAsked = keys == null || keys.isEmpty;
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.edits['${kind.wire}/$id'] = <SrsEditItem>[];
      }
      final Map<String, List<SrsEditItem>> byId = await _editItemsById(
        <String, Object?>{
          'kind': kind.wire,
          'ids': chunk,
          if (!keysAsked) 'keys': keys,
        },
        keyCanon: keysAsked ? null : keyCanon,
      );
      keysAsked = true;
      for (final MapEntry<String, List<SrsEditItem>> e in byId.entries) {
        pre.edits['${kind.wire}/${e.key}']!.addAll(e.value);
      }
    }
  }

  static void _noteServerTime(_RefreshPrefetch pre, String id, int? s) {
    pre.serverTimesKnown.add(id);
    if (s != null) pre.serverTimes[id] = s;
  }

  /// 一组卡的全部复习日志 + 日志的服务器时刻（同一条语句 LEFT JOIN，见 [_prefetchEdits]）。
  Future<void> _prefetchLogs(
    _RefreshPrefetch pre,
    Iterable<String> cardIds,
  ) async {
    for (final List<String> chunk in _chunks(cardIds)) {
      for (final String id in chunk) {
        pre.logsByCard[id] = <String>[];
      }
      final SrsColumns c = await _readTable('logs', <String, Object?>{
        'cards': chunk,
      });
      final SrsStringColumn id = c.strings('id');
      final SrsStringColumn card = c.strings('card_id');
      final SrsStringColumn json = c.strings('json');
      final SrsIntColumn st = c.ints('st');
      for (int i = 0; i < c.rows; i++) {
        pre.logsByCard[card[i]]!.add(json[i]);
        _noteServerTime(pre, id[i], st.at(i));
      }
    }
  }

  /// 刚落库的日志 [logId] 的 HLC：`apply` 带 `logHlcs: true` 时回包按输入下标交回每条写下的日志的 HLC（与 `read` 的
  /// `logs` 行里的 `hlc` 同形，native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」）。协议 3 由 `stamps` 交回
  /// 旧版时钟的戳；新代没有旧版时钟，日志的 HLC 就是它那条操作的。不再按卡读全部日志去找（O(该卡日志数)）。
  static Hlc _answeredLogHlc(Map<String, Object?> reply, String logId) {
    for (final Object? row
        in (reply['logHlcs'] as List?) ?? const <Object?>[]) {
      if (row case <Object?>[
        _,
        final String id,
        final String hlc,
      ] when id == logId) {
        return Hlc.decode(hlc);
      }
    }
    throw StateError(
      'srs: the `apply` reply has no HLC for the answered log $logId '
      '(the native core and Dart do not match)',
    );
  }

  /// Anki 导入的复习日志里发生时刻（= Anki revlog id，见 srs_apkg_import.dart `_revlogLog`）落在 [revlogIds] 的那些，
  /// 连同日志所在卡此刻的笔记与可见性（卡没有缓存行时为 null）。导入器写 revlog 前按它判「这次复习已经在本 profile
  /// 里、只是落在另一张卡上」（BUG-4254）。走 `idx_srs_review_logs_profile_kind_time`，按块一次查。
  Future<List<SrsAnkiLogAt>> ankiImportedLogsAt(Iterable<int> revlogIds) async {
    final List<int> ids = revlogIds.toSet().toList();
    if (ids.isEmpty) return const <SrsAnkiLogAt>[];
    final SrsColumns c = await _readTable('anki_logs_at', <String, Object?>{
      'at': ids,
    });
    final SrsStringColumn card = c.strings('card_id');
    final SrsIntColumn at = c.ints('at');
    final SrsIntColumn rating = c.ints('rating');
    final SrsStringColumn rtype = c.strings('rtype');
    final SrsIntColumn dur = c.ints('dur');
    final SrsStringColumn note = c.strings('note_id');
    final SrsIntColumn hidden = c.ints('hidden');
    return <SrsAnkiLogAt>[
      for (int i = 0; i < c.rows; i++)
        SrsAnkiLogAt(
          cardId: card[i],
          revlogId: at[i],
          rating: rating.at(i),
          reviewType: rtype[i],
          durationMs: dur[i],
          noteId: note.at(i),
          visible: switch (hidden.at(i)) {
            null => false,
            final int h => h == 0,
          },
        ),
    ];
  }

  /// 本 profile 里发生时刻落在 [times] 任一值 ±[srsImportEquivalenceWindowMs] 内的原生（非 Anki 导入）评分类
  /// 日志。导入器给「没有卡可比」的 Anki revlog（来源包里卡已删除，BUG-4657）判重用：Fushi 导出 apkg 时 revlog
  /// id 就取原生日志的发生时刻（srs_apkg_export.dart），绕 Anki 一圈再导回来，这次复习本机已有原生那份。
  /// 是否同一次复习由卡片历史内核的同一判据（[srsImportEquivalentAny]）定，这里只按落库列粗筛
  /// （读命令 `native_logs_near`，走 `idx_srs_review_logs_profile_kind_time`），一次查。
  Future<List<SrsReviewLog>> nativeRatingLogsNear(Iterable<int> times) async {
    final List<int> ts = times.toSet().toList();
    if (ts.isEmpty) return <SrsReviewLog>[];
    final SrsColumns c = await _readTable('native_logs_near', <String, Object?>{
      'at': ts,
      'win': srsImportEquivalenceWindowMs,
    });
    final SrsStringColumn json = c.strings('json');
    return <SrsReviewLog>[
      for (int i = 0; i < c.rows; i++)
        SrsReviewLog.fromJson(
          (jsonDecode(json[i]) as Map).cast<String, Object?>(),
        ),
    ];
  }

  /// 全部「前身卡 → 后继卡」链接（卡的 `historyFrom/<前身>` 修改记录）。
  ///
  /// 条件用 v119 的部分覆盖索引 `idx_srs_field_edits_history_from` 的同一句 WHERE
  /// （[kSrsHistoryFromCondition]，字面量）；实体类型写成 `+entity_kind`，不让规划器改挑
  /// `(entity_kind, entity_id)` 索引去扫全部卡片修改记录。命中时只扫前身链接那几行，不随修改记录表
  /// 增长——每次缓存刷新（每次评分、每次改卡）都要读一遍（BUG-3543，以前全表扫描）。
  Future<Map<String, List<String>>> _successorIndex() async {
    const String prefix = SrsFieldKeys.cardHistoryFromPrefix;
    final SrsColumns c = await _readTable('successors');
    final SrsStringColumn entity = c.strings('entity_id');
    final SrsStringColumn key = c.strings('field_key');
    final Map<String, List<String>> out = <String, List<String>>{};
    for (int i = 0; i < c.rows; i++) {
      (out[key[i].substring(prefix.length)] ??= <String>[]).add(entity[i]);
    }
    return out;
  }

  /// 一组卡各自的血统（自己在前，再按广度优先列出全部前身，防环），与输入同序：内核按卡 id 解析
  /// （store/caches.rs `lineage_ids`，只读前身链接那几条修改记录），一块一次命令。看得见本机写事务里还没提交的行。
  Future<List<List<String>>> _lineages(List<String> cardIds) async {
    final List<List<String>> out = <List<String>>[];
    for (int i = 0; i < cardIds.length; i += 2000) {
      final Object? r = (await _sync2Raw(<String, Object?>{
        'op': 'lineages',
        'cards': cardIds.sublist(i, min(i + 2000, cardIds.length)),
      })).json;
      for (final Object? l in r! as List<Object?>) {
        out.add(<String>[
          for (final Object? id in l! as List<Object?>) id! as String,
        ]);
      }
    }
    return out;
  }

  /// 注册本 profile 的缓存配置（`cache_config_set`，native/fushi_fsrs/src/store/gen4/dispatch.rs）：与库里存的按 JSON
  /// 值比，相同回 `{changed: false}`；变了内核写下并在同一个事务里整层重建派生层，回 `{changed: true, settled}`。
  /// 整层重建不推进本机状态行的修订号（刷新键），所以变了时这里把本对象按刷新键 / 缓存日志记的缓存一并作废。失败照常
  /// 抛出（打开失败），下次打开重来。
  Future<void> _registerCacheConfig() => runExclusive(() async {
    final Map<String, Object?> r = await _sync2(const <String, Object?>{
      'op': 'cache_config_set',
    });
    if (r['changed'] == true) _invalidateDerivedCaches();
  });

  /// 派生层整层重建（`rebuild_caches`，`Settle::Rebuild`）：新代的派生层是真相的纯函数，重建结果与随写入维护的
  /// 相同；用于诊断 / 覆盖恢复之后。重建不推进修订号，本对象记的缓存一并作废。
  Future<void> rebuildCaches() => runExclusive(() async {
    await _sync2(const <String, Object?>{'op': 'rebuild_caches'});
    _invalidateDerivedCaches();
  });

  /// 派生层被整层换过（不经修订号）：本对象按刷新键 / 缓存变更日志记的缓存全部作废。
  void _invalidateDerivedCaches() {
    _resetCacheJournal();
    _deckTreeCache = null;
    _profileEditsCache = null;
  }

  /// 删除时刻不晚于 [deletedBeforeMs] 的已删笔记引用的媒体（过了保留期、可以回收的候选；是否真删由调用方
  /// 再扣掉存活引用）。
  Future<Set<String>> expiredNoteMediaRefs(int deletedBeforeMs) async {
    return _mediaRefs(<String, Object?>{'deletedBefore': deletedBeforeMs});
  }

  /// 本 profile 未删除笔记当前引用的全部媒体文件名（读笔记缓存的 media_refs 列，不解析字段值）。
  ///
  /// [deletedAfterMs] 给出时，删除时刻晚于它的已删笔记也算（媒体保留期，设计 §10.5：被删笔记独占的媒体满
  /// 90 天才清，期间恢复笔记媒体还在）。
  Future<Set<String>> noteMediaRefs({int? deletedAfterMs}) async {
    return _mediaRefs(<String, Object?>{'deletedAfter': ?deletedAfterMs});
  }

  /// 笔记缓存里非空的媒体引用列拆成文件名（`read` 的 `media_refs`）。
  Future<Set<String>> _mediaRefs(Map<String, Object?> query) async {
    final SrsColumns c = await _readTable('media_refs', query);
    final SrsStringColumn refs = c.strings('refs');
    return <String>{for (int i = 0; i < c.rows; i++) ...refs[i].split('\n')};
  }

  /// 一张卡的复习历史：自己的日志 + 全部前身卡（更改笔记类型继承来的）的日志。
  Future<SrsCardHistory> history(String cardId) async {
    return _historyOf((await _lineages(<String>[cardId])).single);
  }

  /// 复习日志的归属：前身卡 → 继承它历史的可见卡（与 [history] 合并前身日志同一条血统规则）。
  ///
  /// 更改笔记类型 / 旧 Lapis 迁到 Fushi 卡片后，日志仍记在前身卡（已没有缓存行）名下；按卡读日志的地方
  /// （统计）要把它们算到继承它们的那张可见卡上，否则那张卡在牌组统计里一条复习都没有。一张前身被
  /// 几张可见卡继承时（极少）归 id 最小的那张，不重复计数。
  Future<Map<String, String>> historyOwnerIndex() async {
    final Map<String, List<String>> successors = await _successorIndex();
    if (successors.isEmpty) return const <String, String>{};
    final Set<String> candidates = <String>{
      for (final List<String> l in successors.values) ...l,
    };
    final List<String> visible = <String>[
      for (final SrsCardCacheRow c in await cardRows(candidates))
        if (!c.hidden) c.id,
    ]..sort();
    final Map<String, String> out = <String, String>{};
    for (int i = 0; i < visible.length; i += _refreshChunk) {
      final List<String> chunk = visible.sublist(
        i,
        min(i + _refreshChunk, visible.length),
      );
      final List<List<String>> lineages = await _lineages(chunk);
      for (int k = 0; k < chunk.length; k++) {
        for (final String id in lineages[k].skip(1)) {
          out.putIfAbsent(id, () => chunk[k]);
        }
      }
    }
    // 前身自己还可见（没被换掉）时它的日志仍归它自己。
    for (final SrsCardCacheRow c in await cardRows(out.keys.toList())) {
      if (!c.hidden) out.remove(c.id);
    }
    return out;
  }

  /// [cardIds] 里各卡此刻继承它历史的可见卡（血统里含它的可见卡，不含它自己；几张时取 id 最小的，与
  /// [historyOwnerIndex] 同一条规则）。没有可见后继的卡不在结果里。只沿 [cardIds] 的后继链接扩，不建全表归属。
  Future<Map<String, String>> visibleHeirsOf(Iterable<String> cardIds) async {
    final Set<String> wanted = cardIds.toSet();
    if (wanted.isEmpty) return const <String, String>{};
    final Map<String, List<String>> successors = await _successorIndex();
    // 链接表是超集，这里只收候选；真正的血统下面按 [_lineages]（修改记录的生效值）判。
    final Set<String> candidates = <String>{};
    final List<String> frontier = wanted.toList();
    while (frontier.isNotEmpty) {
      for (final String next
          in successors[frontier.removeLast()] ?? const <String>[]) {
        if (candidates.add(next)) frontier.add(next);
      }
    }
    if (candidates.isEmpty) return const <String, String>{};
    final List<String> visible = <String>[
      for (final SrsCardCacheRow c in await cardRows(candidates))
        if (!c.hidden) c.id,
    ]..sort();
    final Map<String, String> out = <String, String>{};
    final List<List<String>> lineages = await _lineages(visible);
    for (int k = 0; k < visible.length; k++) {
      for (final String id in lineages[k].skip(1)) {
        if (wanted.contains(id)) out.putIfAbsent(id, () => visible[k]);
      }
    }
    return out;
  }

  /// 一组卡各自的复习历史（同 [history]；按输入顺序去重）。按块预读整条血统的修改记录、日志与
  /// 服务器时刻（每块几次往返），批量重置 / 设置到期 / 撤销 / 立即重排 / 导出 / 优化器取数不再每张卡
  /// 各查四五次（BUG-3543）。
  Future<Map<String, SrsCardHistory>> histories(
    Iterable<String> cardIds,
  ) async {
    final List<String> ids = cardIds.toSet().toList();
    final Map<String, SrsCardHistory> out = <String, SrsCardHistory>{};
    for (int i = 0; i < ids.length; i += _refreshChunk) {
      final List<String> chunk = ids.sublist(
        i,
        min(i + _refreshChunk, ids.length),
      );
      final List<List<String>> lineages = await _lineages(chunk);
      // 整块血统的日志 + 服务器时刻一次预读（每块一两次往返），不逐卡查。
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchLogs(pre, <String>{
        for (final List<String> l in lineages) ...l,
      });
      await _readWith(pre, () async {
        final List<SrsHistoryInput> inputs = <SrsHistoryInput>[
          for (final List<String> l in lineages) await _historyInput(l),
        ];
        // 整块一次 FFI 调用（卡片历史内核），不逐卡跨边界。
        final List<SrsCardHistory> hs = SrsCardHistory.many(inputs);
        for (int k = 0; k < chunk.length; k++) {
          out[chunk[k]] = hs[k];
        }
      });
    }
    return out;
  }

  // ------------------------------------------------------------------ P6 直读命令（统计 / 优化器 / RWKV）
  //
  // 日志不经 Dart：Rust 在 srs.db 的读连接上一个读事务里直读日志与服务器时刻、选取、投影，只回结果列
  // （docs/specs/2026-10-23-srs-rust-store.md §7）。只交卡 id：血统也由内核在同一个快照里解析
  // （store/projections.rs `expand_lineages`）。命令在常驻后台 isolate 执行，UI isolate 不做同步 FFI 读库。

  /// 每张卡自成一份历史的输入（内核补齐前身）。
  static List<List<String>> _seedGroups(List<String> cardIds) => <List<String>>[
    for (final String id in cardIds) <String>[id],
  ];

  /// 优化器训练集：[cardIds] 这些卡（按给定顺序）的有效评分（[srsPrepareOptimization] 的规则在 Rust）。
  Future<SrsTrainingSet> optimizerTrainingSet(
    List<String> cardIds, {
    required SrsAlgorithm algorithm,
    required SrsDayContext day,
  }) async {
    if (cardIds.isEmpty) return SrsTrainingSet.empty();
    final List<int> numeric = SrsIds.ankiNumericIds(cardIds);
    return SrsTrainingSet(
      await _coreOptimizerItems(
        core.address,
        core.libraryPath,
        profileUid,
        _seedGroups(cardIds),
        numeric,
        srsProjectionAlgorithmCode(algorithm),
        day.utcOffsetMin,
        day.rolloverHour,
      ),
    );
  }

  /// 复习统计页校准图的训练集（[optimizerTrainingSet] 同一份，外加每个条目的时刻 / 日志数字 ID / 间隔天数 /
  /// 卡数字 id / 记住）。
  Future<SrsCalibrationItems> calibrationItems(
    List<String> cardIds, {
    required SrsAlgorithm algorithm,
    required SrsDayContext day,
  }) async {
    if (cardIds.isEmpty) return SrsCalibrationItems(Uint8List(32));
    return SrsCalibrationItems(
      await _coreCalibrationItems(
        core.address,
        core.libraryPath,
        profileUid,
        _seedGroups(cardIds),
        SrsIds.ankiNumericIds(cardIds),
        srsProjectionAlgorithmCode(algorithm),
        day.utcOffsetMin,
        day.rolloverHour,
      ),
    );
  }

  /// RWKV 逐卡：每张卡（[ids] 每卡 4 个数字 id：卡 / 笔记 / 牌组 / 预设）的保留评分行与摘要。
  Future<List<SrsRwkvCardRows>> rwkvCardRows(
    List<String> cardIds,
    List<int> ids,
    SrsDayContext day,
  ) async {
    if (cardIds.isEmpty) return const <SrsRwkvCardRows>[];
    return srsDecodeRwkvCards(
      await _coreRwkvCards(
        core.address,
        core.libraryPath,
        profileUid,
        _seedGroups(cardIds),
        ids,
        day.utcOffsetMin,
        day.rolloverHour,
      ),
    );
  }

  /// RWKV 全量回放：[cardIds]（回放的加入顺序）的保留评分行按评分时刻排好序，连同同一快照里的日志指纹；
  /// [since] 之后出现、不在这些卡血统里的卡作为 [SrsRwkvReplay.strays] 返回。
  ///
  /// [rebaseSince]：局部重放——同一快照里算出 rowid 在它之后的日志让回放序列最早从哪个时刻起不同
  /// （[SrsRwkvReplay.divergeAt]），行只取从 [rowsFrom]（给了的话）或分歧时刻起的。
  Future<SrsRwkvReplay> rwkvReplay(
    List<String> cardIds,
    List<int> ids,
    SrsDayContext day, {
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) async => srsDecodeRwkvReplay(
    await rwkvReplayBytes(
      cardIds,
      ids,
      day,
      since: since,
      rebaseSince: rebaseSince,
      rowsFrom: rowsFrom,
    ),
  );

  /// [rwkvReplay] 未解码的字节（[srsDecodeRwkvReplay] 的布局）：RWKV 排程内核原样收下，不在 Dart 里解码。
  Future<Uint8List> rwkvReplayBytes(
    List<String> cardIds,
    List<int> ids,
    SrsDayContext day, {
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) async {
    // 收段会话期间不扫：等会话结束（[sync2IngestBegin] 反过来等在途的回放）。
    await sync2IngestSettled();
    _rwkvReplaysInFlight++;
    _rwkvReplaysIdle ??= Completer<void>();
    try {
      return (await _coreRwkvReplay(
        core.address,
        core.libraryPath,
        profileUid,
        _seedGroups(cardIds),
        ids,
        day.utcOffsetMin,
        day.rolloverHour,
        since,
        rebaseSince,
        rowsFrom,
      )).materialize().asUint8List();
    } finally {
      if (--_rwkvReplaysInFlight == 0) {
        _rwkvReplaysIdle?.complete();
        _rwkvReplaysIdle = null;
      }
    }
  }

  /// RWKV 对齐：本 profile 日志的指纹与 rowid 在 [since] 之后的行数（同一个快照），[withRows] 时连同这些行。
  Future<SrsRwkvLogTail> rwkvLogTail({
    required int since,
    bool withRows = false,
    bool incremental = false,
  }) async => srsDecodeRwkvLogTail(
    await _coreRwkvLogTail(
      core.address,
      core.libraryPath,
      profileUid,
      since,
      withRows,
      incremental,
    ),
  );

  Future<SrsCardHistory> _historyOf(List<String> cardIds) async {
    final (List<SrsReviewLog> logs, int? Function(String)? s) =
        await _historyInput(cardIds);
    return SrsCardHistory(logs, serverTimeOf: s);
  }

  /// 一组卡（一张卡的血统）的全部日志与服务器时刻：[SrsCardHistory] 的输入。
  Future<SrsHistoryInput> _historyInput(List<String> cardIds) async {
    _RefreshPrefetch? pre = _RefreshPrefetch.current;
    if (pre == null || !cardIds.every(pre.logsByCard.containsKey)) {
      // 没预读：这几张卡的日志与服务器时刻一条读命令取回（同 [_prefetchLogs]）。
      pre = _RefreshPrefetch();
      await _prefetchLogs(pre, cardIds);
    }
    final _RefreshPrefetch p = pre;
    final List<SrsReviewLog> logs = <SrsReviewLog>[
      for (final String c in cardIds)
        for (final String json in p.logsByCard[c]!)
          SrsReviewLog.fromJson(
            (jsonDecode(json) as Map).cast<String, Object?>(),
          ),
    ];
    return (
      logs,
      (String id) => p.serverTimesKnown.contains(id) ? p.serverTimes[id] : null,
    );
  }

  // ------------------------------------------------------------------ 修改记录

  /// 改一个字段（no-op 不产生记录）。
  Future<SrsFieldEdit?> editField(
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value, {
    bool machine = false,
  }) async {
    final List<SrsFieldEdit>? out = await editFields(
      kind,
      entityId,
      <String, Object?>{key: value},
      machine: machine,
    );
    return out == null || out.isEmpty ? null : out.single;
  }

  /// 同一实体的多个字段一次写（同一个事务；例如 algorithm 与参数组「同一次修改」）。
  Future<List<SrsFieldEdit>?> editFields(
    SrsEntityKind kind,
    String entityId,
    Map<String, Object?> values, {
    bool machine = false,
  }) => runExclusive(() async {
    if (values.isEmpty) return const <SrsFieldEdit>[];
    // 值没变的键由内核在落库的那一笔里筛掉（[SrsEditDraft.ifChanged]）：这里不预读现值。
    return _emit(<SrsEditDraft>[
      for (final MapEntry<String, Object?> e in values.entries)
        SrsEditDraft(
          kind,
          entityId,
          e.key,
          e.value,
          machine: machine,
          ifChanged: true,
        ),
    ], stamps: true);
  });

  /// 一组候选写入 `(现值, 键, 新值, 草稿)` 里会改变现值的那些的草稿（值没变且无冲突的键不产生记录；
  /// 现值为 null = 实体还没有记录，全都要写）。要比较值的整批一次 FFI 调用（「值相同」只在字段寄存器
  /// 内核里算）。
  static List<T> _changing<T>(List<(SrsEntityEdits?, String, Object?, T)> c) {
    final List<bool> noop = srsEditsAreNoop(<(SrsRegister?, Object?)>[
      for (final (SrsEntityEdits? cur, String key, Object? value, T _) in c)
        (cur?[key], value),
    ]);
    return <T>[
      for (int i = 0; i < c.length; i++)
        if (!noop[i]) c[i].$4,
    ];
  }

  /// 一次写多个实体的修改记录（可带新身份记录），同一个事务、同一次缓存刷新。
  /// 值没变且无冲突的键不产生记录（与 [editFields] 同一规则）：内核在落库的那一笔里读现值判
  /// （[SrsEditDraft.ifChanged]），序号紧接着分配——这里不预读（以前按实体分块预读一遍全部修改记录原文，
  /// 再早是每个实体各查两次库，BUG-3543）。
  Future<List<SrsFieldEdit>> writeEdits(
    List<SrsEditSpec> specs, {
    List<SrsEntityRecord> records = const <SrsEntityRecord>[],
    void Function(List<String> landed)? onRecords,
  }) => runExclusive(() async {
    final List<SrsEventDraft> drafts = <SrsEventDraft>[
      for (final SrsEntityRecord r in records) SrsReadyDraft(SrsEntityEvent(r)),
      for (final SrsEditSpec spec in specs)
        SrsEditDraft(
          spec.kind,
          spec.entityId,
          spec.key,
          spec.value,
          ifChanged: true,
        ),
    ];
    if (drafts.isEmpty) return const <SrsFieldEdit>[];
    return _emit(
      drafts,
      stamps: true,
      onEntities: onRecords == null
          ? null
          : (List<String?> e) => onRecords(<String>[
              for (int i = 0; i < records.length; i++) _landedEntity(e, i),
            ]),
    );
  });

  /// [srsEntityWritesByInput] 的第 [at] 项：身份记录草稿必定落一条（已有的实体也照样追加），缺了是内核与 Dart 对不上。
  static String _landedEntity(List<String?> entities, int at) =>
      entities[at] ??
      (throw StateError(
        'srs: the `apply` reply has no entityWrites item for input $at '
        '(the native core and Dart do not match)',
      ));

  /// 一次结构性改动（更改笔记类型、删除重复模板、旧 Lapis 迁移）：还原点 [checkpoint] + 一批修改记录 [specs]
  /// （no-op 规则同 [writeEdits]，同样由内核在这一笔里判）+ 可选的移牌组 [moveNotes]，内核 `change` **一条命令、一笔**
  /// （native/fushi_fsrs/src/store/sync2/change.rs）：任何一段失败整次改动都不落库。
  ///
  /// [moveNotes]：这批修改记录落库、缓存刷新（换了类型的笔记的新卡在这时生成）之后，把这些笔记的首选牌组与它们
  /// 此刻可见的卡都移到 `deckId`，已经在那里的不写。换完类型之后有哪些可见卡只有内核的缓存推导知道，所以这一段
  /// 在内核里做，Dart 不再读回缓存行。
  ///
  /// [debugFailAfter] 只给测试用：让内核在做完 `apply`（还原点 + 修改记录）或 `move`（移牌组）那一段之后报错。
  Future<void> writeChange(
    List<SrsEditSpec> specs, {
    ({String name, String reason})? checkpoint,
    ({String deckId, List<String> noteIds})? moveNotes,
    String? debugFailAfter,
  }) async {
    await _change(
      specs,
      checkpoint: checkpoint,
      moveNotes: moveNotes,
      debugFailAfter: debugFailAfter,
    );
  }

  /// 一批笔记换笔记类型 / 补迁，**由内核逐条笔记读现值、算、写**（`change` 的换类型段，
  /// native/fushi_fsrs/src/store/gen4/cmd/writes_retype.rs）：Dart 只给类型层面的计划 [plan]，不物化这批笔记、不攒逐条
  /// 的修改记录——整批物化 + 整批修改记录在大牌组上把 Dart 堆撑爆（BUG-5176）。还原点、移牌组、注入失败同
  /// [writeChange]，整次一条命令、一笔。返回 (换了类型的笔记数, 补了至少一个字段的笔记数)。
  Future<({int retyped, int filled})> writeRetype(
    SrsRetypePlan plan, {
    ({String name, String reason})? checkpoint,
    ({String deckId, List<String> noteIds})? moveNotes,
    String? debugFailAfter,
  }) async {
    final Map<String, Object?> r = await _change(
      const <SrsEditSpec>[],
      checkpoint: checkpoint,
      retype: plan,
      moveNotes: moveNotes,
      debugFailAfter: debugFailAfter,
    );
    return (
      retyped: (r['retyped'] as int?) ?? 0,
      filled: (r['filled'] as int?) ?? 0,
    );
  }

  Future<Map<String, Object?>> _change(
    List<SrsEditSpec> specs, {
    ({String name, String reason})? checkpoint,
    SrsRetypePlan? retype,
    ({String deckId, List<String> noteIds})? moveNotes,
    String? debugFailAfter,
  }) => runExclusive(() async {
    // 值没变的由内核在这条命令的那一笔里筛掉（[SrsEditDraft.ifChanged]），不预读现值。
    final List<SrsEventDraft> drafts = <SrsEventDraft>[
      for (final SrsEditSpec spec in specs)
        SrsEditDraft(
          spec.kind,
          spec.entityId,
          spec.key,
          spec.value,
          ifChanged: true,
        ),
    ];
    if (drafts.isEmpty &&
        checkpoint == null &&
        retype == null &&
        moveNotes == null) {
      return const <String, Object?>{};
    }
    // 走一步用的「此刻」与修改记录的时间来源：落库前这一刻取（同 [_emit]）。
    final (int tickNow, SrsTimeSource source) = now();
    final List<Map<String, Object?>> input = await _applyInput(
      drafts,
      receive: false,
      source: source,
    );
    Map<String, Object?> reply = const <String, Object?>{};
    await _commandOrReload(() async {
      final Map<String, Object?> r = await _sync2(
        <String, Object?>{
          'op': 'change',
          'now': now().$1,
          'legacyDevice': deviceId,
          'tickNow': tickNow,
          'ts': source.wire,
          if (checkpoint != null)
            'checkpoint': <String, Object?>{
              'name': checkpoint.name,
              'reason': checkpoint.reason,
            },
          if (retype != null) 'retype': retype.toJson(),
          if (moveNotes != null)
            'move': <String, Object?>{
              'deck': moveNotes.deckId,
              'notes': moveNotes.noteIds,
            },
          'failAfter': ?debugFailAfter,
          'anchor': ?_anchorArg(),
        },
        blobs: <Uint8List>[utf8.encode(jsonEncode(input))],
      );
      _absorbLocalWrite(r);
      reply = r;
    });
    return reply;
  });

  /// 一条本机写意图命令（内核自己读现值、自己判、自己写）：一个独占区、一条命令——命令本体、缓存刷新、本机状态行
  /// 在内核的同一笔里（native/fushi_fsrs/src/store/gen4/dispatch.rs `local_write`）。旧版 HLC 时钟每条写入走一步，用这一刻的
  /// 「此刻」。
  Future<Map<String, Object?>> _intentWrite(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => runExclusive(() async {
    late Map<String, Object?> r;
    await _commandOrReload(() async {
      final (int tickNow, SrsTimeSource source) = now();
      r = await _sync2(<String, Object?>{
        ...request,
        'now': now().$1,
        'legacyDevice': deviceId,
        'tickNow': tickNow,
        'ts': source.wire,
        'anchor': ?_anchorArg(),
      }, blobs: blobs);
      _absorbLocalWrite(r);
    });
    return r;
  });

  /// 条件写笔记字段（compare-and-set；批量改字段的落计划与撤销，srs_note_batch_edit.dart）：每项的字段现值仍是
  /// `expect` 才写成 `value`。比对与写入是内核的一条命令（`note_fields_if`）、一笔：现值在写锁里读，比对与写入之间
  /// 插不进别的写入。值没变的不产生记录（同 [editFieldsBatch]）。返回被拒的笔记。
  ///
  /// - [wholeNote]（落计划）：笔记不存在 / 已删除 / 它名下任一项对不上 → 整条笔记一项都不写（同一笔记的几个字段要么
  ///   一起写、要么都不写）；
  /// - 否则（撤销）：笔记不存在 / 已删除 → 它的项都不写；其余逐项，对不上的那一项不写、别的照写。
  ///
  /// `expect` 按笔记视图的字段值比（[SrsNoteView.field]：落库表示，没有这个字段 = 空串）。
  Future<Set<String>> editNoteFieldsIf(
    List<SrsNoteFieldWrite> writes, {
    required bool wholeNote,
  }) async {
    if (writes.isEmpty) return const <String>{};
    final List<Map<String, Object?>> items = <Map<String, Object?>>[
      for (final SrsNoteFieldWrite w in writes)
        <String, Object?>{
          'n': w.noteId,
          'f': w.fieldId,
          'x': w.expect,
          'v': switch (_compactValue(
            SrsEntityKind.note,
            SrsFieldKeys.noteField(w.fieldId),
            w.value,
          )) {
            final Future<Object?> f => await f,
            final Object? v => v,
          },
        },
    ];
    final Map<String, Object?> r = await _intentWrite(
      <String, Object?>{
        'op': 'note_fields_if',
        'mode': wholeNote ? 'note' : 'field',
      },
      blobs: <Uint8List>[utf8.encode(jsonEncode(items))],
    );
    // 在 [undoable] 里：把这条命令写下的修改记进撤销凭据。改前值不必再从库读——内核只写现值 == `expect` 的项，
    // 写下的键的改前值就是它的 `expect`（同一个键出现几次时各项的 `expect` 相同，否则过不了比对）。
    if (_undoRecorder case final _SrsUndoRecorder recorder) {
      final List<Object?> edits =
          (r['edits'] as List<Object?>?) ?? const <Object?>[];
      recorder.noteKnownBefore(<(SrsEntityKind, String, String), Object?>{
        for (final SrsNoteFieldWrite w in writes)
          (SrsEntityKind.note, w.noteId, SrsFieldKeys.noteField(w.fieldId)):
              w.expect,
      }, edits);
      recorder.noteWritten(edits);
    }
    return <String>{...(r['rejected']! as List).cast<String>()};
  }

  /// [editNoteFieldsIf] 的落计划模式（整条笔记），并交回这次写入的撤销凭据（[revertEdits]）。返回被拒的笔记与凭据。
  Future<(Set<String>, SrsEditUndo)> editNoteFieldsIfUndoable(
    List<SrsNoteFieldWrite> writes,
  ) => undoable(() => editNoteFieldsIf(writes, wholeNote: true));

  /// 把 [absorbIds] 并进 [keepId]（重复笔记的合并，规则见 srs_duplicate_notes.dart 的库注释）：还原点、前身链接、
  /// 补空字段 / 并标签、删除被吸收的笔记是内核的一条命令（`merge_notes`）、一笔——笔记与卡在写锁里读，任何一步出错
  /// 整次合并都不落库。返回挂成前身的卡数与保留笔记没有对应模板的卡数。笔记不存在、笔记类型不同时抛 [StateError]
  /// （文案里带 `not found` / `different note types`）。
  Future<({int linked, int unmatched})> mergeNotesInto(
    String keepId,
    List<String> absorbIds,
  ) {
    final _SrsUndoRecorder? recorder = _undoRecorder;
    if (recorder == null) return _mergeNotesCommand(keepId, absorbIds);
    // 在 [undoable] 里：内核自己读现值、自己判、自己写，录制器要的改前值在发命令之前、同一个独占区里读——可能被
    // 写到的键（保留笔记上被吸收笔记带着的字段与标签、保留卡上指向被吸收卡的前身链接、被吸收笔记的删除标记），
    // 实际写了哪些以命令回包的 `edits` 为准。整列表标签内核不报 dot（展开成了 OR-Set 操作），按合并前后的差量记。
    return runExclusive(() async {
      final Map<String, SrsNoteView?> views = await notes(<String>{
        keepId,
        ...absorbIds,
      });
      final List<SrsCardCacheRow> keepCards = await cardsOfNote(keepId);
      final List<(SrsEntityKind, String, String)> keys =
          <(SrsEntityKind, String, String)>[
            (SrsEntityKind.note, keepId, SrsFieldKeys.noteTags),
          ];
      final Set<String> fields = <String>{};
      for (final String id in absorbIds) {
        if (id == keepId) continue;
        keys.add((SrsEntityKind.note, id, SrsFieldKeys.deleted));
        for (final String f
            in views[id]?.fields.keys ?? const Iterable<String>.empty()) {
          if (fields.add(f)) {
            keys.add((SrsEntityKind.note, keepId, SrsFieldKeys.noteField(f)));
          }
        }
        for (final SrsCardCacheRow absorbed in await cardsOfNote(id)) {
          for (final SrsCardCacheRow kept in keepCards) {
            keys.add((
              SrsEntityKind.card,
              kept.id,
              SrsFieldKeys.cardHistoryFrom(absorbed.id),
            ));
          }
        }
      }
      await recorder.noteBefore(keys);
      final ({int linked, int unmatched}) out = await _mergeNotesCommand(
        keepId,
        absorbIds,
        onEdits: recorder.noteWritten,
      );
      final SrsNoteView? after = (await notes(<String>{keepId}))[keepId];
      final List<String> tagsBefore = views[keepId]?.tags ?? const <String>[];
      if (after != null &&
          (after.tags.length != tagsBefore.length ||
              !after.tags.toSet().containsAll(tagsBefore))) {
        recorder.noteTags(keepId, after.tags);
      }
      return out;
    });
  }

  /// [mergeNotesInto] 的那一条内核命令。[onEdits] 收回包里写下的字段修改（`edits`，见 [_SrsUndoRecorder.noteWritten]）。
  Future<({int linked, int unmatched})> _mergeNotesCommand(
    String keepId,
    List<String> absorbIds, {
    void Function(List<Object?> edits)? onEdits,
  }) async {
    late Map<String, Object?> r;
    try {
      r = await _intentWrite(<String, Object?>{
        'op': 'merge_notes',
        'keep': keepId,
        'absorb': absorbIds,
        'deletedAt': now().$1,
      });
    } on SrsCoreException catch (e) {
      // 调用方（冲突页、控制通道）按 StateError 的文案区分「笔记不存在」。
      if (e.message.contains('merge_notes: note') ||
          e.message.contains('different note types')) {
        throw StateError(e.message.replaceFirst('merge_notes: ', ''));
      }
      rethrow;
    }
    onEdits?.call((r['edits'] as List<Object?>?) ?? const <Object?>[]);
    return (linked: r['linked']! as int, unmatched: r['unmatched']! as int);
  }

  // ------------------------------------------------------------------ 牌组

  /// 按名字 [name] 在 [parentId] 下（null = 顶层）新建或复活牌组时用的 ID（[createDeck] 与
  /// Anki 导入共用）。先取「父::子」全名确定性派生的牌组 ID（[SrsKernelIds.deck]）：多台设备离线各建同名牌组
  /// 落在同一个 ID 上。
  ///
  /// 「同名」按牌组此刻的名字与父牌组认，不按 ID：牌组改过名或挪过父牌组后 ID 不变，按它原来
  /// 的全名再新建时派生 ID 落在它身上——那不是同一个牌组，沿用就会把它改名 / 拽回原处（BUG：
  /// 拖放挪走 A 后再按「A」建牌组，挪走的那个被拽回顶层）。这时依次试 [SrsKernelIds.deckAlternate]
  /// 的备选 ID，取第一个没被用过的、或名字与父牌组都一致（可沿用 / 复活）的。只由本机牌组状态
  /// 决定：看到同样牌组状态的设备（含收下了挪动 / 改名记录的其它设备）得到同一个 ID。
  Future<String> deckIdForNew(String name, {String? parentId}) async {
    final SrsDeckTree tree = await deckTree();
    final String parentPath = parentId == null || tree[parentId] == null
        ? ''
        : '${tree.fullName(parentId)}::';
    final String fullPath = '$parentPath$name';
    final String trimmed = name.trim();
    String id = kernelIds.deck(fullPath);
    for (int n = 1; ; n++) {
      final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
      if (current.keys.isEmpty ||
          (current.value(SrsFieldKeys.name) == trimmed &&
              current.value(SrsFieldKeys.deckParent) == parentId)) {
        return id;
      }
      id = kernelIds.deckAlternate(fullPath, n);
    }
  }

  /// 新建牌组，ID 见 [deckIdForNew]；名字与父牌组都一致的牌组已存在（含已删除的）时复活并沿用它。
  /// 身份记录不含本机时刻（createdAt = 0），同 ID 同内容。
  Future<String> createDeck(
    String name, {
    String? parentId,
  }) => runExclusive(() async {
    final String trimmed = name.trim();
    final String id = await deckIdForNew(name, parentId: parentId);
    final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
    // 返回内核落下的规范 ID（回包 `entityWrites`；身份记录是第一条草稿）。
    String landed = id;
    // 身份记录与名字 / 父牌组记录同一个事务落库（以前分两次事务、两次缓存刷新）。
    final List<SrsEventDraft> drafts = <SrsEventDraft>[
      SrsReadyDraft(
        SrsEntityEvent(
          SrsEntityRecord(
            id: id,
            profileUid: profileUid,
            kind: SrsEntityKind.deck,
            payload: const <String, Object?>{'createdAt': 0},
          ),
        ),
      ),
      ...newEditDrafts(SrsEntityKind.deck, id, <String, Object?>{
        SrsFieldKeys.name: trimmed,
        if (parentId != null) SrsFieldKeys.deckParent: parentId,
        if (current.deletedAt != null) SrsFieldKeys.deleted: null,
        // 新建牌组的 RWKV 排队设置初值（[SrsRwkvQueueSettings.forNewDeck]：复习上限当停止点、每天
        // 最少复习 40）。只在牌组从没写过这一项时写——复活的旧牌组保留原值。
        if (current[SrsFieldKeys.deckRwkvQueue] == null)
          SrsFieldKeys.deckRwkvQueue: SrsRwkvQueueSettings.forNewDeck.toValue(),
        // 每日上限单位明写缺省的作答次数：没写过单位的只剩加这项设置之前的存量牌组，牌组页只提醒它们
        // （[SrsDeckView.limitUnitSet]）。同样只在从没写过时写。
        if (current[SrsFieldKeys.deckLimitUnit] == null)
          SrsFieldKeys.deckLimitUnit: SrsLimitUnit.reviews.wire,
      }, current: current),
    ];
    await _emit(
      drafts,
      onEntities: (List<String?> e) => landed = _landedEntity(e, 0),
    );
    return landed;
  });

  /// 按「父::子」全名找或建牌组（AnkiConnect createDeck / 导入用）。
  Future<String> ensureDeckPath(String fullName) async {
    final List<String> parts = fullName
        .split('::')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return defaultDeckId;
    String? parent;
    for (final String part in parts) {
      final SrsDeckTree tree = await deckTree();
      String? found;
      for (final SrsDeckView d in tree.decks) {
        if (d.name == part && tree.parentOf(d.id) == parent) {
          found = d.id;
          break;
        }
      }
      parent = found ?? await createDeck(part, parentId: parent);
    }
    return parent!;
  }

  /// 删牌组每步处理的实体数（笔记 + 卡；一步一个独占区、一条内核命令）。
  static const int _deleteDeckChunk = 500;

  /// 删牌组（连同全部子牌组）：子树里的卡移到被删牌组的父牌组（没有父牌组则到默认牌组），每张卡
  /// 一条修改记录；卡都移完后给子树里每个牌组写删除标记。
  ///
  /// 这里只发意图，找卡、判「值没变的卡不写」、落修改记录都在内核（native/fushi_fsrs/src/store/sync2/deck_delete.rs
  /// `deck_delete`）：先一步只数（有要删的笔记就顺手打还原点，设计 §10.2），再按步（每步 [_deleteDeckChunk] 个实体、
  /// 一个独占区）走，步与步之间别的写入（复习评分、后台导入）照常插进来；卡取完的那一步在同一笔里重读子树、扫一遍
  /// 期间放进来的笔记 / 卡，再写删除标记。记录、顺序都与逐张 `editField` 相同；中途被杀时已提交的步留在库里，
  /// 删除标记在最后，再删一次即补齐。[onProgress] 按实体数报进度。
  ///
  /// [deleteCards] 为真时（Anki「删除牌组」的语义）先删掉只在这个子树里有卡的笔记（进度里笔记数在前），之后照样把
  /// 子树里的卡移走——删掉的笔记的卡已隐藏，移走只是让「恢复笔记」后卡不落在已删除的牌组里。Fushi 只能整条删笔记：
  /// 在子树外还有卡的笔记不删，它在子树里的卡照常移走。
  ///
  /// 返回这次写了删除标记的笔记（[deleteCards] 为假时为空）。删除标记只是墓碑：正文、复习日志、
  /// 媒体留到墓碑过了同步安全期才由 srs_purge.dart 物理清除；从没同步过的副本可以当场清除
  /// （`srsPurgeNotesNow`）。
  Future<List<String>> deleteDeck(
    String deckId, {
    bool deleteCards = false,
    SrsProgress? onProgress,
  }) async {
    if (deckId == defaultDeckId) {
      throw StateError('the default deck cannot be deleted');
    }
    final (int deletedAt, _) = now();
    Map<String, Object?> r = await _deckDeleteStep(<String, Object?>{
      'deck': deckId,
      'deleteCards': deleteCards,
      'plan': true,
    });
    final int total = (r['total']! as num).toInt();
    // 总数先报一次：这之后、第一步之前排进来的写入（往这个牌组加卡、建子牌组）由收尾那一步处理。
    onProgress?.call(0, total);
    final List<String> deletedNotes = <String>[];
    int done = 0;
    Object? token;
    while (r['done'] != true) {
      r = await _deckDeleteStep(<String, Object?>{
        'deck': deckId,
        'deleteCards': deleteCards,
        'limit': _deleteDeckChunk,
        'token': ?token,
        'deletedAt': deletedAt,
      });
      token = r['token'];
      deletedNotes.addAll((r['notes']! as List<Object?>).cast<String>());
      final int n = (r['count']! as num).toInt();
      if (n > 0) {
        done += n;
        onProgress?.call(min(done, total), total);
      }
    }
    // 步与步之间别的写入把卡移出了子树：按游标数到的比开头数的少，进度补到头。
    if (done < total) onProgress?.call(total, total);
    return deletedNotes;
  }

  /// 删牌组的一步（内核 `deck_delete`，见 [deleteDeck]）：一个独占区、一条命令（命令本体、缓存刷新、本机状态行在内核
  /// 的同一笔里）。旧版 HLC 时钟每条写入走一步，用这一步的「此刻」。
  Future<Map<String, Object?>> _deckDeleteStep(Map<String, Object?> args) =>
      runExclusive(() async {
        late Map<String, Object?> r;
        await _commandOrReload(() async {
          final (int tickNow, SrsTimeSource source) = now();
          r = await _sync2(<String, Object?>{
            'op': 'deck_delete',
            ...args,
            'now': now().$1,
            'legacyDevice': deviceId,
            'tickNow': tickNow,
            'ts': source.wire,
            'anchor': ?_anchorArg(),
          });
          _absorbLocalWrite(r);
        });
        return r;
      });

  // ------------------------------------------------------------------ 墓碑物理清除（策略见 srs_purge.dart）

  /// 待回收的媒体文件名：媒体保留期到了 / 彻底清除时收集到、还没回收的。集合在内核里（本机状态行的 `mediaGc`，
  /// 内核持有，native/fushi_fsrs/src/store/media_gc.rs）；持久化是为了被跳过（宽限期内）、被叫停或中途崩溃的名字
  /// 下次接着处理。
  Future<Set<String>> pendingMediaGc() =>
      _mediaGcQueue(const <String, Object?>{});

  /// 把 [names] 加进待回收集合；返回加完之后的集合。
  Future<Set<String>> queueMediaGc(Iterable<String> names) =>
      _mediaGcQueue(<String, Object?>{'names': names.toList()});

  /// 把这些笔记此刻的字段引用的媒体（[notes]：彻底清除之前调，清除会抹掉字段）、删除时刻不晚于 [expiredBeforeMs]
  /// 的已删笔记引用的媒体（保留期到了的候选）加进待回收集合；返回加完之后的集合。引用由内核在同一笔里读、并
  /// （Dart 不先读出来再交回去）。是否真删由 [collectPendingMedia] 再扣掉存活引用。
  Future<Set<String>> queueMediaGcOf({
    Iterable<String>? notes,
    int? expiredBeforeMs,
  }) => _mediaGcQueue(<String, Object?>{
    'notes': ?notes?.toList(),
    'expiredBefore': ?expiredBeforeMs,
  });

  Future<Set<String>> _mediaGcQueue(Map<String, Object?> args) =>
      runExclusive(() async {
        final Map<String, Object?> r = await _sync2(<String, Object?>{
          'op': 'media_gc_queue',
          ...args,
        });
        return <String>{...(r['pending']! as List).cast<String>()};
      });

  /// [collectPendingMedia] 一条命令处理的文件名数：命令全程持着内核写锁做文件 IO，分批让作答等写入插得进来。
  static const int kSrsMediaGcBatch = 200;

  /// 回收待回收集合里此刻没有任何存活引用、且过了宽限期的文件（只删 [mediaRoot] 下的裸文件名），返回删掉的文件数。
  ///
  /// 「核对存活引用 → 删文件 → 移出集合」是内核的一条命令（`media_gc_collect`）：在写锁里、一笔里做完，期间没有
  /// 写入能重新引用某个刚判为无引用的文件（HBK-AUDIT-014）。集合大时分成几条（每条 [kSrsMediaGcBatch] 个名字，
  /// 各自重算存活引用），条与条之间看一次 [shouldStop]。[aliveAfterMs]：删除晚于它的已删笔记仍算存活引用（媒体
  /// 保留期）；[freshAfterMs]：修改时间晚于它的文件不删（刚写 / 刚复用，引用它的笔记可能还没提交）。
  Future<int> collectPendingMedia(
    String mediaRoot, {
    required int aliveAfterMs,
    required int freshAfterMs,
    bool Function()? shouldStop,
  }) async {
    int deleted = 0;
    String? after;
    do {
      final Map<String, Object?> r = await runExclusive(
        () => _sync2(<String, Object?>{
          'op': 'media_gc_collect',
          'root': mediaRoot,
          'aliveAfter': aliveAfterMs,
          'freshAfter': freshAfterMs,
          'after': ?after,
          'limit': kSrsMediaGcBatch,
        }),
      );
      deleted += r['deleted']! as int;
      after = r['next'] as String?;
    } while (after != null && !(shouldStop?.call() ?? false));
    return deleted;
  }

  /// 媒体回收 / 位置清理用的「存活引用」：存活笔记、删除晚于 [aliveAfterMs] 的已删笔记、全部笔记类型（含已删除的：
  /// 可能被恢复）的模板与 CSS 引用的媒体文件名（只留裸文件名）。口径只在内核（store/media_gc.rs `live_refs`），
  /// 回收用的是同一份。只读，不进写锁。
  Future<Set<String>> liveMediaRefs({required int aliveAfterMs}) async {
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      'op': 'media_live_refs',
      'aliveAfter': aliveAfterMs,
    });
    return <String>{...(r['refs']! as List).cast<String>()};
  }

  Future<SrsSchedulingConfig> schedulingConfigFor(String deckId) async =>
      _schedulingConfigIn(await deckTree(), deckId);

  SrsSchedulingConfig _schedulingConfigIn(SrsDeckTree tree, String deckId) {
    final String id = tree.effectiveDeckOf(deckId, fallback: defaultDeckId);
    return tree.schedulingConfig(id, defaultsOf: engine?.defaultParams);
  }

  // ------------------------------------------------------------------ 笔记

  /// 新建笔记（Fushi 新建时随机生成 guid；noteId 由 guid 派生）。
  Future<String> createNote({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    String? guid,
    int? createdAt,
  }) => runExclusive(() async {
    final String g = guid ?? newNoteGuid();
    final String id = kernelIds.note(g);
    String landed = id;
    // 身份记录与字段修改记录同一个事务、同一次缓存刷新（以前分两次落库，笔记先以空字段生成一遍卡）。这条笔记
    // 已经在（同一个 guid 再建）时值没变的键不再写：内核在落库的那一笔里判，不预读它的修改记录。返回内核落下的
    // 规范 ID（回包 `entityWrites`，身份记录是第一条草稿）。
    await _emit(
      onEntities: (List<String?> e) => landed = _landedEntity(e, 0),
      newNoteDrafts(
        noteTypeId: noteTypeId,
        fieldsById: fieldsById,
        deckId: deckId,
        tags: tags,
        source: source,
        guid: g,
        noteId: id,
        createdAt: createdAt,
        ifChanged: true,
      ),
    );
    return landed;
  });

  /// 新笔记的全部事件草稿（身份记录 + 字段 / 标签 / 来源 / 牌组修改记录），**不落库、不占序号**：
  /// 交给 [importDrafts] 与别的事件攒成一批，序号在落库时才分配（Anki 包导入每批几十条笔记一个事务）。
  ///
  /// [current] 是这条笔记已有的修改记录（值相同的键不再写）；null = 调用方确定本机还没有这条笔记
  /// （导入先查过身份记录），跳过逐条读库。[ifChanged] 见 [newEditDrafts]。
  /// noteId = [SrsKernelIds.note]（[noteId] 已算好时传进来，批量导入整块一次 FFI）。
  List<SrsEventDraft> newNoteDrafts({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    required String guid,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    int? createdAt,
    SrsEntityEdits? current,
    bool ifChanged = false,
    String? noteId,
  }) {
    final (int nowMs, _) = now();
    final String id = noteId ?? kernelIds.note(guid);
    return <SrsEventDraft>[
      SrsReadyDraft(
        SrsEntityEvent(
          SrsEntityRecord(
            id: id,
            profileUid: profileUid,
            kind: SrsEntityKind.note,
            payload: <String, Object?>{
              'noteTypeId': noteTypeId,
              'guid': guid,
              'createdAt': createdAt ?? nowMs,
            },
          ),
        ),
      ),
      ...newEditDrafts(
        SrsEntityKind.note,
        id,
        <String, Object?>{
          for (final MapEntry<String, String> f in fieldsById.entries)
            if (f.value.isNotEmpty) SrsFieldKeys.noteField(f.key): f.value,
          if (tags.isNotEmpty) SrsFieldKeys.noteTags: tags,
          if (source != null) SrsFieldKeys.noteSource: source.toJson(),
          SrsFieldKeys.noteDeck: deckId ?? defaultDeckId,
        },
        current: current,
        ifChanged: ifChanged,
      ),
    ];
  }

  /// 一个实体若干字段的本机修改记录草稿，**不落库、不占序号**（交给 [importDrafts] 成批落）。
  /// [current] 同 [newNoteDrafts]：给了就跳过与现值相同的键；null = 实体刚由同一批事件新建、本机没有记录
  /// ——这时草稿标成初值（[SrsEditDraft.initial]），落库时键已有记录的不落。
  ///
  /// [ifChanged]（不与 [current] 同给）：不知道本机有没有这个实体、也不预读——草稿全出，标成「值变了才落」
  /// （[SrsEditDraft.ifChanged]），由内核落库时判。这样的草稿只能交给本机写入（`apply`），不能进
  /// [importDrafts] 的批。
  List<SrsEditDraft> newEditDrafts(
    SrsEntityKind kind,
    String entityId,
    Map<String, Object?> values, {
    SrsEntityEdits? current,
    bool ifChanged = false,
  }) => ifChanged
      ? <SrsEditDraft>[
          for (final MapEntry<String, Object?> e in values.entries)
            SrsEditDraft(kind, entityId, e.key, e.value, ifChanged: true),
        ]
      : current == null
      ? <SrsEditDraft>[
          for (final MapEntry<String, Object?> e in values.entries)
            SrsEditDraft(kind, entityId, e.key, e.value, initial: true),
        ]
      : _changing(<(SrsEntityEdits?, String, Object?, SrsEditDraft)>[
          for (final MapEntry<String, Object?> e in values.entries)
            (
              current,
              e.key,
              e.value,
              SrsEditDraft(kind, entityId, e.key, e.value),
            ),
        ]);

  /// 本 profile 某类实体的全部 ID（只读 ID 列；导入据此一次判断哪些笔记本机已有）。
  Future<Set<String>> entityIds(SrsEntityKind kind) async =>
      (await _entityIdsWhere(kind: kind)).toSet();

  Future<void> updateNote(
    String noteId, {
    Map<String, String>? fieldsById,
    List<String>? tags,
  }) async {
    await editFields(SrsEntityKind.note, noteId, <String, Object?>{
      if (fieldsById != null)
        for (final MapEntry<String, String> f in fieldsById.entries)
          SrsFieldKeys.noteField(f.key): f.value,
      if (tags != null) SrsFieldKeys.noteTags: tags,
    });
  }

  Future<void> deleteNote(String noteId) => runExclusive(() async {
    final (int nowMs, _) = now();
    await editField(SrsEntityKind.note, noteId, SrsFieldKeys.deleted, nowMs);
  });

  /// 恢复（「删除与并发修改」待裁决项里的「恢复」也走这里）。
  Future<void> restoreNote(String noteId) =>
      editField(SrsEntityKind.note, noteId, SrsFieldKeys.deleted, null);

  /// 按 guid 找已存在的笔记（导入去重）。
  Future<String?> noteIdByGuid(String guid) async {
    final String id = kernelIds.note(guid);
    return (await _entityIdsWhere(ids: <String>[id])).firstOrNull;
  }

  // ------------------------------------------------------------------ 卡片标志

  Future<void> setSuspended(String cardId, bool value) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.suspended, value);

  Future<void> buryUntil(String cardId, int? dayIndex) => editField(
    SrsEntityKind.card,
    cardId,
    SrsFieldKeys.buriedUntilDay,
    dayIndex,
  );

  Future<void> setFlag(String cardId, int flag) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.flag, flag);

  Future<void> moveCard(String cardId, String deckId) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.cardDeck, deckId);

  // ------------------------------------------------------------------ 批量（浏览页）

  /// 多个实体的多个字段一次写：一个事务、一次发件箱批次（浏览页的批量操作）。
  /// no-op 不产生记录（内核在落库的那一笔里判，[SrsEditDraft.ifChanged]；不预读现值）；返回实际写出的修改记录。
  /// 同一个（实体, 键）给了多次的以最后一次为准、排在它第一次出现的位置。
  Future<List<SrsFieldEdit>> editFieldsBatch(List<SrsFieldChange> changes) =>
      runExclusive(() async {
        final Map<(SrsEntityKind, String), Map<String, Object?>> byEntity =
            <(SrsEntityKind, String), Map<String, Object?>>{};
        for (final SrsFieldChange c in changes) {
          (byEntity[(c.kind, c.entityId)] ??= <String, Object?>{})[c.key] =
              c.value;
        }
        final List<SrsEditDraft> drafts = <SrsEditDraft>[
          for (final MapEntry<(SrsEntityKind, String), Map<String, Object?>> e
              in byEntity.entries)
            for (final MapEntry<String, Object?> v in e.value.entries)
              SrsEditDraft(e.key.$1, e.key.$2, v.key, v.value, ifChanged: true),
        ];
        if (drafts.isEmpty) return const <SrsFieldEdit>[];
        return _emit(drafts, stamps: true);
      });

  // ------------------------------------------------------------------ 编辑类撤销（srs_edit_undo.dart）

  /// [undoable] 的 Zone 键：值是本副本正在记的 [_SrsUndoRecorder]。
  final Object _undoZoneKey = Object();

  _SrsUndoRecorder? get _undoRecorder {
    final Object? r = Zone.current[_undoZoneKey];
    return r is _SrsUndoRecorder && identical(r.store, this) ? r : null;
  }

  /// 在写锁里跑 [body]，把其间本机写下的字段修改记成一份撤销凭据（语义见 srs_edit_undo.dart）：每个被改的键记
  /// 写锁里从库读的改前值、改后值与内核分配的 dot。嵌套时内层记下的也并进外层。
  Future<(T, SrsEditUndo)> undoable<T>(Future<T> Function() body) =>
      runExclusive(() async {
        final _SrsUndoRecorder? outer = _undoRecorder;
        final _SrsUndoRecorder recorder = _SrsUndoRecorder(this);
        final T out = await runZoned(
          body,
          zoneValues: <Object?, Object?>{_undoZoneKey: recorder},
        );
        final SrsEditUndo undo = recorder.result();
        outer?.absorb(undo);
        return (out, undo);
      });

  /// [editFieldsBatch]，并交回撤销凭据（复习页 / 浏览页的暂停、搁置、旗标、移牌组、改字段、标签、删除）。
  Future<SrsEditUndo> editFieldsUndoable(List<SrsFieldChange> changes) async =>
      (await undoable(() => editFieldsBatch(changes))).$2;

  /// 按凭据撤销（语义见 srs_edit_undo.dart）：内核按修改记录裁决每个键（`undo_check`，只读），裁决可撤的写回改前
  /// 值（普通本机写入），被别人动过的保留现值、列进 [SrsEditUndoResult.kept]。裁决与写回在同一个写锁独占区里，
  /// 中间插不进别的写入（本机写、收段投递）。
  Future<SrsEditUndoResult> revertEdits(SrsEditUndo undo) => runExclusive(
    () async {
      if (undo.isEmpty) return SrsEditUndoResult.none;
      final List<SrsEditUndoItem> checked = <SrsEditUndoItem>[
        for (final SrsEditUndoItem i in undo.items)
          if (!i.isTags) i,
      ];
      final List<SrsEditUndoItem> tags = <SrsEditUndoItem>[
        for (final SrsEditUndoItem i in undo.items)
          if (i.isTags) i,
      ];
      final List<SrsFieldChange> writes = <SrsFieldChange>[];
      final List<SrsEditUndoKept> kept = <SrsEditUndoKept>[];
      int reverted = 0;
      if (checked.isNotEmpty) {
        final Map<String, Object?> r = await _sync2(<String, Object?>{
          'op': 'undo_check',
          'items': <Map<String, Object?>>[
            for (final SrsEditUndoItem i in checked)
              <String, Object?>{
                'k': i.kind.wire,
                'e': i.entityId,
                'f': i.key,
                'w': ?i.writer,
                's': ?i.seq,
                'v': i.after,
              },
          ],
        });
        final List<Object?> verdicts = r['r']! as List<Object?>;
        for (int n = 0; n < checked.length; n++) {
          final SrsEditUndoItem i = checked[n];
          final Map<Object?, Object?> v = verdicts[n]! as Map<Object?, Object?>;
          if (v['ok'] == true) {
            writes.add(SrsFieldChange(i.kind, i.entityId, i.key, i.before));
            reverted++;
          } else {
            kept.add(
              SrsEditUndoKept(
                kind: i.kind,
                entityId: i.entityId,
                key: i.key,
                current: v['cur'],
              ),
            );
          }
        }
      }
      if (tags.isNotEmpty) {
        final Map<String, SrsNoteView?> views = await notes(<String>{
          for (final SrsEditUndoItem i in tags) i.entityId,
        });
        for (final SrsEditUndoItem i in tags) {
          final SrsNoteView? n = views[i.entityId];
          if (n == null) {
            kept.add(
              SrsEditUndoKept(
                kind: i.kind,
                entityId: i.entityId,
                key: i.key,
                current: null,
              ),
            );
            continue;
          }
          final List<String> next = srsRevertTagDelta(
            current: n.tags,
            before: _stringList(i.before),
            after: _stringList(i.after),
          );
          if (next.join('\u0001') != n.tags.join('\u0001')) {
            writes.add(
              SrsFieldChange(
                SrsEntityKind.note,
                i.entityId,
                SrsFieldKeys.noteTags,
                next,
              ),
            );
          }
          reverted++;
        }
      }
      if (writes.isNotEmpty) await editFieldsBatch(writes);
      return SrsEditUndoResult(reverted: reverted, kept: kept);
    },
  );

  static List<String> _stringList(Object? raw) => <String>[
    if (raw is List)
      for (final Object? x in raw)
        if (x is String) x,
  ];

  /// 一组字段键此刻的生效值（[undoable] 记改前值用；调用方在独占区里）。卡片的四个标志 / 牌组按缓存行（含血统
  /// 继承，与界面看到的一致），笔记的字段 / 标签 / 删除按物化视图，其余按修改记录寄存器。键为 `<kind>/<id>/<key>`。
  Future<Map<String, Object?>> _currentValues(
    List<(SrsEntityKind, String, String)> keys,
  ) async {
    final Map<String, SrsCardCacheRow> cards = <String, SrsCardCacheRow>{
      for (final SrsCardCacheRow r in await cardRows(<String>{
        for (final (SrsEntityKind k, String id, String _) in keys)
          if (k == SrsEntityKind.card) id,
      }))
        r.id: r,
    };
    final Set<String> noteIds = <String>{
      for (final (SrsEntityKind k, String id, String _) in keys)
        if (k == SrsEntityKind.note) id,
    };
    final Map<String, SrsNoteView?> noteViews = noteIds.isEmpty
        ? const <String, SrsNoteView?>{}
        : await notes(noteIds);
    // 修改记录寄存器按类型分组成批读（键为 `<kind>/<id>`）。键里嵌着 ID 的（`f/<字段>` 等）一并交给同一次读：视图与
    // 寄存器按规范键出（内核 `Index::canonical_key`），键里是别名类的非规范成员（调用方传进持久化的带盐旧 ID）时按请求
    // 键取不到，回包 `keyCanon` 给出它的规范键（[_editItemsById]）——不另发 `canonical_ids`。
    final Map<SrsEntityKind, Set<String>> byKind =
        <SrsEntityKind, Set<String>>{};
    final Map<SrsEntityKind, Set<String>> idKeysByKind =
        <SrsEntityKind, Set<String>>{};
    for (final (SrsEntityKind k, String id, String key) in keys) {
      (byKind[k] ??= <String>{}).add(id);
      if (srsKeyEmbeddedId(key) != null) {
        (idKeysByKind[k] ??= <String>{}).add(key);
      }
    }
    final Map<String, SrsEntityEdits> registers = <String, SrsEntityEdits>{};
    final Map<SrsEntityKind, Map<String, String>> keyCanon =
        <SrsEntityKind, Map<String, String>>{};
    for (final MapEntry<SrsEntityKind, Set<String>> k in byKind.entries) {
      final Set<String>? idKeys = idKeysByKind[k.key];
      for (final MapEntry<String, SrsEntityEdits> e in (await _entityEditsMany(
        k.key,
        k.value,
        keys: idKeys?.toList(),
        keyCanon: idKeys == null
            ? null
            : (keyCanon[k.key] = <String, String>{}),
      )).entries) {
        registers['${k.key.wire}/${e.key}'] = e.value;
      }
    }
    final String fieldPrefix = SrsFieldKeys.noteField('');
    Object? valueOf(SrsEntityKind kind, String id, String key) {
      final SrsCardCacheRow? card = kind == SrsEntityKind.card
          ? cards[id]
          : null;
      final SrsNoteView? note = kind == SrsEntityKind.note
          ? noteViews[id]
          : null;
      return switch (key) {
        SrsFieldKeys.suspended when card != null => card.suspended,
        SrsFieldKeys.buriedUntilDay when card != null => card.buriedUntilDay,
        SrsFieldKeys.flag when card != null => card.flag,
        SrsFieldKeys.cardDeck when card != null => card.deckId,
        SrsFieldKeys.noteTags when note != null => note.tags,
        SrsFieldKeys.deleted when note != null => note.deletedAt,
        _ when note != null && key.startsWith(fieldPrefix) => note.field(
          key.substring(fieldPrefix.length),
        ),
        _ => registers['${kind.wire}/$id']?.value(key),
      };
    }

    return <String, Object?>{
      for (final (SrsEntityKind kind, String id, String key) in keys)
        '${kind.wire}/$id/$key': valueOf(kind, id, keyCanon[kind]?[key] ?? key),
    };
  }

  /// 一组卡片的缓存行（不存在的 ID 跳过）。
  Future<List<SrsCardCacheRow>> cardRows(Iterable<String> cardIds) async {
    final List<String> ids = cardIds.toSet().toList();
    if (ids.isEmpty) return <SrsCardCacheRow>[];
    return cardRowsWhere(<String, Object?>{'ids': ids});
  }

  /// 批量重置为新卡：每张一条 manual 日志，一次内核命令落库。已经是新卡的跳过。返回写出的日志（撤销用），
  /// 按传入顺序（去重后）排列。
  Future<List<SrsReviewLog>> resetCards(Iterable<String> cardIds) =>
      runExclusive(() async {
        final _SchedOutcome r = await _schedLocal(<Map<String, Object?>>[
          for (final String id in cardIds.toSet())
            <String, Object?>{'a': 'reset', 'card': id, 'skipNew': true},
        ]);
        return r.logs;
      });

  /// 批量设置到期日（cardId → 排程日序号），一次内核命令落库。返回写出的日志（撤销用）。
  Future<List<SrsReviewLog>> setDueDays(Map<String, int> dueDays) =>
      runExclusive(() async {
        final _SchedOutcome r = await _schedLocal(<Map<String, Object?>>[
          for (final MapEntry<String, int> e in dueDays.entries)
            <String, Object?>{'a': 'setDue', 'card': e.key, 'due': e.value},
        ]);
        return r.logs;
      });

  /// 批量撤销日志（cardId, logId）：一次内核命令落库。返回撤不了的条数（那条已不是该卡最后一条
  /// 有效日志——别的设备同步来了更新的复习，铁律 B 的协议限制）。
  Future<int> undoLogs(List<(String, String)> targets) =>
      runExclusive(() async {
        final _SchedOutcome r = await _schedLocal(<Map<String, Object?>>[
          for (final (String cardId, String logId) in targets)
            <String, Object?>{'a': 'undo', 'card': cardId, 'log': logId},
        ]);
        return r.blocked;
      });

  /// 本机手动排程操作（重置 / 改到期 / 撤销 / 立即重排）：把显式意图交给内核（`sched`，
  /// native/fushi_fsrs/src/store/sync2/sched_local.rs），内核在一次事务里逐卡重放到此刻、判能不能做、算结果、
  /// 落操作与投影并刷新缓存；交回落库后的日志行（结果是内核算出的值）与撤不了的条数。Dart 不读历史、不算排程。
  ///
  /// 日志的 HLC 由内核的旧版时钟分配（写了几条走几步，native/fushi_fsrs/src/store/legacy_clock.rs）；日志 ID、
  /// 时刻、时间来源、日界口径与以前 Dart 组日志时同一套。调用方在独占区里。
  Future<_SchedOutcome> _schedLocal(List<Map<String, Object?>> items) async {
    assert(
      identical(Zone.current[_writeZoneKey], this),
      '_schedLocal outside runExclusive',
    );
    if (items.isEmpty) return const _SchedOutcome(<SrsReviewLog>[], 0);
    final SrsDayContext day = await dayContext();
    final (int nowMs, SrsTimeSource source) = now();
    late Map<String, Object?> r;
    await _commandOrReload(() async {
      // 本机状态行随命令写下（旧版时钟也在这一行里，内核在同一条命令里推进并写下）。
      r = await _sync2(<String, Object?>{
        'op': 'sched',
        'now': nowMs,
        'at': nowMs,
        'ts': source.wire,
        'utcOff': day.utcOffsetMin,
        'rollover': day.rolloverHour,
        'legacyDevice': deviceId,
        'items': items,
        'anchor': ?_anchorArg(),
      });
      _absorbLocalWrite(r);
    });
    return _SchedOutcome(<SrsReviewLog>[
      for (final Object? l in (r['logs'] as List?) ?? const <Object?>[])
        SrsReviewLog.fromJson((l! as Map).cast<String, Object?>()),
    ], (r['blocked'] as int?) ?? 0);
  }

  // ------------------------------------------------------------------ 复习

  Future<SrsCardCacheRow?> cardRow(String cardId) async =>
      (await cardRowsWhere(<String, Object?>{
        'ids': <String>[cardId],
      })).firstOrNull;

  /// 四个评分的预览。走 Rust 的重放路径（`preview`）：按钮上显示的间隔与之后合并重放出的到期是同一段
  /// 代码、同一套确定性浮点运算（设计 §4.5）；记忆状态 / 参数也由它给出，RWKV 是否可用只决定日志的 `alg`。
  Future<SrsAnswerPreview> preview(String cardId) async =>
      _previewOf(await _previewRaw(cardId), await deckTree());

  /// 一次 `preview` 命令（读快照，一次 FFI）：卡所属笔记与有效牌组由内核按缓存行查，不先在 Dart 读一遍
  /// 卡片行；结果里的 `current` 就是作答前的状态（日志的复习类型据它的队列定）。
  Future<_PreviewRaw> _previewRaw(String cardId) async =>
      (await _previewRawOrNull(cardId)) ??
      (throw StateError('SrsDbStore.preview: no card $cardId'));

  /// [_previewRaw]；卡不存在（没有缓存行）= null。
  Future<_PreviewRaw?> _previewRawOrNull(String cardId) async {
    if (engine == null) throw StateError('FSRS native library unavailable');
    final SrsDayContext day = await dayContext();
    final (int nowMs, SrsTimeSource source) = now();
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      'op': 'preview',
      'card': cardId,
      'now': nowMs,
      'utcOff': day.utcOffsetMin,
      'rollover': day.rolloverHour,
    });
    final String? note = r['note'] as String?;
    if (note == null) return null;
    return (
      r: r,
      note: note,
      deck: (r['deck'] as String?) ?? defaultDeckId,
      nowMs: nowMs,
      source: source,
      day: day,
    );
  }

  SrsAnswerPreview _previewOf(_PreviewRaw raw, SrsDeckTree tree) {
    final SrsSchedulingConfig config = _schedulingConfigIn(tree, raw.deck);
    final List<Object?> plan = raw.r['plan']! as List<Object?>;
    return SrsAnswerPreview(
      plan: SrsAnswerPlan(<int, SrsScheduleResult>{
        for (int i = 0; i < 4; i++)
          i + 1: SrsScheduleResult.fromJson(
            (plan[i]! as Map).cast<String, Object?>(),
          ),
      }),
      memoryBefore: SrsMemory.fromJson(raw.r['memoryBefore']),
      algorithm: _queuesByRwkv(config)
          ? SrsAlgorithm.rwkv
          : config.algorithm.memoryAlgorithm,
      params: <double>[
        for (final Object? x in (raw.r['params'] as List?) ?? const <Object?>[])
          (x! as num).toDouble(),
      ],
      nowMs: raw.nowMs,
      timeSource: raw.source,
    );
  }

  /// 评分 = 一个事务：算新状态 → 写日志 → 更新卡片缓存。返回日志（撤销栈用）。
  Future<SrsReviewLog> answer(
    String cardId,
    int rating, {
    int durationMs = 0,
  }) async =>
      (await answerAndStudy(cardId, rating, durationMs: durationMs)).log;

  /// 评分并排出下一张（复习页的一次作答）：预览（一次命令）→ 写日志、刷新缓存、按 [studyDeckId] 排队（同一次
  /// `apply` 命令，见 native/fushi_fsrs/src/store/study.rs）。[studyDeckId] 为 null 只评分。
  ///
  /// 子树里有按 RWKV-Instant 排队的牌组时，排队要用 RWKV 对这次作答之后的状态打分（[SrsRwkvScheduling.onAnswered]
  /// 先排进 RWKV 的串行队列），所以作答落库后另发一次排队命令（在写锁外）。
  ///
  /// [expectBase]（远程作答）：调用方出题时看到的这张卡最后一条生效日志（null = 还没有日志）。核对与落库是内核的
  /// 同一条 `apply`（`expectLast`）：卡已经不在、或它的最后一条日志不是这一条（出题之后又被作答 / 撤销过）就什么都
  /// 不落，抛 [SrsStaleCardError]。
  Future<SrsAnswerOutcome> answerAndStudy(
    String cardId,
    int rating, {
    int durationMs = 0,
    String? studyDeckId,
    SrsCustomStudy? custom,
    ({String? lastLogId})? expectBase,
  }) async {
    if (rating < 1 || rating > 4) {
      throw ArgumentError.value(rating, 'rating', 'must be 1..4');
    }
    final (
      SrsReviewLog log,
      Map<String, Object?>? merged,
      SrsDeckTree tree,
    ) = await runExclusive(() async {
      // 永远在评分这一刻重算（学习步按分钟算，用出题时刻会偏一档；日志时刻也必须是评分时刻）。
      final _PreviewRaw? found = await _previewRawOrNull(cardId);
      if (found == null) {
        // 给了基准的调用方（远程作答）：卡已经不在 = 基准不成立。
        if (expectBase != null) throw SrsStaleCardError(cardId);
        throw StateError('SrsDbStore.preview: no card $cardId');
      }
      final _PreviewRaw raw = found;
      final SrsDeckTree tree = await deckTree();
      final SrsAnswerPreview p = _previewOf(raw, tree);
      final SrsScheduleResult before = SrsScheduleResult.fromJson(
        (raw.r['current']! as Map).cast<String, Object?>(),
      );
      final String logId = uuidV7(nowMs: p.nowMs);
      SrsReviewLog logWith(Hlc hlc) => SrsReviewLog(
        id: logId,
        profileUid: profileUid,
        cardId: cardId,
        kind: SrsLogKind.review,
        rating: rating,
        hlc: hlc,
        occurredAt: p.nowMs,
        timeSource: p.timeSource,
        origin: SrsLogOrigin.fushi,
        reviewType: SrsReviewType.ofQueue(before.queue),
        durationMs: durationMs,
        paramsHash: srsParamsHash(p.algorithm, p.params),
        algorithm: p.algorithm.wire,
        utcOffsetMin: raw.day.utcOffsetMin,
        dayRolloverHour: raw.day.rolloverHour,
        result: p.plan[rating],
      );
      // 自定义学习不按 RWKV 出卡（选卡条件在内核里），同样一次命令排完。
      final bool merge =
          studyDeckId != null &&
          tree[studyDeckId] != null &&
          (custom != null ||
              !_instantPossible(tree, tree.subtree(studyDeckId)));
      Map<String, Object?>? study;
      final Map<String, Object?>? request = merge
          ? await _studyRequest(tree, studyDeckId, pick: true, custom: custom)
          : null;
      // 日志的 HLC 由内核的旧版时钟分配（`clk: t`，评分这一刻走一步）：交给内核的线格式里不带 `hlc`，回包的戳就是
      // 它；显式声明评分意图（内核不从日志形状反推）。
      final Map<String, Object?> event = <String, Object?>{
        't': 'log',
        'x': logWith(Hlc.zero).toJson()..remove('hlc'),
      };
      late _Applied applied;
      await _commandOrReload(() async {
        applied = await _applyLocal(
          <Map<String, Object?>>[
            <String, Object?>{
              'e': event,
              'note': raw.note,
              'intent': 'answer',
              'clk': 't',
            },
          ],
          tickNow: p.nowMs,
          logHlcs: true,
          study: request,
          onStudy: (Map<String, Object?> s) => study = s,
          expectLast: expectBase == null
              ? null
              : <String, Object?>{'card': cardId, 'log': expectBase.lastLogId},
        );
      });
      // 基准不成立（内核在落库的同一笔里核对的）：什么都没落。在 [_commandOrReload] 之外抛——这不是写失败，
      // 内存状态与库一致，不用重读。
      if (identical(applied, _Applied.stale)) throw SrsStaleCardError(cardId);
      final SrsReviewLog log = logWith(_answeredLogHlc(applied.reply, logId));
      return (log, study, tree);
    });
    // RWKV 状态追加这一条（不等：它在后台 isolate 里串行执行，下一次打分前会对齐）。
    unawaited(rwkv?.onAnswered(cardId, log));
    if (studyDeckId == null) return SrsAnswerOutcome(log, null);
    final SrsStudyState? study = merged != null
        ? _studyStateOf(merged, tree, studyDeckId)
        : await studyState(studyDeckId, custom: custom);
    return SrsAnswerOutcome(log, study);
  }

  /// 撤销一条评分；它已不是该卡最后一条有效日志（别的设备同步来了更新的复习）时返回 false。
  Future<bool> undo(String cardId, String logId) => runExclusive(
    () async =>
        (await _schedLocal(<Map<String, Object?>>[
          <String, Object?>{'a': 'undo', 'card': cardId, 'log': logId},
        ])).blocked ==
        0,
  );

  /// 设为新卡（单卡入口：已经是新卡也照写一条）。
  Future<void> resetCard(String cardId) => runExclusive(() async {
    await _schedLocal(<Map<String, Object?>>[
      <String, Object?>{'a': 'reset', 'card': cardId},
    ]);
  });

  Future<void> setDueDay(String cardId, int dueDay) => runExclusive(() async {
    await _schedLocal(<Map<String, Object?>>[
      <String, Object?>{'a': 'setDue', 'card': cardId, 'due': dueDay},
    ]);
  });

  /// 「立即重排整组」：子树里每张复习卡写一条 reschedule 日志（候选、记忆状态、到期都由内核在一次命令里算）。
  /// 返回写出的条数。
  Future<int> rescheduleDeck(String deckId) => runExclusive(
    () async => (await _schedLocal(<Map<String, Object?>>[
      <String, Object?>{'a': 'rescheduleDeck', 'deck': deckId},
    ])).logs.length,
  );

  // ------------------------------------------------------------------ 查询

  // ------------------------------------------------------------------ 排队（计数 + 出卡）

  /// 一次排队命令的请求（Rust `study`，native/fushi_fsrs/src/store/study.rs）：牌组计数（每日上限、子树截断、
  /// 今天已学量）与出卡都在内核的一个读快照里算，Dart 只给「此刻」、日界与 RWKV 分数（[_instantInput]）。
  /// [deckId] 为 null = 全部牌组（牌组列表），不出卡。
  Future<Map<String, Object?>> _studyRequest(
    SrsDeckTree tree,
    String? deckId, {
    bool pick = false,
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async {
    final SrsDayContext day = await dayContext();
    final (int nowMs, _) = now();
    final List<String> decks = deckId == null
        ? <String>[for (final SrsDeckView d in tree.decks) d.id]
        : tree.subtree(deckId);
    // 自定义学习的出卡不看 RWKV 分数（[SrsCustomStudy]），不必等 RWKV 打分。
    final Map<String, Object?>? rw = custom != null
        ? null
        : await _instantInput(tree, decks, day, nowMs);
    return <String, Object?>{
      'op': 'study',
      'deck': ?deckId,
      'now': nowMs,
      'utcOff': day.utcOffsetMin,
      'rollover': day.rolloverHour,
      'pick': pick,
      if (exclude.isNotEmpty) 'exclude': exclude.toList(),
      'rwkv': ?rw,
      if (custom != null && deckId != null) 'custom': custom.toRequest(),
    };
  }

  int _depthOf(SrsDeckTree tree, String id) {
    int d = 0;
    String? p = tree.parentOf(id);
    while (p != null && d < 64) {
      d++;
      p = tree.parentOf(p);
    }
    return d;
  }

  /// 内核的一行计数 `[新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 缩减原因, 剩余复习分钟?]` → 摘要。内核与 Dart 的牌组树
  /// 来自同一份数据；读的间隙恰好新建的牌组内核那边还没有（没有卡），按零计。
  SrsDeckSummary _summaryFrom(
    SrsDeckView d,
    SrsDeckTree tree,
    Object? row, {
    Set<String> rwkvPendingDecks = const <String>{},
    Set<String> rwkvDecks = const <String>{},
  }) {
    final List<Object?> c = (row as List?) ?? const <Object?>[];
    int at(int i, int fallback) =>
        (c.length > i ? c[i] as int? : null) ?? fallback;
    final String? reason = c.length > 7 ? c[7] as String? : null;
    final int? minutesLeft = c.length > 8 ? c[8] as int? : null;
    return SrsDeckSummary(
      deck: d,
      fullName: tree.fullName(d.id),
      depth: _depthOf(tree, d.id),
      parentId: tree.parentOf(d.id),
      newCount: at(0, 0),
      learnCount: at(1, 0),
      reviewCount: at(2, 0),
      newBudget: SrsNewCardBudget(
        limit: at(4, d.newPerDay),
        allowed: at(5, d.newPerDay),
        reviewBudget: at(6, 0),
        reason: reason == null
            ? null
            : SrsNewCardBudgetReason.values.byName(reason),
      ),
      totalCards: at(3, 0),
      rwkvPending:
          rwkvPendingDecks.isNotEmpty &&
          tree.subtree(d.id).any(rwkvPendingDecks.contains),
      rwkvScheduled:
          rwkvDecks.isNotEmpty && tree.subtree(d.id).any(rwkvDecks.contains),
      reviewMinutesLeft: minutesLeft,
    );
  }

  /// 排队请求（[_studyRequest]）里按 RWKV-Instant 排队的牌组（[_instantInput] 的 `decks`，就绪与否都有）。
  static Set<String> _rwkvDecks(Map<String, Object?> request) {
    final Map<Object?, Object?>? rw = request['rwkv'] as Map<Object?, Object?>?;
    if (rw == null) return const <String>{};
    return <String>{
      for (final Object? d
          in (rw['decks'] as Map<Object?, Object?>? ??
                  const <Object?, Object?>{})
              .keys)
        d! as String,
    };
  }

  /// 排队请求（[_studyRequest]）里因 RWKV 没准备好而一张复习卡都没交的 RWKV 牌组（[_instantInput] 的 `pending`）。
  static Set<String> _rwkvPendingDecks(Map<String, Object?> request) {
    final Map<Object?, Object?>? rw = request['rwkv'] as Map<Object?, Object?>?;
    if (rw == null || rw['pending'] != true) return const <String>{};
    return <String>{
      for (final Object? d
          in (rw['decks'] as Map<Object?, Object?>? ??
                  const <Object?, Object?>{})
              .keys)
        d! as String,
    };
  }

  SrsStudyState? _studyStateOf(
    Map<String, Object?> r,
    SrsDeckTree tree,
    String deckId, {
    Map<String, Object?>? request,
  }) {
    final SrsDeckView? d = tree[deckId];
    final Map<Object?, Object?>? counts = r['counts'] as Map<Object?, Object?>?;
    if (d == null || counts == null) return null;
    return SrsStudyState(
      summary: _summaryFrom(
        d,
        tree,
        counts[deckId],
        rwkvPendingDecks: request == null
            ? const <String>{}
            : _rwkvPendingDecks(request),
        rwkvDecks: request == null ? const <String>{} : _rwkvDecks(request),
      ),
      next: r['next'] as String?,
      after: r['after'] as String?,
      custom: SrsCustomStudyProgress.fromValue(r['custom']),
    );
  }

  /// 复习页的一次排队：[deckId]（含子树）的计数、下一张、排除它之后的再下一张（预取用），一次命令。
  /// 牌组不存在时 null。
  ///
  /// [custom] 不为 null = 自定义学习的临时会话（[SrsCustomStudy]）：出卡换成会话的选卡条件，结果带
  /// [SrsStudyState.custom] 进度。
  Future<SrsStudyState?> studyState(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async {
    final SrsDeckTree tree = await deckTree();
    if (tree[deckId] == null) return null;
    final Map<String, Object?> request = await _studyRequest(
      tree,
      deckId,
      pick: true,
      exclude: exclude,
      custom: custom,
    );
    return _studyStateOf(await _sync2(request), tree, deckId, request: request);
  }

  /// 牌组列表：每个牌组（含子树）的新卡 / 学习 / 到期数（一次排队命令）。
  Future<List<SrsDeckSummary>> deckSummaries() async {
    final SrsDeckTree tree = await deckTree();
    final Map<String, Object?> request = await _studyRequest(tree, null);
    final Set<String> pending = _rwkvPendingDecks(request);
    final Set<String> rwkvDecks = _rwkvDecks(request);
    final Map<Object?, Object?> counts =
        ((await _sync2(request))['counts'] as Map?) ??
        const <Object?, Object?>{};
    final Map<String?, List<SrsDeckView>> children =
        <String?, List<SrsDeckView>>{};
    for (final SrsDeckView d in tree.decks) {
      (children[tree.parentOf(d.id)] ??= <SrsDeckView>[]).add(d);
    }
    // 先序（父在前、子紧跟父）；同级按手动位置、再按名字（[SrsDeckView.compareSiblings]）。
    // 没人排过时与 Anki 按名字逐层排序同一口径——直接比全名的话「Lang2」会插进「Lang」
    // 与「Lang::JP」之间，子牌组就离开了父牌组。
    final List<SrsDeckSummary> out = <SrsDeckSummary>[];
    void visit(String? parent) {
      final List<SrsDeckView> level = (children[parent] ?? <SrsDeckView>[])
        ..sort(SrsDeckView.compareSiblings);
      for (final SrsDeckView d in level) {
        out.add(
          _summaryFrom(
            d,
            tree,
            counts[d.id],
            rwkvPendingDecks: pending,
            rwkvDecks: rwkvDecks,
          ),
        );
        visit(d.id);
      }
    }

    visit(null);
    return out;
  }

  /// 今天已做的复习（[SrsTodayReviewSummary]）：有效复习投影（`srs_stat_reviews`，被撤销的不在）里落在
  /// 今天（[dayContext] 的日界，与牌组计数同一个「今天」）的评分复习，按 (profile, 时刻) 索引聚合一次。
  Future<SrsTodayReviewSummary> todayReviewSummary() async {
    final SrsDayContext day = await dayContext();
    final int today = day.dayIndexOf(now().$1);
    final Map<String, Object?> row = (await _read(
      'today_reviews',
      <String, Object?>{
        'from': day.dayStartMs(today),
        'to': day.dayStartMs(today + 1),
      },
    )).json;
    return SrsTodayReviewSummary(
      count: row['n']! as int,
      durationMs: row['ms']! as int,
      again: row['again']! as int,
    );
  }

  /// 每日上限单位的存量牌组：还没写过单位（[SrsDeckView.limitUnitSet]），且自己或子树里有卡在**本机第一次跑懂单位
  /// 的版本之前**（[_limitUnitSince]）在 Fushi 里评过分——那些复习是旧版按卡片数计上限时做的（上限与这里一样按整棵
  /// 子树算），升级后缺省改按作答次数计，牌组页据此提醒一次。
  ///
  /// - 判据按本机的升级时刻、不按缺省改动合入的时刻：合入之后、升级之前一直用旧版复习的牌组同样算；
  /// - 从 Anki 导入的复习不算（内核 `reviewed_decks` 按日志 ID 排除，native/fushi_fsrs/src/store/reads.rs
  ///   `native_log_sql`）：它们从没受过 Fushi 的上限，新导入 Anki 历史不该收到「以前按卡片数」的提醒；
  /// - 新装时内置默认牌组没写过单位，但本机之前没有复习，不算；别的设备同步来的、早于本机升级的复习算（那台设备上
  ///   这个牌组可能一直按卡片数计），回应一次写下的单位随同步到所有设备。
  Future<Set<String>> limitUnitLegacyDecks() async {
    final int? since = _limitUnitSince;
    if (since == null) return const <String>{};
    final SrsDeckTree tree = await deckTree();
    final List<SrsDeckView> unset = <SrsDeckView>[
      for (final SrsDeckView d in tree.decks)
        if (!d.limitUnitSet) d,
    ];
    if (unset.isEmpty) return const <String>{};
    final Map<String, Object?> row = (await _read(
      'reviewed_decks',
      <String, Object?>{'before': since},
    )).json;
    final Set<String> reviewed = <String>{
      for (final Object? d in row['decks']! as List<Object?>) d! as String,
    };
    if (reviewed.isEmpty) return const <String>{};
    return <String>{
      for (final SrsDeckView d in unset)
        if (tree.subtree(d.id).any(reviewed.contains)) d.id,
    };
  }

  /// 单个牌组（含子树）的计数，与 [deckSummaries] 里同一牌组的那一行相同：
  /// 一个牌组的计数只取决于它自己的子树，祖先的上限不参与。
  Future<SrsDeckSummary?> deckSummary(String deckId) async {
    final SrsDeckTree tree = await deckTree();
    if (tree[deckId] == null) return null;
    final Map<String, Object?> request = await _studyRequest(tree, deckId);
    return _studyStateOf(
      await _sync2(request),
      tree,
      deckId,
      request: request,
    )?.summary;
  }

  /// 自定义学习「提升今日上限」：给 [deckId] 今天的新卡 / 复习上限各追加 [newCards] / [reviews] 张（与今天
  /// 已追加的累加；昨天以前的追加作废）。走修改记录，随同步到其它设备；第二天自动失效。返回今天的追加总量。
  Future<({int newCards, int reviews})> extendTodayLimits(
    String deckId, {
    int newCards = 0,
    int reviews = 0,
  }) async {
    final SrsDeckView? deck = (await deckTree())[deckId];
    if (deck == null) throw StateError('deck not found: $deckId');
    final SrsDayContext day = await dayContext();
    final int today = day.dayIndexOf(now().$1);
    final ({int newCards, int reviews}) cur =
        deck.limitExtension?.on(today) ?? (newCards: 0, reviews: 0);
    final SrsDeckLimitExtension next = SrsDeckLimitExtension(
      day: today,
      newCards: (cur.newCards + newCards.clamp(0, SrsDeckLimitExtension.max))
          .clamp(0, SrsDeckLimitExtension.max),
      reviews: (cur.reviews + reviews.clamp(0, SrsDeckLimitExtension.max))
          .clamp(0, SrsDeckLimitExtension.max),
    );
    await editField(
      SrsEntityKind.deck,
      deckId,
      SrsFieldKeys.deckExtendLimits,
      next.toValue(),
    );
    return (newCards: next.newCards, reviews: next.reviews);
  }

  /// 牌组列表里收起 / 展开子牌组（Anki 的 deck collapsed）。走修改记录，随同步到其它设备；
  /// 并发开合不进冲突记录（[SrsFieldClass.viewState]）。
  Future<void> setDeckCollapsed(String deckId, bool collapsed) async {
    await editField(
      SrsEntityKind.deck,
      deckId,
      SrsFieldKeys.deckCollapsed,
      collapsed,
    );
  }

  /// 把牌组（连同子树）挪到 [newParentId] 下、末尾；null = 顶层（Anki 拖放牌组同语义）。
  /// 见 [placeDeck]。
  Future<SrsDeckMoveResult> moveDeck(String deckId, String? newParentId) =>
      placeDeck(deckId, parentId: newParentId);

  /// 把牌组（连同子树）放到 [parentId] 下（null = 顶层）、排在同级的 [beforeId] 前面
  /// （null = 排最后）。拖放与「上移 / 下移」都走这里。
  ///
  /// 父牌组只改父字段，ID 不变（卡、设置、同步身份都跟着走）；同级顺序给新父牌组下
  /// 的全部同级重新编排位置（[SrsFieldKeys.deckPosition]，只写变了的）。拒绝的情形返回
  /// 对应 [SrsDeckMoveResult]、不写库：挪到自己或自己的子孙下（本地成环；跨设备并发
  /// 成环由 [SrsDeckTree] 确定性打破）、目标下已有同名牌组、[beforeId] 不是目标下的同级。
  Future<SrsDeckMoveResult> placeDeck(
    String deckId, {
    required String? parentId,
    String? beforeId,
  }) => runExclusive(() async {
    final SrsDeckTree tree = await deckTree();
    final SrsDeckView? deck = tree[deckId];
    if (deck == null || (parentId != null && tree[parentId] == null)) {
      return SrsDeckMoveResult.missing;
    }
    for (String? p = parentId; p != null; p = tree.parentOf(p)) {
      if (p == deckId) return SrsDeckMoveResult.intoOwnSubtree;
    }
    final bool reparent = tree.parentOf(deckId) != parentId;
    final List<SrsDeckView> siblings = <SrsDeckView>[
      for (final SrsDeckView d in tree.decks)
        if (d.id != deckId && tree.parentOf(d.id) == parentId) d,
    ]..sort(SrsDeckView.compareSiblings);
    if (reparent && siblings.any((SrsDeckView d) => d.name == deck.name)) {
      return SrsDeckMoveResult.nameTaken;
    }
    final int at = beforeId == null
        ? siblings.length
        : siblings.indexWhere((SrsDeckView d) => d.id == beforeId);
    if (at < 0) return SrsDeckMoveResult.missing;
    final List<SrsDeckView> ordered = <SrsDeckView>[...siblings]
      ..insert(at, deck);
    final List<SrsDeckView> before = <SrsDeckView>[
      for (final SrsDeckView d in tree.decks)
        if (tree.parentOf(d.id) == parentId) d,
    ]..sort(SrsDeckView.compareSiblings);
    final bool reordered =
        before.length != ordered.length ||
        <int>[
          for (int i = 0; i < ordered.length; i++) i,
        ].any((int i) => before[i].id != ordered[i].id);
    if (!reparent && !reordered) return SrsDeckMoveResult.unchanged;
    if (reparent) {
      await editField(
        SrsEntityKind.deck,
        deckId,
        SrsFieldKeys.deckParent,
        parentId,
      );
    }
    // 只换父牌组（没指定位置）、新同级又都没手动排过：保持「按名字」的缺省排法，
    // 不给整组写位置。显式排序（[beforeId] 或同父下挪到末尾）一律写。
    final bool keepNameOrder =
        reparent &&
        beforeId == null &&
        siblings.every((SrsDeckView d) => d.position == null);
    if (reordered && !keepNameOrder) {
      for (int i = 0; i < ordered.length; i++) {
        await editField(
          SrsEntityKind.deck,
          ordered[i].id,
          SrsFieldKeys.deckPosition,
          i,
        );
      }
    }
    return SrsDeckMoveResult.moved;
  });

  /// 新卡位置序（按位置出卡的牌组、[nextCard] 的兜底、「按词频重排新卡」共用这一处）：排过的卡在前、按位置
  /// 升序；没排过的（[SrsCardCacheRow.newPosition] 为 null）在后、按（笔记创建时刻,
  /// cardId）——从没重排过的库出卡顺序与加位置之前逐张相同。位置相同再按后者。
  static int compareNewCardOrder(SrsCardCacheRow a, SrsCardCacheRow b) {
    final int? pa = a.newPosition;
    final int? pb = b.newPosition;
    if (pa != pb) {
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pa.compareTo(pb);
    }
    final int byCreated = a.noteCreatedAt.compareTo(b.noteCreatedAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }

  /// [deckFullName]（「父::子」全名；同名牌组全部算上）及其全部子牌组里的可见新卡（含暂停 /
  /// 搁置的：位置与它们无关），按 [compareNewCardOrder] 排好。笔记已删 / 类型缺失的卡跳过。
  /// 「按词频重排新卡」的取卡步，对应 AnkiConnect 的 `deck:… is:new` + `cardsInfo`。
  Future<List<SrsNewCardEntry>> newCardsInDeck(String deckFullName) async {
    final Set<String> sub = await _deckSubtreeByFullName(deckFullName);
    if (sub.isEmpty) return const <SrsNewCardEntry>[];
    final List<SrsCardCacheRow> rows =
        await cardRowsWhere(_visibleNewCardIn(sub))
          ..sort(compareNewCardOrder);
    if (rows.isEmpty) return const <SrsNewCardEntry>[];
    final Map<String, SrsNoteView?> notesById = await notes(<String>[
      for (final SrsCardCacheRow c in rows) c.noteId,
    ]);
    final Map<String, SrsNoteTypeView?> typesById = await noteTypesById(
      <String>{
        for (final SrsNoteView? n in notesById.values)
          if (n != null) n.noteTypeId,
      },
    );
    int next = 0;
    for (final SrsCardCacheRow c in rows) {
      final int? pos = c.newPosition;
      if (pos != null && pos > next) next = pos;
    }
    final List<SrsNewCardEntry> out = <SrsNewCardEntry>[];
    for (final SrsCardCacheRow c in rows) {
      final SrsNoteView? n = notesById[c.noteId];
      if (n == null || n.deletedAt != null) continue;
      final SrsNoteTypeView? t = typesById[n.noteTypeId];
      if (t == null) continue;
      final int ord = t.isCloze
          ? max(0, c.clozeOrd - 1)
          : (t.templates
                    .where((SrsTemplateDef x) => x.id == c.templateId)
                    .firstOrNull
                    ?.ord ??
                0);
      out.add(
        SrsNewCardEntry(
          card: c,
          note: n,
          noteType: t,
          ord: ord,
          position: c.newPosition ?? ++next,
        ),
      );
    }
    return out;
  }

  /// [deckFullName]（含子牌组）里此刻可见新卡的 cardId——[newCardsInDeck] 的只读 ID 版：
  /// 不读笔记、不物化，供写回前重校验「还是不是新卡」。比 [newCardsInDeck] 宽（不排除笔记
  /// 已删 / 类型缺失的卡）：它只用来过滤，真正写入时 [setNewCardPositions] 还会再校验一次。
  Future<Set<String>> newCardIdsInDeck(String deckFullName) async {
    final Set<String> sub = await _deckSubtreeByFullName(deckFullName);
    if (sub.isEmpty) return const <String>{};
    return (await _cardIdsWhere(_visibleNewCardIn(sub))).toSet();
  }

  /// 全名为 [deckFullName] 的牌组（同名的全部算上）及其子孙的 ID；没有为空。
  Future<Set<String>> _deckSubtreeByFullName(String deckFullName) async {
    final SrsDeckTree tree = await deckTree();
    return <String>{
      for (final SrsDeckView d in tree.decks)
        if (tree.fullName(d.id) == deckFullName) ...tree.subtree(d.id),
    };
  }

  /// 本 profile、牌组在 [decks] 里的可见新卡（`read` 的 `cards` 的条件）。
  Map<String, Object?> _visibleNewCardIn(Set<String> decks) =>
      <String, Object?>{
        'decks': decks.toList(),
        'visibleOnly': true,
        'queue': SrsQueue.newCard.wire,
      };

  /// 写新卡位置（cardId → 位置）：一个事务、一次发件箱批次，每张卡一条 `newPos` 修改记录
  /// （值没变的不写）。**只写此刻仍是可见新卡的那些**——学过的卡位置不起作用，写了只是
  /// 无用的同步行；返回实际被接受的 cardId（含值没变而没产生记录的）。
  Future<Set<String>> setNewCardPositions(Map<String, int> positions) async {
    if (positions.isEmpty) return const <String>{};
    final Set<String> accepted = <String>{
      for (final SrsCardCacheRow c in await cardRows(positions.keys))
        if (!c.hidden && c.queue == SrsQueue.newCard.wire) c.id,
    };
    await editFieldsBatch(<SrsFieldChange>[
      for (final String id in accepted)
        SrsFieldChange(
          SrsEntityKind.card,
          id,
          SrsFieldKeys.cardNewPosition,
          positions[id],
        ),
    ]);
    return accepted;
  }

  /// [decks] 里算法是 RWKV 的牌组 → 目标保留率（没有 RWKV 服务时为空）。
  Map<String, double> _instantTargets(
    SrsDeckTree tree,
    Iterable<String> decks,
  ) {
    if (rwkv == null) return const <String, double>{};
    return <String, double>{
      for (final String d in decks)
        if (_schedulingConfigIn(tree, d) case final SrsSchedulingConfig c
            when _queuesByRwkv(c))
          d: c.desiredRetention,
    };
  }

  /// 按 [config] 排程的牌组在这个宿主上是不是由 RWKV-Instant 排队：算法是 RWKV **且**宿主装配了 RWKV 运行时
  /// （[rwkv]）。没有运行时的宿主（无头服务端 / CLI）上 RWKV 牌组照存下的 FSRS-7 到期日排队（[_instantInput]
  /// 返回 null），这时评分日志的 `alg` 也必须是 FSRS-7（[_previewOf]）——日志记的是实际排它的算法。
  bool _queuesByRwkv(SrsSchedulingConfig config) =>
      rwkv != null && config.algorithm.usesRwkv;

  /// 这些牌组里可能有按 RWKV-Instant 排队的（有 RWKV 服务且有 RWKV 牌组）。
  bool _instantPossible(SrsDeckTree tree, Iterable<String> decks) =>
      _instantTargets(tree, decks).isNotEmpty;

  /// RWKV-Instant 的排队输入（上游 kuma3 `rslib/src/scheduler/rwkv.rs` 与 `scheduler/queue/builder/gathering.rs`）：
  /// [decks] 里算法是 RWKV 的牌组，其可出复习卡**不看到期日**，按今天结束时的回忆率 R（即时头）排。这里只取分数
  /// （RWKV 服务是另一个原生库，[SrsRwkvScheduling]），排队规则（目标保留率、同日间隔守卫、每天最少复习数、
  /// 按 R 升序、每日上限）在内核（store/study.rs `instant_eligible`）。
  ///
  /// 返回 null = [decks] 里没有 RWKV 牌组，或这个宿主没有 RWKV 运行时（[rwkv] 为 null）。RWKV 没准备好（权重
  /// 没下载 / 正在回放 / 出错）时交出这些牌组、**零个候选**并标 `pending`：内核于是不出它们的复习卡
  /// （[SrsStudyState.rwkvPending]），复习页等 RWKV 就绪再出。绝不退回按 FSRS-7 存下的到期日排队——那是另一种
  /// 排程，日志的 `alg` 会混进 FSRS-7，时钟出问题时还会把「回放失败 → 改按到期日」放大成整批重复出卡。
  /// 只交 R 不高于目标保留率的卡，加上「每天最少复习数」补足可能用到的卡（[_minimumTopUp]）；其余的内核也只会丢掉。
  Future<Map<String, Object?>?> _instantInput(
    SrsDeckTree tree,
    List<String> decks,
    SrsDayContext day,
    int nowMs,
  ) async {
    final SrsRwkvScheduling? source = rwkv;
    if (source == null) return null;
    final Map<String, double> targets = _instantTargets(tree, decks);
    if (targets.isEmpty) return null;
    // 排队设置与目标保留率同一条继承（参数归属的 own 祖先）。
    final Map<String, SrsRwkvQueueSettings> queueOf =
        <String, SrsRwkvQueueSettings>{
          for (final String d in targets.keys)
            d: tree
                .paramsOwner(tree.effectiveDeckOf(d, fallback: defaultDeckId))
                .rwkvQueue,
        };
    final Map<String, Object?> deckInput = <String, Object?>{
      for (final MapEntry<String, double> e in targets.entries)
        e.key: <Object?>[
          e.value,
          queueOf[e.key]!.minReviewsPerDay,
          queueOf[e.key]!.repeatMinReviews,
          queueOf[e.key]!.repeatMinSeconds,
        ],
    };
    final Map<String, Object?> pending = <String, Object?>{
      'decks': deckInput,
      'cands': const <Object?>[],
      'pending': true,
    };
    if (!source.ready) {
      // 不读候选卡：没准备好时 [SrsRwkvScheduling.instantRetrievability] 只触发准备并返回 null。
      unawaited(
        source.instantRetrievability(const <SrsRwkvCandidate>[], atMs: nowMs),
      );
      return pending;
    }
    final int today = day.dayIndexOf(nowMs);
    final int todayStart = day.dayStartMs(today);
    // 今天还没答过的卡取今天结束那一刻（下一个翻日时刻前 1 ms）的 R：到那时会降到目标线以下的就是今天到期，与
    // FSRS 按天到期同一粒度。计数是「今天还剩多少」，出卡与它同一口径（数字 > 0 就有卡出）。
    // 今天已答过的卡取此刻的 R：答过就不再是「今天还剩的」，同日重出要等它真的掉到目标线下（再加内核的同日
    // 间隔守卫）。它也按今天结束时的 R 判的话，刚答完模型仍预测它撑不到今天结束（年轻卡、刚重学毕业的卡），
    // 守卫一过又合格，一天里被反复刷、答一张计数不降。「今天答过」与内核守卫同一判据（上次作答 ≥ 今天开始，
    // store/study.rs `instant_eligible`）。
    final List<_RwkvCandidate> rows = <_RwkvCandidate>[];
    final List<_RwkvCandidate> answered = <_RwkvCandidate>[];
    for (final _RwkvCandidate r in (await _rwkvCandidates(
      today,
      targets.keys,
    )).values) {
      final int? last = r.lastReviewedAt;
      (last != null && last >= todayStart ? answered : rows).add(r);
    }
    final List<double>? dayEnd = await source.instantRetrievability(
      <SrsRwkvCandidate>[for (final _RwkvCandidate r in rows) r.card],
      atMs: day.dayStartMs(today + 1) - 1,
    );
    if (dayEnd == null) return pending;
    final List<double>? current = answered.isEmpty
        ? const <double>[]
        : await source.currentRetrievability(<SrsRwkvCandidate>[
            for (final _RwkvCandidate r in answered) r.card,
          ], nowMs: nowMs);
    if (current == null) return pending;
    if (dayEnd.length != rows.length || current.length != answered.length) {
      // 违反 [SrsRwkvScheduling] 的契约（与候选同序同长）：不是「没准备好」，当成 pending 的话复习页会一直等
      // 一个已经来过的「就绪」。
      throw StateError(
        'SrsDbStore: RWKV returned ${dayEnd.length} + ${current.length} scores '
        'for ${rows.length} + ${answered.length} cards',
      );
    }
    rows.addAll(answered);
    final List<double> scores = <double>[...dayEnd, ...current];
    final int answeredFrom = dayEnd.length;
    final Set<int> topUp = _minimumTopUp(
      tree,
      targets,
      queueOf,
      rows,
      scores,
      unansweredCount: answeredFrom,
    );
    bool sent(int i) {
      if (!scores[i].isFinite) return false;
      if (scores[i] <= targets[rows[i].card.deckId]!) return true;
      // 今天答过的卡还要过内核的同日间隔守卫，补足时被挡下的由后面的卡顶上，所以它们全交。
      return i >= answeredFrom
          ? queueOf[rows[i].card.deckId]!.minReviewsPerDay > 0
          : topUp.contains(i);
    }

    return <String, Object?>{
      'decks': deckInput,
      'cands': <Object?>[
        for (int i = 0; i < rows.length; i++)
          if (sent(i))
            <Object?>[
              rows[i].card.id,
              rows[i].card.deckId,
              rows[i].lastReviewedAt,
              scores[i],
            ],
      ],
    };
  }

  /// 「每天最少复习数」补足时内核可能用到的、今天还没答过且 R 高于目标的卡（[rows] / [scores] 的下标）：每个参数
  /// 归属牌组（配额按它记，store/study.rs `instant_eligible`）只留 R 最低（同 R 按 id）的前 `minReviewsPerDay`
  /// 张——内核补足时按同一顺序取、最多取这么多，其余的交过去也只会被丢掉（归属牌组按分钟记配额时例外，全交）。
  /// 这里只决定交哪些卡，不判定补不补：补足规则只在内核。以前开了这一项就把 RWKV 牌组的全部
  /// 复习卡都交给内核，新建牌组默认开（[SrsRwkvQueueSettings.forNewDeck]）后每次排队都要搬整表。
  Set<int> _minimumTopUp(
    SrsDeckTree tree,
    Map<String, double> targets,
    Map<String, SrsRwkvQueueSettings> queueOf,
    List<_RwkvCandidate> rows,
    List<double> scores, {
    required int unansweredCount,
  }) {
    final Map<String, String> ownerOf = <String, String>{
      for (final String d in targets.keys)
        if (queueOf[d]!.minReviewsPerDay > 0)
          d: tree
              .paramsOwner(tree.effectiveDeckOf(d, fallback: defaultDeckId))
              .id,
    };
    if (ownerOf.isEmpty) return const <int>{};
    final Map<String, List<int>> above = <String, List<int>>{};
    final Map<String, int> quota = <String, int>{};
    for (int i = 0; i < unansweredCount; i++) {
      final String deck = rows[i].card.deckId;
      final String? owner = ownerOf[deck];
      if (owner == null) continue;
      if (!scores[i].isFinite || scores[i] <= targets[deck]!) continue;
      (above[owner] ??= <int>[]).add(i);
      quota[owner] = queueOf[deck]!.minReviewsPerDay;
    }
    final Set<int> out = <int>{};
    for (final MapEntry<String, List<int>> e in above.entries) {
      // 归属牌组按分钟记配额（[SrsLimitUnit.minutes]）：内核在今天复习时长没到之前把高于目标的卡全部补上，
      // 补多少张由时长决定、事先不知道，所以全交。按次数 / 卡片数记时内核每补一张至少扣 1，最多补这么多张。
      if (tree[e.key]?.limitUnit == SrsLimitUnit.minutes) {
        out.addAll(e.value);
        continue;
      }
      e.value.sort((int a, int b) {
        final int byR = scores[a].compareTo(scores[b]);
        return byR != 0 ? byR : rows[a].card.id.compareTo(rows[b].card.id);
      });
      out.addAll(e.value.take(quota[e.key]!));
    }
    return out;
  }

  /// RWKV-Instant 的候选复习卡（RWKV 牌组里此刻可出的复习卡）。按（纪元、今天、RWKV 牌组集）缓存，之后只按
  /// 缓存行的变更日志（[cacheChangesSince]）重读写过的卡：以前每答一题修订号一变就把 RWKV 牌组的全部复习卡
  /// （上万行）整份从 SQL 搬回 Dart（L-10）。卡换牌组、改队列、暂停 / 搁置都会写它的缓存行，所以都在日志里。
  ({String key, int generation, Map<String, _RwkvCandidate> rows})?
  _rwkvCandidateCache;

  Future<Map<String, _RwkvCandidate>> _rwkvCandidates(
    int today,
    Iterable<String> decks,
  ) async {
    final List<String> deckList = decks.toList()..sort();
    final String key = '$_epoch|$today|${deckList.join(',')}';
    final int generation = _cacheGeneration;
    final ({String key, int generation, Map<String, _RwkvCandidate> rows})?
    cached = _rwkvCandidateCache;
    final ({Set<String> notes, Set<String> cards})? changes =
        cached == null || cached.key != key
        ? null
        : cacheChangesSince(cached.generation);
    if (cached != null && changes != null) {
      for (final List<String> chunk in _chunks(changes.cards)) {
        chunk.forEach(cached.rows.remove);
        for (final _RwkvCandidate r in await _rwkvCandidateRows(
          today,
          deckList,
          ids: chunk,
        )) {
          cached.rows[r.card.id] = r;
        }
      }
      _rwkvCandidateCache = (
        key: key,
        generation: generation,
        rows: cached.rows,
      );
      return cached.rows;
    }
    final Map<String, _RwkvCandidate> rows = <String, _RwkvCandidate>{
      for (final _RwkvCandidate r in await _rwkvCandidateRows(today, deckList))
        r.card.id: r,
    };
    _rwkvCandidateCache = (key: key, generation: generation, rows: rows);
    return rows;
  }

  /// [decks] 里此刻可出的复习卡（[ids] 给了只看这些卡）。
  Future<List<_RwkvCandidate>> _rwkvCandidateRows(
    int today,
    List<String> decks, {
    List<String>? ids,
  }) async {
    if (decks.isEmpty) return const <_RwkvCandidate>[];
    final SrsColumns c = await cardColumnsWhere(
      const <String>[
        'id',
        'note_id',
        'deck_id',
        'last_log_id',
        'last_reviewed_at',
      ],
      <String, Object?>{
        'decks': decks,
        'ids': ?ids,
        'visibleOnly': true,
        'studyableOn': today,
        'queue': SrsQueue.review.wire,
      },
    );
    final SrsStringColumn id = c.strings('id');
    final SrsStringColumn note = c.strings('note_id');
    final SrsStringColumn deck = c.strings('deck_id');
    final SrsStringColumn lastLog = c.strings('last_log_id');
    final SrsIntColumn last = c.ints('last_reviewed_at');
    return <_RwkvCandidate>[
      for (int i = 0; i < c.rows; i++)
        (
          card: SrsRwkvCandidate(
            id: id[i],
            noteId: note[i],
            deckId: deck[i],
            lastLogId: lastLog.at(i),
          ),
          lastReviewedAt: last.at(i),
        ),
    ];
  }

  /// 牌组 [deckId] 现在按 RWKV-Instant 排队：算法是 RWKV 且 RWKV 可用。这时它的复习卡没有有意义的
  /// 到期日（存下的那个只在 RWKV 不可用时排队），统计 / 浏览 / 词状态据此不按到期日解读。
  bool instantActiveFor(SrsDeckTree tree, String deckId) =>
      (rwkv?.ready ?? false) &&
      _schedulingConfigIn(tree, deckId).algorithm.usesRwkv;

  /// RWKV-Instant 此刻会出的复习卡（与 [nextCard] / 牌组计数同口径）：浏览器的 `is:due` 用。
  /// RWKV 用不了时 null——RWKV 牌组这时照旧按存下的到期日排队，调用方也按到期日算。
  Future<Set<String>?> instantDueCardIds() async {
    final SrsDeckTree tree = await deckTree();
    final Map<String, Object?> req = await _studyRequest(tree, null);
    if (req['rwkv'] == null) return null;
    return <String>{
      for (final Object? id
          in ((await _sync2(req))['eligible'] as List?) ?? const <Object?>[])
        id! as String,
    };
  }

  /// [cards]（RWKV 牌组的复习卡）此刻的 RWKV 回忆率：统计页的可提取度用。RWKV 用不了时 null。不经排队的
  /// 常驻分数表（[SrsRwkvScheduling.currentRetrievability]）：那张表按今天结束的时刻维护。
  Future<Map<String, double>?> instantRetrievabilityOf(
    List<SrsRwkvCandidate> cards,
  ) async {
    final SrsRwkvScheduling? source = rwkv;
    if (source == null || !source.ready) return null;
    if (cards.isEmpty) return const <String, double>{};
    final List<double>? scores = await source.currentRetrievability(
      cards,
      nowMs: now().$1,
    );
    if (scores == null || scores.length != cards.length) return null;
    return <String, double>{
      for (int i = 0; i < cards.length; i++) cards[i].id: scores[i],
    };
  }

  /// [cards]（RWKV 牌组的复习卡）在 [atMs] 各个时刻的 RWKV 回忆率，与 [atMs] 同序（复习首页「停在这里的话」）。
  /// 等于 [dayEndMs]（今天结束）的那个时刻走排队的常驻分数表（[SrsRwkvScheduling.instantRetrievability]，与复习页
  /// 数「今天到期」同一时刻、同一张表，通常已算好），其余时刻直接查询（[SrsRwkvScheduling.currentRetrievability]）。
  /// RWKV 用不了、或任一时刻打不了分时 null。
  Future<List<Map<String, double>>?> rwkvRetrievabilityAt(
    List<SrsRwkvCandidate> cards, {
    required List<int> atMs,
    required int dayEndMs,
  }) async {
    final SrsRwkvScheduling? source = rwkv;
    if (source == null || !source.ready) return null;
    final List<Map<String, double>> out = <Map<String, double>>[];
    for (final int at in atMs) {
      if (cards.isEmpty) {
        out.add(const <String, double>{});
        continue;
      }
      final List<double>? scores = at == dayEndMs
          ? await source.instantRetrievability(cards, atMs: at)
          : await source.currentRetrievability(cards, nowMs: at);
      if (scores == null || scores.length != cards.length) return null;
      out.add(<String, double>{
        for (int i = 0; i < cards.length; i++) cards[i].id: scores[i],
      });
    }
    return out;
  }

  /// 下一张要复习的卡：到期的学习卡 → 到期复习卡（可提取度从低到高；RWKV 牌组按 R）→ 新卡（所点牌组的
  /// 「新卡顺序」：按词频 = 有名次的在前按名次升序，其余按 [compareNewCardOrder]；按位置 = [compareNewCardOrder]
  /// 的同序）→ 20 分钟内到期的学习卡。与计数同一次排队命令（[studyState]）。
  Future<String?> nextCard(
    String deckId, {
    Set<String> exclude = const <String>{},
    SrsCustomStudy? custom,
  }) async =>
      (await studyState(deckId, exclude: exclude, custom: custom))?.next;

  Future<SrsCardDetail?> cardDetail(String cardId) async {
    final SrsCardCacheRow? c = await cardRow(cardId);
    if (c == null) return null;
    final SrsNoteView? n = await note(c.noteId);
    if (n == null) return null;
    final SrsNoteTypeView? t = await noteType(n.noteTypeId);
    if (t == null) return null;
    final SrsTemplateDef? tpl = t.templates
        .where((SrsTemplateDef x) => x.id == c.templateId)
        .firstOrNull;
    final SrsDeckTree tree = await deckTree();
    return SrsCardDetail(
      card: c,
      note: n,
      noteType: t,
      template: tpl,
      deckName: tree.effectiveDeckNameOf(c.deckId, fallback: defaultDeckId),
    );
  }

  Map<String, String> _fieldsByName(SrsNoteView n, SrsNoteTypeView t) =>
      <String, String>{
        for (final SrsFieldDef f in t.fields) f.name: n.field(f.id),
      };

  Map<String, String> _idToName(SrsNoteTypeView t) => <String, String>{
    for (final SrsFieldDef f in t.fields) f.id: f.name,
  };

  /// 渲染卡面（模板正文里的 fieldId 引用换回名字后交给 Anki 渲染器）。
  ///
  /// 调用方刚取过这张卡的 [cardDetail] 时传进来（[detail]），不再读第二遍（复习页出题 / 预取）。
  Future<SrsRenderedCard?> renderCard(
    String cardId, {
    SrsCardDetail? detail,
  }) async {
    assert(detail == null || detail.card.id == cardId);
    final SrsCardDetail? d = detail ?? await cardDetail(cardId);
    final SrsTemplateDef? tpl = d?.template;
    if (d == null || tpl == null) return null;
    final Map<String, String> idToName = _idToName(d.noteType);
    final String front = templateIdsToNames(tpl.front, idToName);
    final String back = templateIdsToNames(tpl.back, idToName);
    // 共享样式引用先展开回内联 `<style>`：渲染结果与去重前逐字节相同（卡面再按内容哈希
    // 只登记一次样式）。样式文件还没同步到时去掉引用行，不让 WebView 去请求相对地址。
    final Map<String, String> fields = await expandFields(
      _fieldsByName(d.note, d.noteType),
      dropMissing: true,
    );
    final AnkiCardSpecialFields specials = AnkiCardSpecialFields(
      tags: d.note.tags,
      deckName: d.deckName,
      noteTypeName: d.noteType.name,
      cardName: tpl.name,
      cardFlag: d.card.flag,
      cardId: d.card.id,
    );
    final int cardOrd = d.noteType.isCloze ? d.card.clozeOrd - 1 : tpl.ord;
    final AnkiRenderedCard r = renderAnkiCard(
      questionTemplate: front,
      answerTemplate: back,
      noteFields: fields,
      cardOrd: cardOrd,
      isCloze: d.noteType.isCloze,
      specials: specials,
    );
    // 「打字输入答案」（`{{type:…}}`）：问题面换成输入框，答案面换成带期望答案的比对占位
    // （卡面拿到打的字后填比对，见 anki_type_answer.dart）。
    final ({String question, String answer}) faces = ankiResolveTypeAnswer(
      question: r.question,
      answer: r.answer,
      fields: fields,
      cardOrd: cardOrd,
    );
    // 原生卡面画不全的媒体（SVG / 远程图片、Picture 里的杂项内容）留在整面 WebView
    // （同一份模板），见 srs_fushi_card_native_media。
    final SrsFushiCardNativeProbe probe = srsFushiCardNative(
      builtinKey: d.noteType.builtinKey,
      front: front,
      back: back,
      css: d.noteType.css,
      fieldsByName: fields,
      cardOrd: tpl.ord,
      specials: specials,
    );
    final SrsFushiCardNative? native = probe.native;
    return SrsRenderedCard(
      question: faces.question,
      answer: faces.answer,
      // 原生卡面只拿样式给释义 WebView 用：冻住的历史内置样式换成当前内置样式（释义 HTML
      // 按当前模板生成），见 [SrsFushiCardNative.css]。
      css: native?.css ?? d.noteType.css,
      isEmpty: r.isEmpty,
      fields: fields,
      fushiCardDefinitions: native?.definitions,
      fushiCardFront: native?.front ?? const <FushiCardItem>[],
      fushiCardBack: native?.back ?? const <FushiCardItem>[],
      nativeFallback: probe.fallback,
    );
  }

  /// 词状态查询（B-3）：按 termKey（与可选读音）索引。一个词多张卡时取最需要复习的一张，带卡数。
  ///
  /// 一批词一条 JOIN（笔记缓存 × 卡片缓存，按 termKey 走 idx_srs_notes_cache_term，只取要用的列），
  /// 牌组树也只取一次（以前每个词两次查询，命中时还在循环里各取一次牌组树）。
  Future<Map<String, SrsTermStatus>> lookupTermStatus(
    List<SrsTermQuery> terms,
  ) async {
    final Map<String, SrsTermStatus> out = <String, SrsTermStatus>{};
    final Set<String> keys = <String>{
      for (final SrsTermQuery q in terms)
        if (q.termKey.isNotEmpty) q.termKey,
    };
    if (keys.isEmpty) return out;
    // termKey → 命中的可见卡（带笔记的读音键）：(读音键, 结果表, 行号)。
    final Map<String, List<(String, SrsColumns, int)>> byKey =
        <String, List<(String, SrsColumns, int)>>{};
    for (final List<String> chunk in _chunks(keys)) {
      final SrsColumns c = await _readTable('term_status', <String, Object?>{
        'terms': chunk,
      });
      final SrsStringColumn term = c.strings('term_key');
      final SrsStringColumn reading = c.strings('reading_key');
      for (int i = 0; i < c.rows; i++) {
        (byKey[term[i]] ??= <(String, SrsColumns, int)>[]).add((
          reading[i],
          c,
          i,
        ));
      }
    }
    if (byKey.isEmpty) return out;
    final SrsDeckTree tree = await deckTree();
    for (final SrsTermQuery q in terms) {
      final List<(String, SrsColumns, int)>? hits = byKey[q.termKey];
      if (hits == null) continue;
      final String rk = q.readingKey;
      final List<(SrsColumns, int)> cards = <(SrsColumns, int)>[
        for (final (String reading, SrsColumns c, int i) in hits)
          if (rk.isEmpty || reading.isEmpty || reading == rk) (c, i),
      ];
      if (cards.isEmpty) continue;
      final List<SrsTermStatus> st = <SrsTermStatus>[
        for (final (SrsColumns c, int i) in cards)
          SrsTermStatus(
            cardId: c.strings('id')[i],
            noteId: c.strings('note_id')[i],
            queue: SrsQueue.parse(c.strings('queue')[i]),
            suspended: c.ints('suspended').flag(i),
            deckId: c.strings('deck_id')[i],
            cardCount: cards.length,
            dueDay: c.ints('due_day').at(i),
            dueAt: c.ints('due_at').at(i),
            byRecall: instantActiveFor(tree, c.strings('deck_id')[i]),
          ),
      ]..sort(srsTermUrgencyCompare);
      out[q.expression] = st.first;
    }
    return out;
  }

  /// 笔记缓存列表（浏览页）。
  Future<List<SrsNoteCacheRow>> listNotes({
    String? deckId,
    String? textQuery,
    int limit = 500,
    int offset = 0,
  }) async {
    List<SrsNoteCacheRow> rows = await noteRows(<String, Object?>{
      'alive': true,
      'order': 'created_desc',
      'limit': limit,
      'offset': offset,
    });
    if (deckId != null) {
      final SrsDeckTree tree = await deckTree();
      final Set<String> sub = tree.subtree(deckId).toSet();
      final Set<String> inDeck = (await cardColumnsWhere(
        const <String>['note_id'],
        <String, Object?>{'decks': sub.toList()},
      )).strings('note_id').toList().toSet();
      rows = rows.where((SrsNoteCacheRow n) => inDeck.contains(n.id)).toList();
    }
    final String? text = textQuery?.trim().toLowerCase();
    if (text != null && text.isNotEmpty) {
      rows = rows
          .where(
            (SrsNoteCacheRow n) => n.sortField.toLowerCase().contains(text),
          )
          .toList();
    }
    return rows;
  }

  /// 这些牌组里全部可见卡片的 ID（优化器训练范围）。
  /// 只读 id 列（以前整行读回再取 id）。
  Future<List<String>> cardIdsInDecks(Set<String> deckIds) async {
    if (deckIds.isEmpty) return <String>[];
    return _cardIdsWhere(<String, Object?>{
      'decks': deckIds.toList(),
      'visibleOnly': true,
    });
  }

  Future<List<SrsCardCacheRow>> cardsOfNote(String noteId) =>
      cardRowsWhere(<String, Object?>{
        'notes': <String>[noteId],
      });

  /// 待裁决笔记数（冲突角标；走 v125 的部分索引 idx_srs_notes_cache_pending，不读回行）。
  Future<int> pendingDecisionCount() async =>
      (await _read('pending_notes')).json['n']! as int;

  /// 有待裁决（内容类冲突 / 删除与并发修改）的笔记。
  Future<List<SrsNoteCacheRow>> notesPendingDecision() =>
      noteRows(const <String, Object?>{'pending': true});

  /// 一批卡 / 笔记的人读名：笔记缓存的 `sort_field`（笔记类型的排序字段——缺省第一个字段——去标签、去首尾空白，与浏览页的排序字段同口径；
  /// 卡片按所属笔记）。固定至多两条批量读（卡 → 笔记 ID、笔记 → 排序字段），不随条数增长。
  ///
  /// 冲突中心以前逐条 `cardDetail` / `note`（每条三次读 + 一次字段寄存器物化）：6950 条冲突的库上一次整页
  /// 重读要 2 万次读、63 s，常驻内存翻倍到 3.3 GB（BUG-4948）。
  ///
  /// 没有缓存行、或排序字段为空的 ID 不在结果里（调用方自己兜底，例如显示 ID）。
  Future<({Map<String, String> cards, Map<String, String> notes})>
  sortLabelsOf({
    Iterable<String> cardIds = const <String>[],
    Iterable<String> noteIds = const <String>[],
  }) async {
    final Map<String, String> noteOfCard = <String, String>{};
    final List<String> cards = cardIds.toSet().toList();
    if (cards.isNotEmpty) {
      final SrsColumns c = await cardColumnsWhere(
        const <String>['id', 'note_id'],
        <String, Object?>{'ids': cards},
      );
      final SrsStringColumn id = c.strings('id');
      final SrsStringColumn note = c.strings('note_id');
      for (int i = 0; i < c.rows; i++) {
        noteOfCard[id[i]] = note[i];
      }
    }
    final Set<String> wanted = <String>{...noteIds, ...noteOfCard.values};
    final Map<String, String> sortOf = <String, String>{};
    if (wanted.isNotEmpty) {
      final SrsColumns n = await noteColumns(
        const <String>['id', 'sort_field'],
        <String, Object?>{'ids': wanted.toList()},
      );
      final SrsStringColumn id = n.strings('id');
      final SrsStringColumn sort = n.strings('sort_field');
      for (int i = 0; i < n.rows; i++) {
        final String text = sort[i].trim();
        if (text.isNotEmpty) sortOf[id[i]] = text;
      }
    }
    return (
      cards: <String, String>{
        for (final MapEntry<String, String> e in noteOfCard.entries)
          if (sortOf[e.value] case final String text) e.key: text,
      },
      notes: <String, String>{
        for (final String id in noteIds)
          if (sortOf[id] case final String text) id: text,
      },
    );
  }

  /// 标志类 / 设置类的同步冲突（被覆盖的候选），不含机器产出（第六轮审查第 10 条）与界面状态（折叠）。
  ///
  /// 被支配的记录落库时就删了，所以一个字段键上还留着 ≥ 2 条记录的才可能有冲突：先在库里
  /// （SQLite 侧 GROUP BY）挑出这些字段键，只把它们的记录读回来解析。以前把本 profile 全部修改
  /// 记录（含每条笔记的字段正文）整表读回 UI isolate 逐条 JSON 解析，牌组列表每次重读都付一遍
  /// O(全部修改记录) 的代价（BUG-3548）。
  ///
  /// 只读标志类 / 设置类的字段键（[srsFieldClassRules]，与 [srsFieldClassOf] 同一张表）：内容类（笔记字段
  /// 正文）的并发候选不进这份清单（它们走待裁决），以前却连同正文全部读回来再丢掉。两台设备各自导入同一个
  /// 包（笔记 ID 由 guid 确定）后，每条笔记的每个字段都留着两条互不支配的记录——这条查询一次读回整库正文两遍
  /// （1.9 万张卡的库上过 GB），牌组列表的冲突角标每次重读都跑，原生分配失败闪退（BUG-3947）。
  ///
  /// 只关心一个实体（牌组设置页标「此项有同步冲突」）时传 [entity]：按
  /// `idx_srs_field_edits_profile_register` 直接定位这一个实体的记录。不传则 GROUP BY 要扫本 profile
  /// 的全部修改记录索引——两台设备各导入过同一个包的库上每条笔记的「所属牌组」都有两条记录，
  /// 1.5 万条笔记的真实库上热缓存 2.3 s、冷缓存近 10 s，牌组设置页每次打开都付一遍。
  Future<List<(SrsEntityKind, String, SrsRegister)>> syncConflicts({
    ({SrsEntityKind kind, String id})? entity,
  }) async {
    // 内核按字段类别筛、只取还留着两条以上记录的字段键（store/reads.rs `conflict_edits`）。
    final SrsColumns rows = await _readTable(
      'conflict_edits',
      <String, Object?>{
        'rules': srsFieldClassRules(_kSyncConflictClasses),
        if (entity != null) ...<String, Object?>{
          'kind': entity.kind.wire,
          'id': entity.id,
        },
      },
    );
    final SrsStringColumn k = rows.strings('k');
    final SrsStringColumn i = rows.strings('i');
    final SrsStringColumn fk = rows.strings('f');
    final SrsStringColumn j = rows.strings('j');
    final SrsIntColumn st = rows.ints('st');
    // 每个多于一条记录的字段键一组：原文 + 服务器时刻整批一次交给字段寄存器内核。
    final Map<String, (String, List<SrsEditItem>)> byReg =
        <String, (String, List<SrsEditItem>)>{};
    for (int r = 0; r < rows.rows; r++) {
      final String f = fk[r];
      (byReg['${k[r]}/${i[r]}/$f'] ??= (
        f,
        <SrsEditItem>[],
      )).$2.add(SrsEditItem.stored(j.bytes(r), st.at(r)));
    }
    final List<(String, List<SrsEditItem>)> regs = byReg.values.toList();
    final List<SrsEntityEdits> built = srsEntityEditsOf(<List<SrsEditItem>>[
      for (final (String _, List<SrsEditItem> items) in regs) items,
    ]);
    debugSyncConflictRowsRead = rows.rows;
    final List<(SrsEntityKind, String, SrsRegister)> out =
        <(SrsEntityKind, String, SrsRegister)>[];
    for (int i = 0; i < regs.length; i++) {
      final SrsRegister reg = built[i][regs[i].$1]!;
      if (reg.visibleLosers.isEmpty) continue;
      final SrsFieldEdit w = reg.winner!;
      out.add((w.entityKind, w.entityId, reg));
    }
    return out;
  }

  /// [syncConflicts] 收的字段类别：内容类走待裁决，界面状态（折叠 / 新卡位置）最后修改生效、不进冲突记录。
  static const Set<SrsFieldClass> _kSyncConflictClasses = <SrsFieldClass>{
    SrsFieldClass.flag,
    SrsFieldClass.setting,
  };

  /// 最近一次 [syncConflicts] 从库里读回的修改记录条数（测试核对内容类正文没被读回来）。
  @visibleForTesting
  int debugSyncConflictRowsRead = 0;

  /// 改回 / 确认：写一条覆盖全部候选的新修改记录。
  Future<void> resolveConflict(
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value,
  ) => runExclusive(() async {
    await _emit(<SrsEventDraft>[SrsEditDraft(kind, entityId, key, value)]);
  });

  /// 库的变化指纹：本机状态纪元 + 单调修订号。任何事件真正落库（本机写、对端同步来的、导入）都会改变它；
  /// 只读查询、被支配而丢弃的记录不会。不用 (行数, 最大 rowid)：修改记录落库时先删被支配的旧行再插新行，
  /// TEXT 主键表会复用最大 rowid，同一字段连改两次 (行数, 最大 rowid) 不变。自动备份据此判断「有没有变动」。
  Future<String> changeFingerprint() async => '$_epoch:$_revision';

  /// 从库里重读本机状态（修订号、样式去重进度、待回收媒体……），丢掉内存里的影响面。
  /// 事务回滚不回滚内存：恢复等多步写入中途失败后必须调它，否则内存里的修订号 / 影响面还是已回滚的那些写入之后的。
  /// （旧版 HLC 时钟与因果上下文在内核 / 库里，随事务一起回滚，不用重读。）
  Future<void> reloadLocal() => runExclusive(() async {
    _resetCacheJournal();
    await _loadLocal();
  });

  /// 本 profile 是否有用户笔记（铁律 E：只有内置行不算有数据）。
  Future<bool> hasUserNotes() async =>
      ((await _read('entity_count', <String, Object?>{
            'kind': SrsEntityKind.note.wire,
            'limit': 1,
          })).json['n']!
          as int) >
      0;

  /// 本 profile 有没有用户数据（[srsProfileHasUserData]：不只是笔记，自建牌组、改过的预设 / 内置笔记类型、
  /// 复习日志都算）。决定换 uid 时能不能直接采用（删旧 uid 的全部行）还是必须并入。
  Future<bool> hasUserData() => srsProfileHasUserData(core, profileUid);

  /// 本 profile（集合）的绑定状态（内核 `binding_get`，见 srs_collection_binding.dart）；没有记录为 null。
  Future<SrsCollectionBinding?> collectionBinding() async =>
      SrsCollectionBinding.fromJson(
        (await sync2Command(const <String, Object?>{
          'op': 'binding_get',
        })).map['binding'],
      );

  /// 写本 profile 的绑定状态（内核 `binding_set`：只进不退，已定下的不改），返回写完之后的状态。
  Future<SrsCollectionBinding?> setCollectionBinding(
    SrsCollectionBindingState state, {
    required String via,
  }) async => SrsCollectionBinding.fromJson(
    (await sync2Command(<String, Object?>{
      'op': 'binding_set',
      'state': state.wire,
      'via': via,
      'now': now().$1,
    })).map['binding'],
  );

  /// 本 profile 的用户笔记数（铁律 E：内置行不算）。profile 冲突时给用户对比本机与候选（反馈 dOv8AdJ6yV）。
  Future<int> userNoteCount() async =>
      (await _read('entity_count', <String, Object?>{
            'kind': SrsEntityKind.note.wire,
          })).json['n']!
          as int;

  // ------------------------------------------------------------------ SrsSyncReplica

  /// 并入一批外来、已盖过戳的事件（备份合并、旧格式 `.fushisrs` 备份导入）：保留原 dot / 因果上下文 / HLC
  /// （Rust `apply` 的 stamped 路径），按 ID 取并集、修改记录走支配判定，一个事务、一次缓存刷新。
  /// [serverTimes] = 逐事件的服务器时间 S(e)（旧备份的 `server_times.json`；排序键），没有的取 [serverTimeMs]。
  Future<void> applyRemote(
    List<SrsEvent> events, {
    int? serverTimeMs,
    Map<String, int>? serverTimes,
  }) => runExclusive(() async {
    final (int nowMs, _) = now();
    final List<SrsEvent> mine = <SrsEvent>[
      for (final SrsEvent e in events)
        if (e is! SrsEntityEvent || e.record.profileUid == profileUid) e,
    ];
    final Map<String, String> noteOf = await _logNotesOf(
      mine,
      const <String, String>{},
    );
    final List<Map<String, Object?>> input = <Map<String, Object?>>[];
    for (final SrsEvent e in mine) {
      final SrsEvent stored = await _compactEvent(e);
      final int? server = serverTimes?[stored.id] ?? serverTimeMs;
      input.add(<String, Object?>{
        'e': stored.toJson(),
        'note': stored is SrsLogEvent ? noteOf[stored.log.cardId] : null,
        // 外来、已盖戳的事件：保留原 dot / 因果上下文 / HLC，支配关系照旧。
        'stamped': true,
        // S(e)：排序键，也是旧版时钟收这条事件时钳位用的服务器时间。
        'server': ?server,
        // 旧版时钟按收到对端事件的规则推进（先钳位），与命令同一笔事务：命令失败时钟不动。
        'clk': 'r',
      });
    }
    await _commandOrReload(() async {
      // `remote`：这批是别的设备的事件（同步合并），落了就带动牌组 / 全局状态，RWKV 分数表要整表重查一次
      // （[rwkvScoresKey]）。
      await _applyLocal(input, recvNow: nowMs, remote: true);
    });
  });

  /// 一条本机写命令（[body] 发命令、把结果接进内存）；失败时从库里重读本机状态再抛出。
  ///
  /// 内核在命令的同一个 SAVEPOINT 里做完命令本体、缓存刷新、排队与本机状态行
  /// （native/fushi_fsrs/src/store/gen4/dispatch.rs `local_write`），要么全落、要么全不落。收段通道没做完时内核在命令之前先把它
  /// 按片做完，每片提交时内核推进刷新键（[contentFingerprint] 等）。
  ///
  /// 命令失败不回滚内存：攒下的影响面要丢掉、修订号等从库里重读（与 [reloadLocal] 同一理由）。调用方已在独占区里。
  ///
  /// 抛出的永远是命令本身的错误。重读也失败（典型是连接已经关了：app 退出时同步还在跑）时，
  /// 内存状态已无从与库对齐：副本标为作废（[_unusable]），之后的写入一律明确失败，不在过期的
  /// 本机状态上继续写；也不拿重读的错误顶替原错误——以前日志里只剩 `_loadLocal` 上的
  /// 「connection was closed」，看不出是哪一步写失败。
  Future<void> _commandOrReload(Future<void> Function() body) async {
    try {
      await body();
    } catch (error, stack) {
      _resetCacheJournal();
      try {
        await _loadLocal();
      } on Object catch (reloadError) {
        _unusable = StateError(
          'SRS store is unusable: reloading local state after a failed '
          'write failed ($reloadError); original error: $error',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// 写失败后重读本机状态也失败时置上（见 [_commandOrReload]）；之后进独占区的写入都抛它。
  StateError? _unusable;

  /// 改投影的命令的回包：先核对内核写下的修订号与纪元（`localRevision` / `localEpoch`）在，再把投影变化接进内存
  /// （[_absorbProjection]）。修订号与纪元以内核写下的为准——内核在命令的同一笔事务里从**库里的值**推进
  /// （native/fushi_fsrs/src/store/local_state.rs `persist_projected`），所以指向同一个 profile 的两个副本对象交替写也不会
  /// 把修订号写回去。返回落进投影的事件数。
  ///
  /// 两个键缺任何一个都是契约错误（原生库与 Dart 不配套、或某条命令漏接了本机状态行）：在动内存之前抛出，不静默沿用
  /// 内存里的值——那样库里的本机状态行没写、内存却照常前进，下次开库修订号回退。
  /// 测试：[_absorbLocalWrite]（回包缺 `localRevision` / `localEpoch` 时报契约错误、不动内存）。
  @visibleForTesting
  int debugAbsorbLocalWrite(Map<String, Object?> r) => _absorbLocalWrite(r);

  int _absorbLocalWrite(Map<String, Object?> r) {
    final Object? revision = r['localRevision'];
    final Object? epoch = r['localEpoch'];
    if (revision is! int || epoch is! String) {
      throw StateError(
        'srs: a projecting command reply lacks `localRevision` / `localEpoch` '
        '(the native core did not write the local state row)',
      );
    }
    final int landed = _absorbProjection(r);
    _adoptRevision(revision, epoch);
    return landed;
  }

  /// 副本还能写（没有被 [retire]、也没有因重读失败作废）。
  bool get isUsable => _unusable == null;

  /// 当前代码正跑在本副本的独占区里（[runExclusive] 的 body 内，按 Zone 认）。
  bool get holdsExclusive => identical(Zone.current[_writeZoneKey], this);

  Future<List<SrsEvent>> exportAll() => _exportEvents(null);

  /// 本 profile 的全部身份记录与修改记录（[exportAll] 去掉复习日志与不认识的事件）。按时间点恢复
  /// 改回字段只要这两类；日志是库里最大的一块，不必整份读回来逐条解码。
  Future<List<SrsEvent>> exportEntitiesAndEdits() =>
      _exportEvents(const <String>['entities', 'edits']);

  /// 本 profile 的全部事件（`read` 的 `events`；[parts] 为 null = 四张表都要），按身份记录、修改记录、复习日志、
  /// 不认识的事件的顺序。
  Future<List<SrsEvent>> _exportEvents(List<String>? parts) async {
    final Map<String, SrsColumns> t = (await _read('events', <String, Object?>{
      'parts': ?parts,
    })).tables;
    final List<SrsEvent> out = <SrsEvent>[];
    final SrsColumns? entities = t['entities'];
    if (entities != null) {
      for (final _EntityRow r in _entityRowsOf(entities)) {
        out.add(SrsEntityEvent(_entityFromRow(r)));
      }
    }
    Iterable<Map<String, Object?>> jsons(String name) sync* {
      final SrsColumns? c = t[name];
      if (c == null) return;
      final SrsStringColumn json = c.strings('json');
      for (int i = 0; i < c.rows; i++) {
        yield (jsonDecode(json[i]) as Map).cast<String, Object?>();
      }
    }

    for (final Map<String, Object?> m in jsons('edits')) {
      out.add(SrsEditEvent(SrsFieldEdit.fromJson(m)));
    }
    for (final Map<String, Object?> m in jsons('logs')) {
      out.add(SrsLogEvent(SrsReviewLog.fromJson(m)));
    }
    for (final Map<String, Object?> m in jsons('unknown')) {
      out.add(SrsUnknownEvent(m));
    }
    return out;
  }

  /// [cardIds] 各自的复习日志（解码好的；没有日志的卡不出现）。
  Future<Map<String, List<SrsReviewLog>>> logsOfCards(
    Iterable<String> cardIds,
  ) async {
    final Map<String, List<SrsReviewLog>> out = <String, List<SrsReviewLog>>{};
    for (final List<String> chunk in _chunks(cardIds)) {
      final SrsColumns c = await _readTable('logs', <String, Object?>{
        'cards': chunk,
      });
      final SrsStringColumn card = c.strings('card_id');
      final SrsStringColumn json = c.strings('json');
      for (int i = 0; i < c.rows; i++) {
        (out[card[i]] ??= <SrsReviewLog>[]).add(
          SrsReviewLog.fromJson(
            (jsonDecode(json[i]) as Map).cast<String, Object?>(),
          ),
        );
      }
    }
    return out;
  }

  /// 卡片的「前身 → 后继」链接（更改笔记类型 / Lapis 迁移的 historyFrom 修改记录，只扫部分索引）。
  Future<Map<String, List<String>>> successorIndex() => _successorIndex();

  /// 同步成功拿到服务器时间后校时。[observedAtBootMs] 见 [SrsTrustedClock.anchor]。
  Future<void> anchorTime(int serverTimeMs, {required int observedAtBootMs}) =>
      runExclusive(() async {
        _trusted.anchor(
          serverTimeMs: serverTimeMs,
          observedAtBootMs: observedAtBootMs,
        );
        // 内核写进本机状态行（`local_anchor`；没有行就建）。校时之后 [_anchorArg] 必不为空。
        await _sync2(<String, Object?>{
          'op': 'local_anchor',
          'anchor': _anchorArg(),
        });
      });

  /// 覆盖恢复备份（或采用了别处的 profile 身份）后调用：按库里的事实重建缓存，存量样式去重从头再查。
  ///
  /// 同步 v2 的本机身份不进备份（快照剥掉 `sync2_self`），恢复出来的库打开时就是一台新设备；旧身份按普通
  /// 远端设备续收（设计 §7.3）。所以这里不需要换化身、重新发布。[freshIncarnation] 只为兼容旧调用方保留。
  Future<void> afterRestore({bool freshIncarnation = false}) => rebuildCaches();

  /// 本 profile 的卡片缓存行按列（内核 `card_columns`，native/fushi_fsrs/src/store/bulk.rs）：只读快照里一次读完，
  /// 列式字节经 [TransferableTypedData] 从 worker 原样交过来，不再解码成行对象、再 SendPort 深拷贝。
  /// [fields] 限定要哪几列（缓存表列名，如 `id` / `note_id` / `deck_id`；缺省全部）；[visibleOnly] 只要可见卡。
  Future<SrsColumns> cardColumns({
    List<String>? fields,
    bool visibleOnly = false,
  }) async => (await _columnsCommand(<String, Object?>{
    'op': 'card_columns',
    'fields': ?fields,
    if (visibleOnly) 'visibleOnly': true,
  })).tables['columns']!;

  /// 统计命令（内核 native/fushi_fsrs/src/store/stats.rs）：`stats_report` 一次范围 / 牌组的全部聚合、
  /// `stats_recall` 按 RWKV 回忆率排队的复习卡、`stats_rows` 归一化后的逐卡视图（只给回归向量）、`stats_release`
  /// 丢掉内核缓存的统计原料。在后台 isolate 跑；口径与用法见 `loadSrsStats`。
  Future<Map<String, Object?>> statsCommand(Map<String, Object?> request) {
    if (!_kStatsOps.contains(request['op'])) {
      throw ArgumentError.value(request['op'], 'op', 'not a stats command');
    }
    return _sync2(request);
  }

  static const Set<String> _kStatsOps = <String>{
    'stats_report',
    'stats_recall',
    'stats_rows',
    'stats_release',
  };

  /// 本 profile 的全部卡片缓存行（含隐藏）。由 [cardColumns] 组装；只要几列的调用方直接用 [cardColumns]。
  Future<List<SrsCardCacheRow>> allCardRows() async =>
      _cardRowsOf(await cardColumns());

  /// AnkiConnect 整数笔记 id（[SrsIds.ankiNumericId]）→ noteId；没有这条笔记为 null。
  ///
  /// 内核按缓存表的 `anki_id` 列（srs.db v13，写缓存行时算好、建了索引）直接反查（`anki_resolve`）。以前这里在
  /// Dart 里整表读笔记缓存与卡片缓存、批量算一遍 hash53，常驻两张 int → UUID 映射，缓存整体换掉后再整表回填。
  Future<String?> noteIdForAnkiNumericId(int ankiId) async =>
      (await noteIdsForAnkiNumericIds(<int>[ankiId])).single;

  /// AnkiConnect 整数卡片 id → cardId（同 [noteIdForAnkiNumericId]）。
  Future<String?> cardIdForAnkiNumericId(int ankiId) async =>
      (await cardIdsForAnkiNumericIds(<int>[ankiId])).single;

  /// [noteIdForAnkiNumericId] 的成批版本（按输入顺序），一次内核命令。
  Future<List<String?>> noteIdsForAnkiNumericIds(List<int> ankiIds) =>
      _ankiResolve('notes', ankiIds);

  /// [cardIdForAnkiNumericId] 的成批版本（按输入顺序），一次内核命令。
  Future<List<String?>> cardIdsForAnkiNumericIds(List<int> ankiIds) =>
      _ankiResolve('cards', ankiIds);

  /// AnkiConnect `notesInfo` 要的笔记内容（按输入顺序；查不到 / 已删除的为 null）：内核 `anki_notes_info`
  /// （native/fushi_fsrs/src/store/bulk.rs）在只读快照上一次读完数字 id 反查、笔记物化与可见卡，只交回要用的值。
  /// 字段值是落库表示（样式引用没展开，见 [expandStylesAll]）。
  Future<List<SrsAnkiNoteInfo?>> ankiNotesInfo(List<int> ankiIds) async {
    if (ankiIds.isEmpty) return const <SrsAnkiNoteInfo?>[];
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      'op': 'anki_notes_info',
      'notes': ankiIds,
    });
    return <SrsAnkiNoteInfo?>[
      for (final Object? n in r['notes']! as List)
        n == null
            ? null
            : SrsAnkiNoteInfo._fromKernel((n as Map).cast<String, Object?>()),
    ];
  }

  Future<List<String?>> _ankiResolve(String kind, List<int> ankiIds) async {
    if (ankiIds.isEmpty) return const <String?>[];
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      'op': 'anki_resolve',
      kind: ankiIds,
    });
    return <String?>[for (final Object? id in r[kind]! as List) id as String?];
  }

  // ------------------------------------------------------------------ 缓存变更日志

  /// 缓存行的变化代号：每次 [_absorbProjection] 写入 +1，缓存被整体换掉（[_resetCacheJournal]）也 +1。
  /// 只在本对象内单调；跨对象 / 跨进程不可比。
  int _cacheGeneration = 0;

  /// [_cacheJournal] 还能完整回答的最小代号：比它旧的代号问 [cacheChangesSince] 得 null。
  int _cacheJournalFloor = 0;

  /// (代号, 写过缓存行的笔记, 写过缓存行的卡)，按代号升序。
  final List<(int, List<String>, List<String>)> _cacheJournal =
      <(int, List<String>, List<String>)>[];
  int _cacheJournalIds = 0;

  /// 日志最多留多少个 ID（超了丢最旧的，更旧的代号只能整份重读）。
  static const int _kCacheJournalMaxIds = 100000;

  /// 缓存行的当前变化代号（见 [cacheChangesSince]）。
  int get cacheGeneration => _cacheGeneration;

  /// 代号 [generation] 之后写过缓存行的笔记与卡（同一实体可能出现在两边）。null = 日志已经答不了
  /// （缓存整体换过、事务回滚重读过本机状态，或日志滚掉了这段）：调用方要整份重读。
  ///
  /// 常驻视图（AnkiConnect 兼容层）据此只重读变了的那些笔记 / 卡，不再每次请求整库重物化。
  /// 缓存行只经 [_absorbProjection] 写，所以导入、同步、编辑、复习、更改笔记类型都在这里留痕。
  ({Set<String> notes, Set<String> cards})? cacheChangesSince(int generation) {
    if (generation > _cacheGeneration || generation < _cacheJournalFloor) {
      return null;
    }
    final Set<String> notes = <String>{};
    final Set<String> cards = <String>{};
    for (int i = _cacheJournal.length - 1; i >= 0; i--) {
      final (int gen, List<String> n, List<String> c) = _cacheJournal[i];
      if (gen <= generation) break;
      notes.addAll(n);
      cards.addAll(c);
    }
    return (notes: notes, cards: cards);
  }

  void _journalCacheWrite(List<String> noteIds, List<String> cardIds) {
    _cacheGeneration++;
    _cacheJournal.add((_cacheGeneration, noteIds, cardIds));
    _cacheJournalIds += noteIds.length + cardIds.length;
    while (_cacheJournalIds > _kCacheJournalMaxIds &&
        _cacheJournal.isNotEmpty) {
      final (int gen, List<String> n, List<String> c) = _cacheJournal.removeAt(
        0,
      );
      _cacheJournalIds -= n.length + c.length;
      _cacheJournalFloor = gen;
    }
  }

  /// 缓存行被整体换掉 / 内存与库可能不一致：日志作废（旧代号一律答 null）。
  void _resetCacheJournal() {
    _cacheGeneration++;
    _cacheJournal.clear();
    _cacheJournalIds = 0;
    _cacheJournalFloor = _cacheGeneration;
  }
}

/// 复习页的一次排队（[SrsDbStore.studyState]）：所点牌组（含子树）的计数、下一张、排除下一张之后的再下一张。
class SrsStudyState {
  const SrsStudyState({
    required this.summary,
    required this.next,
    required this.after,
    this.custom,
  });

  final SrsDeckSummary summary;

  /// 自定义学习会话的进度（只在按 [SrsCustomStudy] 排队时有）。
  final SrsCustomStudyProgress? custom;

  /// 下一张；null = 今天这棵子树没有可出的卡。
  final String? next;

  /// 排除 [next] 之后的下一张（预取的猜测：真正的下一张仍以评分后的排队为准）。
  final String? after;

  /// 子树里有 RWKV 牌组而 RWKV 还没准备好（下载 / 回放 / 出错）：这些牌组的复习卡这一次一张没出，等就绪后
  /// 再排一次。[next] 为 null 时界面据此说「等 RWKV」，不说「今天复习完了」。与 [summary] 的同名标志同源。
  bool get rwkvPending => summary.rwkvPending;
}

/// 单次作答记入日志的最长用时（与 Anki「最长作答秒数」默认 60 秒同口径）：走神、切出去之类的长停顿
/// 不该把复习用时统计撑爆。本机复习页与远程复习库主机端（srs_remote_store.dart）共用。
const int kSrsMaxAnswerDurationMs = 60000;

/// [SrsDbStore.answerAndStudy] 拒绝作答：这张卡出题之后已在别处被复习过（只有远程复习库会抛——
/// 本机库没有「出题之后」这一说）。没记日志；调用方跳过这张、重新排队。
class SrsCardChangedError implements Exception {
  const SrsCardChangedError(this.cardId);

  final String cardId;

  @override
  String toString() => 'SrsCardChangedError($cardId)';
}

/// 一次 `apply` 命令（[SrsDbStore._applyLocal]）的结果：落进投影的事件数，与每项落库用的戳（没要就是空的；日志 = 它的
/// HLC 字符串，修改记录 = 投影行，其余 null）。
final class _Applied {
  const _Applied(this.landed, [this.reply = const <String, Object?>{}]);

  /// `apply` 的前置条件（`expectLast`）不成立：什么都没落（按同一个对象判）。
  static const _Applied stale = _Applied(0);

  final int landed;

  /// 内核的回包（`edits` / `tagWrites` / `logHlcs` 按输入下标读，见 [SrsDbStore._writtenEdits]）。
  final Map<String, Object?> reply;
}

/// 一次本机手动排程命令（[SrsDbStore._schedLocal]）的结果：落库后的日志行与撤不了的条数。
final class _SchedOutcome {
  const _SchedOutcome(this.logs, this.blocked);

  final List<SrsReviewLog> logs;
  final int blocked;
}

/// [SrsDbStore.answerAndStudy] 的结果：写出的日志（撤销栈用）与评分之后的排队（没要求排队时 null）。
class SrsAnswerOutcome {
  const SrsAnswerOutcome(this.log, this.study);

  final SrsReviewLog log;
  final SrsStudyState? study;
}

/// RWKV-Instant 一张候选复习卡与它的上次作答时刻（同日间隔守卫用）。
typedef _RwkvCandidate = ({SrsRwkvCandidate card, int? lastReviewedAt});

/// 一次 `preview` 命令的原始结果：卡所属笔记、有效牌组，以及发出时的此刻 / 日界。
typedef _PreviewRaw = ({
  Map<String, Object?> r,
  String note,
  String deck,
  int nowMs,
  SrsTimeSource source,
  SrsDayContext day,
});

/// 一条身份记录（`read` 的 `entities`）。
typedef _EntityRow = ({String id, String kind, String payloadJson});

/// 一次批量读的预读（见 [SrsDbStore._readWith]）：只在那次读的 Zone 里可见。
/// 各 Map 里「有键」= 已预读（值可能为空 / null）；没键的照常查库。
class _RefreshPrefetch {
  static final Object zoneKey = Object();

  static _RefreshPrefetch? get current =>
      Zone.current[zoneKey] as _RefreshPrefetch?;

  final Map<String, _EntityRow?> entities = <String, _EntityRow?>{};

  /// `<kind>/<entityId>` → 修改记录原文 + 服务器时刻（[SrsDbStore._prefetchEdits]）。
  final Map<String, List<SrsEditItem>> edits = <String, List<SrsEditItem>>{};

  /// 卡 → 它的复习日志原文（canonical JSON；[SrsDbStore._prefetchLogs]）。
  final Map<String, List<String>> logsByCard = <String, List<String>>{};

  final Map<String, int> serverTimes = <String, int>{};
  final Set<String> serverTimesKnown = <String>{};
}

// ------------------------------------------------------------------ 内核命令的后台 isolate 入口
//
// 都在常驻 worker 池里执行（srs_core_workers.dart：符号只解析一次，不再每条命令起一个 isolate）。写成顶层
// 函数：闭包只捕获句柄地址与入参（都可发送）——闭包写在实例方法里会连带捕获 `this`（SrsDbStore 里有
// Future 等不可发送的对象），发送当场抛「object is unsendable」。

Future<Uint8List> _coreOptimizerItems(
  int address,
  String? libraryPath,
  String profile,
  List<List<String>> groups,
  List<int> cardIds,
  int algorithm,
  int utcOffsetMin,
  int rolloverHour,
) => SrsOpLedger.track(
  'core:optimizer_items',
  () => SrsCoreWorkers.of(libraryPath).run<Uint8List>(
    address,
    (SrsCore c) => c.optimizerItems(
      groups,
      cardIds,
      algorithm: algorithm,
      utcOffsetMin: utcOffsetMin,
      rolloverHour: rolloverHour,
      profile: profile,
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<Uint8List> _coreCalibrationItems(
  int address,
  String? libraryPath,
  String profile,
  List<List<String>> groups,
  List<int> cardIds,
  int algorithm,
  int utcOffsetMin,
  int rolloverHour,
) => SrsOpLedger.track(
  'core:calibration_items',
  () => SrsCoreWorkers.of(libraryPath).run<Uint8List>(
    address,
    (SrsCore c) => c.calibrationItems(
      groups,
      cardIds,
      algorithm: algorithm,
      utcOffsetMin: utcOffsetMin,
      rolloverHour: rolloverHour,
      profile: profile,
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<Uint8List> _coreRwkvCards(
  int address,
  String? libraryPath,
  String profile,
  List<List<String>> groups,
  List<int> ids,
  int utcOffsetMin,
  int rolloverHour,
) => SrsOpLedger.track(
  'core:rwkv_cards',
  () => SrsCoreWorkers.of(libraryPath).run<Uint8List>(
    address,
    (SrsCore c) => c.rwkvCards(
      groups,
      ids,
      utcOffsetMin: utcOffsetMin,
      rolloverHour: rolloverHour,
      profile: profile,
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<TransferableTypedData> _coreRwkvReplay(
  int address,
  String? libraryPath,
  String profileUid,
  List<List<String>> groups,
  List<int> ids,
  int utcOffsetMin,
  int rolloverHour,
  int since,
  int? rebaseSince,
  int? rowsFrom,
) => SrsOpLedger.track(
  'core:rwkv_replay',
  () => SrsCoreWorkers.of(libraryPath).run<TransferableTypedData>(
    address,
    (SrsCore c) => c.rwkvReplay(
      profileUid,
      groups,
      ids,
      utcOffsetMin: utcOffsetMin,
      rolloverHour: rolloverHour,
      since: since,
      rebaseSince: rebaseSince,
      rowsFrom: rowsFrom,
    ),
  ),
);

Future<Uint8List> _coreRwkvLogTail(
  int address,
  String? libraryPath,
  String profileUid,
  int since,
  bool withRows,
  bool incremental,
) => SrsOpLedger.track(
  'core:rwkv_log_tail',
  () => SrsCoreWorkers.of(libraryPath).run<Uint8List>(
    address,
    (SrsCore c) => c.rwkvLogTail(
      profileUid,
      since: since,
      withRows: withRows,
      incremental: incremental,
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<(Object?, Map<String, TransferableTypedData>)> _coreColumns(
  int address,
  String? libraryPath,
  Map<String, Object?> request,
) => SrsCoreWorkers.of(libraryPath)
    .run<(Object?, Map<String, TransferableTypedData>)>(address, (SrsCore c) {
      final SrsSync2Result r = c.sync2(request);
      return (
        r.json,
        <String, TransferableTypedData>{
          for (final (String name, Uint8List bytes) in r.files)
            name: TransferableTypedData.fromList(<TypedData>[bytes]),
        },
      );
    });

Future<SrsSync2Result> _coreSync2(
  int address,
  String? libraryPath,
  Map<String, Object?> request,
  List<Uint8List> blobs, {
  SrsCoreLane lane = SrsCoreLane.bulk,
}) => SrsCoreWorkers.of(libraryPath).run<SrsSync2Result>(
  address,
  (SrsCore c) => c.sync2(request, blobs: blobs),
  lane: lane,
);

/// [SrsDbStore._noteTypeCache] 的一份：[key] 下物化过的笔记类型（含已删除的；不存在的 ID 记 null）与
/// [SrsDbStore.noteTypes] 的整份列表（没算过 = null）。
final class _NoteTypeCache {
  _NoteTypeCache(this.key);

  final String key;
  final Map<String, SrsNoteTypeView?> byId = <String, SrsNoteTypeView?>{};
  List<SrsNoteTypeView>? all;
}

/// [SrsDbStore.ankiNotesInfo] 的一项：一条未删除笔记的 AnkiConnect `notesInfo` 原料。
class SrsAnkiNoteInfo {
  const SrsAnkiNoteInfo({
    required this.id,
    required this.noteTypeId,
    required this.tags,
    required this.fields,
    required this.cards,
  });

  factory SrsAnkiNoteInfo._fromKernel(Map<String, Object?> m) =>
      SrsAnkiNoteInfo(
        id: m['id']! as String,
        noteTypeId: m['nt']! as String,
        tags: <String>[for (final Object? t in m['t']! as List) t! as String],
        // 与 SrsNoteView 同：同一字段 ID 出现两次时后者为准。
        fields: <String, String>{
          for (final List<Object?> f in (m['f']! as List).cast<List<Object?>>())
            f[0]! as String: f[1]! as String,
        },
        cards: <({int num, String templateId, int clozeOrd})>[
          for (final List<Object?> c in (m['c']! as List).cast<List<Object?>>())
            (
              num: c[0]! as int,
              templateId: c[1]! as String,
              clozeOrd: c[2]! as int,
            ),
        ],
      );

  /// 笔记 ID（UUID）。
  final String id;
  final String noteTypeId;
  final List<String> tags;

  /// 字段 ID → 值（落库表示）。
  final Map<String, String> fields;

  /// 可见卡：AnkiConnect 数字 id、模板 ID、cloze 序号（未排序）。
  final List<({int num, String templateId, int clozeOrd})> cards;

  /// 同 [SrsNoteView.field]：没有 = 空串。
  String field(String fieldId) => fields[fieldId] ?? '';
}

/// [profileUid] 在 srs.db 里有没有用户数据（铁律 E 的「有数据」，决定换 uid 时能直接采用还是必须并入）：
///
/// - 内置 ID 集合（[srsBuiltinEntities]：内置默认牌组与内置笔记类型）之外的任何实体——笔记、自建牌组、自建笔记类型、
///   profile 实体，含已删的墓碑；
/// - 任何修改记录：没改过的内置定义不写修改记录（[SrsDbStore.ensureBuiltins]），所以改过内置牌组的预设 / 内置笔记
///   类型 / 日界都会留下一条；
/// - 任何复习日志、看不懂的事件（更新版本写的，同样是用户数据）。
///
/// 只有内置行 = 没有。以前只看笔记（[SrsDbStore.hasUserNotes]），只建了牌组 / 改了预设、还没有笔记的 profile 会被
/// 当成空的直接采用对方 uid，删掉这些数据。
Future<bool> srsProfileHasUserData(SrsCore core, String profileUid) async =>
    (await srsRead(core, profileUid, 'has_user_data', <String, Object?>{
      'builtins': <String>[
        for (final SrsEntityRecord r in srsBuiltinEntities(profileUid)) r.id,
      ],
    })).json['any'] ==
    true;

/// 标签撤销的差量（OR-Set，见 srs_edit_undo.dart）：这次加上的（[after] 有、[before] 没有）现在还在就去掉，
/// 这次去掉的（[before] 有、[after] 没有）现在还没有就加回；别的标签（含别人之后加 / 删的）原样。比较不分大小写，
/// 与浏览页加 / 删标签一致。顺序：[before] 里有的按 [before] 的顺序，其余（别人之后加的）按现在的顺序排在后面。
List<String> srsRevertTagDelta({
  required List<String> current,
  required List<String> before,
  required List<String> after,
}) {
  String low(String t) => t.toLowerCase();
  final Set<String> beforeLow = <String>{for (final String t in before) low(t)};
  final Set<String> afterLow = <String>{for (final String t in after) low(t)};
  final Set<String> added = afterLow.difference(beforeLow);
  final Map<String, String> kept = <String, String>{
    for (final String t in current)
      if (!added.contains(low(t))) low(t): t,
  };
  for (final String t in before) {
    if (!afterLow.contains(low(t))) kept.putIfAbsent(low(t), () => t);
  }
  final List<String> next = <String>[];
  for (final String t in before) {
    final String? k = kept.remove(low(t));
    if (k != null) next.add(k);
  }
  next.addAll(kept.values);
  return next;
}

/// [SrsDbStore.undoable] 的录制器：按字段键记改前值（第一次写之前从库读）、改后值与内核分配的 dot（最后一次写）。
class _SrsUndoRecorder {
  _SrsUndoRecorder(this.store);

  final SrsDbStore store;

  /// 改前值，键 `<kind>/<id>/<key>`（只读一次：同一键在一次操作里写几次，撤销回到第一次之前）。
  final Map<String, Object?> _before = <String, Object?>{};

  /// 已写下的键（插入顺序 = 第一次写的顺序）。
  final Map<String, SrsEditUndoItem> _items = <String, SrsEditUndoItem>{};

  static String _key(SrsEntityKind kind, String id, String key) =>
      '${kind.wire}/$id/$key';

  /// 落库之前：读下还没记过改前值的键此刻的生效值。
  Future<void> noteBefore(List<(SrsEntityKind, String, String)> keys) async {
    final List<(SrsEntityKind, String, String)> missing =
        <(SrsEntityKind, String, String)>[
          for (final (SrsEntityKind k, String id, String f) in keys)
            if (!_before.containsKey(_key(k, id, f))) (k, id, f),
        ];
    if (missing.isEmpty) return;
    _before.addAll(await store._currentValues(missing));
  }

  /// 改前值已由内核在写锁里核对过的键（条件写 `note_fields_if`：现值 == 期望值才写）：[edits] 里写下的那些直接记
  /// [known] 给的改前值，不再从库读；没写下的不记（它的期望值未必是现值）。
  void noteKnownBefore(
    Map<(SrsEntityKind, String, String), Object?> known,
    List<Object?> edits,
  ) {
    for (final Object? raw in edits) {
      if (raw is! List || raw.length < 3) continue;
      final SrsEntityKind? kind = SrsEntityKind.tryParse(raw[0] as String?);
      final Object? id = raw[1], key = raw[2];
      if (kind == null || id is! String || key is! String) continue;
      final (SrsEntityKind, String, String) at = (kind, id, key);
      if (!known.containsKey(at)) continue;
      _before.putIfAbsent(_key(kind, id, key), () => known[at]);
    }
  }

  /// 落库之后：内核报告的 `edits`（`[种类, 规范实体, 规范字段键, 设备, 序号, 值, 输入下标]`，
  /// native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」）。
  ///
  /// [byInput]：第 i 条输入点名的 (种类, 实体, 字段键)（请求形，[noteBefore] 按它记的改前值）。回包里带输入下标的项
  /// 按它认领：草稿点名别名类的非规范成员时，回包里的实体 / 键是规范形，按 (种类, 实体, 字段键) 对不上 `_before`，
  /// 这一项的 dot 就记不下（撤销退回无 dot 的比较）。没有输入下标的项（意图命令自己拼的、调用方没给 [byInput]）
  /// 仍按回包里的 (种类, 实体, 字段键) 对。
  void noteWritten(
    List<Object?> edits, {
    Map<int, (SrsEntityKind, String, String)> byInput =
        const <int, (SrsEntityKind, String, String)>{},
  }) {
    for (final Object? raw in edits) {
      if (raw is! List || raw.length < 6) continue;
      final Object? at = raw.length > 6 ? raw[6] : null;
      final Object? w = raw[3], s = raw[4];
      final (SrsEntityKind, String, String)? named = at is int
          ? byInput[at]
          : null;
      final SrsEntityKind? kind =
          named?.$1 ?? SrsEntityKind.tryParse(raw[0] as String?);
      final Object? id = named?.$2 ?? raw[1], key = named?.$3 ?? raw[2];
      if (kind == null || id is! String || key is! String) continue;
      final String k = _key(kind, id, key);
      if (!_before.containsKey(k)) continue;
      _put(
        k,
        SrsEditUndoItem(
          kind: kind,
          entityId: id,
          key: key,
          before: _before[k],
          after: raw[5],
          writer: w is String ? w : null,
          seq: s is int ? s : null,
        ),
      );
    }
  }

  /// 整列表标签（内核展开成 OR-Set 操作、不报 dot）：按差量撤，只记改后的列表。
  void noteTags(String noteId, Object? after) {
    final String k = _key(SrsEntityKind.note, noteId, SrsFieldKeys.noteTags);
    if (!_before.containsKey(k)) return;
    _put(
      k,
      SrsEditUndoItem(
        kind: SrsEntityKind.note,
        entityId: noteId,
        key: SrsFieldKeys.noteTags,
        before: _before[k],
        after: after,
      ),
    );
  }

  void _put(String k, SrsEditUndoItem item) {
    final SrsEditUndoItem? first = _items[k];
    _items[k] = first == null
        ? item
        : first.withAfter(item.after, writer: item.writer, seq: item.seq);
  }

  /// 内层 [SrsDbStore.undoable] 记下的并进来。
  void absorb(SrsEditUndo inner) {
    for (final SrsEditUndoItem i in inner.items) {
      final String k = _key(i.kind, i.entityId, i.key);
      _before.putIfAbsent(k, () => i.before);
      _put(k, i);
    }
  }

  SrsEditUndo result() => SrsEditUndo(_items.values.toList());
}

/// 修改键里嵌的实体 ID（`f/<字段>`、`fieldDef/<…>`、`fieldDesc/<…>`、`tmplDef/<…>`、`historyFrom/<卡>`）：返回
/// (前缀, ID)；不是这几种、或后面不是规范形状的 UUID 文本 = null。与内核 `Index::canonical_key` 归一的是同一组键
/// （native/fushi_fsrs/src/store/gen4/alias.rs）。
@visibleForTesting
(String, String)? srsKeyEmbeddedId(String key) {
  final RegExpMatch? m = _srsKeyWithId.firstMatch(key);
  return m == null ? null : (m.group(1)!, m.group(2)!);
}

final RegExp _srsKeyWithId = RegExp(
  r'^(f/|fieldDef/|fieldDesc/|tmplDef/|historyFrom/)'
  r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
);

/// 按实体出行的读（`entities` / `edits`）把行对回请求里的 ID（G9-7）：[byCanonical] 按规范 ID 分组，[reply] 的 `canon`
/// 是请求里别名成员的 ID → 规范 ID（native/fushi_fsrs/src/store/gen4/cmd/reads.rs `single_echo`，只列不同的）。
/// [ids] 不是列表（请求没带 `ids`）或 `canon` 表为空时原样返回（此时行的键就是请求里的 ID）；否则按请求 ID 一一对回，
/// 读不到的不出现。
@visibleForTesting
Map<String, T> srsRowsByRequest<T>(
  Map<String, T> byCanonical,
  Object? ids,
  Map<String, Object?> reply,
) {
  final Object? canon = reply['canon'];
  if (ids is! List || canon is! Map || canon.isEmpty) return byCanonical;
  final Map<String, T> out = <String, T>{};
  for (final Object? id in ids) {
    if (id is! String) continue;
    final Object? c = canon[id];
    final T? v = byCanonical[c is String ? c : id];
    if (v != null) out[id] = v;
  }
  return out;
}

/// `apply` 回包的 `entityWrites`（`[输入下标, 种类, 规范实体 ID]`，native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头
/// 「回包」）按输入下标认领：返回长 [inputs] 的列表，第 i 项是第 i 条输入（身份记录）落下的规范实体 ID，不是身份
/// 记录 = null。一条输入认领两次、下标越界 = 内核与 Dart 对不上，报错。
@visibleForTesting
List<String?> srsEntityWritesByInput(int inputs, Map<String, Object?> reply) {
  final List<String?> out = List<String?>.filled(inputs, null);
  for (final Object? raw
      in (reply['entityWrites'] as List?) ?? const <Object?>[]) {
    final List<Object?> e = (raw! as List).cast<Object?>();
    final Object? at = e[0];
    if (at == null) continue;
    if (at is! int || at < 0 || at >= inputs || out[at] != null) {
      throw StateError(
        'srs: the `apply` reply claims entity input $at twice or out of range '
        '(the native core and Dart do not match)',
      );
    }
    out[at] = e[2]! as String;
  }
  return out;
}

/// `apply` 一类命令的一条输入写下的东西（[srsWrittenByInput]）：修改记录（[tags] = false，`(writer, seq)` 是它的 dot）
/// 或整列表标签草稿展开成的标签操作（[tags] = true，`(writer, seq)` 是展开出的最后一条操作）。[entity] / [key] 是
/// 内核归一后的规范形。[row] / [serverTime]：请求带了 `editRows` 时，收尾之后这条修改（标签草稿是那条笔记合成的
/// `tags` 行）在 `read edits` 里的行 JSON 与服务器时刻；没要、或这一项被同批后面的写入盖掉了 = null。
/// [superseded]：内核明确标出这一项被同批后面的写入盖掉了（同一个键后面又写了一次、标签是同一条笔记后面又整列表写了
/// 一次、或实体在这批里被彻底清除；native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」修改行）。
typedef SrsWrittenItem = ({
  String kind,
  String entity,
  String key,
  String writer,
  int seq,
  bool tags,
  String? row,
  int? serverTime,
  bool superseded,
});

/// `apply` 回包按输入下标认领（native/fushi_fsrs/src/store/gen4/cmd/writes.rs 文件头「回包」）：返回长 [inputs] 的列表，
/// 第 i 项是第 i 条输入写下的那条，没写出（内核按「值没变」丢掉、日志、身份记录）= null。
///
/// - `edits` 每项 `[种类, 规范实体, 字段键, 设备, 序号, 值, 输入下标, 行 JSON?, 服务器时刻?, 被盖掉]`，输入下标是
///   null 的（意图命令自己拼的项）不认领；后三列只在请求带 `editRows` 时有；
/// - `tagWrites` 每项 `[输入下标, 规范笔记, 设备, 最后一条操作的序号, 行 JSON?, 被盖掉]`（后两列同上）。
///
/// 一条输入认领两次、下标越界 = 内核与 Dart 对不上，报错（不静默挑一条）。
@visibleForTesting
List<SrsWrittenItem?> srsWrittenByInput(
  int inputs,
  Map<String, Object?> reply,
) {
  final List<SrsWrittenItem?> out = List<SrsWrittenItem?>.filled(inputs, null);
  void claim(Object? at, SrsWrittenItem item) {
    if (at == null) return;
    if (at is! int || at < 0 || at >= inputs || out[at] != null) {
      throw StateError(
        'srs: the `apply` reply claims input $at twice or out of range '
        '(the native core and Dart do not match)',
      );
    }
    out[at] = item;
  }

  for (final Object? raw in (reply['edits'] as List?) ?? const <Object?>[]) {
    final List<Object?> e = (raw! as List).cast<Object?>();
    if (e.length < 7) continue;
    claim(e[6], (
      kind: e[0]! as String,
      entity: e[1]! as String,
      key: e[2]! as String,
      writer: e[3]! as String,
      seq: (e[4]! as num).toInt(),
      tags: false,
      row: e.length > 7 ? e[7] as String? : null,
      serverTime: e.length > 8 ? (e[8] as num?)?.toInt() : null,
      superseded: e.length > 9 && e[9] == true,
    ));
  }
  for (final Object? raw
      in (reply['tagWrites'] as List?) ?? const <Object?>[]) {
    final List<Object?> t = (raw! as List).cast<Object?>();
    claim(t[0], (
      kind: SrsEntityKind.note.wire,
      entity: t[1]! as String,
      key: SrsFieldKeys.noteTags,
      writer: t[2]! as String,
      seq: (t[3]! as num).toInt(),
      tags: true,
      row: t.length > 4 ? t[4] as String? : null,
      serverTime: null,
      superseded: t.length > 5 && t[5] == true,
    ));
  }
  return out;
}

/// [SrsDbStore.scrubState] 的结果。
typedef SrsScrubState = ({bool due, String? error});
