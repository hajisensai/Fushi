import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/mining/galgame_repository.dart'
    show galgameEntryFromRow;
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:fushi_engine/media/links/wikidata_anime_bridge.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart'
    show VideoMetadataNetworkException;

/// 书范围推断时最多为几部标题相近的动画查 MAL 原作（Jikan 全局 1.1 s 一条）。
const int kMediaLinkBookScopeMalLimit = 5;

/// MAL 原作查询（可注入，测试用离线 fixture）。
typedef MalSourceMaterialFetcher =
    Future<List<MalSourceMaterial>> Function(String malId);

/// Wikidata id 桥（可注入，测试用离线 fixture）：VNDB id → AniDB anime id 集合。
typedef WikidataAnimeLookup =
    Future<Map<String, Set<String>>> Function(Iterable<String> vndbIds);

/// 本机全部可参与推断的条目（一次推断内复用）。外部 id 只收已在用的视频身份
/// （mal / anidb / tmdb）与游戏的 vndb；**不收 Bangumi**（所有者 2026-10-24 拍板）。
class MediaLinkLibrarySnapshot {
  const MediaLinkLibrarySnapshot({
    required this.books,
    required this.videos,
    required this.games,
  });

  final List<MediaLinkSubject> books;
  final List<MediaLinkSubject> videos;
  final List<MediaLinkSubject> games;

  static const Set<String> _videoProviders = <String>{'mal', 'anidb', 'tmdb'};

  static Future<MediaLinkLibrarySnapshot> load(FushiDatabase db) async {
    final List<MediaLinkSubject> books = <MediaLinkSubject>[
      for (final EpubBookRow b in await db.getAllEpubBooks())
        MediaLinkSubject(
          endpoint: (kind: MediaLinkKind.book, key: b.bookKey),
          titles: <String>[b.title],
        ),
    ];

    final Map<int, Map<String, String>> idsByWork =
        <int, Map<String, String>>{};
    for (final VideoMetadataProviderIdentityRow r
        in await db.select(db.videoMetadataProviderIdentities).get()) {
      final int? workId = r.workId;
      if (workId == null || !_videoProviders.contains(r.provider)) continue;
      idsByWork.putIfAbsent(workId, () => <String, String>{})[r.provider] =
          r.externalId;
    }
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in await db.getAllMediaCollections())
        c.id: c,
    };
    final List<MediaLinkSubject> videos = <MediaLinkSubject>[];
    final Set<int> collectionsWithWork = <int>{};
    for (final VideoMetadataWorkRow w
        in await db.select(db.videoMetadataWorks).get()) {
      final MediaLinkEndpoint endpoint;
      final List<String> titles = <String>[w.title];
      if (w.collectionId case final int cid) {
        endpoint = (
          kind: MediaLinkKind.videoCollection,
          key: collectionTagEntryKey(cid),
        );
        collectionsWithWork.add(cid);
        if (collections[cid]?.name case final String name) titles.add(name);
      } else if (w.bookUid case final String uid) {
        endpoint = (kind: MediaLinkKind.videoEpisode, key: uid);
      } else {
        continue;
      }
      if (w.originalTitle case final String original) titles.add(original);
      videos.add(
        MediaLinkSubject(
          endpoint: endpoint,
          titles: titles,
          year: w.year,
          externalIds: idsByWork[w.id] ?? const <String, String>{},
        ),
      );
    }
    // 没刮削过的视频合集也参与标题匹配（只有合集名）。
    final Set<int> videoCollectionIds = <int>{
      for (final MediaCollectionRow c
          in await db.getMediaCollectionsForEntryDomain(MediaKind.video, ''))
        c.id,
    };
    for (final int id in videoCollectionIds.difference(collectionsWithWork)) {
      final MediaCollectionRow? c = collections[id];
      if (c == null) continue;
      videos.add(
        MediaLinkSubject(
          endpoint: (
            kind: MediaLinkKind.videoCollection,
            key: collectionTagEntryKey(id),
          ),
          titles: <String>[c.name],
        ),
      );
    }

    final Map<String, List<GalgameSourceRow>> sources = await db
        .getAllGalgameSources();
    final List<MediaLinkSubject> games = <MediaLinkSubject>[];
    for (final GalgameRow g in await db.getAllGalgames()) {
      final List<GalgameSourceRow> rows =
          sources[g.id] ?? const <GalgameSourceRow>[];
      final List<String> titles = <String>[
        galgameEntryFromRow(g, sources: rows).displayName,
      ];
      final Map<String, String> ids = <String, String>{};
      for (final GalgameSourceRow s in rows) {
        if (s.source != 'vndb') continue;
        final GalgameMetadataDraft draft = GalgameMetadataDraft.decode(
          s.dataJson,
        );
        titles.addAll(<String>[
          if (draft.name case final String n) n,
          ...draft.aliases,
        ]);
        if (s.externalId case final String id when id.trim().isNotEmpty) {
          ids['vndb'] = id.trim();
        }
      }
      games.add(
        MediaLinkSubject(
          endpoint: (kind: MediaLinkKind.game, key: g.id),
          titles: titles,
          externalIds: ids,
        ),
      );
    }
    return MediaLinkLibrarySnapshot(books: books, videos: videos, games: games);
  }

  MediaLinkSubject? find(MediaLinkEndpoint e) {
    for (final MediaLinkSubject s in <MediaLinkSubject>[
      ...books,
      ...videos,
      ...games,
    ]) {
      if (s.endpoint.kind == e.kind && s.endpoint.key == e.key) return s;
    }
    return null;
  }
}

