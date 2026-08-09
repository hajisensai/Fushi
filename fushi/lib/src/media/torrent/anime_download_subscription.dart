import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_release_descriptor.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart'
    show kDownloadDiscoveryTimeout;
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/jimaku_batch.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';

const Object _notSet = Object();

/// A durable "series + video release + optional Jimaku subtitle" subscription.
///
/// [startAfterEpisode] is the episode the user selected when subscribing.
/// Existing releases are deliberately not backfilled. [processedEpisodes]
/// records successfully queued later episodes, allowing an older missing
/// episode to arrive after a newer one without being skipped.
class AnimeDownloadSubscription {
  const AnimeDownloadSubscription({
    required this.id,
    required this.createdAtMs,
    required this.anilistId,
    required this.seriesTitle,
    required this.nyaaQuery,
    required this.category,
    required this.releaseGroup,
    required this.startAfterEpisode,
    this.coverUrl,
    this.resolution,
    this.jimakuEntryId,
    this.jimakuEntryName,
    this.jimakuLanguage,
    this.trustedOnly = false,
    this.enabled = true,
    this.processedEpisodes = const <int>{},
    this.lastCheckedAtMs,
    this.lastMatchedAtMs,
    this.lastError,
  });

  factory AnimeDownloadSubscription.fromSelection({
    required int anilistId,
    required String seriesTitle,
    required String nyaaQuery,
    required String category,
    required String releaseGroup,
    required int startAfterEpisode,
    String? coverUrl,
    String? resolution,
    int? jimakuEntryId,
    String? jimakuEntryName,
    String? jimakuLanguage,
    bool trustedOnly = false,
    DateTime? now,
  }) {
    final int createdAtMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final String identity = <String>[
      '$anilistId',
      releaseGroup.trim().toLowerCase(),
      (resolution ?? '').trim().toLowerCase(),
      category.trim().toLowerCase(),
      '${jimakuEntryId ?? ''}',
      (jimakuLanguage ?? '').trim().toLowerCase(),
    ].join('|');
    return AnimeDownloadSubscription(
      id: sha1.convert(utf8.encode(identity)).toString(),
      createdAtMs: createdAtMs,
      anilistId: anilistId,
      seriesTitle: seriesTitle.trim(),
      coverUrl: coverUrl,
      nyaaQuery: nyaaQuery.trim(),
      category: category.trim().isEmpty ? '1_0' : category.trim(),
      trustedOnly: trustedOnly,
      releaseGroup: releaseGroup.trim(),
      resolution: resolution?.trim(),
      jimakuEntryId: jimakuEntryId,
      jimakuEntryName: jimakuEntryName?.trim(),
      jimakuLanguage: jimakuLanguage?.trim(),
      startAfterEpisode: startAfterEpisode,
    );
  }

  final String id;
  final int createdAtMs;
  final int anilistId;
  final String seriesTitle;
  final String? coverUrl;
  final String nyaaQuery;
  final String category;
  final bool trustedOnly;
  final String releaseGroup;
  final String? resolution;

  /// null = video-only subscription. A non-null id pins one explicit Jimaku
  /// entry; season packs are resolved inside that entry by episode number.
  final int? jimakuEntryId;
  final String? jimakuEntryName;
  final String? jimakuLanguage;

  final int startAfterEpisode;
  final Set<int> processedEpisodes;
  final bool enabled;
  final int? lastCheckedAtMs;
  final int? lastMatchedAtMs;
  final String? lastError;

  AnimeDownloadSubscription copyWith({
    bool? enabled,
    Set<int>? processedEpisodes,
    int? lastCheckedAtMs,
    int? lastMatchedAtMs,
    Object? lastError = _notSet,
  }) {
    return AnimeDownloadSubscription(
      id: id,
      createdAtMs: createdAtMs,
      anilistId: anilistId,
      seriesTitle: seriesTitle,
      coverUrl: coverUrl,
      nyaaQuery: nyaaQuery,
      category: category,
      trustedOnly: trustedOnly,
      releaseGroup: releaseGroup,
      resolution: resolution,
      jimakuEntryId: jimakuEntryId,
      jimakuEntryName: jimakuEntryName,
      jimakuLanguage: jimakuLanguage,
      startAfterEpisode: startAfterEpisode,
      processedEpisodes: processedEpisodes ?? this.processedEpisodes,
      enabled: enabled ?? this.enabled,
      lastCheckedAtMs: lastCheckedAtMs ?? this.lastCheckedAtMs,
      lastMatchedAtMs: lastMatchedAtMs ?? this.lastMatchedAtMs,
      lastError:
          identical(lastError, _notSet) ? this.lastError : lastError as String?,
    );
  }
}

