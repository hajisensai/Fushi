/// 「为整个合集配字幕」面板：把合集绑定到一个 AniList 系列 → 经**统一字幕来源**
/// （[VideoSubtitleRegistry]：Jimaku + OpenSubtitles + AJATT）一次列出全部候选 → 按来源
/// 分组供用户挑一个 → 逐集按集号选文件、下载、持久化。同时承载合集级字幕配置
/// （默认语言 / 偏好版本，落 `MediaCollections.subtitleLanguage / subtitleReleaseGroup`）。
///
/// 前身 `JimakuBatchDialog` 直连 `JimakuClient`——OpenSubtitles / AJATT 永远进不了批量。
/// 现在候选来自 registry，「哪一个文件是这一集的」仍只有一个判据
/// （`chooseSubtitleForEpisode`，BUG-1695）。面板不带外壳：对话框壳与全屏工作台各包一层。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_episode_matching.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi/src/pages/implementations/jimaku_api_key_field.dart';
import 'package:fushi/src/pages/implementations/jimaku_entry_picker.dart'
    show JimakuLanguagePicker;
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show
        describeSubtitleFailure,
        kSubtitleNoticeBannerKey,
        primarySubtitleFailure;
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// registry 候选按「来源条目」聚合后的一个可选来源（Jimaku entry / AJATT 作品目录 /
/// OpenSubtitles 整体）。[key] 是 `providerId:collectionId`，跨 provider 不撞。
class SubtitleCollectionSource {
  SubtitleCollectionSource({
    required this.key,
    required this.providerId,
    required this.label,
    required List<VideoSubtitleCandidate> candidates,
    String? preferredLanguage,
  }) : candidates = List<VideoSubtitleCandidate>.unmodifiable(candidates),
       index = SubtitleEpisodeIndex.fromCandidates(
         candidates,
         preferredLanguage: preferredLanguage,
       );

  final String key;
  final String providerId;
  final String label;
  final List<VideoSubtitleCandidate> candidates;

  /// 按集索引（只含文本字幕；构建时已按语言权重排序）。
  final SubtitleEpisodeIndex<VideoSubtitleCandidate> index;

  /// 认得出集号的集数。
  int get episodeCount => index.byEpisode.length;

  /// 来源里出现过的语言（去重，稳定顺序）。
  List<String> get languages => <String>{
    for (final VideoSubtitleCandidate c in candidates)
      if (c.language.isNotEmpty) c.language,
  }.toList();
}

/// 把 registry 一次搜索的候选按来源分组。纯函数，便于单测。
///
/// 分组键 = `providerId:collectionId`（Jimaku entry id / AJATT 作品页路径）；provider
/// 没有合集概念（OpenSubtitles）时整个 provider 算一个来源。顺序保持候选首次出现顺序
/// （registry 已按 provider 优先级排好）。
List<SubtitleCollectionSource> groupSubtitleCollectionSources(
  List<VideoSubtitleCandidate> candidates, {
  String? preferredLanguage,
}) {
  final Map<String, List<VideoSubtitleCandidate>> byKey =
      <String, List<VideoSubtitleCandidate>>{};
  final Map<String, String> labels = <String, String>{};
  for (final VideoSubtitleCandidate c in candidates) {
    final String key = '${c.providerId}:${c.collectionId ?? ''}';
    byKey.putIfAbsent(key, () => <VideoSubtitleCandidate>[]).add(c);
    labels.putIfAbsent(
      key,
      () => c.collectionLabel?.trim().isNotEmpty == true
          ? c.collectionLabel!.trim()
          : (c.releaseName?.trim().isNotEmpty == true
                ? c.releaseName!.trim()
                : c.providerId),
    );
  }
  return <SubtitleCollectionSource>[
    for (final MapEntry<String, List<VideoSubtitleCandidate>> e
        in byKey.entries)
      SubtitleCollectionSource(
        key: e.key,
        providerId: e.value.first.providerId,
        label: labels[e.key]!,
        candidates: e.value,
        preferredLanguage: preferredLanguage,
      ),
  ];
}

