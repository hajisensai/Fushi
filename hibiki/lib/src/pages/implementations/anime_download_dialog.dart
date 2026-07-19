import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_matching.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart'
    show jimakuLanguageLabel;
import 'package:hibiki/src/pages/implementations/download_actions.dart';
import 'package:hibiki/utils.dart';

/// 「番剧下载」选种对话框：搜番（AniList）→ 选种（Nyaa）→ 确认字幕（Jimaku）→
/// 推送 qBittorrent + 落盘 [AnimeDownloadPlan]（完成后由常驻服务自动入库挂合集）。
///
/// 分节渐进式（同 [JimakuSubtitleDialog] 的节奏）：三个阶段互斥展示（搜番结果 /
/// 种子列表 / 确认推送），底部常驻「下载任务」折叠区列出既有计划。所有网络操作
/// 容错降级为空结果 + 节内提示，不崩对话框。
class AnimeDownloadDialog extends ConsumerStatefulWidget {
  const AnimeDownloadDialog({super.key});

  @override
  ConsumerState<AnimeDownloadDialog> createState() =>
      _AnimeDownloadDialogState();
}

class _AnimeDownloadDialogState extends ConsumerState<AnimeDownloadDialog> {
  final TextEditingController _animeQueryCtrl = TextEditingController();
  final TextEditingController _nyaaQueryCtrl = TextEditingController();
  late final TextEditingController _jimakuKeyCtrl;

  // ---- 通用下载（粘贴磁力：书/视频/任意）----
  final TextEditingController _magnetCtrl = TextEditingController();
  String _genericKind = AnimeDownloadPlan.kindAuto;
  bool _pushingGeneric = false;

  /// Jimaku key 为空时显示输入行（`onChanged` 直接落偏好）。
  bool _showJimakuKeyField = false;

  // ---- 阶段 1：搜番（AniList）----
  bool _searchingAnime = false;
  bool _searchedAnime = false;
  List<AniListMedia> _animeMatches = const <AniListMedia>[];
  AniListMedia? _selectedMedia;

  // ---- 阶段 2：选种（Nyaa）+ 字幕索引（Jimaku）----
  bool _loadingTorrents = false;
  bool _torrentsLoaded = false;
  List<NyaaTorrent> _torrents = const <NyaaTorrent>[];
  String _category = '1_0';
  bool _trustedOnly = false;
  JimakuEpisodeIndex _jimakuIndex =
      JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
  bool _jimakuLoaded = false;

  // ---- 阶段 3：确认推送 ----
  NyaaTorrent? _selectedTorrent;
  List<(int?, JimakuFile)> _chosenSubs = const <(int?, JimakuFile)>[];
  bool _includeSubs = true;
  bool _pushing = false;

  // ---- 下载任务折叠区 ----
  List<AnimeDownloadPlan> _plans = const <AnimeDownloadPlan>[];

  @override
  void initState() {
    super.initState();
    final AppModel appModel = ref.read(appProvider);
    _jimakuKeyCtrl = TextEditingController(text: appModel.jimakuApiKey);
    _showJimakuKeyField = appModel.jimakuApiKey.trim().isEmpty;
    unawaited(_reloadPlans());
  }

  @override
  void dispose() {
    _animeQueryCtrl.dispose();
    _nyaaQueryCtrl.dispose();
    _jimakuKeyCtrl.dispose();
    _magnetCtrl.dispose();
    super.dispose();
  }

  /// 下载后端是否就绪（推送按钮禁用条件；浏览选种不禁）。默认（auto）在桌面
  /// 走内置引擎、开箱即用；只有显式外接 qb 且没填地址才算未就绪。
  bool get _backendReady => torrentBackendReady(ref.read(appProvider));

  /// 后端未就绪（推送禁用 + 提示横幅）。
  bool get _qbMissing => !_backendReady;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- 阶段 1

