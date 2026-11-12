// Host side of the optional contract extensions
// (docs/specs/2026-11-11-bangumi-bundled-plugin.md §2), run in the real
// plugin engine: game status links, the page address template, the user's
// list, one-book subjects.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

import 'tracking_plugin_test_support.dart';

/// Entries in storage; game 70, one-book novel 80 (one volume), anime 1;
/// `trackingList` pages of two items, three items in all.
const String _js = r'''
const SUBJECTS = {
  1: { id: 1, name: 'Anime', kind: 'anime', totalEpisodes: 2 },
  70: { id: 70, name: 'Game', kind: 'game', titles: ['Game', 'ゲーム'] },
  80: { id: 80, name: 'Book', kind: 'novel', finalVolume: 1, singleVolume: true },
};
async function entries() {
  const raw = await fushi.storage.get('entries');
  return raw ? JSON.parse(raw) : {};
}
module.exports = {
  async login(a) {
    if (a.op === 'methods') return { methods: [{ id: 'token', type: 'form', label: 'Token' }] };
    if (a.op === 'submit') { await fushi.credentials.set('token', 'x'); return { state: 'done' }; }
    return { state: 'pending', form: { fields: [{ id: 'token', label: 'T' }], actions: [{ id: 'ok', label: 'OK' }] } };
  },
  async account() {
    return (await fushi.credentials.get('token')) ? { loggedIn: true } : { loggedIn: false };
  },
  async trackingSubject(a) { return SUBJECTS[a.id] || null; },
  async trackingSearch(a) { return { items: Object.values(SUBJECTS).filter((s) => s.kind === a.kind) }; },
  async trackingEntry(a) {
    const all = await entries();
    if (a.op === 'get') return all[a.id] || null;
    const e = all[a.id] || { progress: 0 };
    for (const k of ['status', 'progress', 'progressVolume']) if (a[k] !== undefined) e[k] = a[k];
    all[a.id] = e;
    await fushi.storage.set('entries', JSON.stringify(all));
    return null;
  },
  async trackingList(a) {
    const all = [1, 2, 3].map((n) => ({
      subject: { id: n, name: 'Watched ' + n, kind: 'anime' },
      status: a.status, progress: n, updatedAt: '2026-11-0' + n + 'T00:00:00Z',
    }));
    const page = all.slice(a.offset, a.offset + 2);
    return a.offset + 2 < all.length ? { items: page, next: a.offset + 2 } : { items: page };
  },
};
''';

Map<String, Object?> _manifest({bool withList = true}) {
  final Map<String, Object?> m = fakeManifest(
    kinds: const <String>['anime', 'novel', 'game'],
    capabilities: <String>[
      'login',
      'account',
      'trackingEntry',
      'trackingSubject',
      'trackingSearch',
      if (withList) 'trackingList',
    ],
  );
  final Map<String, Object?> tracking = Map<String, Object?>.of(
    m['tracking']! as Map<String, Object?>,
  );
  tracking['modes'] = <String>['episode', 'chapter', 'volume', 'status'];
  tracking['subjectUrl'] = 'https://example.org/{kind}/{id}';
  return <String, Object?>{...m, 'tracking': tracking};
}

