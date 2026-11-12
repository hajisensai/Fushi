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
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/srs/sync2/srs_wal_checkpoint_pacer.dart';

/// 旧库迁移成同步 v2 操作时每批包多少条旧行（[SrsDbStore] 打开时）。每批是内核里一个独立提交的 savepoint：
/// 被杀 / 关库只丢这一批。桌面实测见 docs/specs/2026-10-25-srs-sync-v2-plan.md「规模基准」。
const int kSrsSync2MigrateBatch = 20000;

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

  /// 子树里有 RWKV 牌组而 RWKV 还没准备好（下载 / 回放 / 出错）：这些牌组的复习卡这一次一张没算进
  /// [reviewCount]（也不出），所以 [reviewCount] 不是「今天没有到期」。界面据此显示「准备中」，不显示 0。
  final bool rwkvPending;

  /// 子树里有按 RWKV-Instant 排队的牌组（就绪与否都算）：这些牌组的复习卡不看存下的到期日，按 RWKV 预测的
  /// 今天结束时的回忆率挑（降到目标保留率以下的就是今天到期；今天已答过的卡按此刻的回忆率，[_instantInput]），
  /// 已算进 [reviewCount]。
  final bool rwkvScheduled;
}

/// 今天（[SrsDbStore.dayContext] 的日界）已做的复习：首页复习条的「今日」一行。口径与复习统计页
/// 「今天」一节（`SrsStatsData.todayStats`，不按牌组筛选）相同：有效复习投影里的评分复习。
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

