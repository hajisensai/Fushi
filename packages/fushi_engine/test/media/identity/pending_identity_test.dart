// BUG-5283：书 / 漫画与游戏没认出来的条目在界面上哪里都看不到。待确认身份统一模型：
// 忽略的持久化（视频沿用旧键）、原因 / AI 结论的落库值冻结、书 / 游戏数据源从库管家
// 运行记录 + 当前库状态派生（已修好的条目消失、从没试过的不列、忽略跨次生效）。
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/identity/curator_pending_identity.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ignored_works.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:test/test.dart';

class _Facts implements LibraryCurateFacts {
  List<LibraryCurateBookUnit> books = <LibraryCurateBookUnit>[];
  List<LibraryCurateGameUnit> games = <LibraryCurateGameUnit>[];
  final List<int?> bookSince = <int?>[];
  final List<int?> gameSince = <int?>[];

  @override
  Future<List<LibraryCurateBookUnit>> bookScrapeUnits(int? sinceMs) async {
    bookSince.add(sinceMs);
    return books;
  }

  @override
  Future<List<LibraryCurateGameUnit>> gameScrapeUnits(int? sinceMs) async {
    gameSince.add(sinceMs);
    return games;
  }

  @override
  Future<List<String>> linkEndpointsSince(int? sinceMs) async =>
      const <String>[];

  @override
  Future<bool> musicChangedSince(int? sinceMs) async => false;

  @override
  Future<bool> videoWorksChangedSince(int? sinceMs) async => false;

  @override
  Future<String> changeStamp() async => '';

  @override
  Future<Set<String>?> organizeEntriesSince(
    CollectionShelfDomain domain,
    int? sinceMs,
  ) async => null;

  @override
  Future<int> organizeRequestEstimate(
    CollectionShelfDomain domain,
    Set<String>? only,
  ) async => 0;
}

LibraryCurateBookVolume _vol(String key, String title, {bool manga = false}) =>
    LibraryCurateBookVolume(
      bookKey: key,
      title: title,
      missingCover: true,
      fileNameTitle: false,
      manga: manga,
    );

LibraryCurateBookUnit _single(LibraryCurateBookVolume v) =>
    LibraryCurateBookUnit(
      id: v.shelfKey,
      title: v.title,
      volumes: <LibraryCurateBookVolume>[v],
    );

LibraryCuratePendingItem _bookItem(
  String ref,
  String reason, {
  int? candidates,
  String? ai,
}) => LibraryCuratePendingItem(
  stage: LibraryCurateStage.scrapeBooks,
  kind: 'book_scrape_pending',
  title: ref,
  ref: ref,
  reason: reason,
  candidates: candidates,
  ai: ai,
);

