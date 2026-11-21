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

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/anilist_failure_notice.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel, jimakuLanguageRank;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi_engine/media/video/subtitle/scraped_subtitle_targets.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_episode_matching.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_series_season.dart';
import 'package:fushi/src/media/video/episode_span_format.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_language_probe.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi/src/pages/implementations/jimaku_api_key_field.dart';
import 'package:fushi/src/pages/implementations/jimaku_entry_picker.dart'
    show JimakuLanguagePicker;
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show
        describeSubtitleFailure,
        logSubtitleDownloadFailure,
        kSubtitleNoticeBannerKey,
        primarySubtitleFailure;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
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

  /// 能解开的整季压缩包格式（来源里第一个 zip 包）；没有为 null。批量下载时这些
  /// 包按集号拆分（[runSubtitleBatch]），所以没有单集文件的集照样能配上。
  SubtitleArchiveFormat? get unpackablePackFormat {
    for (final VideoSubtitleCandidate c in candidates) {
      final SubtitleArchiveFormat? f = c.archiveFormat;
      if (f != null && f.isSupported) return f;
    }
    return null;
  }

  /// 只有解不开的整季包（RAR / 7z）时的格式；有可解的包或没有包为 null。
  SubtitleArchiveFormat? get unsupportedPackFormat {
    if (unpackablePackFormat != null) return null;
    for (final VideoSubtitleCandidate c in candidates) {
      final SubtitleArchiveFormat? f = c.archiveFormat;
      if (f != null) return f;
    }
    return null;
  }

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

/// 聚合列表里的一行版本：版本卡 + 实际参与排名的语言 + 对本合集的覆盖。
class SubtitleCollectionVersion {
  const SubtitleCollectionVersion({
    required this.group,
    required this.language,
    required this.contentLanguage,
    required this.coveredEpisodes,
  });

  final SubtitleVersionGroup group;

  /// 参与排名的粗语言码：文件名声明的，否则正文判出的；都没有为 null。
  final String? language;

  /// 正文判出的细分语言（文件名没写语言时才有）；用于展示「正文：中日双语」。
  final SubtitleContentLanguage? contentLanguage;

  /// 本合集成员里这个版本能配上的集号。
  final Set<int> coveredEpisodes;
}

/// 一个来源的版本列表，按**批量下载的同一判据**排好（[SubtitleEpisodeIndex.rankVersions]：
/// 语言 → 覆盖本合集集数 → ASS 先于 SRT）：首行就是「自动」会用的版本。纯函数。
///
/// 没进排名的版本（只有未编号文件 / 整季包）按版本卡原顺序接在后面。
List<SubtitleCollectionVersion> rankSubtitleCollectionVersions(
  SubtitleCollectionSource source, {
  required Iterable<int> targetEpisodes,
  String? preferredLanguage,
  Map<String, SubtitleContentLanguage?> probedLanguages =
      const <String, SubtitleContentLanguage?>{},
}) {
  final Set<int> targets = targetEpisodes.toSet();
  String? languageOf(VideoSubtitleCandidate c) {
    if (c.language.isNotEmpty) return c.language;
    final SubtitleContentLanguage? probed =
        probedLanguages[subtitleVersionKeyOf(c)];
    return probed == null ? null : coarseLanguageCode(probed);
  }

  final List<SubtitleVersionGroup> groups = buildSubtitleVersionGroups(
    source.candidates,
    preferredLanguage: preferredLanguage,
  );
  final List<String> ranked = source.index.rankVersions(
    targetEpisodes: targets,
    versionOf: subtitleVersionKeyOf,
    languageRankOf: (VideoSubtitleCandidate c) =>
        jimakuLanguageRank(languageOf(c), preferred: preferredLanguage),
    fileNameOf: (VideoSubtitleCandidate c) => c.fileName,
  );
  final Map<String, int> order = <String, int>{
    for (int i = 0; i < ranked.length; i++) ranked[i]: i,
  };
  final List<SubtitleVersionGroup> sorted =
      <SubtitleVersionGroup>[
        ...groups.where((SubtitleVersionGroup g) => order.containsKey(g.key)),
      ]..sort(
        (SubtitleVersionGroup a, SubtitleVersionGroup b) =>
            order[a.key]!.compareTo(order[b.key]!),
      );
  return <SubtitleCollectionVersion>[
    for (final SubtitleVersionGroup g in <SubtitleVersionGroup>[
      ...sorted,
      ...groups.where((SubtitleVersionGroup g) => !order.containsKey(g.key)),
    ])
      SubtitleCollectionVersion(
        group: g,
        language: languageOf(g.members.first),
        contentLanguage: g.language.isEmpty ? probedLanguages[g.key] : null,
        coveredEpisodes: g.episodes.intersection(targets),
      ),
  ];
}

/// 合集列 `subtitleReleaseGroup` 里存的版本键 → 当前要选中的（来源键, 版本键）。纯函数。
///
/// 列值能直接命中某来源的版本键就原样用（[migrated] = false）。命中不了时按 BUG-3998
/// 之前的键组成（[legacySubtitleVersionKeyOf]：名字段只认发布组、没组名的平台抽轨
/// 末段为空）再找一遍——用户在旧下拉里点名的 `….WEBRip.Netflix.ja[cc].srt` 一类版本
/// 就这样落回它现在的版本（[migrated] = true，调用方把列改写成新键，只改一次）。
/// 旧键现在拆成了多个版本（同时有 Netflix 与 Amazon 的无组名抽轨）时取 [rankedOf]
/// 排名最靠前的那个——与「自动」同一判据。都对不上返回 null。
({String sourceKey, String versionKey, bool migrated})?
resolvePinnedSubtitleVersion(
  List<SubtitleCollectionSource> sources,
  String storedKey, {
  required List<SubtitleCollectionVersion> Function(
    SubtitleCollectionSource source,
  )
  rankedOf,
}) {
  for (final SubtitleCollectionSource source in sources) {
    for (final SubtitleCollectionVersion v in rankedOf(source)) {
      if (v.group.key == storedKey) {
        return (sourceKey: source.key, versionKey: storedKey, migrated: false);
      }
    }
  }
  for (final SubtitleCollectionSource source in sources) {
    for (final SubtitleCollectionVersion v in rankedOf(source)) {
      if (v.group.members.any(
        (VideoSubtitleCandidate c) =>
            legacySubtitleVersionKeyOf(c) == storedKey,
      )) {
        return (sourceKey: source.key, versionKey: v.group.key, migrated: true);
      }
    }
  }
  return null;
}

/// 批量下载能否开放：选中来源存在且确有可下的字幕、没在搜索/下载中。纯函数。
///
/// 「可下的字幕」= 单集文件（[SubtitleCollectionSource.index]）**或**能解开的整季包
/// （[SubtitleCollectionSource.unpackablePackFormat]）。整季包不进 index（它不是某一
/// 集的文件），但批量会按集号从包里拆（`runSubtitleBatch`），成员行也据此预览「将从
/// 整季包中拆出」；只看 index 的话只有整季包的来源按钮是灰的，与成员行自相矛盾。
bool canRunSubtitleCollectionBatch({
  required SubtitleCollectionSource? selected,
  required bool searching,
  required bool running,
}) =>
    selected != null &&
    !searching &&
    !running &&
    (!selected.index.isEmpty || selected.unpackablePackFormat != null);

/// 合集成员的分季键（与合集详情页季 tab 同一规则）。
///
/// [sectionKeys] 是入口预先解析好的生效分栏（`book_uid → 键`，手动分栏 / 手动
/// 季集指定优先，见 `loadCollectionSections`，拍板台 iR6ccUys9H），有就用它。
/// 没有时按文件名派生（[collectionGroupKeyForFilename]）：先看完整路径（季号可能
/// 只写在父目录 `Show/Season 2/01.mkv`）；路径解不出集号（流媒体成员的
/// `anime-source://…` 描述等）再退到标题（远端标题常带 `S04E18`）。
String subtitleCollectionSeasonKeyOf(
  VideoBookRow member, {
  Map<String, String> sectionKeys = const <String, String>{},
}) {
  if (sectionKeys[member.bookUid] case final String resolved) return resolved;
  return subtitleCollectionDerivedSeasonKeyOf(member);
}