/// 内核缓存刷新的配置（内核命令的 `caches`；[SrsDbStore] 打开时注册一次，`cache_config_set`）：[profileUid] 的默认
/// 牌组与各内置笔记类型（代码默认值 + 读音字段，readingKey 的来源）。只由 profile 的 uid 决定。
Map<String, Object?> srsCacheConfigFor(String profileUid) => <String, Object?>{
  'defaultDeck': SrsIds.builtinDefaultDeck(profileUid),
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
    Future<void> Function(SrsDbStore store)? beforeMigrate,
    bool deferMigration = false,
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
    final ({bool exists, bool epochStored}) local = await s._loadLocal();
    // 注册本 profile 的缓存配置（库重开后内核里就没了，每次打开都注册），内核顺带把缓存补到当前推导口径
    // （版本记在本机状态行里，native/fushi_fsrs/src/store/cache_rev.rs）。
    await s._registerCacheConfig();
    if (!local.exists && await s._hasAnyEvent()) {
      // 有事件却没有本机状态：覆盖恢复了备份（本机状态与缓存不进备份，恢复时清空）。重建缓存；同步 v2 的
      // 本机身份同样不进备份，打开时按新设备起步（[_sync2Open]），绝不沿用备份来源设备的身份。
      await s.afterRestore();
    }
    // 还没有本机状态行（新 profile、刚覆盖恢复）或老版本存的行没有纪元：当场落下，否则每次打开都是新纪元、指纹
    // 每次都「变了」。排在重建之后——「有事件却没有这一行」正是上面判要不要重建的依据，重建途中失败下次还得再来。
    if (!local.epochStored) await s._ensureLocalState();
    await s.ensureBuiltins();
    await s._sync2Open(beforeMigrate, deferMigration);
    return s;
  }

  /// 同步 v2 起步：本机身份（没有就建）；旧库里的事件还没并成操作就并一次（拍板 5：并入、不覆盖）。
  ///
  /// 迁移不改任何卡的排程、不重放（旧日志按作者结果照抄，native/fushi_fsrs/src/sync2/replay.rs 文件头），所以
  /// 缓存不用刷新。迁移分批（[kSrsSync2MigrateBatch] 条一批），每批是内核里一个独立提交的 savepoint：进程被杀 /
  /// 关库只丢正在做的那一批，下次打开从剩下的接着做（大库在慢设备上一次做不完也不会每次从头来）。整个迁移
  /// 在独占区里：迁移期间不会插进本机写入（它们要等迁移做完才落库）。
  ///
  /// [beforeMigrate]：还没迁移时、迁移之前在同一个独占区里先跑一次（store 还没交给调用方，不会有本机写入），用来先
  /// 收一轮同步位置上别的设备已迁出的操作：迁移只包还没有任何设备的操作代表的旧行（内核 store/sync2/mod.rs
  /// `enqueue_legacy_rows`，BUG-4011），先收到的那部分旧行不会再被包成第二条重复的操作流。已迁移时不调用。
  ///
  /// [deferMigration]：这次打开不迁移，留给调用方之后调 [migrateLegacy]（App 等首次同步确认之后、第一轮同步之前
  /// 才迁移，BUG-4011）。没迁移的副本照常可读可写：本机写入本来就是操作，迁移时按「已有操作代表」跳过。
  Future<void> _sync2Open([
    Future<void> Function(SrsDbStore store)? beforeMigrate,
    bool deferMigration = false,
  ]) => runExclusive(() async {
    final (int nowMs, _) = now();
    final Map<String, Object?> id = await _sync2(<String, Object?>{
      'op': 'identity',
      'now': nowMs,
      // 顺带取回旧协议的本机写入者 ID（[writerId]）。
      'legacyDevice': deviceId,
    });
    _sync2Device = id['device'] as String?;
    _legacyWriter = id['legacyWriter'] as String?;
    _sync2Migrated = id['migrated'] == true;
    if (_sync2Migrated || deferMigration) return;
    if (beforeMigrate != null) await beforeMigrate(this);
    await _sync2MigrateAll(nowMs);
  });

  /// 旧库还没并成操作就并（打开时用 `deferMigration` 推迟了的那一次）。已迁移时立即返回。
  ///
  /// [beforeMigrate] 在独占区**外**先跑（只拉不发的一轮可能要等网络，期间本机复习照常落库），然后分批迁移：
  /// **每批单独进出一次独占区**（[batch] 条一批，默认 [kSrsSync2MigrateBatch]）。推迟的迁移是在会话中途（首次同步
  /// 确认之后）触发的，大库要跑十几批、几分钟；以前整个迁移包在一个独占区里，期间本机评分 / 撤销 / 编辑全部排在
  /// 它后面，界面卡到最后一批做完。独占区是 FIFO（[runExclusive]），迁移期间发起的写入排在当前这一批之后、下一批之前。
  ///
  /// 交错写入下语义不变：迁移只包还没有任何操作代表的旧行，队列在第一批排好（只排那一刻已有的旧行，之后的本机写入
  /// 本来就是操作）；续做的批次在内核里包装前逐条再判一次「已被代表」（store/sync2/mod.rs `represented`），所以
  /// [beforeMigrate] 与迁移之间、批与批之间插进来的本机写入 / 收到的操作都不会被重复包装。几条入口同时迁移（不同
  /// 拉取范围的 [SrsSyncScheduler.ensureMigrated]）各自跑批也一样：队列在内核里，谁做到最后一批谁置 [sync2Migrated]。
  Future<void> migrateLegacy({
    Future<void> Function(SrsDbStore store)? beforeMigrate,
    int batch = kSrsSync2MigrateBatch,
  }) async {
    if (_sync2Migrated) return;
    if (beforeMigrate != null) await beforeMigrate(this);
    while (!_sync2Migrated) {
      await runExclusive(() async {
        if (_sync2Migrated) return;
        await _sync2MigrateBatch(now().$1, batch);
      });
    }
  }

  /// 本 profile 的旧库已并成操作（或本来就没有要并的）。
  bool get sync2Migrated => _sync2Migrated;
  bool _sync2Migrated = false;

  /// 打开时（store 还没交给调用方，[_sync2Open] 的独占区里）一口气做完全部批次。
  Future<void> _sync2MigrateAll(int nowMs) async {
    while (!_sync2Migrated) {
      await _sync2MigrateBatch(nowMs, kSrsSync2MigrateBatch);
    }
  }

  /// 迁移一批（内核一个独立提交的 savepoint）；做完最后一批置 [sync2Migrated]。调用方在独占区里。
  Future<void> _sync2MigrateBatch(int nowMs, int batch) async {
    final Map<String, Object?> m = await _sync2(<String, Object?>{
      'op': 'migrate',
      'now': nowMs,
      'limit': batch,
    });
    if (m['done'] == true) _sync2Migrated = true;
  }

  /// 本机在这个 profile 集合里的同步 v2 设备 ID（换身份后会变）。
  String? get sync2Device => _sync2Device;
  String? _sync2Device;

  /// srs.db 的 Rust 句柄：全部读写都是它的命令（写命令在内核里读、算、写完；读命令见 srs_reads.dart），
  /// 表结构与 SQL 只在内核里（docs/specs/2026-10-23-srs-rust-store.md）。
  final SrsCore core;

  /// 本 profile 的一条只读查询（内核 `read`，native/fushi_fsrs/src/store/reads.rs）。
  Future<SrsReadResult> _read(
    String q, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => srsRead(core, profileUid, q, args);

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

  /// 旧协议的本机写入者 ID（[writerId]）：内核持有，开库时随 `identity` 取回（[_sync2Open]）。
  String? _legacyWriter;

  /// 存量样式去重的进度：srs_field_edits 里已检查到的 rowid（本机状态，不进备份）。内核持有（本机状态行的
  /// `styleCursor`），这里是读到 / 写下的那一刻的值：[_loadLocal] 读、[compactStoredStyles] 每批推进、[afterRestore] 归零。
  int _styleCursor = 0;

  /// 这一版内核的缓存推导口径版本（`cache_config_set` 回包的 `current`，native/fushi_fsrs/src/store/cache_rev.rs
  /// `CACHE_REVISION`）。升级测试断言「打开老库后记下的是当前版本」时读它，不写字面量。
  @visibleForTesting
  int debugCacheRevision = 0;

  /// 库的变化修订号：任何事件真正落库（本机产生或对端来的）+1（见 [changeFingerprint]）。内核持有（本机状态行的
  /// `revision`，native/fushi_fsrs/src/store/local_state.rs）：这里只由内核的回包赋值（[_loadLocal] /
  /// [_absorbLocalWrite]），Dart 自己不加。
  int _revision = 0;

  /// 内容修订号（只在内存）：修订号的子集——复习日志与界面状态类修改记录（牌组收起 / 展开，
  /// [SrsFieldClass.viewState]）不推进它。同步冲突、待裁决笔记、旧 Lapis 迁移提醒这类「整库扫一遍」
  /// 的角标只随它变（见 [contentFingerprint]）：评分一次只落日志，牌组列表 / 首页面板跟着重读计数时
  /// 不必把这些角标再扫一遍。
  int _contentRevision = 0;

  /// 当前修订号（同步可读；与 [changeFingerprint] 同一个数，不含纪元）。牌组列表据此判断一份重读
  /// 结果是不是在某次写入之后取的。
  int get revision => _revision;

  /// 本副本对象的实例号（只在内存、不落盘、不进纪元）：进程启动 ID + 进程内第几个副本对象。
  ///
  /// 内容 / 视图 / RWKV 刷新这三个计数只在对象的内存里、每个对象从头数，而纪元是落盘的：同一个 profile 换一个副本
  /// 对象（进程重启，或同一进程里副本关掉重开——换 uid、交接、远程主机按 uid 现取）之后，`纪元:计数` 会回到以前
  /// 出现过的值而内容已经不同。按「指纹相等 = 没变」跳过重读的读者（远程客户端缓存的 dayContext 与牌组树、同步调度
  /// 记的上次媒体对账时的内容指纹、RWKV 分数表）就读到旧数据。凡是带内存计数的指纹都拼上它：换对象指纹必然不同，
  /// 代价是这些缓存每换一次对象失效一次。只含落盘值的 [changeFingerprint] / [rwkvScoresClearKey] 不拼，跨对象可比。
  final String _instance = '$_srsProcessBootId.${_nextInstance++}';
  static int _nextInstance = 0;

  /// [_epoch] + [_instance]：带内存计数的指纹的共同前缀。
  String get _memoryKeyPrefix => '$_epoch:$_instance';

  /// 统计指纹：纪元 + 落库事件里会改变统计结果的那部分（复习日志、卡片 / 笔记 / 牌组 / 笔记类型的内容事件、冲突
  /// 扣住与解除）。界面状态类修改记录（牌组收起 / 展开，[SrsFieldClass.viewState]）不计入；没有事件落库的写入（同步
  /// 簿记、媒体、空轮）不改变它。统计页据此判断 [srsRevisionProvider] 的一跳要不要重读（见 `loadSrsStats`）。
  String get statsFingerprint =>
      '$_memoryKeyPrefix:${_revision - _viewRevision}';

  /// 内容指纹：纪元 + 实例号（[_instance]）+ 内容修订号。相等 = 两次读之间没有落过日志 / 界面状态以外的事件、没有换过服务器
  /// 时刻、没有重读过本机状态——同步冲突 / 待裁决 / 迁移提醒的计数不可能变。
  String get contentFingerprint => '$_memoryKeyPrefix:$_contentRevision';

  /// RWKV-Instant 分数表的全量刷新信号（只在内存）：牌组 / 配置类事件落库（预设归属、排队设置可能
  /// 变了）、应用一批对端事件（同步合并）、重读本机状态时 +1。复习日志、卡片自己的修改（暂停 /
  /// 埋 / 旗标 / 换牌组——换牌组由分数表项的版本覆盖）不推进它。见 `SrsRwkvService` 文件头。
  int _rwkvScoresRevision = 0;

  /// [_rwkvScoresRevision] 连同纪元与实例号（[_instance]）：变了 = 分数表整表按此刻重查。
  String get rwkvScoresKey => '$_memoryKeyPrefix:$_rwkvScoresRevision';

  /// 收段会话（[sync2IngestBegin] … [sync2IngestEnd]）期间攒下的分数表刷新：会话里每片投递 / 收尾重放都可能
  /// 推进它，以前每片 +1，整表重查跟着每片来一次、与下一片抢内存（35 万条日志的 iPhone 收尾 OOM）。会话结束时
  /// 并成一次（[_endIngestSession]）。只在内存：进程死在会话中途时下次启动 [_loadLocal] 本来就 +1、原生分数表
  /// 也是空的，不会漏刷新。
  int _rwkvScoresDeferred = 0;

  /// 推进 [_rwkvScoresRevision]；收段会话里先攒着，会话结束时并成一次。
  void _bumpRwkvScores([int n = 1]) {
    if (n <= 0) return;
    if (_ingestSession != null) {
      _rwkvScoresDeferred += n;
    } else {
      _rwkvScoresRevision += n;
    }
  }

  /// 正在进行的收段会话；完成 = 会话结束。RWKV 回放（[rwkvReplay]，整 profile 扫一遍日志）等它结束才跑，
  /// 会话开始前等在途的回放跑完（[_rwkvReplaysIdle]）：两者都随日志总量线性占内存，不能叠在一起。
  Completer<void>? _ingestSession;

  /// 在途的 [rwkvReplay] 个数与「全部跑完」信号（收段会话开始时等它）。
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
    if (_rwkvScoresDeferred > 0) {
      _rwkvScoresDeferred = 0;
      _rwkvScoresRevision++;
    }
    session.complete();
  }

  /// 纪元：变了（覆盖恢复后本机状态重建）= 分数表清空、按历史重算。
  String get rwkvScoresClearKey => _epoch;

  /// 本机状态的随机纪元：本机状态被清空重建（覆盖恢复）后换一个，修订号从 0 重数也不会撞上旧指纹。内核生成并
  /// 持有（本机状态行的 `epoch`），这里只由内核的回包赋值。
  String _epoch = '';

  /// 旧协议的本机写入者 ID（只用来认出迁移进来的旧修改记录里哪些是本机写的；v2 的写入者是 [sync2Device]）。
  ///
  /// 内核持有（本机状态行的 `writerId`，没存过时按 [deviceId] 拼，native/fushi_fsrs/src/store/legacy_clock.rs）；这里
  /// 是开库那一刻 `identity` 回包里的值。本机日志的 HLC 用的就是它（旧版 HLC 时钟也在内核里，Dart 没有副本）。
  String get writerId => _legacyWriter!;

  /// [writer]（修改记录 / HLC 的写入者）是不是本机：v2 设备 ID 或旧协议的本机写入者。
  bool isOwnWriter(String writer) =>
      writer == _sync2Device || writer == _legacyWriter;
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
      if (prev != null && _ingestSliceHolding && !_ingestYieldSent) {
        // 锁正被收段的一片占着：请内核当场收片（只置一个标志，同步调用不等锁），不让这笔写入等完整片。
        _ingestYieldSent = true;
        core.sync2(const <String, Object?>{'op': 'ingest_yield'});
      }
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
        await _releaseIngestSession();
        return await body();
      } finally {
        _unusable ??= SrsStoreRetiredError(
          this,
          'SRS store is unusable: '
          '${reason ?? 'profile $profileUid was deleted'}',
        );
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

  // ------------------------------------------------------------------ 本机状态

  Future<bool> _hasAnyEvent() async =>
      ((await _read('entity_count', const <String, Object?>{
            'limit': 1,
          })).json['n']!
          as int) >
      0;

  /// 读本机状态（内核 `local_state`，只读：不建行、不补纪元）。`exists`：库里有没有这一行；`epochStored`：行里有没有
  /// 纪元（没有时 [_epoch] 是内核现给的、没落盘的一个）。
  ///
  /// 重读路径（[reloadLocal]、命令失败后的 [_commandOrReload]）也走这里，所以不能顺手建行：这个 profile 的数据可能
  /// 刚被整份删掉（`profile_purge` / 并入收尾），建回一行它就又被当成有数据的 profile。
  Future<({bool exists, bool epochStored})> _loadLocal() async {
    _contentRevision++;
    _bumpRwkvScores();
    final Map<String, Object?> j = await _sync2(const <String, Object?>{
      'op': 'local_state',
    });
    _absorbLocalState(j);
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

  /// 把本机状态行落下（内核 `local_state_ensure`：没有行就建、没有纪元就补）。只在开库时调（见 [open]）。
  Future<void> _ensureLocalState() async {
    _absorbLocalState(
      await _sync2(const <String, Object?>{'op': 'local_state_ensure'}),
    );
  }

  /// `local_state` / `local_state_ensure` 的回包 → 内存里的修订号、纪元、样式去重进度。
  void _absorbLocalState(Map<String, Object?> j) {
    _styleCursor = j['styleCursor']! as int;
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
  /// [_structureKey]：内容修订号覆盖了除复习日志与界面状态外的一切落库、服务器时刻变化、重读
  /// 本机状态与清除；界面状态（牌组收起 / 展开）另由 [_viewRevision] 计。
  ({String key, SrsDeckTree tree})? _deckTreeCache;
  ({String key, SrsEntityEdits edits})? _profileEditsCache;
  int _viewRevision = 0;
  String get _structureKey =>
      '$_memoryKeyPrefix:$_contentRevision:$_viewRevision';

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
  Future<SrsDayContext> dayContext() async {
    final int rollover =
        (await syncedDayRollover())?.hour ?? _fallbackRollover().clamp(0, 23);
    return SrsDayContext(utcOffsetMin: _localOffset(), rolloverHour: rollover);
  }

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

  /// 修改记录原文 + 服务器时刻按实体 ID 分组（`read` 的 `edits`，参数见 store/reads.rs `edits`）。没有记录的 ID
  /// 不出现。
  Future<Map<String, List<SrsEditItem>>> _editItemsById(
    Map<String, Object?> query,
  ) async {
    final SrsColumns c = await _readTable('edits', query);
    final SrsStringColumn e = c.strings('e');
    final SrsStringColumn j = c.strings('j');
    final SrsIntColumn st = c.ints('st');
    final Map<String, List<SrsEditItem>> byId = <String, List<SrsEditItem>>{};
    for (int i = 0; i < c.rows; i++) {
      (byId[e[i]] ??= <SrsEditItem>[]).add(
        SrsEditItem.stored(j.bytes(i), st.at(i)),
      );
    }
    return byId;
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

  /// 存量去重：把本 profile 已落库、还带内联样式的笔记字段修改记录就地换成引用表示。
  ///
  /// - 不产生任何新事件、不进发件箱：改的只是本机行的表示，记录的 id / dot / ctx / hlc 不动，
  ///   合并时与对端手里的原表示视为同值（见库注释）。所以存量迁移零同步流量，对端各自迁移各自的。
  /// - 分批（每批一个事务），按 rowid 游标推进并记进本机状态：随时中断（[shouldStop] 返回 true、
  ///   进程被杀）下次从断点续；重复跑幂等（已换过的行不再含可换的块）。
  /// - 恢复备份后本机状态清空、游标归零，恢复进来的行会被重新检查。
  ///
  /// 返回本次改写的行数。没装样式库时什么也不做。
  Future<int> compactStoredStyles({
    int batchSize = 32,
    bool Function()? shouldStop,
  }) async {
    final SrsStyleStore? st = styles;
    if (st == null) return 0;
    int rewritten = 0;
    while (shouldStop?.call() != true) {
      // 每批一个独占区：样式去重（会写样式文件）在 Dart 算，落库一半交内核（`edits_rewrite_repr`，
      // native/fushi_fsrs/src/store/repr_rewrite.rs）——改写表示、刷新这些笔记的缓存行、推进游标并写本机状态行在一个
      // SAVEPOINT 里。
      final int done = await runExclusive(() async {
        int n = -1;
        await _commandOrReload(() async {
          final SrsColumns rows = await _readTable(
            'style_candidates',
            <String, Object?>{'after': _styleCursor, 'limit': batchSize},
          );
          if (rows.rows == 0) return;
          final SrsIntColumn rid = rows.ints('rid');
          final SrsStringColumn json = rows.strings('json');
          final List<List<Object>> rewrites = <List<Object>>[];
          for (int i = 0; i < rows.rows; i++) {
            final SrsFieldEdit e = SrsFieldEdit.fromJson(
              (jsonDecode(json[i]) as Map).cast<String, Object?>(),
            );
            final FutureOr<SrsFieldEdit> pending = _compactEdit(e);
            final SrsFieldEdit c = pending is SrsFieldEdit
                ? pending
                : await pending;
            if (!identical(c, e)) {
              rewrites.add(<Object>[rid[i], c.canonical()]);
            }
          }
          final int cursor = rid[rows.rows - 1];
          _absorbLocalWrite(
            await _sync2(<String, Object?>{
              'op': 'edits_rewrite_repr',
              'rows': rewrites,
              'cursor': cursor,
              'anchor': ?_anchorArg(),
            }),
          );
          // 游标已随这一批写进本机状态行（同一个 SAVEPOINT）。
          _styleCursor = cursor;
          n = rewrites.length;
        });
        return n;
      });
      if (done < 0) break;
      rewritten += done;
      // 让出事件循环：迁移在后台跑，不长时间占住数据库连接。
      await Future<void>.delayed(Duration.zero);
    }
    return rewritten;
  }

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
  /// [logNotes]：日志卡片 → 笔记（调用方已知时给，省一次读卡片行）；[study]：落库、刷新缓存后在同一次命令里排队
  /// （store/study.rs），结果交给 [onStudy]。
  Future<List<SrsFieldEdit>> _emit(
    List<SrsEventDraft> drafts, {
    bool receive = false,
    bool stamps = false,
    Set<String>? existed,
    Map<String, String> logNotes = const <String, String>{},
    Map<String, Object?>? study,
    void Function(Map<String, Object?> study)? onStudy,
  }) async {
    assert(
      identical(Zone.current[_writeZoneKey], this),
      '_emit outside runExclusive',
    );
    // 收（来源 HLC 的钳位）与走一步各自的「此刻」，以及修改记录草稿的时间来源：都在落库前这一刻取。
    final int recvNow = now().$1;
    final (int tickNow, SrsTimeSource source) = now();
    final List<Map<String, Object?>> input = await _applyInput(
      drafts,
      receive: receive,
      initials: existed != null,
      source: source,
      logNotes: logNotes,
    );
    late _Applied applied;
    await _commandOrReload(() async {
      // 同步 v2：操作落进 ops 就是「已备份、待发布」，没有单独的发件箱（发件按段，见 store/sync2/transport.rs）。
      // 本机状态行由内核在 `apply` 的同一笔事务里写下（[_absorbLocalWrite]）。
      applied = await _applyLocal(
        input,
        recvNow: receive ? recvNow : null,
        tickNow: tickNow,
        stamps: stamps,
        existed: existed,
        study: study,
        onStudy: onStudy,
      );
    });
    if (!stamps) return const <SrsFieldEdit>[];
    final List<SrsFieldEdit> out = <SrsFieldEdit>[];
    for (int i = 0; i < drafts.length; i++) {
      final SrsEventDraft d = drafts[i];
      final Object? stamp = applied.stamps[i];
      if (d is SrsEditDraft && stamp is Map) {
        // 内核交回的是落库的投影行（值是落库形态，内联样式已换成共享引用）；返回值里带调用方给的原值。
        out.add(
          _withValue(
            SrsFieldEdit.fromJson(stamp.cast<String, Object?>()),
            d.value,
          ),
        );
      }
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
    Map<String, String> logNotes = const <String, String>{},
  }) async {
    final Map<String, String> noteOf = await _logNotesOf(<SrsEvent>[
      for (final SrsEventDraft d in drafts)
        if (d case SrsReadyDraft(:final SrsEvent event)) event,
    ], logNotes);
    final List<Map<String, Object?>> input = <Map<String, Object?>>[];
    for (final SrsEventDraft d in drafts) {
      switch (d) {
        case SrsReadyDraft(:final SrsEvent event):
          final SrsEvent stored = await _compactEvent(event);
          input.add(<String, Object?>{
            'e': stored.toJson(),
            'note': stored is SrsLogEvent ? noteOf[stored.log.cardId] : null,
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
            'note': null,
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
  /// 以前每条事件「先查再写」各两三次往返（库在后台 isolate，每次往返都是一次跨 isolate 消息），
  /// 导入一个几千条笔记的包、应用一批对端事件都要几万次往返（BUG-3549 / BUG-3543）。
  ///
  /// [input] 见 [_applyInput]。同步 v2：事件交给 Rust 的 `apply`——分配 OpId / HLC / 因果上下文、落唯一事实表
  /// （ops）、落投影、重放受影响的卡，一次 FFI（docs/specs/2026-10-25-srs-sync-v2-design.md §3、§4）。修改记录的
  /// dot / ID 由 Rust 按本机设备身份分配，这里只交内容；日志的结果由重放算，作者给的只是提示。旧版 HLC 时钟按各项的
  /// `clk` 在同一条命令里推进并写下（[recvNow] / [tickNow] 是收 / 走一步用的「此刻」）；本机状态行由内核在
  /// 同一笔事务里写下（[_absorbLocalWrite]）。
  Future<_Applied> _applyLocal(
    List<Map<String, Object?>> input, {
    int? recvNow,
    int? tickNow,
    bool stamps = false,
    Set<String>? existed,
    Map<String, Object?>? study,
    void Function(Map<String, Object?> study)? onStudy,
    Map<String, Object?>? expectLast,
  }) async {
    final Map<String, Object?> r = await _sync2(
      <String, Object?>{
        'op': existed == null ? 'apply' : 'import_drafts',
        'now': now().$1,
        'legacyDevice': deviceId,
        'recvNow': ?recvNow,
        'tickNow': ?tickNow,
        if (stamps) 'stamps': true,
        'study': ?study,
        'expectLast': ?expectLast,
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
    final Object? got = r['stamps'];
    if (stamps && (got is! List || got.length != input.length)) {
      throw StateError(
        'srs: `apply` was asked for stamps but its reply has none for each '
        'item (the native core and Dart do not match)',
      );
    }
    return _Applied(landed, got is List ? got : const <Object?>[]);
  }

  /// 把一次 sync2 命令（本机 apply、远端 ingest、冲突解决、恢复……）的结果接进修订号与本机缓存的变更日志：
  /// 内核已把落进投影的事件折成粗粒度摘要 `marks`（native/fushi_fsrs/src/store/sync2/mod.rs `Marks`），并在
  /// 同一次调用里按它刷新了缓存行（store/caches.rs），交回写过哪些笔记 / 卡（`cache`）。这里只加计数、记日志——
  /// 不收事件全文，也不在 UI isolate 上重算缓存行（大同步曾因此卡死 / OOM）。冲突扣住 / 解除改变了可见性的
  /// 实体各推进一次内容修订号。修订号本身不在这里加：内核按同一份结果推进并写下，回包带回（[_absorbLocalWrite]）。
  /// 返回落进投影的事件数。
  int _absorbProjection(Map<String, Object?> r) {
    final Map<String, Object?> m =
        (r['marks'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final int landed = (m['landed'] as int?) ?? 0;
    _contentRevision += (m['content'] as int?) ?? 0;
    _viewRevision += (m['view'] as int?) ?? 0;
    _bumpRwkvScores((m['rwkv'] as int?) ?? 0);
    for (final Object? c in (r['changed'] as List?) ?? const <Object?>[]) {
      if (c is List &&
          c.length == 2 &&
          SrsEntityKind.tryParse(c[0] as String?) != null) {
        _contentRevision++;
      }
    }
    for (final Object? c in (r['purged'] as List?) ?? const <Object?>[]) {
      if (c is List && c.length == 2) {
        final SrsEntityKind? kind = SrsEntityKind.tryParse(c[0] as String?);
        if (kind != null) _purgedPending.add((kind, c[1]! as String));
      }
    }
    _absorbCache(r);
    return landed;
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
  /// `plan` 先不进写锁、只在读连接上算（审查 S-8：空轮 head 都没变，什么都不用记）；内核说要记东西（新设备 / 更新的
  /// head）才进写锁再算一次。
  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    if (request['op'] == 'dedup') {
      // 重复流收敛（内核 store/sync2/dedup.rs）改投影（删并存的修改记录行、解除扣留）：与冲突解决同一条路径，
      // 投影变化接进缓存。
      return SrsSync2Result(
        await _sync2Write(request),
        const <(String, Uint8List)>[],
      );
    }
    if (request['op'] == 'plan') {
      final SrsSync2Result r = await _sync2Raw(<String, Object?>{
        ...request,
        'readOnly': true,
      }, blobs: blobs);
      if (r.map['needsWrite'] != true) return r;
    } else if (kSrsSync2LockFreeOps.contains(request['op'])) {
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

  /// [browseCommand] 接受的命令：与原生 `store/ffi.rs` 里分派到 `browse` 会话的那一组相同。
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
  /// - `digest`：读连接上读触发器增量维护的 4096 个摘要桶求根（已提交快照，不再全库扫描），只在末尾往写连接
  ///   记一行摘要缓存（`srs_meta`）；恰好落进另一笔写事务而那笔回滚，丢的只是这行缓存，下一轮按间隔重算。
  /// - `digest_buckets`：同上读连接，列各摘要桶（摘要不一致时定位不一致的 ID 范围）。
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
    'digest_buckets',
    'seal_file',
    'open_file',
  };

  /// 开一场收段会话。先登记会话（之后来的 [rwkvReplay] 排到会话结束），再等在途的回放跑完，然后才让内核开始：
  /// 收段的投递 / 收尾与整 profile 的 RWKV 回放不会同时在内存里。开不成（抛错）时会话随即结束——调用方只在
  /// 这一步成功后才配对 [sync2IngestEnd]。
  @override
  Future<void> sync2IngestBegin() async {
    final Completer<void> session = Completer<void>();
    await sync2IngestSettled();
    _ingestSession = session;
    try {
      final Completer<void>? replays = _rwkvReplaysIdle;
      if (replays != null) await replays.future;
      await runExclusive(() async {
        await _sync2(const <String, Object?>{'op': 'ingest_begin'});
        _ingestOpen = true;
      });
    } catch (_) {
      _endIngestSession(session);
      rethrow;
    }
  }

  /// 本副本开着内核收段会话（[sync2IngestBegin] 之后、[sync2IngestEnd] / [retire] 放掉之前）。
  /// [_ingestSession] 是 Dart 侧的会话（攒分数表刷新、让 RWKV 回放排队），比它早开、不晚于它结束。
  bool _ingestOpen = false;

  /// 测试：[_ingestOpen]。
  @visibleForTesting
  bool get debugIngestOpen => _ingestOpen;

  /// 结束收段会话：会话里攒下的分数表刷新并成一次（[_rwkvScoresDeferred]），等着的 RWKV 回放放行；内核命令失败
  /// 也照样结束 Dart 侧会话。副本在这一轮途中被作废时，[retire] 已在它最后一段独占区里放掉了内核会话：这里不再进
  /// 独占区（进了也只会抛作废错误，而 `ingest_end` 已经发到内核）。
  @override
  Future<void> sync2IngestEnd() async {
    final Completer<void>? session = _ingestSession;
    try {
      if (!_ingestOpen) return;
      await runExclusive(_releaseIngestSession);
    } on SrsStoreRetiredError catch (e) {
      // 排队期间被作废：会话由 [retire] 放掉了（[_ingestOpen] 已清）。别的原因（会话仍开着）照常抛。
      if (!identical(e.store, this) || _ingestOpen) rethrow;
    } finally {
      if (session != null) _endIngestSession(session);
    }
  }

  /// 在独占区里放掉本副本的收段会话（没开着就什么也不做）。调用方已在独占区里。内核会话放掉的同时结束 Dart 侧
  /// 会话：[retire] 走这条路时，攒着的分数表刷新与排队的 RWKV 回放也随之放行，不必等那一轮的 [sync2IngestEnd]。
  Future<void> _releaseIngestSession() async {
    if (!_ingestOpen) return;
    await _sync2(const <String, Object?>{'op': 'ingest_end'});
    _ingestOpen = false;
    final Completer<void>? session = _ingestSession;
    if (session != null) _endIngestSession(session);
  }

  /// 收一批分两步：`ingest_prepare` 不进写锁（解压、解密、验签、重算链，手机上一批要一两秒，这期间本机作答照常
  /// 写入；内核也只在读连接上短暂取公钥），`ingest_commit` 在写锁里投递预处理好的那批。预处理只读已提交的数据，
  /// 之后公钥 / 身份变了内核在投递时按当时的重验，结果与在写锁里一步收完相同。
  ///
  /// 投递按片（native/fushi_fsrs/src/store/sync2/transport.rs `CommitBudget`）：内核每次 commit 只投一片，返回
  /// `more` 就再进一次写锁接着投。每片是独立的独占区 + 事务；没人等锁时一片投到时间上限，有写入来排队
  /// （[runExclusive]）就请内核当场收片（`ingest_yield`），排队的作答只等这一片已投部分的收尾，而不是整批。
  ///
  /// 收这一批期间调高写连接的自动 checkpoint 阈值（[bulkWrites]），按 [SrsWalCheckpointPacer] 定的节奏在写锁外、
  /// 内核另开的连接上把 WAL 并回（[_walCheckpoint]）：在写连接上并，提交那一刻就把同一批热页拷回主库，作答排在
  /// 后面；每片都并，同一批热页每片拷一遍（真实数据里占投递三分之一）；整批都不并，WAL 随片数涨到几百 MB。
  /// 测试用：[sliceOps] 改按条数切（切点确定），[sliceMs] 改一片的时间上限。返回里 `slices` 是这一批投了几片。
  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
    int? sliceOps,
    int? sliceMs,
  }) async {
    await _sync2(<String, Object?>{
      'op': 'ingest_prepare',
      'key': keyHex,
    }, blobs: segments);
    final List<Map<String, Object?>> slices = <Map<String, Object?>>[];
    final SrsWalCheckpointPacer pacer = SrsWalCheckpointPacer();
    await bulkWrites(() async {
      do {
        slices.add(await _sync2IngestSlice(sliceOps, sliceMs));
        if (slices.last['more'] == true && pacer.afterSlice()) {
          pacer.checkpointed(await _walCheckpoint());
        }
      } while (slices.last['more'] == true);
    });
    return _mergeIngestSlices(slices);
  }

  /// 投一片：持锁期间登记成「正在投片」，好让来排队的写入请内核收片（[runExclusive]）。
  Future<Map<String, Object?>> _sync2IngestSlice(int? sliceOps, int? sliceMs) =>
      runExclusive(() async {
        _ingestSliceHolding = true;
        _ingestYieldSent = false;
        try {
          debugOnIngestSlice?.call();
          return await _sync2IngestStep(<String, Object?>{
            'op': 'ingest_commit',
            if (sliceOps != null) 'sliceOps': sliceOps,
            if (sliceMs != null) 'sliceMs': sliceMs,
          });
        } finally {
          _ingestSliceHolding = false;
        }
      });

  /// 写锁正被收段的一片占着（[_sync2IngestSlice]）。
  bool _ingestSliceHolding = false;

  /// 测试钩子：收段的一片拿到写锁、调内核之前调用。
  @visibleForTesting
  void Function()? debugOnIngestSlice;

  /// 这一片已经请过收片。
  bool _ingestYieldSent = false;

  /// 在内核另开的连接上把 WAL 并回主库（PASSIVE，不占写连接，期间作答照常写入）。返回并回时 WAL 里的帧数。
  Future<int> _walCheckpoint() async {
    debugCoreCommands++;
    final SrsSync2Result r = await _coreSync2(
      core.address,
      core.libraryPath,
      const <String, Object?>{'op': 'wal_checkpoint'},
      const <Uint8List>[],
    );
    return (r.map['log'] as num?)?.toInt() ?? 0;
  }

  /// 一批各片的结果拼成一次的形状（[srsSync2Round] 读的那些）：条数、`marks` 的计数相加、清单接起来，报错、
  /// 重放 / 变更 / 清除的清单按片顺序接起来，缓冲条数与其它字段取最后一片，`slices` 记片数。各片的投影变化已在
  /// 各自的 [_sync2IngestStep] 里接进缓存，这里只给调用方汇报。
  static Map<String, Object?> _mergeIngestSlices(
    List<Map<String, Object?>> slices,
  ) {
    if (slices.length == 1) {
      return <String, Object?>{...slices.single, 'slices': 1};
    }
    final Map<String, Object?> out = <String, Object?>{
      ...slices.last,
      'slices': slices.length,
    };
    final Map<String, Object?> marks = <String, Object?>{};
    int applied = 0;
    bool fork = false;
    final Map<String, List<Object?>> lists = <String, List<Object?>>{
      for (final String k in const <String>[
        'errors',
        'replayed',
        'changed',
        'purged',
      ])
        k: <Object?>[],
    };
    for (final Map<String, Object?> r in slices) {
      applied += (r['applied'] as int?) ?? 0;
      fork = fork || r['fork'] == true;
      for (final MapEntry<String, List<Object?>> l in lists.entries) {
        l.value.addAll((r[l.key] as List?) ?? const <Object?>[]);
      }
      for (final MapEntry<Object?, Object?> m
          in ((r['marks'] as Map?) ?? const <Object?, Object?>{}).entries) {
        final String k = m.key! as String;
        final Object? v = m.value;
        final Object? had = marks[k];
        marks[k] = switch (v) {
          final int n => ((had as int?) ?? 0) + n,
          final List<Object?> l => <Object?>[...?had as List<Object?>?, ...l],
          _ => v,
        };
      }
    }
    return out
      ..['applied'] = applied
      ..['fork'] = fork
      ..['marks'] = marks
      ..addAll(lists);
  }

  /// 收尾：换身份，再把各片记下的待重放卡重放完（审查 S-4：每张卡一次会话只重放一遍），再按块刷新各片记下的
  /// 缓存。重放与刷新都按片：内核返回 `more` 就放开写锁、再用 `replay_pending` 接着做，排队的作答只等一片。
  /// WAL 与投递时同样处理（[bulkWrites] + [SrsWalCheckpointPacer]）。各片结果拼成一次的形状。
  @override
  Future<Map<String, Object?>> sync2IngestFinish({int? sliceOps}) async {
    final List<Map<String, Object?>> parts = <Map<String, Object?>>[];
    final SrsWalCheckpointPacer pacer = SrsWalCheckpointPacer();
    await bulkWrites(() async {
      parts.add(
        await _sync2IngestStep(<String, Object?>{
          'op': 'ingest_finish',
          'sliceOps': ?sliceOps,
        }),
      );
      while (parts.last['more'] == true) {
        if (pacer.afterSlice()) pacer.checkpointed(await _walCheckpoint());
        parts.add(
          await _sync2IngestStep(<String, Object?>{
            'op': 'replay_pending',
            'sliceOps': ?sliceOps,
          }),
        );
      }
    });
    return <String, Object?>{..._mergeIngestSlices(parts), 'more': false};
  }

  /// 收段会话的一步（投递一片 / 收尾换身份 / 接着重放）：写锁里跑，投影变化接进本机缓存。
  ///
  /// 这一片由内核自己在一笔事务里提交（提交成功才推进内核的收段会话），本机状态行（这一步只会推进其中的修订号）由
  /// 内核在**同一笔事务**里写下并回报 `localRevision`（[_absorbLocalWrite]）——要么一起落盘、要么一起不落，内存在命令
  /// 成功之后才改。
  /// 命令失败时内存没动过，无需重读本机状态。
  Future<Map<String, Object?>> _sync2IngestStep(
    Map<String, Object?> request, [
    List<Uint8List> segments = const <Uint8List>[],
  ]) => runExclusive(() async {
    final Map<String, Object?> r = await _sync2(<String, Object?>{
      ...request,
      'now': now().$1,
      'anchor': ?_anchorArg(),
    }, blobs: segments);
    final int landed = _absorbLocalWrite(r);
    if (landed > 0 || ((r['replayed'] as List?)?.isNotEmpty ?? false)) {
      _bumpRwkvScores();
    }
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

  /// 解决一项冲突：[delete] = 以删除为准，否则保留。
  Future<void> sync2Resolve(String conflictId, {required bool delete}) =>
      _sync2Write(<String, Object?>{
        'op': 'resolve',
        'conflict': conflictId,
        'delete': delete,
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

  /// `.fushisrs` 的操作部分（全部操作 + 各设备公钥；见 sync2/srs_fushisrs.dart）。与写事务互斥（同 [sync2Command]：
  /// 不能把一笔还没提交、之后可能回滚的操作导出去）。
  Future<Uint8List> sync2ExportOps() async =>
      (await sync2Command(<String, Object?>{'op': 'export'})).files.single.$2;

  /// 并入 `.fushisrs` 的操作部分（不覆盖；包里有本机身份的操作时先换身份）。返回并入条数。
  Future<int> sync2ImportOps(Uint8List bytes) => runExclusive(() async {
    late Map<String, Object?> r;
    await _commandOrReload(() async {
      r = await _sync2(
        <String, Object?>{
          'op': 'import',
          'now': now().$1,
          'anchor': ?_anchorArg(),
        },
        blobs: <Uint8List>[bytes],
      );
      _absorbLocalWrite(r);
      _bumpRwkvScores();
    });
    final Map<String, Object?> id = await _sync2(<String, Object?>{
      'op': 'identity',
      'now': now().$1,
    });
    _sync2Device = id['device'] as String?;
    await _notifyPurged();
    return (r['applied'] as int?) ?? 0;
  });

  /// 同步状态（设计 §10.6）。
  Future<Map<String, Object?>> sync2Status() async =>
      (await sync2Command(<String, Object?>{'op': 'status'})).map;

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
        'settled': true,
      });
      if (json is Map) await _absorbSettled(json['settled']);
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

  /// 发一条内核命令。请求一律带 `settled: true`：收段通道自己做完的片攒下的投影变化随回包交回，这里先接进内存
  /// （[_absorbSettled]）再把回包交给调用方——那些片在这条命令之前就提交了，先于命令自己的结果。
  Future<SrsSync2Result> _sync2Raw(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    assert(
      !kSrsSync2ProjectingOps.contains(request['op']) || holdsExclusive,
      'sync2 `${request['op']}` changes the projection outside runExclusive',
    );
    debugCoreCommands++;
    final SrsSync2Result r = await SrsOpLedger.track(
      'core:${request['op']}',
      () => _coreSync2(
        core.address,
        core.libraryPath,
        <String, Object?>{
          ...request,
          'profile': profileUid,
          'settled': true,
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
    // 回包不是对象的命令（返回数组 / 空）内核不附 `settled`，那一份留给下一条。
    final Object? json = r.json;
    if (json is Map) await _absorbSettled(json['settled']);
    return r;
  }

  /// 内核命令走哪条 worker 道（srs_core_workers.dart [SrsCoreLane]，集成审查【中】）：复习页的作答 / 排队 / 预览
  /// 走交互道，不排在同步的成批命令与媒体文件加解密后面；本机手动排程（`sched`：复习页撤销、浏览页重置 / 改期、
  /// 立即重排）是从 `apply` 拆出来的同一类本机写入，同走交互道；媒体文件的流式加解密 / 哈希走专用的文件道（同步时按
  /// `kSrsSync2Concurrency` 并发，以前一来就占满整个池）；其余走默认道。
  @visibleForTesting
  static SrsCoreLane srsCoreLaneOf(Object? op) => switch (op) {
    'apply' || 'sched' || 'study' || 'preview' => SrsCoreLane.interactive,
    'seal_file' || 'open_file' || 'media_hash' => SrsCoreLane.file,
    _ => SrsCoreLane.bulk,
  };

  /// 改投影的 v2 命令（与内核 native/fushi_fsrs/src/store/ffi.rs `PROJECTING_OPS` 同一组）：只能在本副本的独占区里发
  /// （[_sync2Raw] 断言）：回包要按顺序接进本对象的内存（缓存变更日志、修订号）。
  ///
  /// 不在这里、也不排写锁却可能顺带写库的：`digest`（记一行摘要缓存）、`media_hash`、`plan_restore`（只读，但通道没做完时
  /// 内核先收通道，收下的片经回包的 `settled` 交回，[_absorbSettled]）——见 [kSrsSync2LockFreeOps] 与 [sync2PlanRestore]。
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
    'ingest_batch',
    'ingest_commit',
    'ingest_finish',
    'replay_pending',
    'import',
    'resolve',
    'trust',
    'purge',
    'checkpoint',
    'restore',
    'dedup',
  };

  /// 发出过的内核命令数（`ffsrs_store_sync2` 一次算一条）：复习路径的 FFI 次数守卫 / 基准用。
  @visibleForTesting
  int debugCoreCommands = 0;

  /// 改投影 / 刷新缓存的 v2 命令：内核在同一次调用里刷新本机缓存行（native/fushi_fsrs/src/store/caches.rs），
  /// 要带上只有 Dart 知道的缓存配置（[_cacheConfig]）。
  static const Set<String> _kSync2CacheOps = <String>{
    'apply',
    'import_drafts',
    'change',
    'note_fields_if',
    'merge_notes',
    'sched',
    'deck_delete',
    'ingest',
    'ingest_batch',
    'ingest_commit',
    'ingest_finish',
    'replay_pending',
    'import',
    'retire',
    'resolve',
    'trust',
    'purge',
    'checkpoint',
    'restore',
    'dedup',
    'refresh_caches',
    'rebuild_caches',
    'cache_config_set',
    'edits_rewrite_repr',
    'backfill_dupe_norms',
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
  /// 笔记、落库时已被同步 / 别处建好的，不算「新增」）。
  Future<Set<String>> importDrafts(List<SrsEventDraft> drafts) async {
    if (drafts.isEmpty) return const <String>{};
    return runExclusive(() async {
      final Set<String> existed = <String>{};
      await _emit(drafts, receive: true, existed: existed);
      return existed;
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
  Future<void> ensureBuiltins() => runExclusive(() async {
    final List<SrsEntityRecord> builtins = srsBuiltinEntities(profileUid);
    final Set<String> present = (await _entityIdsWhere(
      ids: <String>[for (final SrsEntityRecord r in builtins) r.id],
    )).toSet();
    final List<SrsEventDraft> missing = <SrsEventDraft>[
      for (final SrsEntityRecord r in builtins)
        if (!present.contains(r.id)) SrsReadyDraft(SrsEntityEvent(r)),
    ];
    if (missing.isNotEmpty) await _emit(missing);
  });

  String get defaultDeckId => SrsIds.builtinDefaultDeck(profileUid);
  String get lapisNoteTypeId => srsLapisNoteTypeId(profileUid);
  String get fushiCardNoteTypeId => srsFushiCardNoteTypeId(profileUid);

  // ------------------------------------------------------------------ 物化

  /// [noteType] / [noteTypes] 的物化缓存（卡片详情每次 [cardDetail]、制卡选项每次库版本变动都要物化，每次两三次
  /// 读命令往返 + 一次寄存器内核）。键是 [contentFingerprint]，与笔记类型的结构写入严格对应：
  /// - 笔记类型只由它的身份记录与修改记录决定；这两类记录落进投影（本机写入、收段、导入、恢复、冲突解决、清除，
  ///   全是内核命令）一律经 [_absorbProjection] 推进内容修订号（内核 `Marks::entity` / `Marks::edit`：笔记类型
  ///   上没有界面状态类字段键，见 `is_view_state`）。Dart 侧对这两张表的直写只有 [compactStoredStyles]（只动笔记的
  ///   修改记录、只换表示不换值）与 profile 合并删整个旧 profile 的行（之后按新 uid 重开），都碰不到本 profile 的
  ///   笔记类型；
  /// - 重读本机状态（开库、覆盖恢复后、写事务回滚后的 [_loadLocal]）推进它，纪元随覆盖恢复更换；
  /// - 复习日志与界面状态（牌组收起 / 排序位、新卡位置）不推进它——它们碰不到笔记类型，所以不在键里
  ///   （[_structureKey] 多出的 [_viewRevision] 只关牌组树）。
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
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, SrsEntityKind.note, chunk);
      out.addAll(await _readWith(pre, () => _materializeNotes(chunk)));
    }
    return out;
  }

  /// 一组实体的物化输入（身份记录 + 全部修改记录），按输入顺序、跳过不存在的 ID；[ids] 为 null = 本 profile 该类的
  /// 全部实体。远程复习库把它交给客户端，客户端用同一个物化内核得出与这里逐字相同的视图（srs_remote_store.dart）。
  Future<List<SrsEntitySource>> entitySources(
    SrsEntityKind kind, {
    Iterable<String>? ids,
  }) async {
    final List<String> wanted =
        ids?.toSet().toList() ?? await _entityIdsWhere(kind: kind);
    final List<SrsEntitySource> out = <SrsEntitySource>[];
    for (final List<String> chunk in _chunks(wanted)) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, kind, chunk);
      await _readWith(pre, () async {
        for (final String id in chunk) {
          final _EntityRow? row = await _entityRow(id);
          if (row == null) continue;
          out.add(
            SrsEntitySource(id, row.payloadJson, await _editItems(kind, id)),
          );
        }
      });
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
  Future<Map<String, SrsEntityEdits>> _entityEditsMany(
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async {
    final Map<String, SrsEntityEdits> out = <String, SrsEntityEdits>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEdits(pre, kind, chunk);
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

  /// 内核交回的缓存写入清单（`cache`：写了整行的笔记 / 卡、删掉的卡）记进变更日志与数字索引（同一个
  /// 独占区里；命令失败时 [_commandOrReload] 会把两者一起作废）。
  void _absorbCache(Map<String, Object?> r) {
    final Map<Object?, Object?>? w = r['cache'] as Map<Object?, Object?>?;
    if (w == null) return;
    List<String> ids(String k) => <String>[
      for (final Object? id in (w[k] as List?) ?? const <Object?>[])
        id! as String,
    ];
    final List<String> notes = ids('notes');
    final List<String> cards = ids('cards');
    final List<String> removed = ids('removed');
    if (notes.isEmpty && cards.isEmpty && removed.isEmpty) return;
    _journalCacheWrite(notes, <String>[...cards, ...removed]);
  }

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

  Future<void> _prefetchEntities(
    _RefreshPrefetch pre,
    Iterable<String> ids,
  ) async {
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.entities[id] = null;
      }
      for (final _EntityRow r in _entityRowsOf(
        await _readTable('entities', <String, Object?>{'ids': chunk}),
      )) {
        pre.entities[r.id] = r;
      }
    }
  }

  /// 一组实体的全部修改记录**原文**（canonical JSON 的 UTF-8 字节）+ 这些记录的服务器时刻（同一条
  /// 语句 LEFT JOIN 出来）：物化整块交给字段寄存器内核，修改记录不在 Dart 侧解析。
  Future<void> _prefetchEdits(
    _RefreshPrefetch pre,
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async {
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.edits['${kind.wire}/$id'] = <SrsEditItem>[];
      }
      final Map<String, List<SrsEditItem>> byId = await _editItemsById(
        <String, Object?>{'kind': kind.wire, 'ids': chunk},
      );
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

  /// 注册本 profile 的缓存配置（`cache_config_set`），内核在同一个 SAVEPOINT 里把缓存补到当前推导口径并记下版本
  /// （native/fushi_fsrs/src/store/cache_rev.rs：版本历史、补哪些行都在那里）。失败照常抛出（打开失败），下次打开重来。
  Future<void> _registerCacheConfig() => runExclusive(() async {
    final Map<String, Object?> r = await _sync2(const <String, Object?>{
      'op': 'cache_config_set',
    });
    debugCacheRevision = (r['current']! as num).toInt();
    _absorbCache(r);
  });

  /// 丢掉全部缓存（笔记 / 卡片缓存行、有效复习投影），由事件重建（缓存不同步，随时可重建）：内核一次调用删
  /// 掉本 profile 的缓存行、按全部笔记与全部有日志的卡重算（native/fushi_fsrs/src/store/caches.rs `rebuild`）。
  /// 内核在同一个 SAVEPOINT 里记下当前推导口径（store/cache_rev.rs）。
  Future<void> rebuildCaches() => _rebuildCaches(resetStyles: false);

  /// [rebuildCaches]；[resetStyles]：同一个 SAVEPOINT 里把存量样式去重的游标归零（[afterRestore]）。
  Future<void> _rebuildCaches({required bool resetStyles}) =>
      runExclusive(() async {
        _resetCacheJournal();
        _absorbCache(
          await _sync2(<String, Object?>{
            'op': 'rebuild_caches',
            if (resetStyles) 'resetStyles': true,
          }),
        );
        if (resetStyles) _styleCursor = 0;
      });

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
  }) async {
    // 收段会话期间不扫：等会话结束（[sync2IngestBegin] 反过来等在途的回放）。
    await sync2IngestSettled();
    _rwkvReplaysInFlight++;
    _rwkvReplaysIdle ??= Completer<void>();
    try {
      return srsDecodeRwkvReplay(
        (await _coreRwkvReplay(
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
        )).materialize().asUint8List(),
      );
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
    return _emit(drafts, stamps: true);
  });

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
    if (drafts.isEmpty && checkpoint == null && moveNotes == null) return;
    // 走一步用的「此刻」与修改记录的时间来源：落库前这一刻取（同 [_emit]）。
    final (int tickNow, SrsTimeSource source) = now();
    final List<Map<String, Object?>> input = await _applyInput(
      drafts,
      receive: false,
      source: source,
    );
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
    });
  });

  /// 一条本机写意图命令（内核自己读现值、自己判、自己写）：一个独占区、一条命令——命令本体、缓存刷新、本机状态行
  /// 在内核的同一笔里（native/fushi_fsrs/src/store/ffi.rs `local_write`）。旧版 HLC 时钟每条写入走一步，用这一刻的
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
    return <String>{...(r['rejected']! as List).cast<String>()};
  }

  /// 把 [absorbIds] 并进 [keepId]（重复笔记的合并，规则见 srs_duplicate_notes.dart 的库注释）：还原点、前身链接、
  /// 补空字段 / 并标签、删除被吸收的笔记是内核的一条命令（`merge_notes`）、一笔——笔记与卡在写锁里读，任何一步出错
  /// 整次合并都不落库。返回挂成前身的卡数与保留笔记没有对应模板的卡数。笔记不存在、笔记类型不同时抛 [StateError]
  /// （文案里带 `not found` / `different note types`）。
  Future<({int linked, int unmatched})> mergeNotesInto(
    String keepId,
    List<String> absorbIds,
  ) async {
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
    return (linked: r['linked']! as int, unmatched: r['unmatched']! as int);
  }

  // ------------------------------------------------------------------ 牌组

  /// 按名字 [name] 在 [parentId] 下（null = 顶层）新建或复活牌组时用的 ID（[createDeck] 与
  /// Anki 导入共用）。先取「父::子」全名确定性派生的 [SrsIds.deck]：多台设备离线各建同名牌组
  /// 落在同一个 ID 上。
  ///
  /// 「同名」按牌组此刻的名字与父牌组认，不按 ID：牌组改过名或挪过父牌组后 ID 不变，按它原来
  /// 的全名再新建时派生 ID 落在它身上——那不是同一个牌组，沿用就会把它改名 / 拽回原处（BUG：
  /// 拖放挪走 A 后再按「A」建牌组，挪走的那个被拽回顶层）。这时依次试 [SrsIds.deckAlternate]
  /// 的备选 ID，取第一个没被用过的、或名字与父牌组都一致（可沿用 / 复活）的。只由本机牌组状态
  /// 决定：看到同样牌组状态的设备（含收下了挪动 / 改名记录的其它设备）得到同一个 ID。
  Future<String> deckIdForNew(String name, {String? parentId}) async {
    final SrsDeckTree tree = await deckTree();
    final String parentPath = parentId == null || tree[parentId] == null
        ? ''
        : '${tree.fullName(parentId)}::';
    final String fullPath = '$parentPath$name';
    final String trimmed = name.trim();
    String id = SrsIds.deck(profileUid, fullPath);
    for (int n = 1; ; n++) {
      final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
      if (current.keys.isEmpty ||
          (current.value(SrsFieldKeys.name) == trimmed &&
              current.value(SrsFieldKeys.deckParent) == parentId)) {
        return id;
      }
      id = SrsIds.deckAlternate(profileUid, fullPath, n);
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
    // 身份记录与名字 / 父牌组记录同一个事务落库（以前分两次事务、两次缓存刷新）。
    await _emit(<SrsEventDraft>[
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
      }, current: current),
    ]);
    return id;
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
    final String id = SrsIds.note(profileUid, g);
    // 身份记录与字段修改记录同一个事务、同一次缓存刷新（以前分两次落库，笔记先以空字段生成一遍卡）。这条笔记
    // 已经在（同一个 guid 再建）时值没变的键不再写：内核在落库的那一笔里判，不预读它的修改记录。
    await _emit(
      newNoteDrafts(
        noteTypeId: noteTypeId,
        fieldsById: fieldsById,
        deckId: deckId,
        tags: tags,
        source: source,
        guid: g,
        createdAt: createdAt,
        ifChanged: true,
      ),
    );
    return id;
  });

  /// 新笔记的全部事件草稿（身份记录 + 字段 / 标签 / 来源 / 牌组修改记录），**不落库、不占序号**：
  /// 交给 [importDrafts] 与别的事件攒成一批，序号在落库时才分配（Anki 包导入每批几十条笔记一个事务）。
  ///
  /// [current] 是这条笔记已有的修改记录（值相同的键不再写）；null = 调用方确定本机还没有这条笔记
  /// （导入先查过身份记录），跳过逐条读库。[ifChanged] 见 [newEditDrafts]。
  /// noteId = `SrsIds.note(profileUid, guid)`。
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
  }) {
    final (int nowMs, _) = now();
    final String id = SrsIds.note(profileUid, guid);
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
    final String id = SrsIds.note(profileUid, guid);
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
          stamps: true,
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
      final SrsReviewLog log = logWith(
        Hlc.decode(applied.stamps.single! as String),
      );
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

  /// 内核的一行计数 `[新, 学习, 到期, 总数, 新卡上限, 新卡配额, 复习预算, 缩减原因, FSRS 到期?]` → 摘要。内核与 Dart 的牌组树
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
  /// 张——内核补足时按同一顺序取、最多取这么多，其余的交过去也只会被丢掉。以前开了这一项就把 RWKV 牌组的全部
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
      final _Applied applied = await _applyLocal(input, recvNow: nowMs);
      // 同步合并：别的设备的作答带动了牌组 / 全局状态，RWKV 分数表整表重查（见 rwkvScoresKey）。
      if (applied.landed > 0) _bumpRwkvScores();
    });
  });

  /// 一条本机写命令（[body] 发命令、把结果接进内存）；失败时从库里重读本机状态再抛出。
  ///
  /// 内核在命令的同一个 SAVEPOINT 里做完命令本体、缓存刷新、排队与本机状态行
  /// （native/fushi_fsrs/src/store/ffi.rs `local_write`），要么全落、要么全不落。收段通道没做完时内核在命令之前先把它
  /// 按片做完，那些片落进投影的变化随回包的 `settled` 交回（[_absorbSettled]）。
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

  /// 回包里的 `settled`：收段通道在这条命令之前自己做完的片（内核 store/sync2/channel.rs `settle`——分发器在要
  /// 完整投影的命令之前、导入 / 停用设备之前、并入提交之前、新收段会话开始时）落进投影的变化。那些片没有自己的
  /// 回包，内核攒着、随这个 profile 的下一条命令交回一次（请求带 `settled: true`，[_sync2Raw] / [_columnsCommand]
  /// 统一带）。形态同改投影命令的回包（`marks` / `changed` / `purged` + 此刻库里的 `localRevision` / `localEpoch`），
  /// 接法也相同（[_absorbProjection]）：不接的话 [_structureKey] / [contentFingerprint] / [rwkvScoresKey] 不动，
  /// 牌组树、profile 修改记录、分数表读到的还是通道做完之前的。通道带来的是对端事件：落了就再推进一次分数表的
  /// 全量刷新（同 [applyRemote]）。
  Future<void> _absorbSettled(Object? settled) async {
    if (settled is! Map) return;
    final Map<String, Object?> r = settled.cast<String, Object?>();
    final Object? revision = r['localRevision'];
    final Object? epoch = r['localEpoch'];
    if (revision is! int || epoch is! String) {
      throw StateError(
        'srs: a `settled` hand-over lacks `localRevision` / `localEpoch`',
      );
    }
    final int landed = _absorbProjection(r);
    _adoptRevision(revision, epoch);
    if (landed > 0) _bumpRwkvScores();
    await _notifyPurged();
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
  Future<void> afterRestore({bool freshIncarnation = false}) =>
      // 恢复进来的行可能还是内联样式：存量去重从头再查一遍（游标随重建在同一个 SAVEPOINT 里归零）。
      _rebuildCaches(resetStyles: true);

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

  /// 统计页的三张表（内核 `stats_bundle`：可见卡的统计列、出处字典、有效复习投影，另有复习归属到的不可见卡 ID），
  /// 见 `loadSrsStats`。
  Future<Map<String, SrsColumns>> statsColumns() async =>
      (await _columnsCommand(const <String, Object?>{
        'op': 'stats_bundle',
      })).tables;

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

  /// 缓存行的变化代号：每次 [_absorbCache] 写入 +1，缓存被整体换掉（[_resetCacheJournal]）也 +1。
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
  /// 缓存行只经 [_absorbCache] 写，所以导入、同步、编辑、复习、更改笔记类型都在这里留痕。
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
  const _Applied(this.landed, this.stamps);

  /// `apply` 的前置条件（`expectLast`）不成立：什么都没落（按同一个对象判）。
  static const _Applied stale = _Applied(0, <Object?>[]);

  final int landed;
  final List<Object?> stamps;
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
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<Uint8List> _coreCalibrationItems(
  int address,
  String? libraryPath,
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
    ),
  ),
  measure: (Uint8List b) => (b.length, 0),
);

Future<Uint8List> _coreRwkvCards(
  int address,
  String? libraryPath,
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