void main() {
  late FushiDatabase db;
  late MemoryLibraryCurateStore store;
  late _Facts facts;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    store = MemoryLibraryCurateStore();
    facts = _Facts();
  });

  tearDown(() => db.close());

  Future<void> saveRuns(List<LibraryCurateRun> runs, {Set<String>? seen}) =>
      store.save(LibraryCurateState(runs: runs, seen: seen));

  CuratorPendingIdentitySource source(CuratorPendingIdentityDomain d) =>
      CuratorPendingIdentitySource(
        db: db,
        store: store,
        facts: facts,
        domain: d,
      );

  group('模型', () {
    test('原因 / AI 结论的落库值冻结，视频别名指向同一枚举', () {
      expect(
        PendingIdentityCause.values.map((PendingIdentityCause c) => c.wire),
        <String>[
          'hash_conflict',
          'no_usable_candidate',
          'awaiting_confirmation',
          'dismissed',
          'not_found',
          'provider_unavailable',
          'error',
        ],
      );
      expect(
        PendingIdentityAiOutcome.values.map(
          (PendingIdentityAiOutcome a) => a.wire,
        ),
        <String>[
          'not_asked',
          'unavailable',
          'unassigned',
          'failed',
          'declined',
          'accepted',
        ],
      );
      expect(
        identical(
          VideoScrapePendingCause.fromWire('not_found'),
          PendingIdentityCause.notFound,
        ),
        isTrue,
      );
      expect(VideoScrapeAiOutcome.declined, PendingIdentityAiOutcome.declined);
    });

    test('忽略：视频域沿用旧键（旧数据原样有效），各域互不影响，坏值当空', () async {
      expect(
        PendingIdentityIgnoreDomain.video.prefKey,
        kVideoScrapeIgnoredWorksPrefKey,
      );
      await db.setPref(kVideoScrapeIgnoredWorksPrefKey, '["collection:1"]');
      expect(
        await loadPendingIdentityIgnored(db, PendingIdentityIgnoreDomain.video),
        <String>{'collection:1'},
      );
      await setPendingIdentityIgnored(
        db,
        PendingIdentityIgnoreDomain.book,
        <String>['book:k1', ''],
        ignored: true,
      );
      expect(await loadIgnoredVideoScrapeWorks(db), <String>{'collection:1'});
      expect(
        await loadPendingIdentityIgnored(db, PendingIdentityIgnoreDomain.book),
        <String>{'book:k1'},
      );
      expect(
        await loadPendingIdentityIgnored(db, PendingIdentityIgnoreDomain.game),
        isEmpty,
      );
      await setPendingIdentityIgnored(
        db,
        PendingIdentityIgnoreDomain.book,
        <String>['book:k1'],
        ignored: false,
      );
      expect(await db.getPref('book_scrape_ignored_works'), isNull);
      await db.setPref('game_scrape_ignored_works', '{oops');
      expect(
        await loadPendingIdentityIgnored(db, PendingIdentityIgnoreDomain.game),
        isEmpty,
      );
      // 漫画与书同一个忽略域。
      expect(
        PendingIdentityMediaKind.manga.ignoreDomain,
        PendingIdentityIgnoreDomain.book,
      );
    });

    test('库管家原因映射', () {
      expect(
        pendingIdentityCauseOfCuratorReason('no_candidates'),
        PendingIdentityCause.notFound,
      );
      expect(
        pendingIdentityCauseOfCuratorReason('ambiguous'),
        PendingIdentityCause.awaitingConfirmation,
      );
      expect(
        pendingIdentityCauseOfCuratorReason('low_confidence'),
        PendingIdentityCause.awaitingConfirmation,
      );
      expect(pendingIdentityCauseOfCuratorReason(null), isNull);
      // 旧记录没有 ai 字段：low_confidence 必然问过 AI。
      expect(
        pendingIdentityAiOfCuratorItem(_bookItem('book:a', 'low_confidence')),
        PendingIdentityAiOutcome.declined,
      );
      expect(
        pendingIdentityAiOfCuratorItem(_bookItem('book:a', 'ambiguous')),
        isNull,
      );
      expect(
        pendingIdentityAiOfCuratorItem(
          _bookItem('book:a', 'ambiguous', ai: 'unassigned'),
        ),
        PendingIdentityAiOutcome.unassigned,
      );
    });
  });

  group('书 / 漫画数据源', () {
    test('试过没认出来的才列；原因取最近一趟；当前不缺资料的消失；从没试过的不列', () async {
      facts.books = <LibraryCurateBookUnit>[
        _single(_vol('k1', 'Alpha')),
        _single(_vol('k2', 'Never tried')),
        _single(_vol('k3', 'Seen only')),
      ];
      await saveRuns(
        <LibraryCurateRun>[
          LibraryCurateRun(
            id: 2,
            trigger: LibraryCurateTrigger.auto,
            startedAt: 2000,
            pendingItems: <LibraryCuratePendingItem>[
              _bookItem(
                'book:k1',
                'ambiguous',
                candidates: 3,
                ai: 'unassigned',
              ),
              // 用户后来手动刮好了：facts 里已经没有它。
              _bookItem('book:fixed', 'no_candidates', candidates: 0),
            ],
          ),
          LibraryCurateRun(
            id: 1,
            trigger: LibraryCurateTrigger.auto,
            startedAt: 1000,
            pendingItems: <LibraryCuratePendingItem>[
              _bookItem('book:k1', 'no_candidates', candidates: 0),
            ],
          ),
        ],
        seen: <String>{'scrape.books:book:k3'},
      );
      final PendingIdentityListing l = await source(
        CuratorPendingIdentityDomain.books,
      ).load();
      // 全量看当前状态（不看水位）。
      expect(facts.bookSince, <int?>[null]);
      expect(l.pending.map((PendingIdentityEntry e) => e.key), <String>[
        'book:k1',
        'book:k3',
      ]);
      final PendingIdentityEntry k1 = l.pending.first;
      expect(k1.kind, PendingIdentityMediaKind.book);
      expect(k1.title, 'Alpha');
      expect(k1.cause, PendingIdentityCause.awaitingConfirmation);
      expect(k1.aiOutcome, PendingIdentityAiOutcome.unassigned);
      expect(k1.candidateCount, 3);
      expect(k1.lastAttemptAt, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(k1.memberKeys, <String>['k1']);
      final PendingIdentityEntry k3 = l.pending.last;
      expect(k3.cause, isNull);
      expect(k3.lastAttemptAt, isNull);
      expect(l.ignored, isEmpty);
    });

    test('显示名清掉文件名残留的 CRC 标签 / 扩展名，键仍是原始书键（BUG-5284）', () async {
      facts.books = <LibraryCurateBookUnit>[
        _single(_vol('raw', '十歳の最強魔導師 第16話 [679fb7c9].cbz')),
      ];
      await saveRuns(<LibraryCurateRun>[
        LibraryCurateRun(
          id: 1,
          trigger: LibraryCurateTrigger.auto,
          startedAt: 1000,
          pendingItems: <LibraryCuratePendingItem>[
            _bookItem('book:raw', 'no_candidates', candidates: 0),
          ],
        ),
      ]);
      final PendingIdentityListing l = await source(
        CuratorPendingIdentityDomain.books,
      ).load();
      expect(l.pending.single.title, '十歳の最強魔導師 第16話');
      expect(l.pending.single.key, 'book:raw');
      expect(l.pending.single.memberKeys, <String>['raw']);
    });

    test('系列单元按卷键对号；各卷都写回过的不列；全是漫画的归漫画书架', () async {
      facts.books = <LibraryCurateBookUnit>[
        LibraryCurateBookUnit(
          id: 'collection:7',
          title: 'Saga',
          isSeries: true,
          volumes: <LibraryCurateBookVolume>[
            _vol('a', 'Saga 1', manga: true),
            _vol('b', 'Saga 2', manga: true),
          ],
        ),
        _single(_vol('done', 'Done')),
      ];
      await saveRuns(
        <LibraryCurateRun>[
          LibraryCurateRun(
            id: 1,
            trigger: LibraryCurateTrigger.manual,
            startedAt: 1000,
            pendingItems: <LibraryCuratePendingItem>[
              // 当时系列只剩一卷待刮，ref 记的是卷键。
              _bookItem('book:b', 'low_confidence'),
              _bookItem('book:done', 'ambiguous'),
            ],
          ),
        ],
        seen: <String>{'scrape.books.done:book:done'},
      );
      final PendingIdentityListing l = await source(
        CuratorPendingIdentityDomain.books,
      ).load();
      final PendingIdentityEntry saga = l.pending.single;
      expect(saga.key, 'collection:7');
      expect(saga.kind, PendingIdentityMediaKind.manga);
      expect(saga.aiOutcome, PendingIdentityAiOutcome.declined);
      expect(saga.memberKeys, <String>['a', 'b']);
      expect(l.only(PendingIdentityMediaKind.book).pending, isEmpty);
      expect(l.only(PendingIdentityMediaKind.manga).pending, hasLength(1));
    });

    test('忽略持久生效、可撤销', () async {
      facts.books = <LibraryCurateBookUnit>[_single(_vol('k1', 'Alpha'))];
      await saveRuns(<LibraryCurateRun>[
        LibraryCurateRun(
          id: 1,
          trigger: LibraryCurateTrigger.auto,
          startedAt: 1000,
          pendingItems: <LibraryCuratePendingItem>[
            _bookItem('book:k1', 'ambiguous'),
          ],
        ),
      ]);
      final CuratorPendingIdentitySource s = source(
        CuratorPendingIdentityDomain.books,
      );
      await s.setIgnored(<String>['book:k1'], ignored: true);
      PendingIdentityListing l = await source(
        CuratorPendingIdentityDomain.books,
      ).load();
      expect(l.pending, isEmpty);
      expect(l.ignored.single.key, 'book:k1');
      await s.setIgnored(<String>['book:k1'], ignored: false);
      l = await s.load();
      expect(l.pending.single.key, 'book:k1');
      expect(l.ignored, isEmpty);
    });
  });

  group('游戏数据源', () {
    test('按 game:<id> 对号；已有资料源快照（不在 facts 里）的消失；seen 兜底', () async {
      facts.games = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: '1', title: 'Clannad'),
        LibraryCurateGameUnit(id: '2', title: 'Kanon'),
        LibraryCurateGameUnit(id: '3', title: 'Untried'),
      ];
      await saveRuns(
        <LibraryCurateRun>[
          LibraryCurateRun(
            id: 1,
            trigger: LibraryCurateTrigger.auto,
            startedAt: 5000,
            pendingItems: const <LibraryCuratePendingItem>[
              LibraryCuratePendingItem(
                stage: LibraryCurateStage.scrapeGames,
                kind: 'game_scrape_pending',
                title: 'Clannad',
                ref: 'game:1',
                reason: 'no_candidates',
                candidates: 0,
                ai: 'not_asked',
              ),
              LibraryCuratePendingItem(
                stage: LibraryCurateStage.scrapeGames,
                kind: 'game_scrape_pending',
                title: 'Gone',
                ref: 'game:9',
                reason: 'ambiguous',
              ),
              // 别的种类不算。
              LibraryCuratePendingItem(
                stage: LibraryCurateStage.scrapeGames,
                kind: 'needs_confirmation',
                title: 'Untried',
                ref: 'game:3',
              ),
            ],
          ),
        ],
        seen: <String>{'scrape.games:2'},
      );
      final PendingIdentityListing l = await source(
        CuratorPendingIdentityDomain.games,
      ).load();
      expect(facts.gameSince, <int?>[null]);
      expect(
        l.pending.map((PendingIdentityEntry e) => '${e.key}|${e.cause?.wire}'),
        <String>['game:1|not_found', 'game:2|null'],
      );
      expect(l.pending.first.kind, PendingIdentityMediaKind.game);
      expect(l.pending.first.memberKeys, <String>['1']);
      expect(l.pending.first.aiOutcome, PendingIdentityAiOutcome.notAsked);
    });
  });
}