/// [subtitleCollectionSeasonKeyOf] 不看任何手动指定时的文件名派生键（入口把它喂给
/// `loadCollectionSections` 当派生键）。
String subtitleCollectionDerivedSeasonKeyOf(VideoBookRow member) {
  final String fromPath = collectionGroupKeyForFilename(member.videoPath);
  if (fromPath != kCollectionExtrasGroupKey) return fromPath;
  return collectionGroupKeyForFilename(member.title);
}

/// 「为合集获取字幕」的分季：把有序成员按季聚成分节（季号升序、PV·特典殿后）。纯函数。
///
/// 多季合集**必须**逐季配字幕：字幕来源（AniList / Jimaku / AJATT 条目）一季一条，
/// 而批量只按集号匹配——整张合集一起配时，第一季条目的第 1 集会同时被当成
/// S02E01、S03E01 的字幕（集号都是 1），静默装到每一季上。返回不足 2 节 = 单季合集。
List<CollectionSeasonSection<VideoBookRow>> subtitleCollectionSeasonSections(
  List<VideoBookRow> members, {
  Map<String, String> sectionKeys = const <String, String>{},
}) => sortCollectionSeasonSections<VideoBookRow>(
  buildCollectionSeasonSections<VideoBookRow>(
    members: members,
    keyOf: (VideoBookRow member) =>
        subtitleCollectionSeasonKeyOf(member, sectionKeys: sectionKeys),
  ),
);