Map<String, dynamic> encodeAnimeDownloadSubscription(
  AnimeDownloadSubscription subscription,
) {
  final List<int> processed = subscription.processedEpisodes.toList()..sort();
  return <String, dynamic>{
    'id': subscription.id,
    'createdAtMs': subscription.createdAtMs,
    'anilistId': subscription.anilistId,
    'seriesTitle': subscription.seriesTitle,
    'coverUrl': subscription.coverUrl,
    'nyaaQuery': subscription.nyaaQuery,
    'category': subscription.category,
    'trustedOnly': subscription.trustedOnly,
    'releaseGroup': subscription.releaseGroup,
    'resolution': subscription.resolution,
    'jimakuEntryId': subscription.jimakuEntryId,
    'jimakuEntryName': subscription.jimakuEntryName,
    'jimakuLanguage': subscription.jimakuLanguage,
    'startAfterEpisode': subscription.startAfterEpisode,
    'processedEpisodes': processed,
    'enabled': subscription.enabled,
    'lastCheckedAtMs': subscription.lastCheckedAtMs,
    'lastMatchedAtMs': subscription.lastMatchedAtMs,
    'lastError': subscription.lastError,
  };
}

AnimeDownloadSubscription? decodeAnimeDownloadSubscription(
  Map<dynamic, dynamic> raw,
) {
  try {
    final Object? id = raw['id'];
    final Object? anilistId = raw['anilistId'];
    final Object? title = raw['seriesTitle'];
    final Object? query = raw['nyaaQuery'];
    final Object? group = raw['releaseGroup'];
    final Object? anchor = raw['startAfterEpisode'];
    if (id is! String ||
        id.isEmpty ||
        anilistId is! int ||
        title is! String ||
        query is! String ||
        group is! String ||
        group.trim().isEmpty ||
        anchor is! int) {
      return null;
    }
    final Set<int> processed = <int>{};
    final Object? rawProcessed = raw['processedEpisodes'];
    if (rawProcessed is List) {
      processed.addAll(rawProcessed.whereType<int>().where((int e) => e > 0));
    }
    return AnimeDownloadSubscription(
      id: id,
      createdAtMs: raw['createdAtMs'] is int ? raw['createdAtMs'] as int : 0,
      anilistId: anilistId,
      seriesTitle: title,
      coverUrl: raw['coverUrl'] is String ? raw['coverUrl'] as String : null,
      nyaaQuery: query,
      category: raw['category'] is String &&
              (raw['category'] as String).trim().isNotEmpty
          ? raw['category'] as String
          : '1_0',
      trustedOnly: raw['trustedOnly'] == true,
      releaseGroup: group.trim(),
      resolution:
          raw['resolution'] is String ? raw['resolution'] as String : null,
      jimakuEntryId:
          raw['jimakuEntryId'] is int ? raw['jimakuEntryId'] as int : null,
      jimakuEntryName: raw['jimakuEntryName'] is String
          ? raw['jimakuEntryName'] as String
          : null,
      jimakuLanguage: raw['jimakuLanguage'] is String
          ? raw['jimakuLanguage'] as String
          : null,
      startAfterEpisode: anchor,
      processedEpisodes: processed,
      enabled: raw['enabled'] != false,
      lastCheckedAtMs:
          raw['lastCheckedAtMs'] is int ? raw['lastCheckedAtMs'] as int : null,
      lastMatchedAtMs:
          raw['lastMatchedAtMs'] is int ? raw['lastMatchedAtMs'] as int : null,
      lastError: raw['lastError'] is String ? raw['lastError'] as String : null,
    );
  } catch (_) {
    return null;
  }
}

class AnimeDownloadSubscriptionStore {
  AnimeDownloadSubscriptionStore({required this.baseDir});

  final Directory baseDir;
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Directory get _directory => Directory(p.join(baseDir.path, 'subscriptions'));

  File _file(String id) => File(p.join(_directory.path, '$id.json'));

