import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_library_service.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';

import 'fake_second_screen_platform.dart';

CompanionLibraryRecord _book(
  String key, {
  String? title,
  String? author,
  int recentAt = 0,
  int addedAt = 0,
  int? collectionId,
  int? sortIndex,
  bool finished = false,
  CompanionLibraryItemKind kind = CompanionLibraryItemKind.book,
  String? cover,
}) => CompanionLibraryRecord(
  kind: kind,
  key: key,
  title: title ?? key,
  subtitle: author,
  recentAt: recentAt,
  addedAt: addedAt,
  collectionId: collectionId,
  sortIndex: sortIndex,
  finished: finished,
  resolveCover: cover == null ? null : () async => cover,
);

class _FakeData implements CompanionLibraryData {
  Set<CompanionLibrarySection> enabled = CompanionLibrarySection.values.toSet();
  List<CompanionLibraryRecord> bookRows = <CompanionLibraryRecord>[];
  List<CompanionLibraryRecord> videoRows = <CompanionLibraryRecord>[];
  List<CompanionLibraryCollection> collectionRows =
      <CompanionLibraryCollection>[];
  CompanionMusicLibrary musicLibrary = const CompanionMusicLibrary();
  List<CompanionLibraryRecord> inProgress = <CompanionLibraryRecord>[];
  List<CompanionLibraryRecord> serverContinue = <CompanionLibraryRecord>[];
  List<CompanionLibraryRecord> serverRows = <CompanionLibraryRecord>[];
  Map<String, CompanionDetailsSource> detailRows =
      <String, CompanionDetailsSource>{};
  Map<String, String> covers = <String, String>{};
  CompanionLibraryRecord? top;
  bool homeAllowed = true;
  bool openSucceeds = true;
  final List<String> calls = <String>[];
  final List<int> coverProbes = <int>[];

  @override
  bool isSectionEnabled(CompanionLibrarySection section) =>
      enabled.contains(section);

  @override
  List<CompanionLibraryMainTarget> onlineTargets(
    CompanionLibrarySection section,
  ) => section == CompanionLibrarySection.manga
      ? const <CompanionLibraryMainTarget>[
          CompanionLibraryMainTarget.onlineManga,
        ]
      : const <CompanionLibraryMainTarget>[];

  @override
  Future<List<CompanionLibraryRecord>> books() async => bookRows;

  @override
  Future<List<CompanionLibraryRecord>> videos() async => videoRows;

  @override
  Future<List<CompanionLibraryCollection>> collections(
    CompanionLibrarySection section,
  ) async => <CompanionLibraryCollection>[
    for (final CompanionLibraryCollection c in collectionRows)
      CompanionLibraryCollection(
        section: section,
        id: c.id,
        title: c.title,
        resolveCover: c.resolveCover,
      ),
  ];

  @override
  Future<CompanionMusicLibrary> music() async => musicLibrary;

  @override
  Future<({String title, List<CompanionLibraryRecord> tracks})?> musicChildren(
    String ref,
  ) async => ref == 'musicArtist:a1'
      ? (
          title: 'Artist',
          tracks: <CompanionLibraryRecord>[
            _book('t1', kind: CompanionLibraryItemKind.musicTrack),
          ],
        )
      : null;

  @override
  Future<List<CompanionLibraryRecord>> continueRecords() async => inProgress;

  @override
  List<CompanionLibraryRecord> continueServer() => serverContinue;

  @override
  Future<List<CompanionLibraryRecord>> servers() async => serverRows;

  @override
  Future<CompanionLibraryPage> serverChildren(
    String parentRef, {
    required String query,
    required int offset,
    required int limit,
  }) async {
    calls.add('serverChildren $parentRef $query $offset $limit');
    return const CompanionLibraryPage(
      items: <CompanionLibraryItem>[],
      hasMore: true,
      nextOffset: 60,
    );
  }

  @override
  Future<CompanionDetailsSource?> details(String ref) async => detailRows[ref];

  @override
  Future<String?> cover(String ref) async {
    calls.add('cover $ref');
    return covers[ref];
  }

  @override
  Future<CompanionLibraryRecord?> currentTop() async => top;

  @override
  Future<bool> returnToHome() async {
    calls.add('home');
    if (homeAllowed) top = null;
    return homeAllowed;
  }

  @override
  Future<bool> open(String ref, {String? entry}) async {
    calls.add('open $ref ${entry ?? '-'}');
    return openSucceeds;
  }