  Future<void> _searchAnime() async {
    final String query = _animeQueryCtrl.text.trim();
    if (query.isEmpty || _searchingAnime) return;
    setState(() {
      _searchingAnime = true;
      _searchedAnime = false;
      _animeMatches = const <AniListMedia>[];
    });
    final AniListClient anilist = AniListClient();
    try {
      final List<AniListMedia> media = await anilist.searchAnime(query);
      if (!mounted) return;
      setState(() {
        _animeMatches = media;
        _searchedAnime = true;
      });
    } finally {
      anilist.close();
      if (mounted) setState(() => _searchingAnime = false);
    }
  }

  /// 点选某番：进入选种阶段，并行拉 Nyaa 种子与 Jimaku 字幕索引。
  /// Jimaku 空结果/无 key 不阻塞选种，只是徽标显示无字幕。
  Future<void> _selectMedia(AniListMedia media) async {
    final String query = (media.romaji?.trim().isNotEmpty ?? false)
        ? media.romaji!.trim()
        : media.displayTitle;
    _nyaaQueryCtrl.text = query;
    setState(() {
      _selectedMedia = media;
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      _jimakuLoaded = false;
    });
    await Future.wait(<Future<void>>[
      _fetchTorrents(),
      _fetchJimaku(media),
    ]);
  }

  /// 返回搜番阶段（换番）。
  void _clearSelectedMedia() {
    setState(() {
      _selectedMedia = null;
      _selectedTorrent = null;
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
    });
  }

  // ---------------------------------------------------------------- 阶段 2

