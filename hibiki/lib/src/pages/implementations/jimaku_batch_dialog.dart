import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_batch.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/media/video/stream_video_launch.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart'
    show jimakuLanguageLabel;
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 合集里**有序**的视频成员（调用方已按 sortIndex 加载）。
  final List<VideoBookRow> members;

  @override
  ConsumerState<JimakuBatchDialog> createState() => _JimakuBatchDialogState();
}

class _JimakuBatchDialogState extends ConsumerState<JimakuBatchDialog> {
  AppModel get appModel => ref.read(appProvider);

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
  List<int> _entryIds = const <int>[];
  String? _preferredLanguage;

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
    _preferredLanguage = appModel.jimakuPreferredLanguages[_seriesKey];
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
    setState(() {
      _resolving = true;
      _seriesMatches = const <AniListMedia>[];
    });
    final AniListClient anilist = AniListClient();
    try {
      final List<AniListMedia> media = await anilist.searchAnime(query);
      if (!mounted) return;
      setState(() => _seriesMatches = media);
      if (media.isNotEmpty) {
        await _selectSeries(media.first, persist: true);
      } else {
        // AniList 无命中 → 用文本直接搜 Jimaku 条目（无 anilist 绑定）。
        await _resolveEntriesByQuery(query);
      }
    } finally {
      anilist.close();
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// 用户点某系列 chip：绑定该系列、快照 anilist_id 到合集、解析其 Jimaku 条目。
  Future<void> _selectSeries(AniListMedia media, {bool persist = false}) async {
    setState(() => _selectedSeriesId = media.id);
    if (persist || widget.collection.anilistId != media.id) {
      await widget.database
          .setMediaCollectionAnilistId(widget.collection.id, media.id);
    }
    await _resolveEntriesForSeries(media.id);
  }

  Future<void> _resolveEntriesForSeries(int anilistId) async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) return;
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey);
    try {
      final List<JimakuEntry> entries =
          await jimaku.searchByAnilistId(anilistId);
      if (!mounted) return;
      setState(() => _entryIds = entries.map((JimakuEntry e) => e.id).toList());
    } finally {
      jimaku.close();
    }
  }

  Future<void> _resolveEntriesByQuery(String query) async {
    final JimakuClient jimaku = JimakuClient(apiKey: _apiKeyCtrl.text.trim());
    try {
      final List<JimakuEntry> entries = await jimaku.searchByQuery(query);
      if (!mounted) return;
      setState(() {
        _selectedSeriesId = null;
        _entryIds = entries.map((JimakuEntry e) => e.id).toList();
      });
    } finally {
      jimaku.close();
    }
  }

  Future<void> _selectLanguage(String? lang) async {
    setState(() => _preferredLanguage = lang);
    if (lang != null) {
      await appModel.setJimakuPreferredLanguage(_seriesKey, lang);
    }
  }

  List<JimakuBatchTarget> _targets() => <JimakuBatchTarget>[
        for (int i = 0; i < widget.members.length; i++)
          JimakuBatchTarget(
            bookUid: widget.members[i].bookUid,
            title: widget.members[i].title,
            videoPath: widget.members[i].videoPath,
            sortIndex: i,
            isStream: isStreamVideoBook(widget.members[i]),
          ),
      ];

  /// 运行批量下载：对每集列文件→挑最佳→下载→持久化（本地落 DB / 远端落 prefs）。
  Future<void> _downloadAll() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) {
      _snack(t.video_jimaku_no_key);
      return;
    }
    if (_entryIds.isEmpty) {
      _snack(t.video_jimaku_no_results);
      return;
    }
    final String saveDir = (await AppPaths.videoSubtitlesDirectory()).path;
    if (!mounted) return;
    setState(() {
      _running = true;
      _statusByUid.clear();
    });
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey);
    try {
      await runJimakuBatch(
        client: jimaku,
        entryIds: _entryIds,
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
      jimaku.close();
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

  Widget _statusIcon(String bookUid) {
    final JimakuBatchItem? item = _statusByUid[bookUid];
    if (item == null) {
      return const Icon(Icons.remove, size: 18);
    }
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasSeries = _entryIds.isNotEmpty;
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
                  TextField(
                    controller: _apiKeyCtrl,
                    decoration: InputDecoration(
                      labelText: t.video_jimaku_api_key,
                      helperText: t.video_jimaku_api_key_hint,
                      helperMaxLines: 2,
                      isDense: true,
                    ),
                    obscureText: true,
                  ),
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
                        label: Text(t.video_jimaku_series),
                      ),
                    ],
                  ),
                  if (_seriesMatches.length >= 2) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final AniListMedia media in _seriesMatches)
                          ChoiceChip(
                            label: Text(media.displayTitle),
                            selected: _selectedSeriesId == media.id,
                            onSelected: _resolving || _running
                                ? null
                                : (_) => _selectSeries(media),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text(t.video_jimaku_language,
                          style: theme.textTheme.labelMedium),
                      ChoiceChip(
                        label: Text(t.video_jimaku_language_all),
                        selected: _preferredLanguage == null,
                        onSelected:
                            _running ? null : (_) => _selectLanguage(null),
                      ),
                      for (final String lang in const <String>[
                        'ja',
                        'zh',
                        'en',
                        'ko'
                      ])
                        ChoiceChip(
                          label: Text(jimakuLanguageLabel(lang)),
                          selected: _preferredLanguage == lang,
                          onSelected:
                              _running ? null : (_) => _selectLanguage(lang),
                        ),
                    ],
                  ),
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
                final JimakuBatchItem? item = _statusByUid[m.bookUid];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _statusIcon(m.bookUid),
                  title: Text(
                    m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item != null && item.language != null
                      ? Text(jimakuLanguageLabel(item.language!))
                      : null,
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
                onPressed: _running || !hasSeries ? null : _downloadAll,
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