/// 以 [self] 为中心收集候选（确定性规则；MAL 原作在前，同一对条目先到先得）。
Future<List<MediaLinkCandidate>> collectMediaLinkCandidates({
  required MediaLinkLibrarySnapshot library,
  required MediaLinkEndpoint self,
  required MalSourceMaterialFetcher fetchMalSourceMaterial,
  required WikidataAnimeLookup lookupWikidataAnime,
}) async {
  final MediaLinkSubject? subject = library.find(self);
  if (subject == null) return const <MediaLinkCandidate>[];
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];
  switch (self.kind) {
    case MediaLinkKind.videoCollection:
    case MediaLinkKind.videoEpisode:
      // R0：本地游戏的 VNDB id 经 Wikidata 桥到这部动画的 AniDB id（强判据）。
      if (subject.externalIds['anidb'] != null) {
        final List<MediaLinkSubject> vns = <MediaLinkSubject>[
          for (final MediaLinkSubject g in library.games)
            if (g.externalIds['vndb'] != null) g,
        ];
        if (vns.isNotEmpty) {
          final Map<String, Set<String>> bridged = await lookupWikidataAnime(
            vns.map((MediaLinkSubject g) => g.externalIds['vndb']!),
          );
          for (final MediaLinkSubject g in vns) {
            out.addAll(
              matchWikidataAnime(
                game: g,
                anidbIds:
                    bridged[normalizeVndbVnId(g.externalIds['vndb']!)] ??
                    const <String>{},
                videos: <MediaLinkSubject>[subject],
              ),
            );
          }
        }
      }
      if (subject.externalIds['mal'] case final String malId) {
        out.addAll(
          matchMalSourceMaterial(
            video: subject,
            sources: await fetchMalSourceMaterial(malId),
            books: library.books,
          ),
        );
      }
      out.addAll(
        matchSubjectsByTitle(
          subject: subject,
          others: <MediaLinkSubject>[...library.games, ...library.books],
        ),
      );
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      final List<MediaLinkSubject> nearVideos = <MediaLinkSubject>[
        for (final MediaLinkSubject v in library.videos)
          if (v.externalIds.containsKey('mal') &&
              titleMatchStrength(v.titles, subject.titles) > 0)
            v,
      ].take(kMediaLinkBookScopeMalLimit).toList();
      for (final MediaLinkSubject v in nearVideos) {
        out.addAll(
          matchMalSourceMaterial(
            video: v,
            sources: await fetchMalSourceMaterial(v.externalIds['mal']!),
            books: <MediaLinkSubject>[subject],
          ),
        );
      }
      out.addAll(
        matchSubjectsByTitle(
          subject: subject,
          others: <MediaLinkSubject>[...library.videos, ...library.games],
        ),
      );
    case MediaLinkKind.game:
      if (subject.externalIds['vndb'] case final String vndb) {
        final Map<String, Set<String>> bridged = await lookupWikidataAnime(
          <String>[vndb],
        );
        out.addAll(
          matchWikidataAnime(
            game: subject,
            anidbIds: bridged[normalizeVndbVnId(vndb)] ?? const <String>{},
            videos: library.videos,
          ),
        );
      }
      out.addAll(
        matchSubjectsByTitle(
          subject: subject,
          others: <MediaLinkSubject>[...library.videos, ...library.books],
        ),
      );
    case MediaLinkKind.musicAlbum:
    case MediaLinkKind.musicTrack:
      // VGMdb / MusicBrainz 关系与声纹比对依赖音乐模块（专辑 / 曲目表与 Rust
      // chromaprint），音乐模块落地前没有候选来源。
      break;
  }
  return out;
}