  /// 按当前查询词/分类/Trusted 过滤搜 Nyaa，结果按 seeders 降序。
  Future<void> _fetchTorrents() async {
    final String query = _nyaaQueryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loadingTorrents = true;
      _torrentsLoaded = false;
    });
    final NyaaClient nyaa = NyaaClient();
    try {
      final List<NyaaTorrent> results = await nyaa.search(
        query,
        category: _category,
        filter: _trustedOnly ? '2' : '0',
      );
      final List<NyaaTorrent> sorted = List<NyaaTorrent>.of(results)
        ..sort(
            (NyaaTorrent a, NyaaTorrent b) => b.seeders.compareTo(a.seeders));
      if (!mounted) return;
      setState(() {
        _torrents = sorted;
        _torrentsLoaded = true;
      });
    } finally {
      nyaa.close();
      if (mounted) setState(() => _loadingTorrents = false);
    }
  }

  /// 拉 Jimaku 字幕索引：searchByAnilistId → 首条目 → listFiles 全量 → 按集索引。
  /// 无 key / 无条目 / 网络失败 → 空索引（徽标显示无字幕），不阻塞选种。
  Future<void> _fetchJimaku(AniListMedia media) async {
    final String apiKey = ref.read(appProvider).jimakuApiKey.trim();
    if (apiKey.isEmpty) {
      if (mounted) setState(() => _jimakuLoaded = true);
      return;
    }
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey);
    try {
      final List<JimakuEntry> entries =
          await jimaku.searchByAnilistId(media.id);
      final List<JimakuFile> files = entries.isEmpty
          ? const <JimakuFile>[]
          : await jimaku.listFiles(entries.first.id);
      // 用户可能已换番：结果只落到仍选中的那个番上。
      if (!mounted || _selectedMedia?.id != media.id) return;
      setState(() {
        _jimakuIndex = JimakuEpisodeIndex.fromFiles(files);
        _jimakuLoaded = true;
      });
    } finally {
      jimaku.close();
    }
  }

  void _selectCategory(String category) {
    if (_category == category) return;
    setState(() => _category = category);
    unawaited(_fetchTorrents());
  }

  void _toggleTrustedOnly(bool value) {
    setState(() => _trustedOnly = value);
    unawaited(_fetchTorrents());
  }

  // ---------------------------------------------------------------- 阶段 3

  void _selectTorrent(NyaaTorrent torrent) {
    setState(() {
      _selectedTorrent = torrent;
      _chosenSubs = chooseSubtitlesFor(torrent, _jimakuIndex);
      _includeSubs = true;
    });
  }

  void _clearSelectedTorrent() {
    setState(() {
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
    });
  }

  /// 推送下载：暂存字幕 → 落计划 → 推 qBittorrent（失败回滚计划）→ 催一轮 tick。
  Future<void> _push() async {
    final AppModel appModel = ref.read(appProvider);
    // null（全新用户没进过设置）→ 默认配置（auto：桌面内置引擎，开箱即用）。
    final QbConnectionConfig config =
        appModel.qbConnectionConfig ?? const QbConnectionConfig();
    final NyaaTorrent? torrent = _selectedTorrent;
    final AniListMedia? media = _selectedMedia;
    if (!_backendReady) return;
    if (torrent == null || media == null || _pushing) return;
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) {
      _snack(t.anime_download_store_unavailable);
      return;
    }
    final String planId = torrent.infoHash.trim().toLowerCase();
    if (planId.isEmpty) {
      // RSS 缺 infoHash：无法与 qb 列表比对，等于计划无法追踪，直接按失败处理。
      _snack(t.anime_download_push_failed);
      return;
    }
    // 首次下载：弹一次「上传/做种」提示（默认关上传、询问是否开启+配限速/时长/
    // 分享率）。仅内置引擎相关（外接 qb 自管上传）；展示后置 flag 不再弹。
    await maybeShowTorrentUploadConsent(context, appModel);
    if (!mounted) return;
    setState(() => _pushing = true);

    // ① 逐条下载选中的字幕到计划暂存目录（单条失败跳过该条）。
    final List<PlanSubtitle> staged = <PlanSubtitle>[];
    if (_includeSubs && _chosenSubs.isNotEmpty) {
      final JimakuClient jimaku =
          JimakuClient(apiKey: appModel.jimakuApiKey.trim());
      try {
        final Directory subsDir = store.subsDirFor(planId);
        for (final (int? episode, JimakuFile file) in _chosenSubs) {
          final Uint8List? bytes = await jimaku.downloadFile(file.url);
          if (bytes == null) continue;
          try {
            final File dest = File(p.join(subsDir.path, p.basename(file.name)))
              ..createSync(recursive: true);
            await dest.writeAsBytes(bytes);
            staged.add(PlanSubtitle(
              episode: episode,
              fileName: file.name,
              stagedPath: dest.path,
              language: detectSubtitleLanguage(file.name),
            ));
          } catch (_) {
            // 单条落盘失败跳过，不影响其余字幕与推送。
          }
        }
      } finally {
        jimaku.close();
      }
    }

    // ② 落计划（先写盘再推 qb，推失败回滚删除）。
    final AnimeDownloadPlan plan = AnimeDownloadPlan(
      id: planId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      seriesTitle: media.displayTitle,
      anilistId: media.id,
      coverUrl: media.coverUrl,
      torrentTitle: torrent.title,
      magnet: torrent.magnet,
      qbCategory: config.category,
      subtitles: staged,
    );
    await store.save(plan);

    // ③ 推种子后端（顺序下载 + 首尾块优先，支持边下边播）。按配置解析后端
    // （默认桌面走内置 libtorrent 引擎；显式外接才走 qb）——与轮询服务同一
    // 选择逻辑，不再硬编码 qb。
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    bool pushed = false;
    try {
      await backend.prepareCategory(config.category);
      pushed = await backend.addTorrent(
        torrent.magnet,
        category: config.category,
        sequential: true,
        firstLastPiecePrio: true,
      );
    } finally {
      backend.close();
    }
    if (!pushed) {
      await store.delete(planId);
      if (mounted) {
        setState(() => _pushing = false);
        _snack(t.anime_download_push_failed);
      }
      return;
    }
    unawaited(appModel.animeDownloadService?.tick());
    if (!mounted) return;
    _snack(t.anime_download_pushed);
    Navigator.pop(context);
  }

  // ------------------------------------------------------------ 下载任务区

  Future<void> _reloadPlans() async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    if (!mounted) return;
    // loadAll 按创建时间升序；展示新的在上。
    setState(() => _plans = plans.reversed.toList(growable: false));
  }

  Future<void> _refreshPlans() async {
    await _reloadPlans();
    unawaited(ref.read(appProvider).animeDownloadService?.tick());
  }

  Future<void> _deletePlan(AnimeDownloadPlan plan) async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    await store.delete(plan.id);
    await _reloadPlans();
  }

  /// 「边下边播」：不等下载完成，立即按计划入库（qb 元数据就绪即可流式播放）。
  Future<void> _playNow(AnimeDownloadPlan plan) async {
    final bool ok =
        await ref.read(appProvider).animeDownloadService?.importNow(plan.id) ??
            false;
    if (!mounted) return;
    _snack(ok ? t.anime_download_play_now_ok : t.anime_download_play_now_fail);
    if (ok) await _reloadPlans();
  }

  // ---------------------------------------------------------------- 渲染

  /// qb 未配置提示条（推送按钮禁用，浏览选种不禁）。
  Widget _buildQbHintBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.anime_download_qb_hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Jimaku key 输入行：仅初始 key 为空时显示，`onChanged` 直接持久化
  /// （与 [JimakuSubtitleDialog] 的 key 落偏好范式一致）。
  Widget _buildJimakuKeyField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _jimakuKeyCtrl,
        decoration: InputDecoration(
          labelText: t.video_jimaku_api_key,
          helperText: t.video_jimaku_api_key_hint,
          helperMaxLines: 2,
          isDense: true,
          prefixIcon: const Icon(Icons.vpn_key, size: 18),
        ),
        obscureText: true,
        onChanged: (String value) =>
            unawaited(ref.read(appProvider).setJimakuApiKey(value.trim())),
      ),
    );
  }

  /// 小徽标 chip（分辨率/组名/体积/seeders/字幕覆盖等）。
  Widget _miniChip(
    ThemeData theme,
    String label, {
    IconData? icon,
    Color? background,
    Color? foreground,
  }) {
    final Color fg = foreground ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 2),
          ],
          Text(label, style: TextStyle(fontSize: 11, color: fg)),
        ],
      ),
    );
  }

  // ---- 阶段 1：搜番 ----

  Widget _buildAnimeSearchStage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildGenericMagnetSection(theme),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _animeQueryCtrl,
                decoration: InputDecoration(
                  labelText: t.anime_download_search_hint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onSubmitted: (_) => _searchAnime(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _searchingAnime ? null : _searchAnime,
              child: Text(t.anime_download_search),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildAnimeResults(theme)),
      ],
    );
  }

  /// 通用下载区（折叠）：粘贴磁力链接 + 选内容类型（自动/视频/书）+ 直接下载，
  /// 不经番剧搜索流程。可下书、视频等任意种子；完成后按类型自动入库
  /// （视频→视频库、epub→阅读库）。
  Widget _buildGenericMagnetSection(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: const Icon(Icons.link, size: 18),
        title: Text(t.anime_download_generic_title),
        children: <Widget>[
          TextField(
            controller: _magnetCtrl,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: t.anime_download_generic_hint,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindAuto,
                      label: Text(t.anime_download_kind_auto),
                    ),
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindVideo,
                      label: Text(t.anime_download_kind_video),
                    ),
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindBook,
                      label: Text(t.anime_download_kind_book),
                    ),
                  ],
                  selected: <String>{_genericKind},
                  onSelectionChanged: _pushingGeneric
                      ? null
                      : (Set<String> s) =>
                          setState(() => _genericKind = s.first),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed:
                    (!_backendReady || _pushingGeneric) ? null : _pushGeneric,
                icon: const Icon(Icons.download, size: 18),
                label: Text(t.anime_download_generic_download),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 通用磁力推送：走共享 [pushGenericMagnet]（首用同意 → 解析 → 落计划 →
  /// 推后端），与独立下载页同一逻辑。
  Future<void> _pushGeneric() async {
    if (_pushingGeneric) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _pushingGeneric = true);
    final GenericPushOutcome outcome = await pushGenericMagnet(
      context: context,
      appModel: appModel,
      magnet: _magnetCtrl.text,
      contentKind: _genericKind,
    );
    if (!mounted) return;
    setState(() => _pushingGeneric = false);
    _snack(genericPushMessage(outcome));
    if (outcome == GenericPushOutcome.ok) {
      _magnetCtrl.clear();
      await _reloadPlans();
    }
  }

  Widget _buildAnimeResults(ThemeData theme) {
    if (_searchingAnime) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchedAnime && _animeMatches.isEmpty) {
      return Center(child: Text(t.anime_download_no_results));
    }
    if (_animeMatches.isEmpty) {
      return Center(
        child: Icon(
          Icons.travel_explore,
          size: 48,
          color: theme.colorScheme.outlineVariant,
        ),
      );
    }
    return ListView.builder(
      itemCount: _animeMatches.length,
      itemBuilder: (BuildContext context, int i) {
        final AniListMedia media = _animeMatches[i];
        final List<String> parts = <String>[
          if (media.seasonYear != null) '${media.seasonYear}',
          if (media.episodes != null) 'EP ${media.episodes}',
        ];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.live_tv_outlined),
          title: Text(
            media.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
          onTap: () => _selectMedia(media),
        );
      },
    );
  }

  // ---- 阶段 2：选种 ----

  Widget _buildTorrentStage(ThemeData theme) {
    final AniListMedia media = _selectedMedia!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: t.anime_download_back,
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: _clearSelectedMedia,
            ),
            Expanded(
              child: Text(
                media.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _nyaaQueryCtrl,
          decoration: InputDecoration(
            labelText: t.anime_download_nyaa_query,
            isDense: true,
            suffixIcon: IconButton(
              tooltip: t.anime_download_search,
              icon: const Icon(Icons.search, size: 20),
              onPressed: _loadingTorrents ? null : _fetchTorrents,
            ),
          ),
          onSubmitted: (_) => _fetchTorrents(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final (String id, String label) in <(String, String)>[
              ('1_0', t.anime_download_category_all),
              ('1_4', t.anime_download_category_raw),
              ('1_2', t.anime_download_category_english),
              ('1_3', t.anime_download_category_non_english),
            ])
              ChoiceChip(
                label: Text(label),
                visualDensity: VisualDensity.compact,
                selected: _category == id,
                onSelected:
                    _loadingTorrents ? null : (_) => _selectCategory(id),
              ),
            FilterChip(
              label: Text(t.anime_download_trusted_only),
              visualDensity: VisualDensity.compact,
              selected: _trustedOnly,
              onSelected: _loadingTorrents ? null : _toggleTrustedOnly,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildTorrentResults(theme)),
      ],
    );
  }

  Widget _buildTorrentResults(ThemeData theme) {
    if (_loadingTorrents) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_torrentsLoaded && _torrents.isEmpty) {
      return Center(child: Text(t.anime_download_no_results));
    }
    return ListView.builder(
      itemCount: _torrents.length,
      itemBuilder: (BuildContext context, int i) {
        final NyaaTorrent torrent = _torrents[i];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            torrent.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _torrentChips(theme, torrent),
            ),
          ),
          onTap: () => _selectTorrent(torrent),
        );
      },
    );
  }

  /// 单个种子行的徽标：分辨率/组名/体积/seeders/trusted/合集区间/字幕覆盖。
  List<Widget> _torrentChips(ThemeData theme, NyaaTorrent torrent) {
    final ColorScheme scheme = theme.colorScheme;
    final List<Widget> chips = <Widget>[];
    final String? resolution = torrent.resolution;
    if (resolution != null) chips.add(_miniChip(theme, resolution));
    final String? group = torrent.releaseGroup;
    if (group != null) chips.add(_miniChip(theme, group));
    if (torrent.sizeText.isNotEmpty) {
      chips.add(_miniChip(theme, torrent.sizeText));
    }
    chips.add(_miniChip(theme, '▲${torrent.seeders}',
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer));
    if (torrent.trusted) {
      chips.add(_miniChip(theme, 'Trusted',
          icon: Icons.verified_outlined,
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer));
    }
    if (torrent.isBatch) {
      final (int, int)? range = torrent.episodeRange;
      final String label = range == null
          ? t.anime_download_batch
          : '${range.$1.toString().padLeft(2, '0')}'
              '-${range.$2.toString().padLeft(2, '0')}';
      chips.add(_miniChip(theme, label, icon: Icons.stacked_bar_chart));
    }
    if (_jimakuLoaded) {
      final ({int covered, int? total}) coverage =
          jimakuCoverageFor(torrent, _jimakuIndex);
      if (coverage.covered == 0) {
        chips.add(_miniChip(theme, t.anime_download_no_subs,
            foreground: scheme.outline));
      } else {
        final String label = coverage.total == null
            ? '${t.anime_download_subs_badge} ?'
            : '${t.anime_download_subs_badge} '
                '${coverage.covered}/${coverage.total}';
        chips.add(_miniChip(theme, label,
            icon: Icons.subtitles_outlined,
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer));
      }
    }
    return chips;
  }

  // ---- 阶段 3：确认推送 ----

  Widget _buildConfirmStage(ThemeData theme) {
    final NyaaTorrent torrent = _selectedTorrent!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: t.anime_download_back,
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: _pushing ? null : _clearSelectedTorrent,
            ),
            Expanded(
              child: Text(
                torrent.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_chosenSubs.isNotEmpty)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(t.anime_download_include_subs),
            value: _includeSubs,
            onChanged: _pushing
                ? null
                : (bool value) => setState(() => _includeSubs = value),
          ),
        Expanded(child: _buildChosenSubsList(theme)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: (_qbMissing || _pushing) ? null : _push,
          icon: _pushing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(t.anime_download_push),
        ),
      ],
    );
  }

  Widget _buildChosenSubsList(ThemeData theme) {
    if (_chosenSubs.isEmpty) {
      return Center(
        child: Text(
          t.anime_download_no_subs,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: _chosenSubs.length,
      itemBuilder: (BuildContext context, int i) {
        final (int? episode, JimakuFile file) = _chosenSubs[i];
        final String? language = detectSubtitleLanguage(file.name);
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: SizedBox(
            width: 36,
            child: Text(
              episode == null ? '—' : '#$episode',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium,
            ),
          ),
          title: Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          trailing: language == null
              ? null
              : _miniChip(theme, jimakuLanguageLabel(language)),
        );
      },
    );
  }

  // ---- 下载任务折叠区 ----

  Widget _buildTasksSection(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        '${t.anime_download_tasks} (${_plans.length})',
        style: theme.textTheme.titleSmall,
      ),
      onExpansionChanged: (bool expanded) {
        if (expanded) unawaited(_reloadPlans());
      },
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: _plans.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    t.anime_download_no_tasks,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _plans.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _buildPlanRow(theme, _plans[i]),
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _refreshPlans,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.anime_download_refresh),
          ),
        ),
      ],
    );
  }

  Widget _buildPlanRow(ThemeData theme, AnimeDownloadPlan plan) {
    final ColorScheme scheme = theme.colorScheme;
    final Widget statusIcon = switch (plan.status) {
      AnimeDownloadPlan.statusImported =>
        Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      AnimeDownloadPlan.statusFailed => Tooltip(
          message: plan.failReason ?? '',
          child: Icon(Icons.error_outline, size: 20, color: scheme.error),
        ),
      _ => const SizedBox(
          width: 20,
          height: 20,
          child: Padding(
            padding: EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: statusIcon,
      title: Text(
        plan.seriesTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        plan.torrentTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (plan.status == AnimeDownloadPlan.statusDownloading)
            IconButton(
              tooltip: t.anime_download_play_now,
              icon: const Icon(Icons.play_circle_outline, size: 20),
              onPressed: () => _playNow(plan),
            ),
          IconButton(
            tooltip: t.anime_download_delete,
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _deletePlan(plan),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget stage;
    if (_selectedMedia == null) {
      stage = _buildAnimeSearchStage(theme);
    } else if (_selectedTorrent == null) {
      stage = _buildTorrentStage(theme);
    } else {
      stage = _buildConfirmStage(theme);
    }
    // scrollable:false：maxHeight 给整个对话框有界高度，Flexible 正常分配空间、
    // 各阶段内部 ListView 正常滚动（同 JimakuSubtitleDialog 的 BUG-279 不变量）。
    return HibikiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.anime_download_title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_qbMissing) _buildQbHintBanner(theme),
          if (_showJimakuKeyField) _buildJimakuKeyField(),
          Flexible(child: stage),
          const SizedBox(height: 4),
          _buildTasksSection(theme),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
          ),
        ],
      ),
    );
  }
}