  Future<List<AnimeDownloadSubscription>> loadAll() async {
    final List<AnimeDownloadSubscription> subscriptions =
        <AnimeDownloadSubscription>[];
    try {
      if (!await _directory.exists()) return subscriptions;
      await for (final FileSystemEntity entity in _directory.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final Object? decoded = jsonDecode(await entity.readAsString());
          if (decoded is! Map) continue;
          final AnimeDownloadSubscription? subscription =
              decodeAnimeDownloadSubscription(decoded);
          if (subscription != null) subscriptions.add(subscription);
        } catch (_) {}
      }
    } catch (_) {}
    subscriptions
        .sort((AnimeDownloadSubscription a, AnimeDownloadSubscription b) {
      final int byCreated = b.createdAtMs.compareTo(a.createdAtMs);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
    return subscriptions;
  }

  Future<void> save(AnimeDownloadSubscription subscription) async {
    try {
      await _directory.create(recursive: true);
      final File target = _file(subscription.id);
      final File temporary = File('${target.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(encodeAnimeDownloadSubscription(subscription)),
      );
      await temporary.rename(target.path);
      revision.value++;
    } catch (_) {}
  }

  Future<void> delete(String id) async {
    try {
      final File target = _file(id);
      if (await target.exists()) await target.delete();
      revision.value++;
    } catch (_) {}
  }
}

String _normaliseMatchValue(String value) => value.trim().toLowerCase();

/// Selects one deterministic release for each new episode in a subscription.
///
/// Batch torrents, remakes, already processed episodes and results before the
/// anchor are excluded. Release-group matching is exact after trim/case-fold,
/// preventing similarly named groups from silently changing the subscription.
List<NyaaTorrent> selectSubscriptionReleases(
  AnimeDownloadSubscription subscription,
  List<NyaaTorrent> results,
) {
  final String expectedGroup = _normaliseMatchValue(subscription.releaseGroup);
  final String? expectedResolution = subscription.resolution == null
      ? null
      : _normaliseMatchValue(subscription.resolution!);
  final Map<int, NyaaTorrent> bestByEpisode = <int, NyaaTorrent>{};
  for (final NyaaTorrent torrent in results) {
    final int? episode = torrent.episode;
    final AnimeReleaseDescriptor release = torrent.releaseDescriptor;
    final String? group = release.releaseGroup;
    if (episode == null ||
        episode <= subscription.startAfterEpisode ||
        subscription.processedEpisodes.contains(episode) ||
        torrent.isBatch ||
        torrent.remake ||
        group == null ||
        _normaliseMatchValue(group) != expectedGroup ||
        (subscription.trustedOnly && !torrent.trusted)) {
      continue;
    }
    if (expectedResolution != null &&
        _normaliseMatchValue(release.resolution ?? '') != expectedResolution) {
      continue;
    }
    final NyaaTorrent? previous = bestByEpisode[episode];
    if (previous == null || _isBetterRelease(torrent, previous)) {
      bestByEpisode[episode] = torrent;
    }
  }
  final List<MapEntry<int, NyaaTorrent>> entries = bestByEpisode.entries
      .toList()
    ..sort((MapEntry<int, NyaaTorrent> a, MapEntry<int, NyaaTorrent> b) =>
        a.key.compareTo(b.key));
  return <NyaaTorrent>[
    for (final MapEntry<int, NyaaTorrent> e in entries) e.value
  ];
}

bool _isBetterRelease(NyaaTorrent candidate, NyaaTorrent previous) {
  if (candidate.trusted != previous.trusted) return candidate.trusted;
  if (candidate.seeders != previous.seeders) {
    return candidate.seeders > previous.seeders;
  }
  final DateTime candidateDate =
      candidate.pubDate ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final DateTime previousDate =
      previous.pubDate ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  if (candidateDate != previousDate) {
    return candidateDate.isAfter(previousDate);
  }
  return candidate.infoHash.compareTo(previous.infoHash) < 0;
}

typedef AnimeSubscriptionSearch = Future<List<NyaaTorrent>> Function(
  AnimeDownloadSubscription subscription,
);

typedef AnimeSubscriptionSubtitleFetcher = Future<List<PlanSubtitle>> Function(
  AnimeDownloadSubscription subscription,
  NyaaTorrent torrent,
  Directory destination,
);

class AnimeDownloadSubscriptionService {
  AnimeDownloadSubscriptionService({
    required this.store,
    required this.planStore,
    required QbConnectionConfig Function() configProvider,
    required TorrentBackend Function(QbConnectionConfig config) backendFactory,
    AnimeSubscriptionSearch? search,
    String Function()? jimakuApiKeyProvider,
    AnimeSubscriptionSubtitleFetcher? subtitleFetcher,
    Future<http.Client> Function()? httpClientFactory,
    this.interval = const Duration(minutes: 15),
  })  : _configProvider = configProvider,
        _backendFactory = backendFactory,
        _search = search,
        _jimakuApiKeyProvider = jimakuApiKeyProvider ?? (() => ''),
        _subtitleFetcher = subtitleFetcher,
        _httpClientFactory = httpClientFactory ?? (() async => http.Client());

