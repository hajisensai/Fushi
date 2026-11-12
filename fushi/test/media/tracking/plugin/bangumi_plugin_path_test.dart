import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/bangumi_token_migration.dart';
import 'package:fushi/src/media/tracking/plugin/bundled_tracking_plugins.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_tracking_provider.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

import 'tracking_plugin_test_support.dart';

/// Step 6 of `docs/specs/2026-11-11-bangumi-bundled-plugin.md`: where
/// tracking plugins run, the `bangumi` site is served by the real bundled
/// plugin (asset `assets/tracking_plugins/…`, real sandbox engine, Bangumi's
/// API answered by [_FakeBangumi], no network) and the built-in Dart provider
/// is never used; elsewhere the built-in provider serves it as before.
void main() {
  const String token = 'secret-token-123';
  late Directory root;
  late _FakeBangumi bangumi;
  late RecordingEngine engine;
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingRepository repository;
  late int dartApiUses;
  late List<Object> errors;
  final List<TrackingPluginManager> managers = <TrackingPluginManager>[];
  final List<MediaTrackingService> services = <MediaTrackingService>[];

  Uint8List asset() => File(
    'assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug',
  ).readAsBytesSync();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fushi-bangumi-plugin-path-');
    bangumi = _FakeBangumi();
    engine = RecordingEngine(
      SharedTrackingPluginEngine(
        httpClientFactory: HttpClient.new,
        log: (String id, String level, String message) {},
        vaultKey: testVaultKey,
        httpSend: bangumi.handle,
      ),
    );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    repository = MediaTrackingRepository(db);
    dartApiUses = 0;
    errors = <Object>[];
  });

  tearDown(() async {
    for (final MediaTrackingService service in services) {
      // Joins a sync a newly registered provider started (it writes prefs).
      await service.syncNow();
      service.dispose();
    }
    services.clear();
    for (final TrackingPluginManager manager in managers) {
      await manager.dispose();
    }
    managers.clear();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MediaTrackingService makeService({required bool builtInBangumi}) {
    final MediaTrackingService service = MediaTrackingService(
      repository: repository,
      preferences: preferences,
      userAgent: 'test-agent',
      builtInBangumi: builtInBangumi,
      apiFactory: (String _) {
        dartApiUses++;
        throw StateError('the built-in Bangumi API was used');
      },
      retryTimerFactory: (Duration delay, void Function() callback) =>
          Timer(const Duration(days: 1), () {}),
    );
    services.add(service);
    return service;
  }

  /// One app start on the plugin path, as `AppModel` does it: the service
  /// without the built-in Bangumi, the manager's changes re-applying the
  /// plugin providers, then [startBundledTrackingPlugins].
  Future<
    ({
      MediaTrackingService service,
      TrackingPluginManager manager,
      PluginTrackingProviders providers,
      BangumiTokenMigration moved,
    })
  >
  startPluginPath() async {
    final MediaTrackingService service = makeService(builtInBangumi: false);
    final TrackingPluginManager manager = TrackingPluginManager(
      rootDir: root,
      engine: engine,
    );
    managers.add(manager);
    final PluginTrackingProviders providers = PluginTrackingProviders(
      manager: manager,
      onAccountChanged: service.notifyStatusChanged,
    );
    manager.changes.addListener(
      () => service.setExtraProviders(providers.current()),
    );
    final BangumiTokenMigration moved = await startBundledTrackingPlugins(
      manager: manager,
      providers: providers,
      preferences: preferences,
      removePref: preferences.removePref,
      onError: (Object error, StackTrace _) => errors.add(error),
      load: () async => asset(),
    );
    return (
      service: service,
      manager: manager,
      providers: providers,
      moved: moved,
    );
  }

  Future<void> linkBook({
    required String key,
    required int subjectId,
    TrackingMediaType type = TrackingMediaType.book,
    TrackingProgressMode mode = TrackingProgressMode.volume,
  }) => repository.saveMapping(
    mediaType: type,
    mediaKey: key,
    mediaTitle: 'Local $key',
    kind: TrackingKind.manga,
    subjectId: subjectId,
    subjectName: 'Remote $subjectId',
    progressMode: mode,
    progressOffset: 0,
  );

  test('first start with a saved token: plugin installed, token moved, '
      'bangumi served by the plugin; an existing link sends through it; a '
      'restart changes nothing', () async {
    await preferences.setPref(kBangumiAccessTokenPref, token);
    await preferences.setPref(kBangumiAccountNamePref, 'Hikari');
    await linkBook(key: 'b1', subjectId: 500);
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'b1',
      localProgress: 2,
      completed: false,
    );

    final first = await startPluginPath();

    expect(first.moved, BangumiTokenMigration.moved);
    expect(errors, isEmpty);
    expect(first.manager.installed.single.id, kBundledBangumiPluginId);
    expect(preferences.getPref(kBangumiAccessTokenPref), isNull);
    expect(preferences.getPref(kBangumiAccountNamePref), isNull);
    final MediaTrackingService service = first.service;
    expect(service.usesBuiltInBangumi, isFalse);
    expect(
      service.providers.byId(kTrackingProviderBangumi),
      isA<PluginTrackingProvider>(),
    );
    expect(service.providers.all.first.id, kTrackingProviderBangumi);
    expect(service.isConfigured, isTrue);
    expect(service.accountName, 'Hikari');
    expect((await service.loadStatus()).accountName, 'Hikari');
    expect(bangumi.requests, isEmpty, reason: 'the move needs no network');

    final MediaTrackingSyncResult result = await service.syncNow(force: true);

    expect(result.succeeded, 1);
    expect(bangumi.collections[500], <String, Object?>{
      'type': 3,
      'vol_status': 2,
    });
    expect(
      bangumi.requests,
      contains('POST https://api.bgm.tv/v0/users/-/collections/500'),
    );
    expect(dartApiUses, 0);
    await expectLater(service.connect(token), throwsStateError);

    // Restart: same plugin, same sign-in, nothing moved or installed again.
    await first.manager.dispose();
    managers.remove(first.manager);
    final int requestsBefore = bangumi.requests.length;
    final second = await startPluginPath();
    expect(second.moved, BangumiTokenMigration.nothing);
    expect(errors, isEmpty);
    expect(second.manager.installed.single.registered, isTrue);
    expect(second.service.isConfigured, isTrue);
    expect(second.service.accountName, 'Hikari');
    expect(
      second.service.providers.byId(kTrackingProviderBangumi),
      isA<PluginTrackingProvider>(),
    );
    expect(bangumi.requests.length, requestsBefore);
    expect(preferences.getPref(kBangumiAccessTokenPref), isNull);
    expect(dartApiUses, 0);
  });

  test('bundled plugin turned off: Bangumi is off, nothing is sent, the '
      'built-in provider does not take over, a saved token waits', () async {
    await preferences.setPref(kBangumiAccessTokenPref, token);
    final started = await startPluginPath();
    expect(started.moved, BangumiTokenMigration.moved);

    await started.manager.setEnabled(kBundledBangumiPluginId, false);
    final MediaTrackingService service = started.service;
    expect(service.providers.byId(kTrackingProviderBangumi), isNull);
    expect(service.isConfigured, isFalse);
    expect(service.accountName, '');

    await linkBook(key: 'b1', subjectId: 500);
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'b1',
      localProgress: 2,
      completed: false,
    );
    await service.syncNow(force: true);
    expect(bangumi.requests, isEmpty);
    expect(dartApiUses, 0);
    expect(
      await repository.pendingCount(provider: kTrackingProviderBangumi),
      1,
    );

    // A token arriving later (a paired host) stays while the plugin is off.
    await preferences.setPref(kBangumiAccessTokenPref, 'from-host');
    expect(
      await migrateBangumiTokenToPlugin(
        preferences: preferences,
        removePref: preferences.removePref,
        manager: started.manager,
        providers: started.providers,
      ),
      BangumiTokenMigration.kept,
    );
    expect(preferences.getPref(kBangumiAccessTokenPref), 'from-host');
    expect(service.providers.byId(kTrackingProviderBangumi), isNull);
  });

  test('watched anime through trackingList and "Open on site" through '
      'tracking.subjectUrl', () async {
    await preferences.setPref(kBangumiAccessTokenPref, token);
    final MediaTrackingService service = (await startPluginPath()).service;

    expect(service.canListWatchedAnime(kTrackingProviderBangumi), isTrue);
    final List<TrackingWatchedItem> watched = await service.loadWatchedAnime();
    expect(watched, hasLength(1));
    expect(watched.single.subjectId, 42);
    expect(watched.single.name, '以前看过的番剧');
    expect(watched.single.progress, 12);
    expect(watched.single.updatedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(
      service.subjectPageUrl(kTrackingProviderBangumi, 42, TrackingKind.anime),
      Uri.parse('https://bgm.tv/subject/42'),
    );
    expect(dartApiUses, 0);
  });

  test('the chapter companion only moves the chapter count: a paused entry '
      'stays paused', () async {
    await preferences.setPref(kBangumiAccessTokenPref, token);
    final MediaTrackingService service = (await startPluginPath()).service;
    bangumi.collections[600] = <String, Object?>{
      'type': 4,
      'ep_status': 3,
      'vol_status': 1,
    };
    await linkBook(
      key: 'b2',
      subjectId: 600,
      type: TrackingMediaType.bookChapter,
      mode: TrackingProgressMode.chapter,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.bookChapter,
      mediaKey: 'b2',
      localProgress: 7,
      completed: true,
    );

    final MediaTrackingSyncResult result = await service.syncNow(force: true);

    expect(result.succeeded, 1);
    expect(bangumi.collections[600]!['type'], 4);
    expect(bangumi.collections[600]!['ep_status'], 7);
    expect(bangumi.collections[600]!['vol_status'], 1);
  });

  test('without the plugin engine the built-in provider serves bangumi as '
      'before and the token preference is untouched', () async {
    await preferences.setPref(kBangumiAccessTokenPref, token);
    await preferences.setPref(kBangumiAccountNamePref, 'Hikari');
    final MediaTrackingService service = makeService(builtInBangumi: true);

    expect(service.usesBuiltInBangumi, isTrue);
    expect(
      service.providers.byId(kTrackingProviderBangumi),
      isA<BangumiTrackingProvider>(),
    );
    expect(service.isConfigured, isTrue);
    expect(service.accountName, 'Hikari');
    expect(service.canListWatchedAnime(kTrackingProviderBangumi), isTrue);
    expect(
      service.subjectPageUrl(kTrackingProviderBangumi, 42, TrackingKind.anime),
      Uri.parse('https://bgm.tv/subject/42'),
    );
    expect(preferences.getPref(kBangumiAccessTokenPref), token);
    expect(bangumi.requests, isEmpty);
  });
}

