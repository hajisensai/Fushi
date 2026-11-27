/// 书 / 漫画「继续阅读」选书的**唯一判据**（BUG-5332）。
///
/// 侧栏书 / 漫画速览（`home_nav_peek.dart` 的 `_loadBooks`）、书架 / 漫画库顶部
/// 「继续阅读」（`reader_fushi_history_page.dart` 的 `_pickShelfContinue`）与首页
/// 「继续」区的书那部分（`home_dashboard_page.dart` 的 `_computeContinueEntries`）
/// 都只经 [selectBookContinueCandidates] 选书，不许各写一份。此前三处各有一套：
///
/// - 首页按主折叠合集归组跑 Next-Up（读完第 1 卷 → 第 2 卷）；
/// - 速览先按合集折叠成「最近读过的那一卷」，只有它恰好「在读」才给继续，读完
///   第 1 卷后这套书从「继续」消失，「最近」里点开的还是读完的第 1 卷；
/// - 书架 hero 根本不看合集，只在「在读」的书里挑最近读的一本。
///
/// 于是同一时刻三张卡给三个答案（合集最新一卷读完、旧一卷读到一半时也各不相同）。
///
/// 规则：
/// - 合集单元（条目的主折叠合集，合集行已删的孤儿引用退回散书）：组内按
///   sortIndex 排序后跑 [bookCollectionContinueIndex]（与视频合集同一个
///   [continueMemberIndex]：锚点 = 最近读过的那卷，它读完就推进下一卷）；整组一卷
///   都没开读或整套读完不出候选。单元时刻 = 组内各卷最近阅读时刻最大值。
/// - 散书：[classifyShelfReadStatus] 判「在读」才进候选，时刻 = 它的最近阅读时刻。
/// - 读完判据一律 [classifyShelfReadStatus]（`EpubBooks.completedAt` 优先于进度）。
/// - 候选按时刻倒序；并列保留输入顺序。
///
/// 最近阅读时刻的来源见 [mergeMangaChapterReadRecency]：`reader_positions` 之外，
/// 在线漫画只在作品页「标记已读」（或 Kavita 对齐）过的章也算读过。
library;

import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/book_media_identifier.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind;
import 'package:fushi_engine/media/collections/book_series_key.dart'
    show collectionMemberVolumeNumber;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, classifyShelfReadStatus;
import 'package:meta/meta.dart';

/// 一本书参与选书所需的事实。
@immutable
class BookContinueFacts {
  const BookContinueFacts({
    required this.position,
    required this.duration,
    required this.completed,
    required this.readAt,
  });

  final int position;
  final int duration;

  /// 显式标记读完（`EpubBooks.completedAt` 非空）。
  final bool completed;

  /// 最近阅读毫秒时刻；0 = 没有记录。
  final int readAt;

  ShelfReadStatus get status => classifyShelfReadStatus(
    completed: completed,
    position: position,
    duration: duration,
  );
}

/// 一个「继续阅读」候选：散书，或合集的续读目标那一卷。
@immutable
class BookContinueCandidate<T> {
  const BookContinueCandidate({
    required this.item,
    required this.recentMs,
    this.collectionId,
    this.members = const <Never>[],
    this.memberIndex = -1,
  });

  /// 打开的那一本（合集 = 续读目标卷）。
  final T item;

  /// 单元的最近阅读时刻（合集 = 组内各卷最大值，含读完的卷）。
  final int recentMs;

  /// null = 散书。
  final int? collectionId;

  /// 合集全部成员（组内 sortIndex 序）；散书为空。
  final List<T> members;

  /// [item] 在 [members] 里的下标；散书 -1。
  final int memberIndex;

  bool get isSeries => collectionId != null;

  /// 合集里第几个（1 起）；散书或只有一卷的合集为 null（不标卷号）。
  int? get memberOrdinal => members.length >= 2 ? memberIndex + 1 : null;

  /// 「第 N 卷」的 N（卷号优先，见 [collectionMemberVolumeNumber]）；散书 /
  /// 单卷合集为 null。[titleOf] 取卡片上显示的书名。
  num? volumeNumber(String Function(T item) titleOf) {
    final int? ordinal = memberOrdinal;
    if (ordinal == null) return null;
    return collectionMemberVolumeNumber(
      title: titleOf(item),
      memberTitles: <String>[for (final T m in members) titleOf(m)],
      memberOrdinal: ordinal,
    );
  }
}

