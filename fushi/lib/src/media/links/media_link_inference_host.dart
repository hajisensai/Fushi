import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/mining/galgame_repository.dart'
    show galgameEntryFromRow;
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:fushi_engine/media/links/music_link_inference.dart';
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
/// [music] 是曲库、刮削结果与声纹缓存（音乐 ↔ 作品推断用，见
/// `music_link_inference.dart`）。
class MediaLinkLibrarySnapshot {
  const MediaLinkLibrarySnapshot({
    required this.books,
    required this.videos,
    required this.games,
    this.music = MusicLinkLibrary.empty,
    this.seriesLinkedPairs = const <String>{},
  });

  final List<MediaLinkSubject> books;
  final List<MediaLinkSubject> videos;
  final List<MediaLinkSubject> games;
  final MusicLinkLibrary music;

  /// 刮削的系列关系（`collection_relations` 已绑定的行）已经连上的条目对
  /// （[mediaLinkPairKey]）：资料源给过答案的不再拿去问 AI。
  final Set<String> seriesLinkedPairs;

  bool seriesLinked(MediaLinkEndpoint a, MediaLinkEndpoint b) =>
      seriesLinkedPairs.contains(mediaLinkPairKey(a, b));

  /// 音乐候选可落的作品（视频合集 / 游戏；单集只作声纹命中的兜底端点）。
  List<MediaLinkSubject> get musicTargets => <MediaLinkSubject>[
    ...videos,
    ...games,
  ];

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
    final Set<String> seriesLinkedPairs = <String>{};
    for (final CollectionRelationRow r
        in await db.select(db.collectionRelations).get()) {
      final MediaLinkEndpoint? from = _videoEndpoint(r.collectionId, r.bookUid);
      final MediaLinkEndpoint? to = _videoEndpoint(
        r.targetCollectionId,
        r.targetBookUid,
      );
      if (from != null && to != null) {
        seriesLinkedPairs.add(mediaLinkPairKey(from, to));
      }
    }
    return MediaLinkLibrarySnapshot(
      books: books,
      videos: videos,
      games: games,
      music: await loadMusicLinkLibrary(db),
      seriesLinkedPairs: seriesLinkedPairs,
    );
  }

  static MediaLinkEndpoint? _videoEndpoint(int? collectionId, String? bookUid) {
    if (collectionId != null) {
      return (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(collectionId),
      );
    }
    if (bookUid != null) {
      return (kind: MediaLinkKind.videoEpisode, key: bookUid);
    }
    return null;
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

/// 以 [self] 为中心收集候选（确定性规则；同一对条目强证据顶掉弱的，同样强的先到
/// 先得）。[withAiOnly]：是否出只有 AI 能定的同类系列候选（[matchSeriesByTitle]）——
/// 没有裁决器时不必算。
Future<List<MediaLinkCandidate>> collectMediaLinkCandidates({
  required MediaLinkLibrarySnapshot library,
  required MediaLinkEndpoint self,
  required MalSourceMaterialFetcher fetchMalSourceMaterial,
  required WikidataAnimeLookup lookupWikidataAnime,
  bool withAiOnly = false,
}) async {
  if (self.kind == MediaLinkKind.musicAlbum ||
      self.kind == MediaLinkKind.musicTrack) {
    // 音乐 → 作品：声纹命中 / 刮削名与本地名带作品名 + 关键词（不联网）。
    return <MediaLinkCandidate>[
      for (final MediaLinkCandidate c in collectMusicLinkCandidates(
        music: library.music,
        works: library.musicTargets,
      ))
        if (c.from.endpoint == self) c,
    ];
  }
  final MediaLinkSubject? subject = library.find(self);
  if (subject == null) return const <MediaLinkCandidate>[];
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[
    // 从作品一侧看：连到它的原声 / 主题曲（声纹命中在前）。
    if (self.kind == MediaLinkKind.videoCollection ||
        self.kind == MediaLinkKind.videoEpisode ||
        self.kind == MediaLinkKind.game)
      for (final MediaLinkCandidate c in collectMusicLinkCandidates(
        music: library.music,
        works: library.musicTargets,
      ))
        if (c.to.endpoint == self) c,
  ];
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
      if (withAiOnly) {
        out.addAll(
          matchSeriesByTitle(
            subject: subject,
            others: library.videos,
            alreadyLinked: library.seriesLinked,
          ),
        );
      }
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
      if (withAiOnly) {
        out.addAll(matchSeriesByTitle(subject: subject, others: library.games));
      }
    case MediaLinkKind.musicAlbum:
    case MediaLinkKind.musicTrack:
      break; // 上面已处理。
  }
  return out;
}

/// 跑一轮以 [self] 为中心的推断（用户手动触发：[MediaLinkInferenceTrigger.manual]
/// 门槛），返回新写入的连接数（直接生效 + 建议）。AI 已指派（且 AI 模块开着）时
/// 候选先经 AI 裁决；AI 失败提示用户并退回只跑确定性规则。
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
    withAiOnly: judge != null,
  );
  if (judge != null) {
    try {
      final int written = (await applyMediaLinkCandidates(
        db: db,
        candidates: candidates,
        trigger: MediaLinkInferenceTrigger.manual,
        judge: judge,
      )).written;
      // 后面的批次失败：已拿到的结论照常落库，剩下的按「没经 AI」处理，告诉用户。
      if (judge is AiMediaLinkJudge && judge.partialFailure != null) {
        FushiToast.show(
          msg: t.media_link_infer_ai_failed,
          severity: ToastSeverity.warning,
        );
      }
      return written;
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
    trigger: MediaLinkInferenceTrigger.manual,
  )).written;
}

/// 全库批量推断音乐 ↔ 作品关系（库管家编排的入口；默认按自动路径门槛：声纹命中
/// 直接生效，标题 + 关键词写建议或经 AI 裁决）。只读本机数据，不联网；[judge] 为
/// null 时不发任何 AI 请求。AI 失败照常抛给调用方。返回逐条写入清单，
/// [revertMusicLinkBatch] 整批撤销。
Future<MusicLinkBatchResult> runMusicMediaLinkBatchInference({
  required FushiDatabase db,
  MediaLinkInferenceTrigger trigger = MediaLinkInferenceTrigger.automatic,
  MediaLinkJudge? judge,
}) async {
  final MediaLinkLibrarySnapshot library = await MediaLinkLibrarySnapshot.load(
    db,
  );
  if (library.music.isEmpty) return MusicLinkBatchResult.empty;
  return inferMusicMediaLinks(
    db: db,
    music: library.music,
    works: library.musicTargets,
    trigger: trigger,
    judge: judge,
  );
}

/// 详情页「查找相关作品」按钮的回调（[MediaLinksSection.onInfer]）。音乐端点只用
/// 本机刮削数据与声纹缓存（不查 MAL / Wikidata）。
Future<int> Function()? mediaLinkInferCallback({
  required WidgetRef ref,
  required MediaLinkEndpoint self,
}) {
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
            : AiMediaLinkJudge(
                client: aiClient!,
                provider: provider,
                cache: MediaLinkVerdictCache(appModel.database),
              ),
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