  @override
  Future<bool> setFinished(String ref, {required bool finished}) async {
    calls.add('finished $ref $finished');
    if (CompanionLibraryRef.kindOf(ref) ==
        CompanionLibraryItemKind.musicAlbum) {
      return false;
    }
    bookRows = <CompanionLibraryRecord>[
      for (final CompanionLibraryRecord r in bookRows)
        r.ref == ref ? _book(r.key, finished: finished) : r,
    ];
    return true;
  }

  @override
  Future<void> openOnMain(CompanionLibraryMainTarget target) async {
    calls.add('openOnMain ${target.wire}');
  }
}

List<String> _refs(Iterable<CompanionLibraryItem> items) => <String>[
  for (final CompanionLibraryItem i in items) i.ref,
];

void main() {
  late _FakeData data;
  late CompanionLibraryService service;

  setUp(() {
    data = _FakeData();
    service = CompanionLibraryService(data);
  });

  group('paging', () {
    test('offset / limit are clamped', () {
      expect(clampCompanionLibraryRange(-5, 0), (
        offset: 0,
        limit: CompanionLibraryArgs.pageSize,
      ));
      expect(clampCompanionLibraryRange(3, 1000), (
        offset: 3,
        limit: CompanionLibraryArgs.maxPageSize,
      ));
    });

    test('pages carry total / hasMore; covers only for the page', () async {
      data.bookRows = <CompanionLibraryRecord>[
        for (int i = 0; i < 5; i++)
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.book,
            key: 'b$i',
            title: 'Book $i',
            recentAt: 100 - i,
            resolveCover: () async {
              data.coverProbes.add(i);
              return '/c/b$i.jpg';
            },
          ),
      ];
      final CompanionLibraryPage first = await service.list(
        section: CompanionLibrarySection.books,
        limit: 2,
      );
      expect(_refs(first.items), <String>['book:b0', 'book:b1']);
      expect(first.total, 5);
      expect(first.hasMore, isTrue);
      expect(first.items.first.coverPath, '/c/b0.jpg');
      expect(data.coverProbes, <int>[0, 1]);
      final CompanionLibraryPage last = await service.list(
        section: CompanionLibrarySection.books,
        offset: 4,
        limit: 2,
      );
      expect(_refs(last.items), <String>['book:b4']);
      expect(last.hasMore, isFalse);
      expect(last.followingOffset, 5);
      final CompanionLibraryPage past = await service.list(
        section: CompanionLibrarySection.books,
        offset: 50,
      );
      expect(past.items, isEmpty);
    });

    test('server lists pass through with their own next offset', () async {
      final CompanionLibraryPage page = await service.list(
        section: CompanionLibrarySection.servers,
        parent: 'serverLibrary:jellyfin.s1/lib',
        query: ' anime ',
        offset: 10,
        limit: 500,
      );
      expect(data.calls, <String>[
        'serverChildren serverLibrary:jellyfin.s1/lib anime 10 100',
      ]);
      expect(page.followingOffset, 60);
      expect(
        CompanionLibraryPage.fromJson(page.toJson()).nextOffset,
        60,
        reason: 'wire round trip',
      );
    });
  });

  group('lists', () {
    test('a query filters title and author, case-insensitive', () async {
      data.bookRows = <CompanionLibraryRecord>[
        _book('k', title: 'Kokoro', author: 'Natsume Soseki'),
        _book('w', title: 'Wagahai wa Neko', author: 'Natsume'),
        _book('r', title: 'Rashomon', author: 'Akutagawa'),
      ];
      expect(
        _refs(
          (await service.list(
            section: CompanionLibrarySection.books,
            query: 'NATSUME',
          )).items,
        ),
        unorderedEquals(<String>['book:k', 'book:w']),
      );
      expect(
        _refs(
          (await service.list(
            section: CompanionLibrarySection.books,
            query: 'kokoro',
          )).items,
        ),
        <String>['book:k'],
      );
    });

    test('collections fold their members; online sources come last; '
        'members list in collection order', () async {
      data.collectionRows = const <CompanionLibraryCollection>[
        CompanionLibraryCollection(
          section: CompanionLibrarySection.manga,
          id: 7,
          title: 'Series',
        ),
        CompanionLibraryCollection(
          section: CompanionLibrarySection.manga,
          id: 8,
          title: 'Empty series',
        ),
      ];
      data.bookRows = <CompanionLibraryRecord>[
        _book(
          'v2',
          kind: CompanionLibraryItemKind.manga,
          collectionId: 7,
          sortIndex: 2,
          recentAt: 50,
        ),
        _book(
          'v1',
          kind: CompanionLibraryItemKind.manga,
          collectionId: 7,
          sortIndex: 1,
          cover: '/c/v1.jpg',
        ),
        _book('solo', kind: CompanionLibraryItemKind.manga, recentAt: 10),
        _book('a book', recentAt: 99),
      ];
      final CompanionLibraryPage top = await service.list(
        section: CompanionLibrarySection.manga,
      );
      expect(_refs(top.items), <String>[
        'collection:manga/7',
        'manga:solo',
        'mainOnly:onlineManga',
      ]);
      expect(top.items.first.count, 2);
      expect(top.items.first.coverPath, '/c/v1.jpg', reason: 'member cover');
      expect(top.items.last.mainTarget, CompanionLibraryMainTarget.onlineManga);
      final CompanionLibraryPage members = await service.list(
        section: CompanionLibrarySection.manga,
        parent: 'collection:manga/7',
      );
      expect(members.title, 'Series');
      expect(_refs(members.items), <String>['manga:v1', 'manga:v2']);
    });

    test('music: groups, then their rows; artists list tracks', () async {
      data.musicLibrary = CompanionMusicLibrary(
        albums: <CompanionLibraryRecord>[
          _book('al', kind: CompanionLibraryItemKind.musicAlbum),
        ],
        artists: <CompanionLibraryRecord>[
          _book('a1', kind: CompanionLibraryItemKind.musicArtist),
        ],
      );
      final CompanionLibraryPage top = await service.list(
        section: CompanionLibrarySection.music,
      );
      expect(_refs(top.items), <String>[
        'collection:music/albums',
        'collection:music/artists',
      ]);
      expect(
        _refs(
          (await service.list(
            section: CompanionLibrarySection.music,
            parent: 'collection:music/albums',
          )).items,
        ),
        <String>['musicAlbum:al'],
      );
      final CompanionLibraryPage tracks = await service.list(
        section: CompanionLibrarySection.music,
        parent: 'musicArtist:a1',
      );
      expect(tracks.title, 'Artist');
      expect(_refs(tracks.items), <String>['musicTrack:t1']);
    });

    test('disabled sections are empty; malformed parents throw', () async {
      data.enabled.remove(CompanionLibrarySection.books);
      data.bookRows = <CompanionLibraryRecord>[_book('x')];
      expect(
        (await service.list(section: CompanionLibrarySection.books)).items,
        isEmpty,
      );
      await expectLater(
        service.list(section: CompanionLibrarySection.books, parent: 'nope'),
        throwsFormatException,
      );
      await expectLater(
        service.list(section: CompanionLibrarySection.books, parent: 'book:x'),
        throwsFormatException,
      );
    });

    test('search covers every enabled local section', () async {
      data.bookRows = <CompanionLibraryRecord>[_book('neko', title: 'Neko')];
      data.videoRows = <CompanionLibraryRecord>[
        _book('nv', title: 'Neko movie', kind: CompanionLibraryItemKind.video),
      ];
      data.musicLibrary = CompanionMusicLibrary(
        tracks: <CompanionLibraryRecord>[
          _book(
            'nt',
            title: 'Neko song',
            kind: CompanionLibraryItemKind.musicTrack,
          ),
        ],
      );
      expect(_refs((await service.search(query: 'neko')).items), <String>[
        'book:neko',
        'video:nv',
        'musicTrack:nt',
      ]);
      data.enabled.remove(CompanionLibrarySection.video);
      expect(_refs((await service.search(query: 'neko')).items), <String>[
        'book:neko',
        'musicTrack:nt',
      ]);
      expect((await service.search(query: '  ')).items, isEmpty);
    });
  });

  group('home', () {
    test(
      'rows newest first, only enabled kinds, empty rows left out',
      () async {
        data.enabled = <CompanionLibrarySection>{
          CompanionLibrarySection.books,
          CompanionLibrarySection.video,
        };
        data.inProgress = <CompanionLibraryRecord>[
          _book('old', recentAt: 1),
          _book('new', recentAt: 9),
          _book('m', recentAt: 5, kind: CompanionLibraryItemKind.manga),
          for (int i = 0; i < 20; i++) _book('x$i', recentAt: 2),
        ];
        data.serverContinue = <CompanionLibraryRecord>[
          _book('feed/1', kind: CompanionLibraryItemKind.serverItem),
        ];
        data.bookRows = <CompanionLibraryRecord>[
          _book('a', addedAt: 5),
          _book('b', addedAt: 7),
          _book('never'),
        ];
        final CompanionLibraryHome home = await service.home();
        expect(home.sections, <CompanionLibrarySection>[
          CompanionLibrarySection.books,
          CompanionLibrarySection.video,
        ]);
        expect(
          home.rows.map((CompanionLibraryHomeRow r) => r.kind),
          <CompanionLibraryHomeRowKind>[
            CompanionLibraryHomeRowKind.continueItems,
            CompanionLibraryHomeRowKind.recentlyAdded,
          ],
        );
        final List<CompanionLibraryItem> cont = home.rows.first.items;
        expect(cont, hasLength(kCompanionLibraryHomeRowLimit));
        expect(cont.first.ref, 'book:new');
        expect(_refs(cont), isNot(contains('manga:m')));
        expect(_refs(home.rows.last.items), <String>['book:b', 'book:a']);

        data.enabled.add(CompanionLibrarySection.servers);
        final CompanionLibraryHome withServers = await service.home();
        expect(
          withServers.rows[1].kind,
          CompanionLibraryHomeRowKind.continueServer,
        );
        expect(
          CompanionLibraryHome.fromJson(withServers.toJson()).rows,
          hasLength(3),
        );
      },
    );
  });

  group('details', () {
    test(
      'episodes, labels and Continue; missing data leaves keys out',
      () async {
        data.detailRows['collection:video/3'] = CompanionDetailsSource(
          record: const CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.collection,
            key: 'video/3',
            title: 'Series',
            count: 4,
          ),
          description: '  An overview  ',
          rating: 7.9,
          ratingVotes: 1200,
          year: 2004,
          originalTitle: 'シリーズ',
          cast: const <String>['A', ' ', 'B'],
          entriesKind: CompanionEntriesKind.episodes,
          entries: const <CompanionEntrySource>[
            CompanionEntrySource(
              id: 'e2',
              title: 'Two',
              number: 2,
              finished: true,
            ),
            CompanionEntrySource(
              id: 'e4',
              title: 'Four',
              number: 4,
              positionMs: 380000,
              durationMs: 1440000,
              current: true,
            ),
            CompanionEntrySource(
              id: 'e5',
              title: '',
              number: 5,
              runtimeMinutes: 24,
            ),
          ],
          canMarkFinished: true,
        );
        final CompanionLibraryDetails d = await service.details(
          'collection:video/3',
        );
        expect(d.description, 'An overview');
        expect(d.rating, 7.9);
        expect(d.ratingVotes, 1200);
        expect(d.year, 2004);
        expect(d.entriesLabel, 'Episodes');
        expect(d.continueLabel, 'Continue E4 on top');
        expect(d.canMarkFinished, isTrue);
        expect(d.entries.map((CompanionLibraryEntry e) => e.title), <String>[
          'E2 · Two',
          'E4 · Four',
          'E5',
        ]);
        expect(d.entries[0].subtitle, 'Watched');
        expect(d.entries[1].subtitle, '6:20 in');
        expect(d.entries[1].progress, closeTo(380000 / 1440000, 1e-9));
        expect(d.entries[1].current, isTrue);
        expect(d.entries[2].subtitle, '24 min');
        expect(
          d.facts.map((CompanionLibraryFact f) => '${f.label}=${f.value}'),
          <String>['Original title=シリーズ', 'Cast=A, B'],
        );

        data.detailRows['book:bare'] = CompanionDetailsSource(
          record: _book('bare'),
          description: ' ',
          rating: 0,
          year: 0,
        );
        final Map<String, Object?> json = (await service.details(
          'book:bare',
        )).toJson();
        expect(json.keys, <String>['item']);
        expect(CompanionLibraryDetails.fromJson(json).canOpen, isTrue);
      },
    );

    test('long entry lists are windowed around the current one', () async {
      data.detailRows['musicAlbum:big'] = CompanionDetailsSource(
        record: _book('big', kind: CompanionLibraryItemKind.musicAlbum),
        entriesKind: CompanionEntriesKind.tracks,
        entries: <CompanionEntrySource>[
          for (int i = 0; i < 300; i++)
            CompanionEntrySource(id: '$i', title: 'T$i', current: i == 200),
        ],
      );
      final CompanionLibraryDetails d = await service.details('musicAlbum:big');
      expect(d.entries, hasLength(CompanionLibraryArgs.maxPageSize));
      expect(d.entries.first.id, '150');
      expect(d.entries.any((CompanionLibraryEntry e) => e.current), isTrue);
      expect(d.continueLabel, isNull);
    });

    test('lists and unknown items have no details', () async {
      await expectLater(
        service.details('musicArtist:a1'),
        throwsFormatException,
      );
      await expectLater(service.details('book:gone'), throwsStateError);
      await expectLater(service.details('garbage'), throwsFormatException);
    });
  });

  group('open', () {
    test(
      'leaves the top normally, opens, and returns it as previous',
      () async {
        data.top = _book('reading', title: 'Reading');
        final CompanionLibraryOpenResult r = await service.open(
          'video:v1',
          entry: 'e3',
        );
        expect(data.calls, <String>['home', 'open video:v1 e3']);
        expect(r.opened, isTrue);
        expect(r.previous!.ref, 'book:reading');
        expect(r.previous!.title, 'Reading');
        expect(
          CompanionLibraryOpenResult.fromJson(r.toJson()).previous!.ref,
          'book:reading',
          reason: 'previous is a ref open accepts',
        );
      },
    );

    test('the item already on top is not closed and reopened', () async {
      data.top = _book('reading');
      final CompanionLibraryOpenResult r = await service.open('book:reading');
      expect(r.opened, isTrue);
      expect(r.previous, isNull);
      expect(data.calls, isEmpty);
    });

    test('refusing to close / gone items report opened: false', () async {
      data.top = _book('reading');
      data.homeAllowed = false;
      expect((await service.open('book:other')).opened, isFalse);
      expect(data.calls, <String>['home']);
      data
        ..homeAllowed = true
        ..openSucceeds = false;
      final CompanionLibraryOpenResult gone = await service.open('book:other');
      expect(gone.opened, isFalse);
    });

    test('collections open their Continue member; lists and bad refs '
        'throw; main-only goes to the main screen', () async {
      expect((await service.open('collection:video/3')).opened, isTrue);
      expect(data.calls.last, 'open collection:video/3 -');
      await expectLater(service.open('musicArtist:a'), throwsFormatException);
      await expectLater(
        service.open('collection:music/albums'),
        throwsFormatException,
      );
      await expectLater(service.open('book:'), throwsFormatException);
      data.calls.clear();
      expect((await service.open('mainOnly:onlineVideo')).opened, isTrue);
      expect(data.calls, <String>['openOnMain onlineVideo']);
    });
  });

  test('markFinished writes and returns the re-read item', () async {
    data.bookRows = <CompanionLibraryRecord>[_book('b')];
    final CompanionLibraryItem item = await service.markFinished(
      'book:b',
      finished: true,
    );
    expect(data.calls, <String>['finished book:b true']);
    expect(item.finished, isTrue);
    await expectLater(
      service.markFinished('musicAlbum:a', finished: true),
      throwsFormatException,
    );
  });

  test(
    'cover: local and remote both come back as a path; none = null',
    () async {
      data.covers = <String, String>{
        'serverItem:jellyfin.s/1': '/cache/remote.jpg',
        'book:b': '/books/b.jpg',
        'video:v': '',
      };
      expect(
        await service.cover('serverItem:jellyfin.s/1'),
        '/cache/remote.jpg',
      );
      expect(await service.cover('book:b'), '/books/b.jpg');
      expect(await service.cover('video:v'), isNull);
      expect(await service.cover('musicTrack:none'), isNull);
    },
  );

  group('bridge', () {
    late Directory spill;

    setUp(() async {
      spill = await Directory.systemTemp.createTemp('companion_library');
    });

    tearDown(() async {
      if (spill.existsSync()) await spill.delete(recursive: true);
    });

    test('library methods answer over the pipe', () async {
      final Map<String, Object?> prefs = <String, Object?>{
        kSecondScreenModePrefKey: SecondScreenMode.always.name,
      };
      final FakeSecondScreenPlatform platform = FakeSecondScreenPlatform(
        displays: <SecondScreenDisplayInfo>[thorBottomScreen],
      );
      final SecondScreenHost host = SecondScreenHost(platform);
      final SecondScreenController controller = SecondScreenController(
        readPref: (String k) => prefs[k],
        writePref: (String k, Object? v) async => prefs[k] = v,
        host: host,
      );
      final CompanionContextRegistry contexts = CompanionContextRegistry();
      final CompanionBridge bridge = CompanionBridge(
        host: host,
        controller: controller,
        contexts: contexts,
        collectSummary: () async => const CompanionDailySummary(dayKey: 'd'),
        spillRoot: spill,
      );
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
        host.dispose();
        contexts.dispose();
      });
      data.bookRows = <CompanionLibraryRecord>[_book('b', addedAt: 1)];
      data.covers = <String, String>{'book:b': '/b.jpg'};
      registerCompanionLibraryHandlers(bridge, service);
      bridge.start();
      await controller.start();

      Future<void> settle() async {
        for (int i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      Future<Map<int, CompanionReplyMessage>> send(
        List<CompanionPanelMessage> messages,
      ) async {
        platform.sent.clear();
        for (final CompanionPanelMessage m in messages) {
          platform.emit(SecondScreenPanelMessageReceived(m.encode()));
        }
        await settle();
        return <int, CompanionReplyMessage>{
          for (final String raw in platform.sent)
            if (CompanionHostMessage.decode(raw)
                case final CompanionReplyMessage r)
              r.id: r,
        };
      }

      await send(<CompanionPanelMessage>[const CompanionReadyMessage()]);
      final Map<int, CompanionReplyMessage> replies = await send(
        <CompanionPanelMessage>[
          const CompanionRequestMessage(
            id: 1,
            method: CompanionRequestMethods.libraryHome,
          ),
          const CompanionRequestMessage(
            id: 2,
            method: CompanionRequestMethods.libraryList,
            args: <String, Object?>{
              CompanionLibraryArgs.section: 'books',
              CompanionLibraryArgs.offset: 0,
              CompanionLibraryArgs.limit: 40,
            },
          ),
          const CompanionRequestMessage(
            id: 3,
            method: CompanionRequestMethods.librarySearch,
            args: <String, Object?>{CompanionLibraryArgs.query: 'b'},
          ),
          const CompanionRequestMessage(
            id: 4,
            method: CompanionRequestMethods.libraryOpen,
            args: <String, Object?>{CompanionLibraryArgs.ref: 'book:b'},
          ),
          const CompanionRequestMessage(
            id: 5,
            method: CompanionRequestMethods.libraryCover,
            args: <String, Object?>{CompanionLibraryArgs.ref: 'book:b'},
          ),
          const CompanionRequestMessage(
            id: 6,
            method: CompanionRequestMethods.libraryOpenOnMain,
            args: <String, Object?>{CompanionLibraryArgs.target: 'statistics'},
          ),
          const CompanionRequestMessage(
            id: 7,
            method: CompanionRequestMethods.libraryDetails,
            args: <String, Object?>{CompanionLibraryArgs.ref: 'oops'},
          ),
          const CompanionRequestMessage(
            id: 8,
            method: CompanionRequestMethods.libraryOpenOnMain,
            args: <String, Object?>{CompanionLibraryArgs.target: 'nowhere'},
          ),
        ],
      );
      expect(
        CompanionLibraryHome.fromJson(
          replies[1]!.value! as Map<String, Object?>,
        ).rows.single.kind,
        CompanionLibraryHomeRowKind.recentlyAdded,
      );
      expect(
        _refs(
          CompanionLibraryPage.fromJson(
            replies[2]!.value! as Map<String, Object?>,
          ).items,
        ),
        <String>['book:b'],
      );
      expect(
        CompanionLibraryPage.fromJson(
          replies[3]!.value! as Map<String, Object?>,
        ).items.single.coverPath,
        null,
        reason: 'no resolver in the fake record',
      );
      expect(
        CompanionLibraryOpenResult.fromJson(
          replies[4]!.value! as Map<String, Object?>,
        ).opened,
        isTrue,
      );
      expect(replies[5]!.value, '/b.jpg');
      expect(replies[6]!.error, isNull);
      expect(data.calls, contains('openOnMain statistics'));
      expect(replies[7]!.error, contains('malformed library ref'));
      expect(replies[8]!.error, isNotNull);

      final Map<int, CompanionReplyMessage> marked = await send(
        <CompanionPanelMessage>[
          const CompanionRequestMessage(
            id: 9,
            method: CompanionRequestMethods.libraryMarkFinished,
            args: <String, Object?>{
              CompanionLibraryArgs.ref: 'book:b',
              CompanionLibraryArgs.finished: true,
            },
          ),
        ],
      );
      expect(
        CompanionLibraryItem.fromJson(
          marked[9]!.value! as Map<String, Object?>,
        ).finished,
        isTrue,
      );
      expect(
        platform.sent.map(CompanionHostMessage.decode),
        contains(isA<CompanionLibraryChangedMessage>()),
        reason: 'a write pings libraryChanged',
      );
    });
  });
}