/// 批量下载能否开放：选中来源存在且确有可解析字幕、没在搜索/下载中。纯函数。
bool canRunSubtitleCollectionBatch({
  required SubtitleCollectionSource? selected,
  required bool searching,
  required bool running,
}) => selected != null && !searching && !running && !selected.index.isEmpty;

class SubtitleCollectionPanel extends StatefulWidget {
  const SubtitleCollectionPanel({
    required this.database,
    required this.collection,
    required this.members,
    required this.subtitleRegistry,
    required this.initialApiKey,
    required this.onApiKeyChanged,
    required this.saveDirectory,
    required this.onRemoteSubtitlePersist,
    this.initialPreferredLanguage,
    this.onPreferredLanguageChanged,
    this.globalDefaultContentLanguage,
    this.httpClientFactory,
    this.onCancel,
    this.showTitle = true,
    super.key,
  });

  final FushiDatabase database;
  final MediaCollectionRow collection;

  /// 合集里**有序**的视频成员（调用方已按 sortIndex 加载）。
  final List<VideoBookRow> members;

  /// 统一字幕来源的延迟解析器（填 key 会重建 runtime，不能早绑）。
  final VideoSubtitleRegistry? Function() subtitleRegistry;

  final String initialApiKey;
  final Future<void> Function(String key) onApiKeyChanged;

  /// 下载字幕保存目录（绝对路径）。
  final String saveDirectory;

  /// 远端/流媒体集的持久化（无本地 DB 行可写 → prefs）。
  final Future<void> Function(String bookUid, String path)
  onRemoteSubtitlePersist;

  /// 该系列的语言记忆（prefs，按番名 key）；合集列 `subtitleLanguage` 非空时优先于它。
  final String? initialPreferredLanguage;
  final Future<void> Function(String langCode)? onPreferredLanguageChanged;

  /// 设置·默认内容语言；合集/系列都没表态时经 [resolveSubtitleDownloadLanguage]
  /// 回退到视频自身语言链（BUG-1700：绝不硬编码 ja）。
  final String? globalDefaultContentLanguage;

  final Future<http.Client> Function()? httpClientFactory;
  final VoidCallback? onCancel;
  final bool showTitle;

  @override
  State<SubtitleCollectionPanel> createState() =>
      _SubtitleCollectionPanelState();
}

class _SubtitleCollectionPanelState extends State<SubtitleCollectionPanel> {
  late final VideoBookRepository _repo = VideoBookRepository(widget.database);
  late final TextEditingController _apiKeyCtrl = TextEditingController(
    text: widget.initialApiKey,
  );
  late final TextEditingController _queryCtrl = TextEditingController(
    text: _initialQuery(),
  );

  bool _resolving = false;
  bool _searching = false;
  bool _running = false;
  List<AniListMedia> _seriesMatches = const <AniListMedia>[];
  int? _selectedSeriesId;
  bool _seriesLookupFailed = false;
  int _generation = 0;

  List<SubtitleCollectionSource> _sources = const <SubtitleCollectionSource>[];
  String? _selectedSourceKey;

  /// 面板内的提示（搜索失败 / 批量结果）；全屏页里 SnackBar 会被盖住（BUG-1844）。
  String? _notice;
  bool _noticeIsError = false;

  /// 已刮削合集的规范身份（BUG-2008）：查询词优先日文原名、请求带已知外部
  /// id——不再拿合集显示名裸猜。null = 该合集还没刮出规范作品，走旧路径。
  VideoMetadataWorkRow? _canonicalWork;
  Map<String, String> _canonicalIds = const <String, String>{};

  int? get _canonicalAnilistId => int.tryParse(_canonicalIds['anilist'] ?? '');

  /// 用户显式选的字幕语言；null = 「全部」= 不限（回退视频自身语言链）。
  String? _language;

  /// 合集偏好的版本组键（`SubtitleVersionGroup.key`）；null = 不限版本。
  String? _releaseGroup;

  final Map<String, SubtitleBatchItem> _statusByUid =
      <String, SubtitleBatchItem>{};

  String _initialQuery() {
    final String series = parseVideoFilename(widget.collection.name).series;
    return series.isEmpty ? widget.collection.name : series;
  }

