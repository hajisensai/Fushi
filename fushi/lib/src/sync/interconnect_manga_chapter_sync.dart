import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/manga_chapter_progress_sync.dart';

/// 一本章节式互联漫画一次按章同步的结果（[InterconnectMangaChapterSync.syncOne]）。
///
/// [supported] 为 false = host 没有这条路由（老 host）或 host 上没有这本漫画（404），本次什么都没做。
/// [pulled] = 落到本端的章数（host 较新）；[pushed] = 推给 host 且 host 合并后停在本端那份上的章数。
typedef MangaChapterSyncStep = ({bool supported, int pulled, int pushed});

/// 互联同步分章漫画的每章阅读进度（拍板台 design-ic-manga-chapter-progress，反馈 2bNEiehLgw）。
///
/// 只管**章节式**互联漫画（host 端是 Mihon / Aidoku 等分章条目）：书级 `reader_positions` 对它们不带
/// 章身份、不参与书进度同步（[InterconnectBookProgressSync.hostBookKeyOf]，BUG-5352），真正的进度在
/// `manga_chapter_states`。两端章 key 逐字相同，所以按章取 `updatedAt` 较新的一方（判定在引擎
/// [planMangaChapterStateSync] / [mangaChapterStateReplaces]，与 host 合并 PUT 同一个函数）：
///
/// 1. `GET` host 这本书的章状态（404 = 老 host / host 上没这本 → 静默跳过）；
/// 2. host 较新的章按章比较后写入本端（事务内读-比较-写，与本机阅读器互不插队，`updatedAt` 逐字
///    保留：它也是「继续阅读」选章的依据）；
/// 3. 本端较新的章 `PUT` 给 host，host 合并后回全部章状态，再按同一规则落一遍（PUT 期间 host 上又被
///    改过的章在这里收下）。
///
/// 已读 / 未读标记是同一行的 `readAt`，随行同步；行从不单删，不需要墓碑。
///
/// 全量 sweep（`SyncOrchestrator`）与退出书的单本同步（`syncExitedBookOnChannel`）共用 [syncOne]。
/// 一个实例一生只绑一台 host（[bind]），会话中途换了 host 时 live 读写抛
/// [InterconnectHostChangedException]。调用方须持有这本书的书锁。
class InterconnectMangaChapterSync {
  InterconnectMangaChapterSync({
    required FushiDatabase db,
    required InterconnectSyncBackend backend,
  }) : _db = db,
       _backend = backend;

  final FushiDatabase _db;
  final InterconnectSyncBackend _backend;

  Future<InterconnectHostPin>? _binding;

  /// 这本书在 host 上的 wire 键；null = 不是章节式互联漫画，不走章级同步。
  ///
  /// 单卷互联漫画不在这里：它唯一那章的进度随书级进度落地（BUG-5352），host 端单卷书也没有章状态。
  static String? hostBookKeyOf(EpubBookRow book) {
    final OnlineMangaLibraryEntry? entry =
        InterconnectBookProgressSync.interconnectMangaEntryOf(book);
    if (entry == null || entry.series.raw['chaptered'] != true) return null;
    if (book.uid.isEmpty) return null;
    final String peerKey = entry.series.key;
    return peerKey.isEmpty ? null : peerKey;
  }

  /// 这本书是否走章级同步（[hostBookKeyOf] 非 null）。
  static bool syncsChapterProgress(EpubBookRow book) =>
      hostBookKeyOf(book) != null;

  /// 绑到会话此刻所连的 host（不发请求）。同一实例只绑一次；失败下次重试。
  Future<InterconnectHostPin> bind() =>
      _binding ??= _backend.liveHostScope().then(
        (InterconnectHostScope scope) => scope.pin,
        onError: (Object e, StackTrace st) {
          _binding = null;
          Error.throwWithStackTrace(e, st);
        },
      );

  /// 对一本章节式互联漫画跑一次按章 LWW 同步。[book] 不走章级同步时抛 [ArgumentError]（调用方漏了
  /// [syncsChapterProgress] 过滤）。
  Future<MangaChapterSyncStep> syncOne(EpubBookRow book, {int? nowMs}) async {
    final String? hostKey = hostBookKeyOf(book);
    if (hostKey == null) {
      throw ArgumentError.value(
        book.bookKey,
        'book',
        'is not a chaptered interconnect manga',
      );
    }
    final InterconnectHostPin pin = await bind();
    final Map<String, RemoteMangaChapterState>? remote = await _backend
        .getLiveMangaChapterProgress(hostKey, pin: pin);
    if (remote == null) return (supported: false, pulled: 0, pushed: 0);
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final MangaChapterSyncPlan plan = planMangaChapterStateSync(
      local: await readMangaChapterStates(_db, book.uid),
      remote: remote,
      nowMs: now,
    );
    int pulled = (await landMangaChapterStates(
      _db,
      bookUid: book.uid,
      incoming: plan.pull,
      nowMs: now,
    )).length;
    int pushed = 0;
    if (plan.push.isNotEmpty) {
      final Map<String, RemoteMangaChapterState>? merged = await _backend
          .putLiveMangaChapterProgress(hostKey, plan.push, pin: pin);
      if (merged == null) {
        // GET 之后这本书在 host 上被删了：本端已落的照留，推送作罢。
        return (supported: false, pulled: pulled, pushed: 0);
      }
      for (final MapEntry<String, RemoteMangaChapterState> e
          in plan.push.entries) {
        final RemoteMangaChapterState? landed = merged[e.key];
        if (landed != null && _sameReading(landed, e.value)) pushed++;
      }
      // host 合并后的那份按同一规则再落一遍：PUT 期间 host 上被改得更新的章在这里收下；本端推上去的
      // 章 host 停在同一份上，比较后不写。
      pulled += (await landMangaChapterStates(
        _db,
        bookUid: book.uid,
        incoming: merged,
        nowMs: now,
      )).length;
    }
    return (supported: true, pulled: pulled, pushed: pushed);
  }

  /// 两份章状态除时间戳外相同（host 落地时会把超限的未来戳截短，戳不一定逐字相同）。
  static bool _sameReading(
    RemoteMangaChapterState a,
    RemoteMangaChapterState b,
  ) =>
      a.lastPage == b.lastPage &&
      a.lastFraction == b.lastFraction &&
      a.pageCount == b.pageCount &&
      a.readAt == b.readAt;
}