/// 书合集的续读目标下标（[sorted] 已按组内 sortIndex 排好）。
///
/// 用户实报：20 卷的合集读完第 1 卷，「继续」区里这套书直接消失、第 2 卷不出现。
/// 与视频合集 Next-Up 同一判据 [continueMemberIndex]（锚点 = 最近读过的那卷，它
/// 读完就推进下一卷）。整组一卷都没开始读（不劝人从头开始）或目标仍是读完的卷
/// （整套读完）→ null，合集不出候选。
int? bookCollectionContinueIndex(List<CollectionMemberProgress> sorted) {
  if (!sorted.any((CollectionMemberProgress m) => m.hasStarted)) return null;
  final int idx = continueMemberIndex(sorted);
  if (sorted[idx].completed) return null;
  return idx;
}

/// 从 [books] 选出「继续阅读」候选（时刻倒序）。规则见库注释。
///
/// [collectionIdOf] 返回条目的主折叠合集 id，合集行不存在（孤儿引用）时调用方
/// 应返回 null 让它按散书算；[sortIndexOf] 是条目在该合集里的 sortIndex（缺失
/// 沉底），并列按 [idOf] 排。
List<BookContinueCandidate<T>> selectBookContinueCandidates<T>({
  required Iterable<T> books,
  required BookContinueFacts Function(T item) factsOf,
  required int? Function(T item) collectionIdOf,
  required int? Function(T item) sortIndexOf,
  required String Function(T item) idOf,
}) {
  // (候选, 输入序) —— 输入序做并列时的稳定次序（List.sort 不保证稳定）。
  final List<(BookContinueCandidate<T>, int)> out =
      <(BookContinueCandidate<T>, int)>[];
  final Map<int, List<T>> byCollection = <int, List<T>>{};
  final Map<int, int> collectionOrder = <int, int>{};
  final Map<T, BookContinueFacts> facts = <T, BookContinueFacts>{};
  int order = 0;
  for (final T item in books) {
    final int position = order++;
    final BookContinueFacts f = facts[item] = factsOf(item);
    final int? cid = collectionIdOf(item);
    if (cid != null) {
      (byCollection[cid] ??= <T>[]).add(item);
      collectionOrder.putIfAbsent(cid, () => position);
      continue;
    }
    if (f.status == ShelfReadStatus.reading) {
      out.add((
        BookContinueCandidate<T>(item: item, recentMs: f.readAt),
        position,
      ));
    }
  }
  for (final MapEntry<int, List<T>> group in byCollection.entries) {
    final List<T> sorted = List<T>.of(group.value)
      ..sort((T a, T b) {
        final int ai = sortIndexOf(a) ?? 1 << 30;
        final int bi = sortIndexOf(b) ?? 1 << 30;
        if (ai != bi) return ai.compareTo(bi);
        return idOf(a).compareTo(idOf(b));
      });
    final int? idx = bookCollectionContinueIndex(<CollectionMemberProgress>[
      for (final T m in sorted)
        CollectionMemberProgress(
          positionMs: facts[m]!.position,
          completed: facts[m]!.status == ShelfReadStatus.finished,
          lastPlayedAt: facts[m]!.readAt,
        ),
    ]);
    if (idx == null) continue;
    int recent = 0;
    for (final T m in sorted) {
      final int at = facts[m]!.readAt;
      if (at > recent) recent = at;
    }
    out.add((
      BookContinueCandidate<T>(
        item: sorted[idx],
        recentMs: recent,
        collectionId: group.key,
        members: List<T>.unmodifiable(sorted),
        memberIndex: idx,
      ),
      collectionOrder[group.key]!,
    ));
  }
  out.sort((
    (BookContinueCandidate<T>, int) a,
    (BookContinueCandidate<T>, int) b,
  ) {
    final int byRecent = b.$1.recentMs.compareTo(a.$1.recentMs);
    return byRecent != 0 ? byRecent : a.$2.compareTo(b.$2);
  });
  return <BookContinueCandidate<T>>[
    for (final (BookContinueCandidate<T>, int) c in out) c.$1,
  ];
}

