import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/models.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_batch.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi/src/pages/implementations/jimaku_api_key_field.dart';
import 'package:fushi/src/pages/implementations/jimaku_entry_picker.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

typedef JimakuBatchHttpClientFactory = Future<http.Client> Function();

/// 「为整个合集获取字幕」批量对话框：把合集绑定到一个 AniList 系列（快照 anilist_id），
/// 再对合集里每一集经 Jimaku 按集号拉最佳字幕、下载、持久化——本地集落 DB（subtitleSource
/// 列 + cue），远端/流媒体集落 prefs（`<bookUid>#ep`）。逐集显示状态，尽力而为（单集失败
/// 不中断整批）。
///
/// 真实拉取需有效 Jimaku API key + 联网（device/network 验证待用户）。
class JimakuBatchDialog extends ConsumerStatefulWidget {
  const JimakuBatchDialog({
    required this.database,
    required this.collection,
    required this.members,
    this.httpClientFactory,
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 合集里**有序**的视频成员（调用方已按 sortIndex 加载）。
  final List<VideoBookRow> members;

  /// 测试注入点；生产路径为空时仍统一走 AppModel 的代理感知客户端工厂。
  final JimakuBatchHttpClientFactory? httpClientFactory;

  @override
  ConsumerState<JimakuBatchDialog> createState() => _JimakuBatchDialogState();
}

class _JimakuBatchDialogState extends ConsumerState<JimakuBatchDialog> {
  AppModel get appModel => ref.read(appProvider);

  Future<http.Client> _createHttpClient() =>
      widget.httpClientFactory?.call() ?? appModel.createDownloadHttpClient();

  late final VideoBookRepository _repo = VideoBookRepository(widget.database);
  late final TextEditingController _apiKeyCtrl =
      TextEditingController(text: appModel.jimakuApiKey);
  late final TextEditingController _queryCtrl =
      TextEditingController(text: _initialQuery());

  /// 合集名归一（小写 trim）作按系列记忆语言的 key，与单集对话框约定一致。
  String get _seriesKey => widget.collection.name.trim().toLowerCase();

  bool _resolving = false; // 正在解析 AniList 系列
  bool _running = false; // 正在批量下载
  List<AniListMedia> _seriesMatches = const <AniListMedia>[];
  int? _selectedSeriesId;
  List<JimakuEntry> _entries = const <JimakuEntry>[];
  int? _selectedEntryId;
  String? _preferredLanguage;

  /// 每个 Jimaku 来源的文本字幕清单。来源搜索完成后立即预取一次，选来源和点下载前
  /// 就能看到文件数、覆盖集数、语言与逐集可用性。
  final Map<int, JimakuFileInventory> _inventories =
      <int, JimakuFileInventory>{};
  final Set<int> _loadingInventoryIds = <int>{};
  final Set<int> _failedInventoryIds = <int>{};
  int _inventoryGeneration = 0;
  int _seriesResolutionGeneration = 0;

  /// 逐集状态：bookUid → item（下载推进时更新）。
  final Map<String, JimakuBatchItem> _statusByUid = <String, JimakuBatchItem>{};

  String _initialQuery() {
    // 合集名可能带画质/集数 tag，先过一道文件名解析收敛成系列名。
    final String series = parseVideoFilename(widget.collection.name).series;
    return series.isEmpty ? widget.collection.name : series;
  }

  @override
  void initState() {
    super.initState();
    // 语言优先级：该系列记住的选择 → 设置页的默认字幕语言 → 不限。
    _preferredLanguage = appModel.jimakuPreferredLanguages[_seriesKey] ??
        appModel.jimakuDefaultLanguageOrNull;
    _selectedSeriesId = widget.collection.anilistId;
    // 合集已绑定 AniList 系列 → 直接解析 Jimaku 条目，免去用户再点一次。
    if (widget.collection.anilistId != null) {
      _resolveEntriesForSeries(widget.collection.anilistId!);
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 解析 AniList 系列候选（用户点「解析系列」）：命中后默认选首条并解析其 Jimaku 条目。
  Future<void> _resolveSeries() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    final String query = _queryCtrl.text.trim();
    if (apiKey.isEmpty) {
      _snack(t.video_jimaku_no_key);
      return;
    }
    if (query.isEmpty) return;
    await appModel.setJimakuApiKey(apiKey);
    final int generation = ++_seriesResolutionGeneration;
    setState(() {
      _resolving = true;
      _seriesMatches = const <AniListMedia>[];
      _entries = const <JimakuEntry>[];
      _selectedEntryId = null;
      _inventories.clear();
      _loadingInventoryIds.clear();
      _failedInventoryIds.clear();
      _inventoryGeneration++;
    });
    AniListClient? anilist;
    try {
      anilist = AniListClient(
        client: await _createHttpClient(),
      );
      final List<AniListMedia> media = await anilist.searchAnime(query);
      if (!mounted || generation != _seriesResolutionGeneration) return;
      setState(() => _seriesMatches = media);
      if (media.isNotEmpty) {
        await _selectSeries(
          media.first,
          persist: true,
          generation: generation,
        );
      } else {
        // AniList 无命中 → 用文本直接搜 Jimaku 条目（无 anilist 绑定）。
        await _resolveEntriesByQuery(query, generation: generation);
      }
    } finally {
      anilist?.close();
      if (mounted && generation == _seriesResolutionGeneration) {
        setState(() => _resolving = false);
      }
    }
  }

  /// 用户点某系列 chip：绑定该系列、快照 anilist_id 到合集、解析其 Jimaku 条目。
  Future<void> _selectSeries(
    AniListMedia media, {
    bool persist = false,
    int? generation,
  }) async {
    final int requestGeneration = generation ?? ++_seriesResolutionGeneration;
    setState(() {
      _selectedSeriesId = media.id;
      _entries = const <JimakuEntry>[];
      _selectedEntryId = null;
      _inventories.clear();
      _loadingInventoryIds.clear();
      _failedInventoryIds.clear();
      _inventoryGeneration++;
    });
    if (persist || widget.collection.anilistId != media.id) {
      await widget.database
          .setMediaCollectionAnilistId(widget.collection.id, media.id);
      if (!mounted || requestGeneration != _seriesResolutionGeneration) {
        // 旧选择的慢 DB 写可能晚于新选择落库；以当前 UI 选择重申一次，避免数据库
        // 最终回退到旧 AniList id。
        final int? latestSeriesId = _selectedSeriesId;
        if (latestSeriesId != null) {
          await widget.database.setMediaCollectionAnilistId(
            widget.collection.id,
            latestSeriesId,
          );
        }
        return;
      }
    }
    await _resolveEntriesForSeries(
      media.id,
      generation: requestGeneration,
    );
  }

  Future<void> _resolveEntriesForSeries(
    int anilistId, {
    int? generation,
  }) async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) return;
    final int requestGeneration = generation ?? ++_seriesResolutionGeneration;
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await _createHttpClient(),
      );
      final List<JimakuEntry> entries =
          await jimaku.searchByAnilistId(anilistId);
      if (!mounted ||
          requestGeneration != _seriesResolutionGeneration ||
          _selectedSeriesId != anilistId) {
        return;
      }
      _setEntries(entries);
    } finally {
      jimaku?.close();
    }
  }

  Future<void> _resolveEntriesByQuery(
    String query, {
    required int generation,
  }) async {
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: _apiKeyCtrl.text.trim(),
        client: await _createHttpClient(),
      );
      final List<JimakuEntry> entries = await jimaku.searchByQuery(query);
      if (!mounted || generation != _seriesResolutionGeneration) return;
      setState(() => _selectedSeriesId = null);
      _setEntries(entries);
    } finally {
      jimaku?.close();
    }
  }

  Future<void> _selectLanguage(String? lang) async {
    setState(() => _preferredLanguage = lang);
    if (lang != null) {
      await appModel.setJimakuPreferredLanguage(_seriesKey, lang);
    }
  }

  void _setEntries(List<JimakuEntry> entries) {
    final int generation = ++_inventoryGeneration;
    setState(() {
      _entries = entries;
      _selectedEntryId = entries.isEmpty ? null : entries.first.id;
      _inventories.clear();
      _failedInventoryIds.clear();
      _loadingInventoryIds
        ..clear()
        ..addAll(entries.map((JimakuEntry entry) => entry.id));
    });
    if (entries.isNotEmpty) {
      unawaited(_loadEntryInventories(entries, generation));
    }
  }

  /// 一条来源只列一次全部文件；不按「来源 × 集数」制造几十次请求。文件名里的集号与
  /// 语言标记足够构造来源摘要和逐集预览。严格模式保留请求异常，避免断网被画成「0 字幕」。
  Future<void> _loadEntryInventories(
    List<JimakuEntry> entries,
    int generation,
  ) async {
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: _apiKeyCtrl.text.trim(),
        client: await _createHttpClient(),
      );
      for (final JimakuEntry entry in entries) {
        try {
          final List<JimakuFile> files = await jimaku.listFiles(
            entry.id,
            throwOnError: true,
          );
          if (!mounted || generation != _inventoryGeneration) return;
          setState(() {
            _loadingInventoryIds.remove(entry.id);
            _inventories[entry.id] = JimakuFileInventory.fromFiles(files);
          });
        } catch (_) {
          if (!mounted || generation != _inventoryGeneration) return;
          setState(() {
            _loadingInventoryIds.remove(entry.id);
            _failedInventoryIds.add(entry.id);
          });
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'JimakuBatchDialog.loadEntryInventories',
        e,
        stack,
      );
      if (!mounted || generation != _inventoryGeneration) return;
      setState(() {
        for (final JimakuEntry entry in entries) {
          if (_loadingInventoryIds.remove(entry.id)) {
            _failedInventoryIds.add(entry.id);
          }
        }
      });
    } finally {
      jimaku?.close();
    }
  }

  JimakuBatchTarget _targetAt(int index) {
    final VideoBookRow member = widget.members[index];
    return JimakuBatchTarget(
      bookUid: member.bookUid,
      title: member.title,
      videoPath: member.videoPath,
      sortIndex: index,
      isStream: isStreamVideoBook(member),
    );
  }

  List<JimakuBatchTarget> _targets() => <JimakuBatchTarget>[
        for (int i = 0; i < widget.members.length; i++) _targetAt(i),
      ];

  /// 运行批量下载：对每集列文件→挑最佳→下载→持久化（本地落 DB / 远端落 prefs）。
  Future<void> _downloadAll() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) {
      _snack(t.video_jimaku_no_key);
      return;
    }
    final int? entryId = _selectedEntryId;
    if (entryId == null) {
      _snack(t.video_jimaku_no_results);
      return;
    }
    final String saveDir = (await AppPaths.videoSubtitlesDirectory()).path;
    if (!mounted) return;
    setState(() {
      _running = true;
      _statusByUid.clear();
    });
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await _createHttpClient(),
      );
      await runJimakuBatch(
        client: jimaku,
        entryIds: <int>[entryId],
        targets: _targets(),
        saveDirectory: saveDir,
        preferredLanguage: _preferredLanguage,
        onItemStart: (JimakuBatchItem item) async {
          if (!mounted) return;
          setState(() => _statusByUid[item.target.bookUid] = item);
        },
        onItemDone: (JimakuBatchItem item) async {
          await _persist(item);
          if (!mounted) return;
          setState(() => _statusByUid[item.target.bookUid] = item);
        },
      );
    } finally {
      jimaku?.close();
      if (mounted) setState(() => _running = false);
    }
    if (mounted) {
      final int done = _statusByUid.values
          .where((JimakuBatchItem i) => i.status == JimakuBatchStatus.done)
          .length;
      _snack(
          t.video_jimaku_batch_done(done: done, total: widget.members.length));
    }
  }

  /// 单集持久化：本地视频写 DB（subtitleSource 列 + 解析的 cue），远端/流媒体写 prefs。
  Future<void> _persist(JimakuBatchItem item) async {
    if (item.status != JimakuBatchStatus.done || item.subtitlePath == null) {
      return;
    }
    final JimakuBatchTarget target = item.target;
    final String path = item.subtitlePath!;
    if (target.isStream) {
      // 远端/流媒体：无本地 DB 行可写，落 prefs（episodeIndex 0 = 该 stream book 自身）。
      await appModel.setRemoteSubtitleSource(target.bookUid, 0, path);
    } else {
      // 本地：解析 cue + 原子写 subtitleSource 列（与单集 _selectSubtitleSource 同链路）。
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
  }

  Widget _statusIcon(String bookUid, int memberIndex) {
    final JimakuBatchItem? item = _statusByUid[bookUid];
    if (item != null) {
      switch (item.status) {
        case JimakuBatchStatus.downloading:
          return const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        case JimakuBatchStatus.done:
          return const Icon(Icons.check_circle, size: 18, color: Colors.green);
        case JimakuBatchStatus.noMatch:
          return const Icon(Icons.search_off, size: 18);
        case JimakuBatchStatus.failed:
          return const Icon(Icons.error_outline, size: 18, color: Colors.red);
        case JimakuBatchStatus.pending:
          return const Icon(Icons.schedule, size: 18);
      }
    }
    final int? entryId = _selectedEntryId;
    if (entryId == null) return const Icon(Icons.remove, size: 18);
    if (_loadingInventoryIds.contains(entryId)) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_failedInventoryIds.contains(entryId)) {
      return const Icon(Icons.error_outline, size: 18, color: Colors.red);
    }
    final JimakuFileInventory? inventory = _inventories[entryId];
    if (inventory == null) return const Icon(Icons.remove, size: 18);
    final int episode = resolveBatchEpisode(_targetAt(memberIndex));
    return inventory.filesForEpisode(episode).isEmpty
        ? const Icon(Icons.search_off, size: 18)
        : const Icon(Icons.check_circle_outline, size: 18, color: Colors.green);
  }

  Widget? _episodeSubtitle(VideoBookRow member, int memberIndex) {
    final JimakuBatchItem? item = _statusByUid[member.bookUid];
    if (item != null) {
      switch (item.status) {
        case JimakuBatchStatus.done:
          return Text(
            item.language == null
                ? t.video_jimaku_downloaded
                : '${t.video_jimaku_downloaded} · '
                    '${jimakuLanguageLabel(item.language!)}',
          );
        case JimakuBatchStatus.noMatch:
          return Text(t.video_jimaku_no_results);
        case JimakuBatchStatus.failed:
          return Text(t.video_jimaku_download_failed);
        case JimakuBatchStatus.downloading:
        case JimakuBatchStatus.pending:
          return Text(t.video_jimaku_source_loading);
      }
    }
    final int? entryId = _selectedEntryId;
    if (entryId == null) return null;
    if (_loadingInventoryIds.contains(entryId)) {
      return Text(t.video_jimaku_source_loading);
    }
    if (_failedInventoryIds.contains(entryId)) {
      return Text(t.video_jimaku_source_failed);
    }
    final JimakuFileInventory? inventory = _inventories[entryId];
    if (inventory == null) return Text(t.video_jimaku_source_hint);
    final int episode = resolveBatchEpisode(_targetAt(memberIndex));
    final List<JimakuFile> matches = inventory.filesForEpisode(episode);
    if (matches.isEmpty) {
      if (inventory.unlabeledCount > 0) {
        return Text(
          t.video_jimaku_episode_unlabeled(
            episode: episode,
            count: inventory.unlabeledCount,
          ),
        );
      }
      return Text(t.video_jimaku_episode_unavailable(episode: episode));
    }
    final Set<String> languages = <String>{
      for (final JimakuFile file in matches)
        if (detectSubtitleLanguage(file.name) != null)
          detectSubtitleLanguage(file.name)!,
    };
    final String languageText = languages.isEmpty
        ? t.video_jimaku_language_unknown
        : languages.map(jimakuLanguageLabel).join(' / ');
    return Text(
      t.video_jimaku_episode_available(
        count: matches.length,
        languages: languageText,
      ),
    );
  }

  /// 「标签在上、chip 在下」分区（与单集对话框 _chipSection 同款清爽排版）：标签弱化，
  /// chip 8/8 均匀间距，长番名 chip 由调用方夹 maxWidth。
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
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canDownload = canDownloadJimakuInventory(
      selectedEntryId: _selectedEntryId,
      inventories: _inventories,
      loadingEntryIds: _loadingInventoryIds,
      failedEntryIds: _failedInventoryIds,
    );
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
          Text(t.video_jimaku_batch_title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
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
                        onPressed:
                            _resolving || _running ? null : _resolveSeries,
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
                                : (_) => _selectSeries(media),
                          ),
                        ),
                    ]),
                  if (_entries.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    JimakuEntryPicker(
                      entries: _entries,
                      selectedEntryId: _selectedEntryId,
                      inventories: _inventories,
                      loadingEntryIds: _loadingInventoryIds,
                      failedEntryIds: _failedInventoryIds,
                      enabled: !_running,
                      onSelected: (JimakuEntry entry) =>
                          setState(() => _selectedEntryId = entry.id),
                    ),
                  ],
                  _chipSection(t.video_jimaku_language, <Widget>[
                    JimakuLanguagePicker(
                      selectedLanguage: _preferredLanguage,
                      enabled: !_running,
                      onSelected: _selectLanguage,
                    ),
                  ]),
                ],
              ),
            ),
          ),
          const Divider(height: 20),
          // 成员逐集列表 + 状态。
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
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              TextButton(
                onPressed: _running ? null : () => Navigator.pop(context),
                child: Text(t.dialog_close),
              ),
              FilledButton.icon(
                onPressed: _running || !canDownload ? null : _downloadAll,
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
      ),
    );
  }
}