  final AnimeDownloadSubscriptionStore store;
  final AnimeDownloadPlanStore planStore;
  final QbConnectionConfig Function() _configProvider;
  final TorrentBackend Function(QbConnectionConfig config) _backendFactory;
  final AnimeSubscriptionSearch? _search;
  final String Function() _jimakuApiKeyProvider;
  final AnimeSubscriptionSubtitleFetcher? _subtitleFetcher;
  final Future<http.Client> Function() _httpClientFactory;
  final Duration interval;
  final ValueNotifier<bool> checking = ValueNotifier<bool>(false);

  Timer? _timer;
  bool _checking = false;

  Future<List<NyaaTorrent>> _searchNyaa(
    AnimeDownloadSubscription subscription,
  ) async {
    final http.Client rawClient = await _httpClientFactory();
    final NyaaClient client = NyaaClient(client: rawClient);
    try {
      return await client
          .search(
            subscription.nyaaQuery,
            category: subscription.category,
            filter: subscription.trustedOnly ? '2' : '0',
          )
          .timeout(kDownloadDiscoveryTimeout);
    } finally {
      client.close();
    }
  }

  Future<List<PlanSubtitle>> _fetchSubtitlesFor(
    AnimeDownloadSubscription subscription,
    NyaaTorrent torrent,
    Directory destination,
  ) async {
    if (subscription.jimakuEntryId == null) {
      return const <PlanSubtitle>[];
    }
    final AnimeSubscriptionSubtitleFetcher? injected = _subtitleFetcher;
    if (injected != null) {
      return injected(subscription, torrent, destination);
    }
    final int? episode = torrent.episode;
    if (episode == null) return const <PlanSubtitle>[];
    final String apiKey = _jimakuApiKeyProvider().trim();
    if (apiKey.isEmpty) {
      throw StateError('Jimaku API key is missing');
    }
    final http.Client rawClient = await _httpClientFactory();
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey, client: rawClient);
    try {
      final List<JimakuFile> files = await jimaku
          .listFiles(subscription.jimakuEntryId!, episode: episode)
          .timeout(kDownloadDiscoveryTimeout);
      final JimakuFile? selected = pickBestSubtitleFile(
        files,
        episode: episode,
        preferredLanguage: subscription.jimakuLanguage,
      );
      if (selected == null) return const <PlanSubtitle>[];
      final bytes = await jimaku
          .downloadFile(selected.url)
          .timeout(kDownloadDiscoveryTimeout);
      if (bytes == null) return const <PlanSubtitle>[];
      await destination.create(recursive: true);
      final String fileName = p.basename(selected.name);
      final File file = File(p.join(destination.path, fileName));
      await file.writeAsBytes(bytes);
      return <PlanSubtitle>[
        PlanSubtitle(
          episode: episode,
          fileName: selected.name,
          stagedPath: file.path,
          language: detectSubtitleLanguage(selected.name),
        ),
      ];
    } finally {
      jimaku.close();
    }
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(checkAll()));
    unawaited(checkAll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> subscribe(AnimeDownloadSubscription subscription) =>
      store.save(subscription);

  Future<void> setEnabled(String id, bool enabled) async {
    final List<AnimeDownloadSubscription> subscriptions = await store.loadAll();
    for (final AnimeDownloadSubscription subscription in subscriptions) {
      if (subscription.id == id) {
        await store.save(subscription.copyWith(enabled: enabled));
        return;
      }
    }
  }

  Future<void> delete(String id) => store.delete(id);

  Future<void> checkAll() async {
    if (_checking) return;
    _checking = true;
    checking.value = true;
    try {
      final List<AnimeDownloadSubscription> subscriptions =
          await store.loadAll();
      for (final AnimeDownloadSubscription subscription in subscriptions) {
        if (subscription.enabled) await _check(subscription);
      }
    } finally {
      _checking = false;
      checking.value = false;
    }
  }

  Future<void> checkSubscription(String id) async {
    if (_checking) return;
    _checking = true;
    checking.value = true;
    try {
      final List<AnimeDownloadSubscription> subscriptions =
          await store.loadAll();
      for (final AnimeDownloadSubscription subscription in subscriptions) {
        if (subscription.id == id) {
          await _check(subscription);
          break;
        }
      }
    } finally {
      _checking = false;
      checking.value = false;
    }
  }

  Future<void> _check(AnimeDownloadSubscription subscription) async {
    final int checkedAt = DateTime.now().millisecondsSinceEpoch;
    AnimeDownloadSubscription current = subscription;
    try {
      final QbConnectionConfig config = _configProvider();
      if (!config.isConfigured) {
        await store.save(current.copyWith(
          lastCheckedAtMs: checkedAt,
          lastError: 'download backend not configured',
        ));
        return;
      }
      final AnimeSubscriptionSearch? injectedSearch = _search;
      final List<NyaaTorrent> releases = selectSubscriptionReleases(
        current,
        await (injectedSearch?.call(current) ?? _searchNyaa(current)),
      );
      if (releases.isEmpty) {
        await store.save(current.copyWith(
          lastCheckedAtMs: checkedAt,
          lastError: null,
        ));
        return;
      }
      final Set<String> existingPlanIds = <String>{
        for (final AnimeDownloadPlan plan in await planStore.loadAll())
          plan.id.toLowerCase(),
      };
      String? pendingError;
      final TorrentBackend backend = _backendFactory(config);
      try {
        await backend.prepareCategory(config.category);
        for (final NyaaTorrent torrent in releases) {
          final int? episode = torrent.episode;
          final String id = torrent.infoHash.trim().toLowerCase();
          if (episode == null || id.isEmpty) continue;
          bool queued = existingPlanIds.contains(id);
          if (!queued) {
            final List<PlanSubtitle> subtitles = await _fetchSubtitlesFor(
              current,
              torrent,
              planStore.subsDirFor(id),
            );
            if (current.jimakuEntryId != null && subtitles.isEmpty) {
              pendingError = 'subtitle not available for episode $episode from '
                  '${current.jimakuEntryName ?? current.jimakuEntryId}';
              await planStore.delete(id);
              continue;
            }
            final AnimeDownloadPlan plan = AnimeDownloadPlan(
              id: id,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
              anilistId: current.anilistId,
              seriesTitle: current.seriesTitle,
              coverUrl: current.coverUrl,
              torrentTitle: torrent.title,
              magnet: torrent.magnet,
              qbCategory: config.category,
              subtitles: subtitles,
              jimakuEntryId: current.jimakuEntryId,
              jimakuEntryName: current.jimakuEntryName,
              jimakuLanguage: current.jimakuLanguage,
              // 订阅只追**单集**种子（上面 `episode == null` 已 continue），标题
              // 集号就是该集，且这里已经真的把字幕下下来了 → 直接 resolved。
              // 不走 BUG-1206 的延迟反查：订阅有一条更强的产品约束——
              // 「要字幕却取不到就整条不下」（见下方 pendingError 分支），
              // 改成完成后再取会把这个门变成「先下完再说没字幕」。
              subtitleStatus: subtitles.isEmpty
                  ? AnimeDownloadPlan.subtitleNone
                  : AnimeDownloadPlan.subtitleResolved,
            );
            await planStore.save(plan);
            queued = await backend.addTorrent(
              torrent.magnet,
              category: config.category,
              sequential: true,
              firstLastPiecePrio: true,
            );
            if (!queued) {
              final List<TorrentSnapshot> torrents = await backend.listTorrents(
                category: config.category.isEmpty ? null : config.category,
              );
              queued = torrents.any(
                (TorrentSnapshot snapshot) => snapshot.hash.toLowerCase() == id,
              );
            }
            if (!queued) await planStore.delete(id);
          }
          if (!queued) continue;
          current = current.copyWith(
            processedEpisodes: <int>{
              ...current.processedEpisodes,
              episode,
            },
            lastCheckedAtMs: checkedAt,
            lastMatchedAtMs: DateTime.now().millisecondsSinceEpoch,
            lastError: null,
          );
          existingPlanIds.add(id);
          await store.save(current);
        }
      } finally {
        backend.close();
      }
      if (current.lastCheckedAtMs != checkedAt) {
        await store.save(current.copyWith(
          lastCheckedAtMs: checkedAt,
          lastError: pendingError ?? 'matching release could not be queued',
        ));
      } else if (pendingError != null) {
        await store.save(current.copyWith(lastError: pendingError));
      }
    } catch (error) {
      await store.save(current.copyWith(
        lastCheckedAtMs: checkedAt,
        lastError: error.toString(),
      ));
    }
  }
}