/// 书条目在合集归属表里的键（`epub|<uid>`）。归属表键 = uid（v83）；旧合集还挂
/// 着 `epub|<bookKey>` 的退到它，否则这卷按散书判、续读推进不到下一卷。字幕书
/// 走 `srt|<uid>`；都认不出的（完整 hoshi:// 标识）给一个必然查不中的键（散书）。
String bookCollectionEntryKey(
  MediaItem item, {
  required Map<String, String> epubUidByKey,
  required Map<String, int> primaryCollectionIdByEntry,
}) {
  final String? bookKey = parseBookKeyOfMediaIdentifier(item.mediaIdentifier);
  if (bookKey != null) {
    final String uidKey = MediaKind.epub.compositeKey(
      epubUidByKey[bookKey] ?? bookKey,
    );
    if (primaryCollectionIdByEntry.containsKey(uidKey)) return uidKey;
    final String legacyKey = MediaKind.epub.compositeKey(bookKey);
    return primaryCollectionIdByEntry.containsKey(legacyKey)
        ? legacyKey
        : uidKey;
  }
  final String? srtUid = parseSrtBookUidOfMediaIdentifier(item.mediaIdentifier);
  if (srtUid != null) return MediaKind.srt.compositeKey(srtUid);
  return MediaKind.epub.compositeKey(item.mediaIdentifier);
}

/// [selectBookContinueCandidates] 的书架条目（[MediaItem]）版：三个消费点手里都是
/// 同一组映射，统一在这里换算，不各写一遍键换算 / 读完判据。
///
/// - [lastReadAtByUid]：`bookLastReadAtProvider`（键 = epub uid，bookKey 经
///   [epubUidByKey] 换算；换算不上退回原键，standalone 条目退回 mediaIdentifier）。
/// - [completedBookKeys]：读完的 bookKey 集合。
/// - [collectionIds]：现存合集 id（不在里面的归属 = 孤儿引用，按散书）。
/// - [memberSortIndex]：归属键 → 组内 sortIndex。
List<BookContinueCandidate<MediaItem>> selectMediaItemContinueCandidates({
  required Iterable<MediaItem> books,
  required Map<String, int> lastReadAtByUid,
  required Map<String, String> epubUidByKey,
  required Set<String> completedBookKeys,
  required Map<String, int> primaryCollectionIdByEntry,
  required Set<int> collectionIds,
  required Map<String, int> memberSortIndex,
}) {
  String bookKeyOf(MediaItem item) =>
      parseBookKeyOfMediaIdentifier(item.mediaIdentifier) ??
      item.mediaIdentifier;
  final Map<String, String> entryKeys = <String, String>{};
  String entryKeyOf(MediaItem item) =>
      entryKeys[item.mediaIdentifier] ??= bookCollectionEntryKey(
        item,
        epubUidByKey: epubUidByKey,
        primaryCollectionIdByEntry: primaryCollectionIdByEntry,
      );
  return selectBookContinueCandidates<MediaItem>(
    books: books,
    factsOf: (MediaItem item) {
      final String bookKey = bookKeyOf(item);
      return BookContinueFacts(
        position: item.position,
        duration: item.duration,
        completed: completedBookKeys.contains(bookKey),
        readAt: lastReadAtByUid[epubUidByKey[bookKey] ?? bookKey] ?? 0,
      );
    },
    collectionIdOf: (MediaItem item) {
      final int? cid = primaryCollectionIdByEntry[entryKeyOf(item)];
      return cid != null && collectionIds.contains(cid) ? cid : null;
    },
    sortIndexOf: (MediaItem item) => memberSortIndex[entryKeyOf(item)],
    idOf: (MediaItem item) => item.mediaIdentifier,
  );
}

/// 书的最近阅读时刻表（键 = 书稳定身份，见 `bookLastReadAtProvider`）：
/// `reader_positions.updatedAt` 与该书各章 `manga_chapter_states.readAt` 取大。
///
/// 在线漫画在作品页「标记此章及更早为已读」（或 Kavita 对齐已读）只写章状态表、
/// 不写 `reader_positions`——书架进度（`onlineMangaShelfProgress`）已经认它是「在
/// 读」，最近阅读时刻却是 0：速览旧实现按「时刻 > 0」过滤把它整个丢掉，而首页
/// 照样列出（BUG-5332 G5）。章状态的键也是书 uid，与位置表同一键空间。
Map<String, int> mergeMangaChapterReadRecency({
  required Map<String, int> readerPositionUpdatedAt,
  required Iterable<({String bookUid, int? readAt})> chapterStates,
}) {
  final Map<String, int> out = Map<String, int>.of(readerPositionUpdatedAt);
  for (final ({String bookUid, int? readAt}) s in chapterStates) {
    final int? at = s.readAt;
    if (at == null || at <= 0) continue;
    if (at > (out[s.bookUid] ?? 0)) out[s.bookUid] = at;
  }
  return out;
}