/// 多季合集打开面板时先选哪一季：[preferredSeason] 对应的季存在就用它（入口带来的
/// 「当前季」：详情页选中的 tab / 播放页正在播的这一集），否则第一个真实季（没有
/// 真实季才落到 PV·特典）。单季合集返回 null。纯函数。
String? initialSubtitleCollectionSeasonKey(
  List<CollectionSeasonSection<VideoBookRow>> sections, {
  int? preferredSeason,
}) {
  if (sections.length < 2) return null;
  if (preferredSeason != null) {
    final String wanted = collectionSeasonGroupKey(
      season: preferredSeason,
      episode: 1,
    );
    if (sections.any(
      (CollectionSeasonSection<VideoBookRow> s) => s.groupKey == wanted,
    )) {
      return wanted;
    }
  }
  for (final CollectionSeasonSection<VideoBookRow> s in sections) {
    if (seasonNumberOfGroupKey(s.groupKey) != null) return s.groupKey;
  }
  return sections.first.groupKey;
}

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
    this.onSubtitlePersisted,
    this.initialPreferredLanguage,
    this.onPreferredLanguageChanged,
    this.globalDefaultContentLanguage,
    this.httpClientFactory,
    this.onCancel,
    this.showTitle = true,
    this.subtitleAligner,
    this.initialSeason,
    this.sectionKeys = const <String, String>{},
    super.key,
  });

  /// 多季合集打开时先选的季号（入口的「当前季」）；null / 合集里没有这一季 = 第一季。
  /// 单季合集忽略。
  final int? initialSeason;

  /// 成员的生效分栏（`book_uid → 键`，手动分栏 / 手动季集指定优先）；缺的成员按
  /// 文件名派生。见 [subtitleCollectionSeasonKeyOf]。
  final Map<String, String> sectionKeys;

  /// 每集落盘前按该集视频的内嵌字幕轨对时间轴；null = 不对齐。
  final AutomaticSubtitleAligner? subtitleAligner;

  final FushiDatabase database;
  final MediaCollectionRow collection;

  /// 合集里**有序**的视频成员（调用方已按 sortIndex 加载）。
  final List<VideoBookRow> members;

  /// 统一字幕来源的延迟解析器（填 key 会重建 runtime，不能早绑）。
  final Future<VideoSubtitleRegistry?> Function() subtitleRegistry;

  final String initialApiKey;
  final Future<void> Function(String key) onApiKeyChanged;

  /// 下载字幕保存目录（绝对路径）。
  final String saveDirectory;

  /// 远端/流媒体集的持久化（无本地 DB 行可写 → prefs）。
  final Future<void> Function(String bookUid, String path)
  onRemoteSubtitlePersist;

  /// 某集字幕已落盘并持久化（本地写 DB / 远端写 prefs）之后回调 `(bookUid, 路径)`。
  ///
  /// 持久化只改存储，不会通知正在播这一集的播放页：播放页的字幕列表与当前 cue
  /// 都是打开视频时读进内存的。从播放页打开工作台时由它订阅，关闭后把落到当前集的
  /// 那条当场登记并应用（BUG-4496）；媒体库 / 合集页入口没有在播的视频，不传。
  final void Function(String bookUid, String path)? onSubtitlePersisted;

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

  /// 用户点了「停止」：批量不再开始下一集，正在跑的那一集做完落盘。只有这个按钮
  /// 能停批量——面板 / 工作台关掉不取消（BUG-4496）。
  bool _stopRequested = false;
  List<AniListMedia> _seriesMatches = const <AniListMedia>[];
  String? _seriesMatchesQuery;
  int? _selectedSeriesId;
  bool _seriesLookupFailed = false;

  /// 降级原因类别，见 [jimakuSeriesLookupNotice]。
  AniListFailureKind? _seriesLookupKind;
  int _generation = 0;

  List<SubtitleCollectionSource> _sources = const <SubtitleCollectionSource>[];
  String? _selectedSourceKey;

  /// 是否已经真正跑过一次来源检索。空来源列表有两种含义——「还没搜过」和「搜过
  /// 但一条都没有」——只看 `_sources.isEmpty` 分不开，空态提示会给错话。
  bool _searched = false;

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

  /// 单季合集已落库的绑定快照（widget.collection 本身不可变，本页改完切去 PV·特典再切回时保留）。
  int? _collectionAnilistId;
  String? _collectionReleaseGroup;

  /// 文件名没写语言的版本按正文判出的语言（版本键 → 检测值），搜索后后台补。
  /// **探过但判不出的版本值为 null**：「判不出」也是结论，批量不再重探。
  Map<String, SubtitleContentLanguage?> _probedLanguages =
      const <String, SubtitleContentLanguage?>{};
  int _probeGeneration = 0;

  /// 候选下载缓存（identityKey → 下载）：**面板探测与批量下载共用这一份**。探测下过
  /// 的代表文件被批量选中时不再从网络重下；探测还没跑完就点「下载全部」也只下一份。
  /// 失败的下载会被移出，下一次照常重试。
  final Map<String, Future<VideoSubtitleDownload>> _downloads =
      <String, Future<VideoSubtitleDownload>>{};

  /// 版本列表已展开「显示全部」的来源键。
  final Set<String> _expandedSources = <String>{};

  // ── 派生状态（[_rederive] 在输入变化处显式重算，build 只读）──────────────
  // 输入：成员（集号 / 内容语言）、来源、探测结果、语言、选中来源、点名版本。

  /// 本合集成员的集号（与批量下载同一解析）。
  List<int> _targetEpisodes = const <int>[];

  /// 去重后的目标集数。
  int _targetEpisodeCount = 0;

  /// 各来源的版本列表（已按批量判据排好，首行 = 「自动」会用的版本）。
  Map<String, List<SubtitleCollectionVersion>> _versionsBySource =
      const <String, List<SubtitleCollectionVersion>>{};

  /// 选中来源里用户点名的版本；「自动」或该版本已不在来源里为 null。
  SubtitleCollectionVersion? _pinnedVersion;

  /// 各集实际会用的候选：与 [runSubtitleBatch] 同一判据（整季版本一致）。
  SubtitleEpisodeIndex<VideoSubtitleCandidate>? _plan;

  final Map<String, SubtitleBatchItem> _statusByUid =
      <String, SubtitleBatchItem>{};

  /// 成员的分季（[subtitleCollectionSeasonSections]）；不足 2 节 = 单季合集。
  List<CollectionSeasonSection<VideoBookRow>> _seasonSections =
      const <CollectionSeasonSection<VideoBookRow>>[];

  /// 多季合集当前在配的季（分节组键）；单季合集为 null。
  String? _seasonKey;

  /// 合集是否被拆成多节（多季，或单季 + PV·特典）：此时界面提供切季、列表与批量
  /// 只作用于 [_seasonKey] 这一节。
  bool get _hasSeasonSections => _seasonSections.length >= 2;

  /// 合集是否含 2 个及以上的**真实季**（如 S01 + S02）。
  bool get _hasMultipleSeasons =>
      _seasonSections
          .where(
            (CollectionSeasonSection<VideoBookRow> s) =>
                seasonNumberOfGroupKey(s.groupKey) != null,
          )
          .length >=
      2;

  /// 合集级单一绑定（`anilistId` / `subtitleReleaseGroup`）是否适用于当前作用域：
  /// 只有单季合集且不在 PV·特典节时才读/写它。多季合集（或 PV·特典）一季一条，
  /// 不拿合集级单值直搜，也不把单季的选择覆写到整张合集上。
  bool get _isCollectionBindingApplicable =>
      !_hasMultipleSeasons &&
      (_seasonKey == null || seasonNumberOfGroupKey(_seasonKey!) != null);

  /// 当前在配的季号；单季合集或选中的是 PV·特典为 null。
  int? get _selectedSeasonNumber =>
      _seasonKey == null ? null : seasonNumberOfGroupKey(_seasonKey!);

  /// 分节给出的季号能不能当成**显式**季号用（发给来源、过滤候选、钉批量目标）。
  ///
  /// 只有合集真有 ≥2 个真实季时才算：分季规则把没写季号的集一律归到 `s1`，
  /// 「单季 + PV·特典」也会拆成两节，那个 `s1` 是推断出来的——把它当显式季号，
  /// 合集名里的「4th season」就不再起作用，`season_number=1` 会发给
  /// OpenSubtitles / SubDL，文件名带 `S04` 的正确候选还会被当成别季滤掉。
  /// 单季时返回 null，季号回到成员文件名里的显式季号（[_memberSeason] /
  /// [resolveSubtitleBatchSeason]）。
  int? get _sectionSeasonOverride =>
      _hasMultipleSeasons ? _selectedSeasonNumber : null;

  /// 本面板实际作用的成员：分季时只取选中那一季，否则整张合集。
  ///
  /// **所有**按成员算的东西（目标集号、版本覆盖、行状态、批量目标）都读它而不是
  /// `widget.members`：一季的字幕来源只对这一季的集号有意义。
  List<VideoBookRow> get _members {
    final String? key = _seasonKey;
    if (key == null) return widget.members;
    for (final CollectionSeasonSection<VideoBookRow> s in _seasonSections) {
      if (s.groupKey == key) return s.items;
    }
    return widget.members;
  }

  /// 成员变化时重算分季；已选的季仍在就保留，否则回到初始季。
  void _rebuildSeasonSections() {
    _seasonSections = subtitleCollectionSeasonSections(
      widget.members,
      sectionKeys: widget.sectionKeys,
    );
    if (!_hasSeasonSections) {
      _seasonKey = null;
      return;
    }
    final String? current = _seasonKey;
    if (current != null &&
        _seasonSections.any(
          (CollectionSeasonSection<VideoBookRow> s) => s.groupKey == current,
        )) {
      return;
    }
    _seasonKey = initialSubtitleCollectionSeasonKey(
      _seasonSections,
      preferredSeason: widget.initialSeason,
    );
  }

  String _initialQuery() {
    final String series = parseVideoFilename(widget.collection.name).series;
    return series.isEmpty ? widget.collection.name : series;
  }

  @override
  void initState() {
    super.initState();
    _rebuildSeasonSections();
    // 语言优先级：合集列（用户在这里配过）→ 该系列 prefs 记忆 → 不限。
    _language =
        widget.collection.subtitleLanguage ?? widget.initialPreferredLanguage;
    _collectionAnilistId = widget.collection.anilistId;
    _collectionReleaseGroup = widget.collection.subtitleReleaseGroup;
    _releaseGroup = _isCollectionBindingApplicable
        ? _collectionReleaseGroup
        : null;
    // 多季合集上绑的 anilistId 只可能是其中一季的条目（AniList 一季一条），不能
    // 当成每一季的身份：多季时按选中季现解析。
    _selectedSeriesId = _isCollectionBindingApplicable
        ? _collectionAnilistId
        : null;
    _rederive();
    // 首搜由 [_loadCanonicalIdentity] 在读回规范身份**之后**发起（BUG-2008）：
    // `_searchSources` 在第一个 await 之前就把请求身份同步构造好了，先发后读
    // 等于「已绑定 AniList 的合集」——也就是绝大多数刮削过的合集——首搜永远
    // 还是裸显示名 + 裸 anilistId，而这个面板绝大多数场景只搜这一次。
    unawaited(_loadCanonicalIdentity());
  }

  /// 读回该合集刮削出的规范作品与身份（BUG-2008），再发起首搜。
  ///
  /// 用户没改过查询词时把它换成日文原名；合集绑了 AniList 就按它搜，没绑而刮削
  /// 身份里有 anilist id 就按后者搜。读库失败或压根没刮过一律**降级为旧路径**
  /// （裸显示名 + 合集 anilistId），绝不因此挡住首搜。
  Future<void> _loadCanonicalIdentity() async {
    try {
      final VideoMetadataWorkRow? work = await widget.database
          .resolveVideoMetadataWorkForCollection(widget.collection.id);
      if (!mounted) return;
      if (work != null) {
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
              row.provider.trim().toLowerCase(): row.externalId,
          };
          final String? original = work.originalTitle?.trim();
          if (queryUntouched && original != null && original.isNotEmpty) {
            _queryCtrl.text = original;
          }
        });
      }
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'SubtitleCollectionPanel.loadCanonicalIdentity',
        error,
      );
    }
    if (!mounted) return;
    // 多季合集不拿合集级 / 刮削快照里的 AniList id 直搜：它只能是其中一季的条目，
    // 拿它配选中的那一季正是「一季字幕装到每一季」的源头。走 [_resolveSeries]
    // 按选中季号挑对应那一季的条目。
    final int? seedId = _isCollectionBindingApplicable
        ? (_collectionAnilistId ?? _canonicalAnilistId)
        : null;
    if (seedId != null && !_searching) {
      unawaited(_searchSources(anilistId: seedId));
      return;
    }
    // 没绑系列的合集过去**根本不发首搜**——「绑了的自动搜、没绑的不搜」是这里唯一
    // 的特殊情况，代价是用户打开面板只看到一排 `Icons.remove` 占位和灰掉的「下载
    // 全部」，得自己猜出要先点「查找字幕」。补上等价首搜（先解析系列再搜来源，与
    // 点那个按钮同一条路径）。一个字幕来源都没配时不自动发：那条路径只会立刻弹
    // 红色的「缺 API key」，留给用户显式点。
    // 这条首搜**只搜不绑**（[_resolveSeries] → [_applySeries]）：这里的前提正是
    // 合集没绑 AniList，若把模糊命中的首条写回库，用户只是打开一次面板就会被
    // 粘性绑定——真人剧合集会被永久绑到一部最像的动画上。
    if (_searching || _resolving || !await _hasConfiguredSubtitleSource()) {
      return;
    }
    if (!mounted || _searching || _resolving) return;
    unawaited(_resolveSeries());
  }

  /// 本次检索交给 provider 的身份。
  ///
  /// 刮出规范作品时走仓库唯一的身份原语 [identityMediaReference]：外部 id
  /// （anilist / tmdb / **imdb** —— OpenSubtitles 的强键）、日文原名、年份、以及
  /// 由 id 推出的 [VideoDiscoveryCategory] 一起带上。写死 anime 会让真人剧合集
  /// 踩回 Jimaku 的 anime 硬过滤（BUG-1694）。
  ///
  /// 还没刮过的合集保持旧路径逐字节不变：裸 anilistId + 显示名 + anime 档。
  VideoMediaReference _searchIdentity({
    required String query,
    required int? anilistId,
  }) {
    final VideoMetadataWorkRow? work = _canonicalWork;
    if (work == null) {
      return VideoMediaReference(
        providerId: 'anilist',
        mediaId: anilistId?.toString() ?? query,
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: query,
        anilistId: anilistId,
      );
    }
    return identityMediaReference(
      providerId: 'anilist',
      kind: work.mediaType == 'movie'
          ? VideoMetadataMediaKind.movie
          : VideoMetadataMediaKind.tv,
      // 用户当场选定的系列压过刮削快照里的 anilist id。多季合集的刮削快照只对得上
      // 其中一季（AniList 一季一条），选中季没解析出条目时宁可不带，也不拿别季的。
      externalIds: <String, String>{
        for (final MapEntry<String, String> e in _canonicalIds.entries)
          if (_isCollectionBindingApplicable || e.key != 'anilist')
            e.key: e.value,
        if (anilistId != null) 'anilist': '$anilistId',
      },
      title: query,
      originalTitle: work.originalTitle,
      year: work.year,
    );
  }

  @override
  void didUpdateWidget(covariant SubtitleCollectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 成员（集号 / 内容语言）与全局默认语言都是派生状态的输入。
    if (!identical(oldWidget.members, widget.members) ||
        !identical(oldWidget.sectionKeys, widget.sectionKeys)) {
      _rebuildSeasonSections();
    }
    if (!identical(oldWidget.members, widget.members) ||
        oldWidget.globalDefaultContentLanguage !=
            widget.globalDefaultContentLanguage) {
      _rederive();
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<bool> _hasConfiguredSubtitleSource() async {
    final VideoSubtitleRegistry? registry = await widget.subtitleRegistry();
    return registry != null && registry.providers.isNotEmpty;
  }

  /// 一个字幕来源都拿不到时的提示：没填 Jimaku key 才说「请先填写 key」；填了
  /// key 却仍然没有来源 = 来源全被关掉了，不能再拿缺 key 糊弄（BUG-3000）。
  String _noSourceMessage() => _apiKeyCtrl.text.trim().isEmpty
      ? t.video_jimaku_no_key
      : t.video_subtitle_sources_all_disabled;

  SubtitleCollectionSource? get _selectedSource {
    for (final SubtitleCollectionSource s in _sources) {
      if (s.key == _selectedSourceKey) return s;
    }
    return null;
  }

  /// 批量真正采用的语言：显式选择 → 视频自身语言链（BUG-1700）。
  String? get _effectiveLanguage => resolveSubtitleDownloadLanguage(
    explicitSubtitlePreference: _language,
    videoContentLanguage: _members.isEmpty ? null : _members.first.language,
    globalDefaultContentLanguage: widget.globalDefaultContentLanguage,
  );

  /// 重算全部派生状态（集号 / 各来源版本排名 / 点名版本 / 各集计划）。
  ///
  /// 只在输入变化处调用：初始化、成员变化（[didUpdateWidget]）、搜索完成、探测
  /// 回填、改语言、选版本、切季。build 与成员行只读字段，不再每帧重排。
  void _rederive() {
    final List<int> targets = <int>[
      for (int i = 0; i < _members.length; i++)
        resolveSubtitleBatchEpisode(_targetAt(i)),
    ];
    final String? preferred = _effectiveLanguage;
    _targetEpisodes = targets;
    _targetEpisodeCount = targets.toSet().length;
    _versionsBySource = <String, List<SubtitleCollectionVersion>>{
      for (final SubtitleCollectionSource source in _sources)
        source.key: rankSubtitleCollectionVersions(
          source,
          targetEpisodes: targets,
          preferredLanguage: preferred,
          probedLanguages: _probedLanguages,
        ),
    };
    final SubtitleCollectionSource? source = _selectedSource;
    final String? pinnedKey = _releaseGroup;
    _pinnedVersion = source == null || pinnedKey == null
        ? null
        : _versionsOf(source)
              .where((SubtitleCollectionVersion v) => v.group.key == pinnedKey)
              .firstOrNull;
    if (source == null) {
      _plan = null;
      return;
    }
    final Map<String, String> probed = coarseVersionLanguages(_probedLanguages);
    _plan =
        SubtitleEpisodeIndex.fromCandidates(
          _batchCandidates,
          preferredLanguage: preferred,
        ).preferConsistentVersion(
          targetEpisodes: targets,
          versionOf: subtitleVersionKeyOf,
          languageRankOf: (VideoSubtitleCandidate c) => jimakuLanguageRank(
            c.language.isNotEmpty
                ? c.language
                : probed[subtitleVersionKeyOf(c)],
            preferred: preferred,
          ),
          fileNameOf: (VideoSubtitleCandidate c) => c.fileName,
        );
  }

  /// [source] 的版本列表（[_rederive] 算好的）。
  List<SubtitleCollectionVersion> _versionsOf(
    SubtitleCollectionSource source,
  ) => _versionsBySource[source.key] ?? const <SubtitleCollectionVersion>[];

  /// 批量下载用的候选：点名了版本只用该版本，否则整个来源（由批量按整季一致自动挑）。
  List<VideoSubtitleCandidate> get _batchCandidates {
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return const <VideoSubtitleCandidate>[];
    return _pinnedVersion?.group.members ?? source.candidates;
  }

  /// 版本的短名：组名（或发行平台）· 容器。
  String _versionShortLabel(SubtitleVersionGroup group) => <String>[
    group.releaseGroupTag ?? t.video_subtitle_collection_version_no_group,
    if (group.container.isNotEmpty) group.container.toUpperCase(),
  ].join(' · ');

  /// 版本行标题：短名 · 语言（文件名没写、靠正文判出的标「正文：」）· 机翻。
  String _versionTitle(SubtitleCollectionVersion version) {
    final SubtitleContentLanguage? content = version.contentLanguage;
    final String language = content != null
        ? '${t.subtitle_version_content_language}: '
              '${subtitleContentLanguageNativeLabel(content)}'
        : (version.language == null
              ? t.video_jimaku_language_unknown
              : jimakuLanguageLabel(version.language!));
    return <String>[
      _versionShortLabel(version.group),
      language,
      if (version.group.aiTranslated) t.subtitle_version_ai_translated,
    ].join(' · ');
  }

  /// 版本行副标题：覆盖本合集几集（部分覆盖时列出集号段）· 文件数。
  String _versionCoverage(SubtitleCollectionVersion version) {
    final int total = _targetEpisodeCount;
    final String coverage = t.video_subtitle_collection_version_coverage(
      covered: version.coveredEpisodes.length,
      total: total,
      files: version.group.members.length,
    );
    final bool partial =
        version.coveredEpisodes.isNotEmpty &&
        version.coveredEpisodes.length < total;
    return partial
        ? '$coverage · ${formatEpisodeSpans(version.coveredEpisodes)}'
        : coverage;
  }

  /// 文件名没写语言的版本：每个下一个代表文件按正文判语言（BUG-3998），结果回填
  /// 到版本列表并交给批量下载。代表文件的挑法与批量 / 番剧下载同一个共享判据
  /// （[probeUnlabeledVersionLanguages]：只挑覆盖本合集某集的文件）；有下载配额的
  /// 源不探（同单集面板的纪律）；按 generation 丢弃迟到结果。
  Future<void> _probeVersionLanguages() async {
    final int generation = ++_probeGeneration;
    final VideoSubtitleRegistry? registry = await widget.subtitleRegistry();
    if (registry == null || !mounted || generation != _probeGeneration) return;
    bool stale() => !mounted || generation != _probeGeneration;
    await probeUnlabeledVersionLanguages<VideoSubtitleCandidate>(
      files: <VideoSubtitleCandidate>[
        for (final SubtitleCollectionSource source in _sources)
          for (final VideoSubtitleCandidate c in source.candidates)
            if (!c.isArchivePack &&
                registry.allowsFreeProbeDownload(c) &&
                !_probedLanguages.containsKey(subtitleVersionKeyOf(c)))
              c,
      ],
      targetEpisodes: _targetEpisodes,
      versionOf: subtitleVersionKeyOf,
      declaredLanguageOf: (VideoSubtitleCandidate c) => c.language,
      episodeOf: (VideoSubtitleCandidate c) => c.episode,
      sizeOf: (VideoSubtitleCandidate c) => c.fileSize,
      fetch: (VideoSubtitleCandidate c) async => (await _download(c)).bytes,
      isCancelled: stale,
      onProbed: (String version, SubtitleContentLanguage? language) {
        if (stale()) return;
        setState(() {
          _probedLanguages = <String, SubtitleContentLanguage?>{
            ..._probedLanguages,
            version: language,
          };
          _rederive();
        });
      },
    );
  }

  /// 候选下载（探测与批量共用，见 [_downloads]）：**每次现取** registry（改 API key
  /// 会重建 provider runtime，早绑的实例正是坑——同单集面板）。
  Future<VideoSubtitleDownload> _download(VideoSubtitleCandidate candidate) {
    final String key = candidate.identityKey;
    final Future<VideoSubtitleDownload>? cached = _downloads[key];
    if (cached != null) return cached;
    final Future<VideoSubtitleDownload> future = () async {
      final VideoSubtitleRegistry? registry = await widget.subtitleRegistry();
      if (registry == null) throw StateError('no subtitle registry');
      return registry.download(candidate);
    }();
    _downloads[key] = future;
    // 失败不留在缓存里：网络抖一下不该让这份字幕在本面板里永远下不成。
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_downloads[key], future)) _downloads.remove(key);
      },
    );
    return future;
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

  /// 解析 AniList 系列候选：命中后默认按首条搜其来源；无命中回退文本搜。
  ///
  /// **这条路径从不写库**——它同时服务自动首搜（[_loadCanonicalIdentity]）和
  /// 「查找字幕」按钮，两者都只是「按这个词找找看」，不是「这个合集就是这部作品」。
  Future<void> _resolveSeries() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    final String query = _queryCtrl.text.trim();
    if (apiKey.isEmpty && !await _hasConfiguredSubtitleSource()) {
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
      _seriesMatchesQuery = null;
      _seriesLookupFailed = false;
      _seriesLookupKind = null;
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
        _seriesMatchesQuery = outcome.degraded ? null : query;
        _seriesLookupFailed = outcome.degraded;
        _seriesLookupKind = outcome.kind;
      });
      final AniListMedia? picked = pickAniListSeriesForSeason(
        outcome.media,
        season: _seasonHint(query),
      );
      if (picked != null) {
        // **只搜不绑**：模糊搜索的首条命中是猜测，不是用户的选择。相关度首条恒为
        // 第一季，按合集成员的季号挑对应那一季（挑不出才退回首条）。
        await _applySeries(picked, generation: generation);
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

  /// 本合集的季号提示：成员文件名一致解析出同一季（`S04E18`）就用它；成员跨季或
  /// 解析不出时看查询词、合集名里的季度记号（「… 4th season (2026)」）。
  int? _seasonHint(String query) {
    return subtitleSeasonHint(
      parsedSeason: _memberSeason(),
      titles: <String?>[query, widget.collection.name],
    );
  }

  int? _seasonOfMemberPathOrTitle(VideoBookRow member) {
    final int? fromPath = parseVideoPath(member.videoPath).season;
    if (fromPath != null && fromPath > 0) return fromPath;
    return subtitleSeasonFromName(member.title);
  }

  /// 成员文件名一致解析出的**显式**季号（`S04E18`），不一致或解析不出为 null。
  /// 只有它会作为 `season_number` 发给 OpenSubtitles / SubDL：从查询词、合集名推断
  /// 的季号只用来挑 AniList 条目（标题记号与 TMDB 季号并不总对得上）。
  int? _memberSeason() {
    // 多季合集只配选中的那一节，季号就是它（分季规则里没写季号的集算第 1 季，
    // 与详情页季 tab 同口径）；选中 PV·特典时没有季号。单季（含「单季 + PV·特典」）
    // 的分节季号是推断的，仍按成员文件名的显式季号走，见 [_sectionSeasonOverride]。
    if (_hasMultipleSeasons) return _selectedSeasonNumber;
    final Set<int?> memberSeasons = <int?>{
      for (final VideoBookRow member in _members)
        _seasonOfMemberPathOrTitle(member),
    };
    return memberSeasons.length == 1 ? memberSeasons.single : null;
  }

  /// 分季合集切到另一节：清掉上一季的来源 / 系列 / 行状态（它们只对上一季的集号
  /// 有意义），丢弃在途的搜索结果，再按新季重新解析（或复用同查询词的 AniList 候选）
  /// 并搜来源。批量下载途中不切。
  Future<void> _selectSeason(String groupKey) async {
    if (_running || groupKey == _seasonKey) return;
    final int generation = ++_generation;
    ++_probeGeneration;
    final String query = _queryCtrl.text.trim();
    final bool reuseSeries =
        _seriesMatchesQuery == query && !_seriesLookupFailed;
    setState(() {
      _seasonKey = groupKey;
      _sources = const <SubtitleCollectionSource>[];
      _selectedSourceKey = null;
      _releaseGroup = _isCollectionBindingApplicable
          ? _collectionReleaseGroup
          : null;
      _searched = false;
      _searching = false;
      _resolving = false;
      _notice = null;
      _statusByUid.clear();
      if (!reuseSeries) {
        _seriesMatches = const <AniListMedia>[];
        _seriesMatchesQuery = null;
        _selectedSeriesId = _isCollectionBindingApplicable
            ? _collectionAnilistId
            : null;
        _seriesLookupFailed = false;
        _seriesLookupKind = null;
      }
      _rederive();
    });
    if (!await _hasConfiguredSubtitleSource()) return;
    if (!mounted || generation != _generation) return;
    if (_isCollectionBindingApplicable) {
      final int? seedId = _collectionAnilistId ?? _canonicalAnilistId;
      if (seedId != null) {
        setState(() => _selectedSeriesId = seedId);
        await _searchSources(anilistId: seedId, generation: generation);
        return;
      }
    }
    if (reuseSeries) {
      final AniListMedia? picked = pickAniListSeriesForSeason(
        _seriesMatches,
        season: _seasonHint(query),
      );
      if (picked != null) {
        await _applySeries(picked, generation: generation);
      } else {
        setState(() => _selectedSeriesId = null);
        await _searchSources(anilistId: null, generation: generation);
      }
      return;
    }
    await _resolveSeries();
  }

  /// 「搜」这一半：把某个 AniList 候选当作**本次检索的身份**，不碰数据库。
  ///
  /// 与 [_selectSeries] 拆开是因为两条调用路径的意图根本不同，而不是同一件事的
  /// 两个开关：自动首搜（[_loadCanonicalIdentity]）与「查找字幕」按钮拿到的是
  /// 模糊搜索的第一条命中——真人剧合集在 AniList 上压根没有条目，模糊搜索照样
  /// 返回一部最像的动画。把这个猜测写进 `media_collections.anilistId` 会**永久**
  /// 改写合集身份：下次开面板走 `seedId` 分支再也不重搜，合集详情页的下载对话框
  /// 也跟着按它去找番剧种子（`media_collection_detail_page.dart` TODO-2485）。
  /// 所以这一半在类型上就够不着写库那一半，不靠调用方记得传对一个 bool。
  Future<void> _applySeries(AniListMedia media, {int? generation}) async {
    final int requestGeneration = generation ?? ++_generation;
    setState(() => _selectedSeriesId = media.id);
    await _searchSources(anilistId: media.id, generation: requestGeneration);
  }

  /// 「绑」这一半：用户显式点某系列 → 快照 anilist_id 到合集，再按它搜来源。
  ///
  /// `setMediaCollectionAnilistId` **只在这里**被调用，唯一调用方是系列
  /// ChoiceChip 的 `onSelected`——也就是用户的明确意图。
  ///
  /// 多季合集不写：用户点的只是**选中这一季**的条目，写进合集列等于把整张多季合集
  /// 绑到这一季上（下次打开、番剧下载都按它走）。
  Future<void> _selectSeries(AniListMedia media) async {
    final int requestGeneration = ++_generation;
    setState(() => _selectedSeriesId = media.id);
    if (_isCollectionBindingApplicable && _collectionAnilistId != media.id) {
      _collectionAnilistId = media.id;
      await widget.database.setMediaCollectionAnilistId(
        widget.collection.id,
        media.id,
      );
      if (!mounted || requestGeneration != _generation) {
        // 旧选择的慢 DB 写可能晚于新选择落库；以当前 UI 选择重申一次，避免数据库
        // 最终回退到旧 AniList id。
        final int? latest = _selectedSeriesId;
        if (latest != null && _isCollectionBindingApplicable) {
          _collectionAnilistId = latest;
          await widget.database.setMediaCollectionAnilistId(
            widget.collection.id,
            latest,
          );
        }
        return;
      }
    }
    await _applySeries(media, generation: requestGeneration);
  }

  /// 经 registry 一次列出全部候选（不带 episode：要看到「字幕侧到底有哪些集号」才能
  /// 判集号冲突，BUG-1695），按来源分组。
  Future<void> _searchSources({
    required int? anilistId,
    int? generation,
  }) async {
    final int requestGeneration = generation ?? ++_generation;
    final VideoSubtitleRegistry? registry = await widget.subtitleRegistry();
    if (!mounted) return;
    final String query = _queryCtrl.text.trim();
    if (registry == null || registry.providers.isEmpty) {
      setState(() {
        _sources = const <SubtitleCollectionSource>[];
        _selectedSourceKey = null;
        _searched = true;
        _rederive();
      });
      _setNotice(_noSourceMessage(), error: true);
      return;
    }
    setState(() {
      _searching = true;
      _notice = null;
    });
    // 列里的旧版本键迁成的新键（见下方 resolvePinnedSubtitleVersion）；搜索收尾后写回。
    String? migratedPin;
    try {
      final int? season = _memberSeason();
      // 规范身份优先（BUG-2008），构造见 [_searchIdentity]。
      final ProviderBatchResult<VideoSubtitleCandidate> result = await registry
          .search(
            VideoSubtitleSearchRequest(
              media: _searchIdentity(
                query: query,
                anilistId:
                    anilistId ??
                    (_isCollectionBindingApplicable
                        ? _canonicalAnilistId
                        : null),
              ),
              query: query,
              season: season,
            ),
          );
      if (!mounted || requestGeneration != _generation) return;
      final List<VideoSubtitleCandidate> seasonCandidates =
          filterSubtitleCandidatesForSeason(result.items, season: season);
      final List<SubtitleCollectionSource> sources =
          groupSubtitleCollectionSources(
            seasonCandidates,
            preferredLanguage: _effectiveLanguage,
          );
      final ExternalProviderFailure? failure = sources.isEmpty
          ? primarySubtitleFailure(result.failures)
          : null;
      setState(() {
        _searched = true;
        _sources = sources;
        _rederive();
        // 合集记着点名的版本：落在哪个来源就选中哪个来源（版本键含来源合集段）。
        // 列里还是 BUG-3998 之前的旧键时就地迁成新键（见 resolvePinnedSubtitleVersion）。
        final String? stored = _releaseGroup;
        final ({String sourceKey, String versionKey, bool migrated})? pin =
            stored == null
            ? null
            : resolvePinnedSubtitleVersion(
                sources,
                stored,
                rankedOf: _versionsOf,
              );
        if (pin != null && pin.migrated) {
          _releaseGroup = pin.versionKey;
          migratedPin = pin.versionKey;
        }
        _selectedSourceKey =
            pin?.sourceKey ??
            (sources.any(
                  (SubtitleCollectionSource s) => s.key == _selectedSourceKey,
                )
                ? _selectedSourceKey
                : (sources.isEmpty ? null : sources.first.key));
        _statusByUid.clear();
        _rederive();
      });
      unawaited(_probeVersionLanguages());
      if (failure != null) {
        _setNotice(
          describeSubtitleFailure(t.video_jimaku_search_failed, failure),
          error: true,
        );
      }
    } on Object catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      setState(() => _searched = true);
      _setNotice(
        describeSubtitleFailure(t.video_jimaku_search_failed, error),
        error: true,
      );
    } finally {
      if (mounted && requestGeneration == _generation) {
        setState(() => _searching = false);
      }
    }
    // 旧键迁成新键后改写合集列（一次性：改写后列值直接命中新键，不再走迁移）。
    // 放在搜索的 try 之外：写库失败不是「搜索失败」，不该冒充成搜索失败的提示，
    // 也不吞——与点版本行写列（[_selectVersion]）一样向调用方传播。
    final String? pinToPersist = migratedPin;
    if (pinToPersist != null && _isCollectionBindingApplicable) {
      _collectionReleaseGroup = pinToPersist;
      await widget.database.updateMediaCollectionSubtitleReleaseGroup(
        widget.collection.id,
        pinToPersist,
      );
    }
  }

  /// 选语言：更新筛选 + 写合集列（本合集的决定）+ 系列 prefs 记忆（老路径兼容）。
  Future<void> _selectLanguage(String? lang) async {
    setState(() {
      _language = lang;
      _rederive();
    });
    await widget.database.updateMediaCollectionSubtitleLanguage(
      widget.collection.id,
      lang,
    );
    if (lang != null) {
      await widget.onPreferredLanguageChanged?.call(lang);
    }
  }

  /// 聚合列表里点一行：选中 [source]，[versionKey] 为 null = 「自动」（整季一致
  /// 自动挑），否则点名该版本。单季合集把版本写合集列（下次打开仍是它）。
  Future<void> _selectVersion(
    SubtitleCollectionSource source,
    String? versionKey,
  ) async {
    setState(() {
      _selectedSourceKey = source.key;
      _releaseGroup = versionKey;
      if (_isCollectionBindingApplicable) {
        _collectionReleaseGroup = versionKey;
      }
      _rederive();
    });
    if (_isCollectionBindingApplicable) {
      await widget.database.updateMediaCollectionSubtitleReleaseGroup(
        widget.collection.id,
        versionKey,
      );
    }
  }

  List<SubtitleBatchTarget> _targets() => <SubtitleBatchTarget>[
    for (int i = 0; i < _members.length; i++) _targetAt(i),
  ];

  SubtitleBatchTarget _targetAt(int index) {
    final VideoBookRow member = _members[index];
    return SubtitleBatchTarget(
      bookUid: member.bookUid,
      title: member.title,
      videoPath: member.videoPath,
      sortIndex: index,
      isStream: isStreamVideoBook(member),
      season: _sectionSeasonOverride,
    );
  }

  Future<void> _downloadAll() async {
    final VideoSubtitleRegistry? registry = await widget.subtitleRegistry();
    if (!mounted) return;
    if (registry == null) {
      _setNotice(_noSourceMessage(), error: true);
      return;
    }
    final List<VideoSubtitleCandidate> candidates = _batchCandidates;
    if (candidates.isEmpty) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _notice = null;
      _statusByUid.clear();
    });
    final List<SubtitleBatchItem> results;
    try {
      results = await runSubtitleBatch(
        registry: registry,
        candidates: candidates,
        targets: _targets(),
        saveDirectory: widget.saveDirectory,
        preferredLanguage: _effectiveLanguage,
        subtitleAligner: widget.subtitleAligner,
        download: _download,
        probedVersionLanguages: _probedLanguages,
        isCancelled: () => _stopRequested,
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
    // 每集的失败原因进错误日志（含持久化抛错——批量把它归到该集、继续下一集）：
    // 行副标题只放得下一句话，排查要靠这里。面板已关也照记。同一个整季包的失败
    // 只记一次（挂在它覆盖的第一集上），不逐集重复。
    for (final SubtitleBatchItem item in subtitleBatchDistinctFailures(
      results,
    )) {
      logSubtitleDownloadFailure(
        'SubtitleCollectionPanel.batch[EP${item.episode}]',
        item.error!,
      );
    }
    if (!mounted) return;
    final int done = _statusByUid.values
        .where((SubtitleBatchItem i) => i.status == SubtitleBatchStatus.done)
        .length;
    final bool stopped = results.any(
      (SubtitleBatchItem i) => i.status == SubtitleBatchStatus.skipped,
    );
    _setNotice(
      stopped
          ? t.video_subtitle_batch_stopped(done: done, total: _members.length)
          : t.video_jimaku_batch_done(done: done, total: _members.length),
    );
  }

  /// 「停止」：只置标记，[runSubtitleBatch] 在下一集开始前看到就把剩下的记成跳过。
  void _requestStop() {
    if (!_running || _stopRequested) return;
    setState(() => _stopRequested = true);
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
    } else {
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
    widget.onSubtitlePersisted?.call(target.bookUid, path);
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
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          );
        case SubtitleBatchStatus.done:
          // 语义色走主题（MD3 和谐化绿 / Apple systemGreen；墨水屏 onSurface），
          // 不再硬编码 Colors.green / red。
          return FushiIcon(
            FushiIcons.filled(FushiIcons.success),
            size: 18,
            color: fushiStatusColor(context, FushiStatusTone.success),
          );
        case SubtitleBatchStatus.noMatch:
          return const FushiIcon(FushiIcons.searchOff, size: 18);
        case SubtitleBatchStatus.failed:
          return FushiIcon(
            FushiIcons.error,
            size: 18,
            color: fushiStatusColor(context, FushiStatusTone.error),
          );
        case SubtitleBatchStatus.pending:
          return const FushiIcon(FushiIcons.schedule, size: 18);
        case SubtitleBatchStatus.skipped:
          return const FushiIcon(FushiIcons.skipNext, size: 18);
      }
    }
    if (_searching) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    }
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return const FushiIcon(FushiIcons.moreHoriz, size: 18);
    final int episode = resolveSubtitleBatchEpisode(_targetAt(memberIndex));
    return (_plan?.byEpisode[episode]?.isEmpty ?? true) &&
            source.unpackablePackFormat == null
        ? const FushiIcon(FushiIcons.searchOff, size: 18)
        : FushiIcon(
            FushiIcons.success,
            size: 18,
            color: fushiStatusColor(context, FushiStatusTone.success),
          );
  }

  /// 行首状态徽标：36 圆形 surfaceContainerHighest 底托住状态图标（Apple /
  /// 墨水屏只画图标本身）。
  Widget _statusBadge(String bookUid, int memberIndex) {
    final Widget icon = _statusIcon(bookUid, memberIndex);
    if (isGlassDesign(context) || isEinkTheme(context)) return icon;
    return SizedBox.square(
      dimension: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: Center(child: icon),
      ),
    );
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
          final SubtitleArchiveFormat? unsupported =
              _selectedSource?.unsupportedPackFormat;
          return Text(
            unsupported == null
                // 整季包没下下来（401 / 429 / 断网）与「真的没有这一集」是两件事。
                ? describeSubtitleFailure(t.video_jimaku_no_results, item.error)
                : t.video_subtitle_archive_pack_unsupported(
                    format: unsupported.label,
                  ),
          );
        case SubtitleBatchStatus.failed:
          return Text(switch (item.failureStage) {
            // 下下来了：说成「下载失败」用户会去换来源，而问题在本地。
            SubtitleBatchFailureStage.write =>
              t.video_subtitle_batch_save_failed,
            SubtitleBatchFailureStage.persist =>
              t.video_subtitle_batch_persist_failed,
            // 与本集面板同一套文案（BUG-1844）：key 被拒 / 连不上 / HTTP 状态码。
            SubtitleBatchFailureStage.download ||
            null => describeSubtitleFailure(
              t.video_jimaku_download_failed,
              item.error,
            ),
          });
        case SubtitleBatchStatus.downloading:
        case SubtitleBatchStatus.pending:
          return Text(t.video_jimaku_source_loading);
        case SubtitleBatchStatus.skipped:
          return Text(t.video_subtitle_batch_skipped);
      }
    }
    if (_searching) return Text(t.video_jimaku_source_loading);
    final SubtitleCollectionSource? source = _selectedSource;
    if (source == null) return Text(t.video_subtitle_collection_members_hint);
    final int episode = resolveSubtitleBatchEpisode(_targetAt(memberIndex));
    final SubtitleEpisodeIndex<VideoSubtitleCandidate> plan =
        _plan ?? source.index;
    final List<VideoSubtitleCandidate> matches =
        plan.byEpisode[episode] ?? const <VideoSubtitleCandidate>[];
    if (matches.isEmpty) {
      // 整季包（BUG-3000 跟进）：没有单集文件的集，下载时从包里按集号拆。
      final SubtitleArchiveFormat? pack = source.unpackablePackFormat;
      if (pack != null) {
        return Text(
          t.video_subtitle_episode_from_pack(
            episode: episode,
            format: pack.label,
          ),
        );
      }
      final SubtitleArchiveFormat? unsupported = source.unsupportedPackFormat;
      if (unsupported != null && plan.unnumbered.isEmpty) {
        return Text(
          t.video_subtitle_archive_pack_unsupported(format: unsupported.label),
        );
      }
      if (plan.unnumbered.isNotEmpty) {
        return Text(
          t.video_jimaku_episode_unlabeled(
            episode: episode,
            count: plan.unnumbered.length,
          ),
        );
      }
      return Text(t.video_jimaku_episode_unavailable(episode: episode));
    }
    // 首个 = 整季一致判据下这一集实际会用的那份（与批量下载同一判据）。
    final String versionKey = subtitleVersionKeyOf(matches.first);
    final SubtitleCollectionVersion? version = _versionsOf(source)
        .where((SubtitleCollectionVersion v) => v.group.key == versionKey)
        .firstOrNull;
    return Text(
      t.video_subtitle_collection_episode_planned(
        count: matches.length,
        version: version == null
            ? matches.first.fileName
            : _versionTitle(version),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
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

  /// 收起状态下每个来源最多显示几个版本（「自动」行另计）。
  static const int _kCollapsedVersionCount = 5;

  /// 聚合的版本列表：来源 → 该来源的字幕版本（组名 / 平台 · 容器 · 语言 · 覆盖），
  /// 每行可直接点选；每个来源的首行是「自动：整季统一版本」，副标题写明它会用哪个
  /// 版本——列表顺序与「自动」实际挑的出自同一判据（[rankSubtitleCollectionVersions]）。
  ///
  /// 取代原来的「来源」chip + 「偏好版本」下拉：两处分开选时，chip 上看不到组合，
  /// 下拉里又看不到覆盖几集、哪个是自动会用的。
  ///
  /// 空列表**不整块隐藏**：合集没绑 AniList id 时首搜根本不发（见 [initState]），
  /// 用户面对的就是一排 `Icons.remove` 占位 + 灰掉的「下载全部」+ 零解释，无从知道
  /// 还要先点「查找字幕」。三种空态各说一句话。
  Widget _buildVersionPicker(ThemeData theme) {
    if (_sources.isEmpty) {
      final String message = _searching || _resolving
          ? t.video_jimaku_source_loading
          : (_searched
                ? t.video_jimaku_no_results
                : t.video_subtitle_source_search_hint);
      return _chipSection(t.video_subtitle_collection_versions, <Widget>[
        Text(
          message,
          key: const ValueKey<String>('subtitle-source-empty'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ]);
    }
    int entrance = 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              t.video_subtitle_collection_versions,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final SubtitleCollectionSource source in _sources)
            ..._buildSourceVersions(theme, source, () => entrance++),
        ],
      ),
    );
  }

  /// 一个来源的分组：来源标题 + 「自动」行 + 版本行（超过上限时可展开）。
  List<Widget> _buildSourceVersions(
    ThemeData theme,
    SubtitleCollectionSource source,
    int Function() nextEntrance,
  ) {
    final List<SubtitleCollectionVersion> versions = _versionsOf(source);
    final bool expanded = _expandedSources.contains(source.key);
    final List<SubtitleCollectionVersion> shown =
        expanded || versions.length <= _kCollapsedVersionCount
        ? versions
        : versions.sublist(0, _kCollapsedVersionCount);
    final bool canToggle = versions.length > _kCollapsedVersionCount;
    final bool sourceSelected = _selectedSourceKey == source.key;
    final String? pinnedKey = sourceSelected ? _pinnedVersion?.group.key : null;
    final int count = 1 + shown.length + (canToggle ? 1 : 0);
    final SubtitleCollectionVersion? autoPick = versions.firstOrNull;

    Widget row({
      required int index,
      required Key key,
      required bool selected,
      required Widget title,
      Widget? subtitle,
      VoidCallback? onTap,
      Widget? leading,
    }) {
      return FushiStaggeredEntrance(
        index: nextEntrance(),
        child: FushiGroupedListItem(
          index: index,
          count: count,
          child: FushiListItem(
            key: key,
            density: FushiListDensity.compact,
            selected: selected,
            onTap: _running ? null : onTap,
            leading: leading ?? _selectionMark(theme, selected),
            title: title,
            subtitle: subtitle,
            titleMaxLines: 2,
          ),
        ),
      );
    }

    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6, left: 2),
        child: Text(
          '${source.label} · ${source.providerId}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
      ),
      row(
        index: 0,
        key: ValueKey<String>('subtitle-source-${source.key}'),
        selected: sourceSelected && pinnedKey == null,
        title: Text(t.video_subtitle_collection_version_auto),
        subtitle: Text(
          autoPick == null
              ? t.video_jimaku_no_results
              : t.video_subtitle_collection_version_auto_detail(
                  version: _versionTitle(autoPick),
                ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => unawaited(_selectVersion(source, null)),
      ),
      for (int i = 0; i < shown.length; i++)
        row(
          index: i + 1,
          key: ValueKey<String>('subtitle-version-${shown[i].group.key}'),
          selected: pinnedKey == shown[i].group.key,
          title: Text(_versionTitle(shown[i])),
          subtitle: Text(
            _versionCoverage(shown[i]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => unawaited(_selectVersion(source, shown[i].group.key)),
        ),
      if (canToggle)
        row(
          index: count - 1,
          key: ValueKey<String>('subtitle-versions-toggle-${source.key}'),
          selected: false,
          leading: FushiIcon(
            expanded ? FushiIcons.expandLess : FushiIcons.expandMore,
            size: 20,
          ),
          title: Text(
            expanded
                ? t.video_subtitle_collection_version_show_less
                : t.video_subtitle_collection_version_show_all(
                    n: versions.length,
                  ),
          ),
          onTap: () => setState(() {
            if (!_expandedSources.add(source.key)) {
              _expandedSources.remove(source.key);
            }
          }),
        ),
    ];
  }

  /// 「番剧匹配」：AniList 系列候选，每条一行单选，标题**不限行**按面板宽度换行。
  ///
  /// 候选之间只靠标题区分，而同系列各季的 romaji 前缀相同、差别在末尾
  /// （`… 2nd Season`）。原先画成定宽 chip、单行省略号，几季显示成同一串
  /// （BUG-4743）；chip 本身也装不下长标题——MD3 `RawChip` 与 Apple 胶囊都把
  /// label 钉成单行。所以与下方「字幕版本」同构，用分组列表行承载。
  Widget _buildSeriesMatches(ThemeData theme) {
    final int count = _seriesMatches.length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              t.video_jimaku_anime_match,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (int i = 0; i < count; i++)
            FushiStaggeredEntrance(
              index: i,
              child: FushiGroupedListItem(
                index: i,
                count: count,
                child: FushiListItem(
                  key: ValueKey<String>(
                    'subtitle-series-${_seriesMatches[i].id}',
                  ),
                  density: FushiListDensity.compact,
                  selected: _selectedSeriesId == _seriesMatches[i].id,
                  onTap: _resolving || _running
                      ? null
                      : () => unawaited(_selectSeries(_seriesMatches[i])),
                  leading: _selectionMark(
                    theme,
                    _selectedSeriesId == _seriesMatches[i].id,
                  ),
                  title: Text(_seriesMatches[i].displayTitle),
                  titleMaxLines: null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 行首单选标记：选中 = 实心勾，未选 = 空心圆；切换走 effects 短时长交叉淡化。
  Widget _selectionMark(ThemeData theme, bool selected) {
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: FushiIcon(
        selected ? FushiIcons.success : FushiIcons.radioUnchecked,
        key: ValueKey<bool>(selected),
        size: 20,
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 合集级配置：默认语言（写列 + prefs）。版本在上方聚合列表里直接选。
  Widget _buildCollectionSettings(ThemeData theme) {
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
      ],
    );
  }

  String _seasonLabel(CollectionSeasonSection<VideoBookRow> section) {
    final int? season = seasonNumberOfGroupKey(section.groupKey);
    final String base = season == null
        ? t.collection_group_extras
        : t.collection_group_season(n: season);
    return '$base (${section.items.length})';
  }

  /// 多季合集切季条：逐季单选，选哪一季就只检索并批量配那一季的成员。
  Widget _buildSeasonPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        key: const ValueKey<String>('subtitle-collection-seasons'),
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final CollectionSeasonSection<VideoBookRow> section
              in _seasonSections)
            FushiChoiceChip(
              key: ValueKey<String>(
                'subtitle-collection-season-${section.groupKey}',
              ),
              label: Text(_seasonLabel(section)),
              selected: section.groupKey == _seasonKey,
              onSelected: _running
                  ? null
                  : (_) => unawaited(_selectSeason(section.groupKey)),
            ),
        ],
      ),
    );
  }

  Widget? _buildNotice(ThemeData theme) {
    final String? notice = _notice;
    if (notice == null && !_seriesLookupFailed) return null;
    final bool error = notice != null && _noticeIsError;
    // 全 app 唯一的提示横幅：中性块 + 语义色图标（Apple / 墨水屏各自分支）。
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FushiInlineNotice(
        key: kSubtitleNoticeBannerKey,
        severity: error ? FushiNoticeSeverity.error : FushiNoticeSeverity.info,
        icon: error ? FushiIcons.error : FushiIcons.info,
        message: notice ?? jimakuSeriesLookupNotice(_seriesLookupKind),
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
    // 表单区与成员列表同属**一个**滚动区，外层 Column 撑满宿主高度：原来是两个
    // `Flexible`(loose) 各分一份 flex，谁没用完谁的份额就落成死白，底部操作条永远
    // 浮在内容尾巴上而不贴底。
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showTitle) ...<Widget>[
          Text(t.video_jimaku_batch_title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
        ],
        if (notice != null) notice,
        Expanded(
          child: FushiEntranceScope(
            replayKey: Object.hash(_seasonKey, _members.length),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      JimakuApiKeyField(controller: _apiKeyCtrl, dense: true),
                      const SizedBox(height: 8),
                      if (_hasSeasonSections) _buildSeasonPicker(),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FushiTextFieldControl(
                              controller: _queryCtrl,
                              decoration: InputDecoration(
                                labelText: t.video_jimaku_query,
                                isDense: true,
                              ),
                              // 与右边的按钮同一道闸：批量途中回车重搜会清掉
                              // 在跑的各集行状态、换掉来源（BUG-4799）。
                              onSubmitted: (_) {
                                if (_resolving || _searching || _running) {
                                  return;
                                }
                                unawaited(_resolveSeries());
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          FushiFilledButton.tonalIcon(
                            key: const ValueKey<String>(
                              'subtitle-collection-find',
                            ),
                            onPressed: _resolving || _searching || _running
                                ? null
                                : _resolveSeries,
                            icon: const FushiIcon(FushiIcons.search, size: 18),
                            label: Text(t.video_jimaku_find_sources),
                          ),
                        ],
                      ),
                      if (_seriesMatches.length >= 2)
                        _buildSeriesMatches(theme),
                      _buildVersionPicker(theme),
                      _buildCollectionSettings(theme),
                      const FushiDividerControl(height: 20),
                    ],
                  ),
                ),
                // M3E：成员按集排成分段卡片（首尾大圆角、行间 2），行首状态图标
                // 放进圆形色块，错峰进场。
                SliverList.builder(
                  itemCount: _members.length,
                  itemBuilder: fushiStaggeredItemBuilder((
                    BuildContext context,
                    int i,
                  ) {
                    final VideoBookRow m = _members[i];
                    return FushiGroupedListItem(
                      index: i,
                      count: _members.length,
                      child: FushiListItem(
                        density: FushiListDensity.compact,
                        leading: _statusBadge(m.bookUid, i),
                        title: Text(
                          m.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: _episodeSubtitle(m, i),
                      ),
                    );
                  }),
                ),
              ],
            ),
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
              FushiTextButton(
                onPressed: _running ? null : widget.onCancel,
                child: Text(t.dialog_close),
              ),
            // 跑起来后主按钮换成「停止（当前集/总数）」；点了之后在等手上那一集
            // 收尾，显示「正在停止…」并禁用。
            if (_running)
              FushiFilledButton.icon(
                key: const ValueKey<String>('subtitle-collection-stop'),
                onPressed: _stopRequested ? null : _requestStop,
                icon: _stopRequested
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : const FushiIcon(FushiIcons.stop),
                label: Text(
                  _stopRequested
                      ? t.video_subtitle_batch_stopping
                      : t.video_subtitle_batch_stop(
                          current: _statusByUid.length,
                          total: _members.length,
                        ),
                ),
              )
            else
              FushiFilledButton.icon(
                key: const ValueKey<String>('subtitle-collection-download-all'),
                onPressed: canDownload ? _downloadAll : null,
                icon: const FushiIcon(FushiIcons.download),
                label: Text(t.video_jimaku_batch_download),
              ),
          ],
        ),
      ],
    );
  }
}
