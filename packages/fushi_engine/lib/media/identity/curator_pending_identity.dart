/// 书 / 漫画与游戏的待确认身份数据源：从 AI 库管家的运行记录 + 当前库状态派生。
///
/// 库管家（`library_curator.dart` 的 `_scrapeBooks` / `_scrapeGames`）认不出的单元
/// 记成运行记录里的 `book_scrape_pending` / `game_scrape_pending` 待确认项，并把单元
/// 键记进 [LibraryCurateState.seen]（`scrape.books:<单元>` / `scrape.games:<游戏 id>`）。
/// 这里把两者与**当前**的「还缺资料」判据（库管家自己用的同一份事实：
/// [LibraryCurateFacts.bookScrapeUnits] / [LibraryCurateFacts.gameScrapeUnits]，全量、
/// 不看水位）对一遍：
/// * 当前已经不缺资料（用户手动刮过、后来的某趟认出来了、书 / 游戏删了）→ 不列；
/// * 还缺资料且库管家试过没认出来 → 列，原因取最近一趟的待确认项（运行记录只留
///   最近 [kLibraryCurateRunHistoryLimit] 趟；更早的只剩 `seen`，原因记为未知）；
/// * 还缺资料但库管家从没试过 → 不列（还没轮到它，不是「认不出来」）。
///
/// 不落任何新状态：忽略走 `pending_identity.dart` 的忽略域（书与漫画共用
/// `book_scrape_ignored_works`，游戏 `game_scrape_ignored_works`）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';

/// 书 / 漫画（[CuratorPendingIdentityDomain.books]）或游戏
/// （[CuratorPendingIdentityDomain.games]）。
enum CuratorPendingIdentityDomain {
  books(
    LibraryCurateStage.scrapeBooks,
    'book_scrape_pending',
    PendingIdentityIgnoreDomain.book,
  ),
  games(
    LibraryCurateStage.scrapeGames,
    'game_scrape_pending',
    PendingIdentityIgnoreDomain.game,
  );

  const CuratorPendingIdentityDomain(
    this.stage,
    this.pendingKind,
    this.ignoreDomain,
  );

  final LibraryCurateStage stage;
  final String pendingKind;
  final PendingIdentityIgnoreDomain ignoreDomain;
}

/// 库管家待确认项的原因短码 → 统一原因。
///
/// `no_candidates`：资料源查无；`ambiguous`：有候选但没有能直接认的（多个，或唯一
/// 一个标题对不上）；`low_confidence`：AI 选了但置信度不到自动采用门槛。都不认识
/// 时为 null（界面如实说「记录里没有原因」）。
PendingIdentityCause? pendingIdentityCauseOfCuratorReason(String? reason) =>
    switch (reason) {
      'no_candidates' => PendingIdentityCause.notFound,
      'ambiguous' ||
      'low_confidence' => PendingIdentityCause.awaitingConfirmation,
      // 认出了作品，但资料源没给这本缺的字段（作者 / 封面 / 书名）。
      'no_fields' => PendingIdentityCause.noUsableCandidate,
      _ => null,
    };

/// 库管家待确认项的 AI 结论。新记录带 `ai`；旧记录只能从原因推：
/// `low_confidence` 必然问过 AI 且没采用（declined），其余未知（null）。
PendingIdentityAiOutcome? pendingIdentityAiOfCuratorItem(
  LibraryCuratePendingItem item,
) {
  final String? wire = item.ai;
  if (wire != null) return PendingIdentityAiOutcome.fromWire(wire);
  return item.reason == 'low_confidence'
      ? PendingIdentityAiOutcome.declined
      : null;
}

/// [PendingIdentitySource] 的书 / 漫画与游戏实现。
class CuratorPendingIdentitySource implements PendingIdentitySource {
  CuratorPendingIdentitySource({
    required this.db,
    required this.store,
    required this.facts,
    required this.domain,
  });

  final FushiDatabase db;
  final LibraryCurateStore store;
  final LibraryCurateFacts facts;
  final CuratorPendingIdentityDomain domain;

  @override
  Future<PendingIdentityListing> load() async {
    final LibraryCurateState state = await store.load();
    final Map<String, (LibraryCuratePendingItem, int)> items =
        _latestPendingItems(state);
    final List<PendingIdentityEntry> all = switch (domain) {
      CuratorPendingIdentityDomain.books => _books(
        await facts.bookScrapeUnits(null),
        state,
        items,
      ),
      CuratorPendingIdentityDomain.games => _games(
        await facts.gameScrapeUnits(null),
        state,
        items,
      ),
    };
    final Set<String> ignoredKeys = await loadPendingIdentityIgnored(
      db,
      domain.ignoreDomain,
    );
    return PendingIdentityListing(
      pending: <PendingIdentityEntry>[
        for (final PendingIdentityEntry e in all)
          if (!ignoredKeys.contains(e.key)) e,
      ],
      ignored: <PendingIdentityEntry>[
        for (final PendingIdentityEntry e in all)
          if (ignoredKeys.contains(e.key)) e,
      ],
    );
  }