/// 跑一轮以 [self] 为中心的推断并写成建议，返回新增建议数。AI 已指派（且 AI 模块
/// 开着）时候选先经 AI 裁决；AI 失败提示用户并退回只写确定性建议。
Future<int> runMediaLinkInference({
  required FushiDatabase db,
  required MediaLinkEndpoint self,
  required MalSourceMaterialFetcher fetchMalSourceMaterial,
  required WikidataAnimeLookup lookupWikidataAnime,
  MediaLinkJudge? judge,
}) async {
  final MediaLinkLibrarySnapshot library = await MediaLinkLibrarySnapshot.load(
    db,
  );
  final List<MediaLinkCandidate> candidates = await collectMediaLinkCandidates(
    library: library,
    self: self,
    fetchMalSourceMaterial: fetchMalSourceMaterial,
    lookupWikidataAnime: lookupWikidataAnime,
  );
  if (judge != null) {
    try {
      return (await applyMediaLinkCandidates(
        db: db,
        candidates: candidates,
        judge: judge,
      )).proposed;
    } on AiChatFailure {
      FushiToast.show(
        msg: t.media_link_infer_ai_failed,
        severity: ToastSeverity.warning,
      );
    }
  }
  return (await applyMediaLinkCandidates(
    db: db,
    candidates: candidates,
  )).proposed;
}

/// 详情页「查找相关作品」按钮的回调（[MediaLinksSection.onInfer]）。音乐端点没有
/// 推断来源，返回 null（不显示按钮）。
Future<int> Function()? mediaLinkInferCallback({
  required WidgetRef ref,
  required MediaLinkEndpoint self,
}) {
  if (self.kind == MediaLinkKind.musicAlbum ||
      self.kind == MediaLinkKind.musicTrack) {
    return null;
  }
  return () async {
    final AppModel appModel = ref.read(appProvider);
    final AiProviderConfig? provider =
        isAiModuleEnabled(appModel.moduleVisibility)
        ? resolveMediaLinkAiProvider(appModel.prefsRepo)
        : null;
    final MalVideoMetadataProvider mal = MalVideoMetadataProvider(
      client: createAppHttpIoClient(),
    );
    final AiChatClient? aiClient = provider == null ? null : AiChatClient();
    try {
      return await runMediaLinkInference(
        db: appModel.database,
        self: self,
        fetchMalSourceMaterial: mal.fetchSourceMaterial,
        lookupWikidataAnime: WikidataAnimeBridge.shared.anidbIdsForVndb,
        judge: provider == null
            ? null
            : AiMediaLinkJudge(client: aiClient!, provider: provider),
      );
    } on WikidataBridgeException {
      FushiToast.show(
        msg: t.media_link_infer_wikidata_failed,
        severity: ToastSeverity.warning,
      );
      return 0;
    } on VideoMetadataNetworkException {
      // MAL（Jikan）连不上 / 限流：本轮整体不写（规则是先收齐候选再落库），
      // 告诉用户而不是假装「没有新建议」。
      FushiToast.show(
        msg: t.media_link_infer_network_failed,
        severity: ToastSeverity.warning,
      );
      return 0;
    } finally {
      mal.close();
      aiClient?.close();
    }
  };
}