void main() {
  late Directory root;
  late RecordingEngine engine;
  late TrackingPluginManager manager;
  late FushiDatabase db;
  late MediaTrackingRepository repository;
  int itemCount = 0;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi-tracking-ext-');
    engine = RecordingEngine.real();
    manager = TrackingPluginManager(rootDir: root, engine: engine);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
  });

  tearDown(() async {
    await manager.dispose();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<PluginTrackingProvider> install({bool withList = true}) async {
    final Uint8List zip = buildPluginZip(
      _manifest(withList: withList),
      js: _js,
    );
    await manager.install(zip, (await manager.inspect(zip)).digest);
    final PluginTrackingProvider provider = createPluginTrackingProvider(
      manager: manager,
      info: manager.registered.single.info!,
      onAccountChanged: () {},
    );
    final TrackingPluginLoginChallenge step = await provider.beginLogin('t');
    await provider.submitLogin(
      't',
      session: step.session,
      action: 'ok',
      inputs: const <String, String>{'token': 'x'},
    );
    return provider;
  }

  Future<void> push(
    PluginTrackingProvider provider, {
    required TrackingMediaType mediaType,
    required TrackingKind kind,
    required TrackingProgressMode mode,
    required int subjectId,
    required int progress,
    bool completed = false,
  }) async {
    final String key = 'item${++itemCount}';
    await repository.saveMapping(
      mediaType: mediaType,
      mediaKey: key,
      mediaTitle: 'Item',
      kind: kind,
      subjectId: subjectId,
      subjectName: 'Subject',
      progressMode: mode,
      progressOffset: 0,
      provider: fakeSiteId,
    );
    await repository.enqueueProgress(
      mediaType: mediaType,
      mediaKey: key,
      localProgress: progress,
      completed: completed,
      monotonic: false,
      provider: fakeSiteId,
    );
    final PendingTrackingUpdate update = (await repository.allPending(
      provider: fakeSiteId,
    )).singleWhere((PendingTrackingUpdate r) => r.mapping.mediaKey == key);
    final TrackingProviderSession session = await provider.openSession();
    try {
      await provider.push(session, update);
    } finally {
      session.close();
    }
  }

  List<Map<String, Object?>> sets() =>
      engine.argsOf('trackingEntry', op: 'set');

  test('the site declares games and the status mode', () async {
    final PluginTrackingProvider provider = await install();
    expect(
      provider.capabilities.accepts(
        TrackingKind.game,
        TrackingProgressMode.status,
      ),
      isTrue,
    );
  });

  test('a game link writes the play status as is, no progress, and skips an '
      'unchanged status', () async {
    final PluginTrackingProvider provider = await install();
    Future<void> game(int code) => push(
      provider,
      mediaType: TrackingMediaType.game,
      kind: TrackingKind.game,
      mode: TrackingProgressMode.status,
      subjectId: 70,
      progress: code,
      completed: code == 2,
    );

    await game(2);
    expect(sets().last, <String, Object?>{
      'op': 'set',
      'id': 70,
      'kind': 'game',
      'create': true,
      'status': 'completed',
    });
    // Back from completed to playing: written (the user's choice).
    await game(3);
    expect(sets().last, <String, Object?>{
      'op': 'set',
      'id': 70,
      'kind': 'game',
      'create': false,
      'status': 'current',
    });
    final int before = sets().length;
    await game(3);
    expect(sets(), hasLength(before));
    expect(engine.argsOf('trackingSubject'), isEmpty);
  });

  test(
    'a one-book novel completes in chapter mode and gets volume 1',
    () async {
      final PluginTrackingProvider provider = await install();
      await push(
        provider,
        mediaType: TrackingMediaType.book,
        kind: TrackingKind.novel,
        mode: TrackingProgressMode.chapter,
        subjectId: 80,
        progress: 9,
        completed: true,
      );
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 80,
        'kind': 'novel',
        'create': true,
        'status': 'completed',
        'progress': 9,
        'progressVolume': 1,
      });
    },
  );

  test('page address from subjectUrl; game search hits', () async {
    final PluginTrackingProvider provider = await install();
    expect(
      provider.subjectPageUrl(70, TrackingKind.game),
      Uri.parse('https://example.org/game/70'),
    );
    final List<TrackingSearchHit> hits = await provider.searchSubjects(
      'g',
      TrackingKind.game,
    );
    expect(hits.single.subjectId, 70);
    expect(hits.single.kind, TrackingKind.game);
    expect(hits.single.altName, 'ゲーム');
    expect((await provider.subjectById(70, TrackingKind.game))!.name, 'Game');
    expect(await provider.subjectById(70, TrackingKind.anime), isNull);
  });

  test('listEntries reads every page through next', () async {
    final PluginTrackingProvider provider = await install();
    expect(provider.canListEntries, isTrue);
    final List<TrackingListItem> items = await provider.listEntries(
      TrackingKind.anime,
      TrackingEntryStatus.completed,
    );
    expect(items.map((TrackingListItem i) => i.subject.subjectId), <int>[
      1,
      2,
      3,
    ]);
    expect(
      engine
          .argsOf('trackingList')
          .map((Map<String, Object?> a) => a['offset']),
      <Object?>[0, 2],
    );
    expect(items.first.status, TrackingEntryStatus.completed);
  });

  test('without trackingList: empty, never called', () async {
    final PluginTrackingProvider provider = await install(withList: false);
    expect(provider.canListEntries, isFalse);
    expect(
      await provider.listEntries(
        TrackingKind.anime,
        TrackingEntryStatus.completed,
      ),
      isEmpty,
    );
    expect(engine.argsOf('trackingList'), isEmpty);
  });

  test('a subjectUrl on another host is not used', () {
    expect(
      TrackingPluginSite.tryParse(<String, Object?>{
        'siteId': 'abc',
        'siteHost': 'example.org',
        'kinds': <String>['anime'],
        'modes': <String>['episode'],
        'requestsPerMinute': 10,
        'subjectUrl': 'https://evil.org/{id}',
      })!.subjectPageUrl(1, TrackingKind.anime),
      isNull,
    );
  });

  TrackingPluginSite perKindSite(Map<String, Object?> subjectUrl) =>
      TrackingPluginSite.tryParse(<String, Object?>{
        'siteId': 'abc',
        'siteHost': 'example.org',
        'kinds': <String>['anime', 'manga', 'novel'],
        'modes': <String>['episode', 'chapter'],
        'requestsPerMinute': 10,
        'subjectUrl': subjectUrl,
      })!;

  test('a per-kind subjectUrl picks the template of the kind', () {
    final TrackingPluginSite site = perKindSite(<String, Object?>{
      'anime': 'https://example.org/anime/{id}',
      'manga': 'https://example.org/manga/{id}',
      'novel': 'https://www.example.org/manga/{id}?as={kind}',
    });
    expect(
      site.subjectPageUrl(5, TrackingKind.anime),
      Uri.parse('https://example.org/anime/5'),
    );
    expect(
      site.subjectPageUrl(6, TrackingKind.manga),
      Uri.parse('https://example.org/manga/6'),
    );
    expect(
      site.subjectPageUrl(7, TrackingKind.novel),
      Uri.parse('https://www.example.org/manga/7?as=novel'),
    );
  });

  test('a kind missing from a per-kind subjectUrl has no page address', () {
    final TrackingPluginSite site = perKindSite(<String, Object?>{
      'anime': 'https://example.org/anime/{id}',
    });
    expect(site.subjectPageUrl(1, TrackingKind.manga), isNull);
    expect(site.subjectPageUrl(1, TrackingKind.novel), isNull);
    expect(
      site.subjectPageUrl(1, TrackingKind.anime),
      Uri.parse('https://example.org/anime/1'),
    );
  });

  test('a per-kind subjectUrl entry on another host is dropped', () {
    final TrackingPluginSite site = perKindSite(<String, Object?>{
      'anime': 'https://example.org/anime/{id}',
      'manga': 'https://evil.org/manga/{id}',
      'novel': 42,
    });
    expect(site.subjectPageUrl(1, TrackingKind.manga), isNull);
    expect(site.subjectPageUrl(1, TrackingKind.novel), isNull);
    expect(
      site.subjectPageUrl(1, TrackingKind.anime),
      Uri.parse('https://example.org/anime/1'),
    );
  });
}