  @override
  void initState() {
    super.initState();
    // 语言优先级：合集列（用户在这里配过）→ 该系列 prefs 记忆 → 不限。
    _language =
        widget.collection.subtitleLanguage ?? widget.initialPreferredLanguage;
    _releaseGroup = widget.collection.subtitleReleaseGroup;
    _selectedSeriesId = widget.collection.anilistId;
    // 合集已绑定 AniList 系列 → 直接搜来源，免去用户再点一次。
    if (widget.collection.anilistId != null) {
      unawaited(_searchSources(anilistId: widget.collection.anilistId));
    }
    unawaited(_loadCanonicalIdentity());
  }

  /// 读回该合集刮削出的规范作品与身份（BUG-2008）。用户没改过查询词时把它换成
  /// 日文原名；合集没绑 AniList 而刮削身份里有 anilist id 时直接按 id 搜来源。
  Future<void> _loadCanonicalIdentity() async {
    final VideoMetadataWorkRow? work = await widget.database
        .getVideoMetadataWorkByCollection(widget.collection.id);
    if (work == null || !mounted) return;
    final List<VideoMetadataProviderIdentityRow> identities = await widget
        .database
        .getVideoMetadataProviderIdentities(workId: work.id);
    if (!mounted) return;
    final bool queryUntouched =
        _queryCtrl.text.trim() == _initialQuery().trim();
    setState(() {
      _canonicalWork = work;
      _canonicalIds = <String, String>{
        for (final VideoMetadataProviderIdentityRow row in identities)
          row.provider: row.externalId,
      };
      final String? original = work.originalTitle?.trim();
      if (queryUntouched && original != null && original.isNotEmpty) {
        _queryCtrl.text = original;
      }
    });
    if (widget.collection.anilistId == null &&
        _selectedSeriesId == null &&
        _canonicalAnilistId != null &&
        !_searching) {
      unawaited(_searchSources(anilistId: _canonicalAnilistId));
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  bool get _hasConfiguredSubtitleSource {
    final VideoSubtitleRegistry? registry = widget.subtitleRegistry();
    return registry != null && registry.providers.isNotEmpty;
  }

  SubtitleCollectionSource? get _selectedSource {
    for (final SubtitleCollectionSource s in _sources) {
      if (s.key == _selectedSourceKey) return s;
    }
    return null;
  }

  /// 批量真正采用的语言：显式选择 → 视频自身语言链（BUG-1700）。
  String? get _effectiveLanguage => resolveSubtitleDownloadLanguage(
    explicitSubtitlePreference: _language,
    videoContentLanguage: widget.members.isEmpty
        ? null
        : widget.members.first.language,
    globalDefaultContentLanguage: widget.globalDefaultContentLanguage,
  );

  /// 选中来源里的版本组（版本选择器同一聚类）。
  List<SubtitleVersionGroup> get _versionGroups {
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return const <SubtitleVersionGroup>[];
    return buildSubtitleVersionGroups(
      source.candidates,
      preferredLanguage: _effectiveLanguage,
    );
  }

  /// 批量下载用的候选：偏好版本组命中时只用该组，否则整个来源。
  List<VideoSubtitleCandidate> get _batchCandidates {
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return const <VideoSubtitleCandidate>[];
    final String? key = _releaseGroup;
    if (key != null) {
      for (final SubtitleVersionGroup g in _versionGroups) {
        if (g.key == key) return g.members;
      }
    }
    return source.candidates;
  }

  void _setNotice(String? message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeIsError = error;
    });
  }

  Future<http.Client> _createHttpClient() {
    final Future<http.Client> Function()? factory = widget.httpClientFactory;
    return factory == null
        ? Future<http.Client>.value(createAppHttpIoClient())
        : factory();
  }