  @override
  Future<void> setIgnored(Iterable<String> keys, {required bool ignored}) =>
      setPendingIdentityIgnored(
        db,
        domain.ignoreDomain,
        keys,
        ignored: ignored,
      );

  /// 每个 ref 最近一趟（运行记录新的在前）留下的待确认项 + 那趟的开始时刻。
  Map<String, (LibraryCuratePendingItem, int)> _latestPendingItems(
    LibraryCurateState state,
  ) {
    final Map<String, (LibraryCuratePendingItem, int)> out =
        <String, (LibraryCuratePendingItem, int)>{};
    final List<LibraryCurateRun> runs = <LibraryCurateRun>[...state.runs]
      ..sort((LibraryCurateRun a, LibraryCurateRun b) => b.id - a.id);
    for (final LibraryCurateRun run in runs) {
      for (final LibraryCuratePendingItem item in run.pendingItems) {
        final String? ref = item.ref;
        if (item.kind != domain.pendingKind || ref == null) continue;
        out.putIfAbsent(ref, () => (item, run.startedAt));
      }
    }
    return out;
  }

  List<PendingIdentityEntry> _books(
    List<LibraryCurateBookUnit> units,
    LibraryCurateState state,
    Map<String, (LibraryCuratePendingItem, int)> items,
  ) => <PendingIdentityEntry>[
    for (final LibraryCurateBookUnit unit in units)
      ?_bookEntry(unit, state, items),
  ];

  PendingIdentityEntry? _bookEntry(
    LibraryCurateBookUnit unit,
    LibraryCurateState state,
    Map<String, (LibraryCuratePendingItem, int)> items,
  ) {
    // 各卷都已写回过（库管家认为这本做完了，只是候选没给全字段）：不算没认出来。
    final List<LibraryCurateBookVolume> open = <LibraryCurateBookVolume>[
      for (final LibraryCurateBookVolume v in unit.volumes)
        if (!state.seen.contains('scrape.books.done:${v.shelfKey}')) v,
    ];
    if (open.isEmpty) return null;
    // 单元 id 优先；单元变过形（单本后来进了系列 / 系列只剩一卷待刮）时按卷对号。
    final List<String> refs = <String>[
      unit.id,
      for (final LibraryCurateBookVolume v in open) v.shelfKey,
    ];
    (LibraryCuratePendingItem, int)? found;
    for (final String ref in refs) {
      found = items[ref];
      if (found != null) break;
    }
    final bool seen = refs.any(
      (String ref) => state.seen.contains('scrape.books:$ref'),
    );
    if (found == null && !seen) return null;
    return _entry(
      kind: open.every((LibraryCurateBookVolume v) => v.manga)
          ? PendingIdentityMediaKind.manga
          : PendingIdentityMediaKind.book,
      key: unit.id,
      title: unit.title,
      found: found,
      memberKeys: <String>[
        for (final LibraryCurateBookVolume v in open) v.bookKey,
      ],
    );
  }

  List<PendingIdentityEntry> _games(
    List<LibraryCurateGameUnit> units,
    LibraryCurateState state,
    Map<String, (LibraryCuratePendingItem, int)> items,
  ) => <PendingIdentityEntry>[
    for (final LibraryCurateGameUnit game in units)
      if (items['game:${game.id}'] case final found?)
        _entry(
          kind: PendingIdentityMediaKind.game,
          key: 'game:${game.id}',
          title: game.title,
          found: found,
          memberKeys: <String>[game.id],
        )
      else if (state.seen.contains('scrape.games:${game.id}'))
        _entry(
          kind: PendingIdentityMediaKind.game,
          key: 'game:${game.id}',
          title: game.title,
          found: null,
          memberKeys: <String>[game.id],
        ),
  ];

  static PendingIdentityEntry _entry({
    required PendingIdentityMediaKind kind,
    required String key,
    required String title,
    required (LibraryCuratePendingItem, int)? found,
    required List<String> memberKeys,
  }) {
    final LibraryCuratePendingItem? item = found?.$1;
    return PendingIdentityEntry(
      kind: kind,
      key: key,
      // 书名是身份（bookKey / 统计 / 同步），存储里带着文件名残留的 CRC 标签 /
      // 扩展名；这里是显示出口，与书架卡同口径清洗（BUG-5284）。
      title: cleanImportedTitle(title),
      cause: pendingIdentityCauseOfCuratorReason(item?.reason),
      aiOutcome: item == null ? null : pendingIdentityAiOfCuratorItem(item),
      candidateCount: item?.candidates ?? 0,
      lastAttemptAt: found == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(found.$2),
      memberKeys: memberKeys,
    );
  }
}
