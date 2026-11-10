/// 复习页正在显示（或预取好）的一张卡「读自库的哪一版」，以及库变了之后它还新不新鲜。
///
/// 复习页刻意不 watch `srsRevisionProvider`（每评一张卡整页重建的教训，见 `srs_review_page.dart` 的
/// `_guarded`），只 listen 它，再用这里的判据决定要不要重读当前这张：与当前卡无关的变化（别的卡被同步拉进来、
/// 别的牌组改了设置）什么也不做。
///
/// 判据只用库现有的变更信息，不另立机制：
/// - 卡片 / 笔记：缓存行变更日志（[SrsDbStore.cacheChangesSince]）。缓存行只经内核的投影命令写，评分、编辑、
///   换牌组、暂停 / 搁置、同步拉入、更改笔记类型，以及笔记类型上影响缓存行的修改（模板、字段……）都会让这张卡
///   或它的笔记出现在日志里。日志答不了（远程库没有日志、日志滚掉了、事务回滚后作废）时退回逐项比对：
///   卡片行逐列比；笔记字段的修改推进内容指纹，指纹变了才比笔记的修改记录。
/// - 笔记类型的 CSS / 名字 / 字段说明、牌组设置：不写卡片 / 笔记缓存行，不在日志里；但都推进内容指纹
///   （[SrsDbStore.contentFingerprint]）。指纹变了才去比这张卡的笔记类型、牌组链的修改记录签名
///   （[srsEditsSignature]）——两者都按指纹缓存在库里，读一次不碰盘。
library;

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 读一份数据**之前**记下的库版本：之后落库的写入一定在 [cacheGeneration] 之后的日志里、或推进了
/// [contentFingerprint]。
class SrsStoreMark {
  const SrsStoreMark({
    required this.cacheGeneration,
    required this.contentFingerprint,
  });

  /// 此刻的库版本（同步读两个计数，不碰盘）。
  factory SrsStoreMark.of(SrsDbStore store) => SrsStoreMark(
    cacheGeneration: store.cacheGeneration,
    contentFingerprint: store.contentFingerprint,
  );

  final int cacheGeneration;
  final String contentFingerprint;
}

/// 一个实体此刻生效的修改记录的签名：每个字段键上没被支配的记录 ID + 删除时刻。值变了（本机、同步、
/// 备份恢复）必然换记录，签名就变；反过来签名相同 = 内容相同。[skipKey] 为真的字段键不计入。
String srsEditsSignature(
  SrsEntityEdits edits, {
  bool Function(String key)? skipKey,
}) {
  final List<String> keys = <String>[
    for (final String k in edits.keys)
      if (skipKey == null || !skipKey(k)) k,
  ]..sort();
  final StringBuffer out = StringBuffer('${edits.deletedAt}');
  for (final String k in keys) {
    out
      ..write('|')
      ..write(k)
      ..write('=');
    for (final SrsFieldEdit e in edits[k]?.live ?? const <SrsFieldEdit>[]) {
      out
        ..write(e.id)
        ..write(',');
    }
  }
  return out.toString();
}

bool _deckViewStateKey(String key) =>
    srsFieldClassOf(SrsEntityKind.deck, key) == SrsFieldClass.viewState;

/// 一张卡在复习页上用到的牌组设置的签名：卡的有效牌组到顶层的整条链（步长 / 上限是自己的，算法 / 参数 /
/// 记忆率 / 音频开关来自 own 祖先，全名来自各级名字），加上正在复习的牌组那条链（标题、计数上限）。
/// 牌组的界面状态（收起 / 展开、排序位）不计入。
String srsDeckChainSignature(
  SrsDeckTree tree, {
  required String cardDeckId,
  required String reviewDeckId,
  required String defaultDeckId,
}) {
  final StringBuffer out = StringBuffer();
  void chain(String start) {
    String? cur = start;
    int guard = 0;
    while (cur != null && guard++ < 64) {
      final SrsDeckView? d = tree[cur];
      if (d == null) break;
      out
        ..write(d.id)
        ..write(':')
        ..write(srsEditsSignature(d.edits, skipKey: _deckViewStateKey))
        ..write(';');
      cur = tree.parentOf(cur);
    }
    out.write('#');
  }

  chain(tree.effectiveDeckOf(cardDeckId, fallback: defaultDeckId));
  chain(reviewDeckId);
  return out.toString();
}