  /// 解析 AniList 系列候选：命中后默认选首条并搜其来源；无命中回退文本搜。
  Future<void> _resolveSeries() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    final String query = _queryCtrl.text.trim();
    if (apiKey.isEmpty && !_hasConfiguredSubtitleSource) {
      _setNotice(t.video_jimaku_no_key, error: true);
      return;
    }
    if (query.isEmpty) return;
    if (apiKey != widget.initialApiKey.trim()) {
      await widget.onApiKeyChanged(apiKey);
    }
    final int generation = ++_generation;
    setState(() {
      _resolving = true;
      _seriesMatches = const <AniListMedia>[];
      _seriesLookupFailed = false;
      _notice = null;
    });
    AniListClient? anilist;
    try {
      anilist = AniListClient(client: await _createHttpClient());
      final AniListSearchOutcome outcome = await anilist.searchAnime(query);
      if (!mounted || generation != _generation) return;
      if (outcome.degraded) {
        ErrorLogService.instance.logDiagnostic(
          'SubtitleCollectionPanel.searchAnime',
          'AniList 搜索降级（${outcome.failure}）：「$query」退化为纯文本来源搜索，'
              '结果可能横跨同系列多季',
        );
      }
      setState(() {
        _seriesMatches = outcome.media;
        _seriesLookupFailed = outcome.degraded;
      });
      if (outcome.media.isNotEmpty) {
        await _selectSeries(outcome.media.first, generation: generation);
      } else {
        setState(() => _selectedSeriesId = null);
        await _searchSources(anilistId: null, generation: generation);
      }
    } finally {
      anilist?.close();
      if (mounted && generation == _generation) {
        setState(() => _resolving = false);
      }
    }
  }

  /// 用户点某系列：绑定该系列、快照 anilist_id 到合集、按它搜来源。
  Future<void> _selectSeries(AniListMedia media, {int? generation}) async {
    final int requestGeneration = generation ?? ++_generation;
    setState(() => _selectedSeriesId = media.id);
    if (widget.collection.anilistId != media.id) {
      await widget.database.setMediaCollectionAnilistId(
        widget.collection.id,
        media.id,
      );
      if (!mounted || requestGeneration != _generation) {
        // 旧选择的慢 DB 写可能晚于新选择落库；以当前 UI 选择重申一次，避免数据库
        // 最终回退到旧 AniList id。
        final int? latest = _selectedSeriesId;
        if (latest != null) {
          await widget.database.setMediaCollectionAnilistId(
            widget.collection.id,
            latest,
          );
        }
        return;
      }
    }
    await _searchSources(anilistId: media.id, generation: requestGeneration);
  }

  /// 经 registry 一次列出全部候选（不带 episode：要看到「字幕侧到底有哪些集号」才能
  /// 判集号冲突，BUG-1695），按来源分组。
  Future<void> _searchSources({
    required int? anilistId,
    int? generation,
  }) async {
    final int requestGeneration = generation ?? ++_generation;
    final VideoSubtitleRegistry? registry = widget.subtitleRegistry();
    final String query = _queryCtrl.text.trim();
    if (registry == null || registry.providers.isEmpty) {
      setState(() {
        _sources = const <SubtitleCollectionSource>[];
        _selectedSourceKey = null;
      });
      _setNotice(t.video_jimaku_no_key, error: true);
      return;
    }
    setState(() {
      _searching = true;
      _notice = null;
    });
    try {
      // 规范身份优先（BUG-2008）：形态取刮削结论、原名/tmdb id 一起带上——
      // Jimaku 的 id 检索与文本兜底都不再只靠合集显示名裸猜。
      final int? effectiveAnilistId = anilistId ?? _canonicalAnilistId;
      final ProviderBatchResult<VideoSubtitleCandidate> result = await registry
          .search(
            VideoSubtitleSearchRequest(
              media: VideoMediaReference(
                providerId: 'anilist',
                mediaId: effectiveAnilistId?.toString() ?? query,
                mediaKind: _canonicalWork?.mediaType == 'movie'
                    ? VideoMetadataMediaKind.movie
                    : VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.anime,
                title: query,
                originalTitle: _canonicalWork?.originalTitle,
                anilistId: effectiveAnilistId,
                tmdbId: int.tryParse(_canonicalIds['tmdb'] ?? ''),
              ),
              query: query,
            ),
          );
      if (!mounted || requestGeneration != _generation) return;
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(
            result.items,
            preferredLanguage: _effectiveLanguage,
          );
      final ExternalProviderFailure? failure = sources.isEmpty
          ? primarySubtitleFailure(result.failures)
          : null;
      setState(() {
        _sources = sources;
        _selectedSourceKey =
            sources.any(
              (SubtitleCollectionSource s) => s.key == _selectedSourceKey,
            )
            ? _selectedSourceKey
            : (sources.isEmpty ? null : sources.first.key);
        _statusByUid.clear();
      });
      if (failure != null) {
        _setNotice(
          describeSubtitleFailure(t.video_jimaku_search_failed, failure),
          error: true,
        );
      }
    } on Object catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      _setNotice(
        describeSubtitleFailure(t.video_jimaku_search_failed, error),
        error: true,
      );
    } finally {
      if (mounted && requestGeneration == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  /// 选语言：更新筛选 + 写合集列（本合集的决定）+ 系列 prefs 记忆（老路径兼容）。
  Future<void> _selectLanguage(String? lang) async {
    setState(() => _language = lang);
    await widget.database.updateMediaCollectionSubtitleLanguage(
      widget.collection.id,
      lang,
    );
    if (lang != null) {
      await widget.onPreferredLanguageChanged?.call(lang);
    }
  }

  Future<void> _selectReleaseGroup(String? key) async {
    setState(() => _releaseGroup = key);
    await widget.database.updateMediaCollectionSubtitleReleaseGroup(
      widget.collection.id,
      key,
    );
  }

  List<SubtitleBatchTarget> _targets() => <SubtitleBatchTarget>[
    for (int i = 0; i < widget.members.length; i++) _targetAt(i),
  ];

  SubtitleBatchTarget _targetAt(int index) {
    final VideoBookRow member = widget.members[index];
    return SubtitleBatchTarget(
      bookUid: member.bookUid,
      title: member.title,
      videoPath: member.videoPath,
      sortIndex: index,
      isStream: isStreamVideoBook(member),
    );
  }

  Future<void> _downloadAll() async {
    final VideoSubtitleRegistry? registry = widget.subtitleRegistry();
    if (registry == null) return;
    final List<VideoSubtitleCandidate> candidates = _batchCandidates;
    if (candidates.isEmpty) return;
    setState(() {
      _running = true;
      _notice = null;
      _statusByUid.clear();
    });
    try {
      await runSubtitleBatch(
        registry: registry,
        candidates: candidates,
        targets: _targets(),
        saveDirectory: widget.saveDirectory,
        preferredLanguage: _effectiveLanguage,
        onItemStart: (SubtitleBatchItem item) async {
          if (!mounted) return;
          setState(() => _statusByUid[item.target.bookUid] = item);
        },
        onItemDone: (SubtitleBatchItem item) async {
          await _persist(item);
          if (!mounted) return;
          setState(() => _statusByUid[item.target.bookUid] = item);
        },
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;
    final int done = _statusByUid.values
        .where((SubtitleBatchItem i) => i.status == SubtitleBatchStatus.done)
        .length;
    _setNotice(
      t.video_jimaku_batch_done(done: done, total: widget.members.length),
    );
  }

  /// 单集持久化：本地视频写 DB（subtitleSource 列 + 解析的 cue），远端/流媒体写 prefs。
  Future<void> _persist(SubtitleBatchItem item) async {
    if (item.status != SubtitleBatchStatus.done || item.subtitlePath == null) {
      return;
    }
    final SubtitleBatchTarget target = item.target;
    final String path = item.subtitlePath!;
    if (target.isStream) {
      await widget.onRemoteSubtitlePersist(target.bookUid, path);
      return;
    }
    final List<AudioCue> cues = await loadCuesForSource(
      SubtitleSource.external(externalPath: path, label: p.basename(path)),
      target.videoPath,
      target.bookUid,
    );
    await _repo.saveSubtitleSelection(
      bookUid: target.bookUid,
      subtitleSource: path,
      cues: cues,
    );
  }

  // ---------------------------------------------------------------- UI

  Widget _statusIcon(String bookUid, int memberIndex) {
    final SubtitleBatchItem? item = _statusByUid[bookUid];
    if (item != null) {
      switch (item.status) {
        case SubtitleBatchStatus.downloading:
          return const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        case SubtitleBatchStatus.done:
          return const Icon(Icons.check_circle, size: 18, color: Colors.green);
        case SubtitleBatchStatus.noMatch:
          return const Icon(Icons.search_off, size: 18);
        case SubtitleBatchStatus.failed:
          return const Icon(Icons.error_outline, size: 18, color: Colors.red);
        case SubtitleBatchStatus.pending:
          return const Icon(Icons.schedule, size: 18);
      }
    }
    if (_searching) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return const Icon(Icons.remove, size: 18);
    final int episode = resolveSubtitleBatchEpisode(_targetAt(memberIndex));
    return (source.index.byEpisode[episode]?.isEmpty ?? true)
        ? const Icon(Icons.search_off, size: 18)
        : const Icon(Icons.check_circle_outline, size: 18, color: Colors.green);
  }

  Widget? _episodeSubtitle(VideoBookRow member, int memberIndex) {
    final SubtitleBatchItem? item = _statusByUid[member.bookUid];
    if (item != null) {
      switch (item.status) {
        case SubtitleBatchStatus.done:
          return Text(
            item.language == null
                ? t.video_jimaku_downloaded
                : '${t.video_jimaku_downloaded} · '
                      '${jimakuLanguageLabel(item.language!)}',
          );
        case SubtitleBatchStatus.noMatch:
          return Text(t.video_jimaku_no_results);
        case SubtitleBatchStatus.failed:
          return Text(t.video_jimaku_download_failed);
        case SubtitleBatchStatus.downloading:
        case SubtitleBatchStatus.pending:
          return Text(t.video_jimaku_source_loading);
      }
    }
    if (_searching) return Text(t.video_jimaku_source_loading);
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return Text(t.video_subtitle_collection_members_hint);
    final int episode = resolveSubtitleBatchEpisode(_targetAt(memberIndex));
    final List<VideoSubtitleCandidate> matches =
        source.index.byEpisode[episode] ?? const <VideoSubtitleCandidate>[];
    if (matches.isEmpty) {
      if (source.index.unnumbered.isNotEmpty) {
        return Text(
          t.video_jimaku_episode_unlabeled(
            episode: episode,
            count: source.index.unnumbered.length,
          ),
        );
      }
      return Text(t.video_jimaku_episode_unavailable(episode: episode));
    }
    final Set<String> languages = <String>{
      for (final VideoSubtitleCandidate c in matches)
        if (c.language.isNotEmpty) c.language,
    };
    return Text(
      t.video_jimaku_episode_available(
        count: matches.length,
        languages: languages.isEmpty
            ? t.video_jimaku_language_unknown
            : languages.map(jimakuLanguageLabel).join(' / '),
      ),
    );
  }

  Widget _chipSection(String label, List<Widget> chips) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }

  /// 来源选择：每个来源一行（provider + 条目名 + 文件数/集数/语言），单选。
  Widget _buildSourcePicker(ThemeData theme) {
    if (_sources.isEmpty) return const SizedBox.shrink();
    return _chipSection(t.video_subtitle_source_label, <Widget>[
      for (final SubtitleCollectionSource source in _sources)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: ChoiceChip(
            key: ValueKey<String>('subtitle-source-${source.key}'),
            label: Text(
              '${source.label} · ${source.providerId} · '
              '${t.video_jimaku_source_summary(files: source.index.totalFiles, episodes: source.episodeCount, languages: source.languages.isEmpty ? t.video_jimaku_language_unknown : source.languages.map(jimakuLanguageLabel).join('/'))}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            selected: _selectedSourceKey == source.key,
            onSelected: _running
                ? null
                : (_) => setState(() => _selectedSourceKey = source.key),
          ),
        ),
    ]);
  }

  /// 合集级配置：默认语言（写列 + prefs）与偏好版本组（写列）。
  Widget _buildCollectionSettings(ThemeData theme) {
    final List<SubtitleVersionGroup> groups = _versionGroups;
    final bool releaseGroupPresent = groups.any(
      (SubtitleVersionGroup g) => g.key == _releaseGroup,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text(
            t.video_subtitle_collection_settings,
            style: theme.textTheme.titleSmall,
          ),
        ),
        _chipSection(t.video_subtitle_collection_language, <Widget>[
          JimakuLanguagePicker(
            selectedLanguage: _language,
            enabled: !_running,
            onSelected: (String? lang) => unawaited(_selectLanguage(lang)),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            t.video_subtitle_collection_language_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (groups.isNotEmpty)
          DropdownButtonFormField<String>(
            key: const ValueKey<String>('subtitle-collection-release-group'),
            // 缺 isExpanded 时按内容固有宽度排版，长标签在紧凑布局横向溢出。
            isExpanded: true,
            initialValue: releaseGroupPresent ? _releaseGroup : null,
            decoration: InputDecoration(
              labelText: t.video_subtitle_collection_release_group,
              helperText: t.video_subtitle_collection_release_group_hint,
              helperMaxLines: 3,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: null,
                child: Text(t.video_subtitle_collection_release_group_any),
              ),
              for (final SubtitleVersionGroup g in groups)
                DropdownMenuItem<String>(
                  value: g.key,
                  child: Text(
                    '${g.collectionLabel} · ${g.container.toUpperCase()}'
                    '${g.language.isEmpty ? '' : ' · ${jimakuLanguageLabel(g.language)}'}'
                    ' · ${g.members.length}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _running
                ? null
                : (String? key) => unawaited(_selectReleaseGroup(key)),
          ),
      ],
    );
  }

  Widget? _buildNotice(ThemeData theme) {
    final String? notice = _notice;
    if (notice == null && !_seriesLookupFailed) return null;
    final bool error = notice != null && _noticeIsError;
    final Color bg = error
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final Color fg = error
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: kSubtitleNoticeBannerKey,
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                error ? Icons.error_outline : Icons.info_outline,
                size: 18,
                color: fg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  notice ?? t.video_jimaku_series_lookup_degraded,
                  style: theme.textTheme.bodySmall?.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canDownload =
        canRunSubtitleCollectionBatch(
          selected: _selectedSource,
          searching: _searching,
          running: _running,
        ) &&
        _batchCandidates.isNotEmpty;
    final Widget? notice = _buildNotice(theme);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showTitle) ...<Widget>[
          Text(t.video_jimaku_batch_title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
        ],
        if (notice != null) notice,
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                JimakuApiKeyField(controller: _apiKeyCtrl, dense: true),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        decoration: InputDecoration(
                          labelText: t.video_jimaku_query,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _resolveSeries(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      key: const ValueKey<String>('subtitle-collection-find'),
                      onPressed: _resolving || _searching || _running
                          ? null
                          : _resolveSeries,
                      icon: const Icon(Icons.search, size: 18),
                      label: Text(t.video_jimaku_find_sources),
                    ),
                  ],
                ),
                if (_seriesMatches.length >= 2)
                  _chipSection(t.video_jimaku_anime_match, <Widget>[
                    for (final AniListMedia media in _seriesMatches)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: ChoiceChip(
                          label: Text(
                            media.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          tooltip: media.displayTitle,
                          selected: _selectedSeriesId == media.id,
                          onSelected: _resolving || _running
                              ? null
                              : (_) => unawaited(_selectSeries(media)),
                        ),
                      ),
                  ]),
                _buildSourcePicker(theme),
                _buildCollectionSettings(theme),
              ],
            ),
          ),
        ),
        const Divider(height: 20),
        Flexible(
          child: ListView.builder(
            itemCount: widget.members.length,
            itemBuilder: (BuildContext context, int i) {
              final VideoBookRow m = widget.members[i];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: _statusIcon(m.bookUid, i),
                title: Text(
                  m.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _episodeSubtitle(m, i),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 8,
          overflowSpacing: 4,
          children: <Widget>[
            if (widget.onCancel != null)
              TextButton(
                onPressed: _running ? null : widget.onCancel,
                child: Text(t.dialog_close),
              ),
            FilledButton.icon(
              key: const ValueKey<String>('subtitle-collection-download-all'),
              onPressed: canDownload ? _downloadAll : null,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(t.video_jimaku_batch_download),
            ),
          ],
        ),
      ],
    );
  }
}