/// Bangumi's v0 API for the plugin's requests: subjects, the user's
/// collection entries (kept in [collections]) and the watched list.
final class _FakeBangumi {
  /// `METHOD url` of every request, in order.
  final List<String> requests = <String>[];

  /// Collection entry fields by subject id.
  final Map<int, Map<String, Object?>> collections =
      <int, Map<String, Object?>>{};

  static const String _api = 'https://api.bgm.tv';

  static const Map<int, Map<String, Object?>> _subjects =
      <int, Map<String, Object?>>{
        42: <String, Object?>{
          'id': 42,
          'type': 2,
          'name': 'Old anime',
          'name_cn': '以前看过的番剧',
          'eps': 12,
        },
        500: <String, Object?>{
          'id': 500,
          'type': 1,
          'name': 'Book',
          'name_cn': '本',
          'platform': '漫画',
          'volumes': 10,
        },
        600: <String, Object?>{
          'id': 600,
          'type': 1,
          'name': 'Web novel',
          'platform': '小说',
          'volumes': 5,
        },
      };

  Future<Map<String, Object?>> handle(Map<String, Object?> request) async =>
      <String, Object?>{...await _route(request), 'url': request['url']};

  Future<Map<String, Object?>> _route(Map<String, Object?> request) async {
    final String method = request['method']! as String;
    final String url = request['url']! as String;
    requests.add('$method $url');
    final Uint8List? raw = request['body'] as Uint8List?;
    final Object? body = raw == null || raw.isEmpty
        ? null
        : jsonDecode(utf8.decode(raw));
    final String path = url.startsWith(_api) ? url.substring(_api.length) : '';
    RegExpMatch? m;
    if (method == 'GET' && path == '/v0/me') {
      return _json(200, <String, Object?>{
        'username': 'hikari',
        'nickname': 'Hikari',
      });
    }
    if (method == 'GET' &&
        (m = RegExp(r'^/v0/subjects/(\d+)$').firstMatch(path)) != null) {
      final Map<String, Object?>? subject = _subjects[int.parse(m!.group(1)!)];
      return subject == null ? _json(404, null) : _json(200, subject);
    }
    if (method == 'GET' &&
        (m = RegExp(
              r'^/v0/users/hikari/collections/(\d+)$',
            ).firstMatch(path)) !=
            null) {
      final Map<String, Object?>? entry = collections[int.parse(m!.group(1)!)];
      return entry == null ? _json(404, null) : _json(200, entry);
    }
    if ((method == 'POST' || method == 'PATCH') &&
        (m = RegExp(r'^/v0/users/-/collections/(\d+)$').firstMatch(path)) !=
            null) {
      final int id = int.parse(m!.group(1)!);
      if (method == 'PATCH' && !collections.containsKey(id)) {
        return _json(404, null);
      }
      collections[id] = <String, Object?>{
        ...?collections[id],
        ...(body! as Map<String, Object?>),
      };
      return _json(204, null);
    }
    if (method == 'GET' &&
        path.startsWith('/v0/users/hikari/collections?subject_type=2&type=2')) {
      return _json(200, <String, Object?>{
        'total': 1,
        'data': <Object?>[
          <String, Object?>{
            'subject': _subjects[42],
            'type': 2,
            'ep_status': 12,
            'updated_at': '2026-01-02T03:04:05Z',
          },
        ],
      });
    }
    return _json(404, null);
  }

  static Map<String, Object?> _json(int status, Object? json) =>
      <String, Object?>{
        'status': status,
        'url': '',
        'headers': <String, String>{},
        'setCookies': <String>[],
        'body': Uint8List.fromList(
          json == null ? <int>[] : utf8.encode(jsonEncode(json)),
        ),
      };
}