/// 显示中的一张卡读自库的哪一版。
class SrsShownCardStamp {
  const SrsShownCardStamp({
    required this.mark,
    required this.card,
    required this.noteTypeId,
    required this.noteSignature,
    required this.noteTypeSignature,
    required this.deckSignature,
  });

  /// [mark]：读 [detail] 之前记下的库版本；[tree]：与 [detail] 同一轮读到的牌组树。
  factory SrsShownCardStamp.of(
    SrsStoreMark mark,
    SrsCardDetail detail,
    SrsDeckTree tree, {
    required String reviewDeckId,
    required String defaultDeckId,
  }) => SrsShownCardStamp(
    mark: mark,
    card: detail.card,
    noteTypeId: detail.noteType.id,
    noteSignature: srsEditsSignature(detail.note.edits),
    noteTypeSignature: srsEditsSignature(detail.noteType.edits),
    deckSignature: srsDeckChainSignature(
      tree,
      cardDeckId: detail.card.deckId,
      reviewDeckId: reviewDeckId,
      defaultDeckId: defaultDeckId,
    ),
  );

  final SrsStoreMark mark;
  final SrsCardCacheRow card;
  final String noteTypeId;
  final String noteSignature;
  final String noteTypeSignature;
  final String deckSignature;

  String get cardId => card.id;
  String get noteId => card.noteId;

  /// 已确认 [mark] 到 [now] 之间没有关它的事的变化：同一份内容，版本记到 [now]。
  SrsShownCardStamp rebased(SrsStoreMark now) => SrsShownCardStamp(
    mark: now,
    card: card,
    noteTypeId: noteTypeId,
    noteSignature: noteSignature,
    noteTypeSignature: noteTypeSignature,
    deckSignature: deckSignature,
  );
}

/// [stamp] 记下的那一版之后，库里有没有关这张卡显示的变化：卡片行、笔记、笔记类型（模板 / CSS）、
/// 牌组链的设置与名字。正在复习的牌组 [reviewDeckId] 决定标题与计数上限，一并比。
Future<bool> srsShownCardStale(
  SrsDbStore store,
  SrsShownCardStamp stamp, {
  required String reviewDeckId,
}) async {
  final ({Set<String> notes, Set<String> cards})? changes = store
      .cacheChangesSince(stamp.mark.cacheGeneration);
  if (changes != null) {
    if (changes.cards.contains(stamp.cardId) ||
        changes.notes.contains(stamp.noteId)) {
      return true;
    }
  } else if (await store.cardRow(stamp.cardId) != stamp.card) {
    return true;
  }
  // 评分只落日志，不推进内容指纹：指纹没变就不可能改了笔记 / 笔记类型 / 牌组（远程库每评一张卡只多一次
  // 卡片行的读，与以前相同）。
  if (store.contentFingerprint == stamp.mark.contentFingerprint) return false;
  if (changes == null) {
    final SrsNoteView? note = await store.note(stamp.noteId);
    if (note == null || srsEditsSignature(note.edits) != stamp.noteSignature) {
      return true;
    }
  }
  final SrsNoteTypeView? type = await store.noteType(stamp.noteTypeId);
  if (type == null ||
      srsEditsSignature(type.edits) != stamp.noteTypeSignature) {
    return true;
  }
  final SrsDeckTree tree = await store.deckTree();
  return srsDeckChainSignature(
        tree,
        cardDeckId: stamp.card.deckId,
        reviewDeckId: reviewDeckId,
        defaultDeckId: store.defaultDeckId,
      ) !=
      stamp.deckSignature;
}
