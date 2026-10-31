import 'dart:async';

import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiModalSheetFrame, FushiSearchField, FushiTextField;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 电脑在线字幕检索的一条候选（`subtitleSearch` 的一项）。[id] 对手机不透明，
/// 只用来让电脑下载这一条。
@immutable
class VideoRemoteSubtitleCandidate {
  const VideoRemoteSubtitleCandidate({
    required this.id,
    required this.fileName,
    this.provider = '',
    this.language,
    this.episode,
    this.aiTranslated = false,
    this.hearingImpaired = false,
  });

  factory VideoRemoteSubtitleCandidate.fromJson(Map<String, dynamic> json) =>
      VideoRemoteSubtitleCandidate(
        id: json['id']?.toString() ?? '',
        fileName: json['fileName']?.toString() ?? '',
        provider: json['provider']?.toString() ?? '',
        language: json['language']?.toString(),
        episode: (json['episode'] as num?)?.toInt(),
        aiTranslated: json['aiTranslated'] == true,
        hearingImpaired: json['hearingImpaired'] == true,
      );

  final String id;
  final String fileName;

  /// 来源 id（`jimaku` / `opensubtitles` …）。
  final String provider;
  final String? language;
  final int? episode;
  final bool aiTranslated;
  final bool hearingImpaired;
}

/// 一次 `subtitleSearch` 的结果。[query] / [episode] 是电脑实际用的检索词与集号
/// （手机没填时是电脑按当前视频推出来的默认值，用来预填输入框）。
@immutable
class VideoRemoteSubtitleSearchResult {
  const VideoRemoteSubtitleSearchResult({
    required this.query,
    required this.candidates,
    this.episode,
  });

  factory VideoRemoteSubtitleSearchResult.fromJson(Map<String, dynamic> json) =>
      VideoRemoteSubtitleSearchResult(
        query: json['query']?.toString() ?? '',
        episode: (json['episode'] as num?)?.toInt(),
        candidates: <VideoRemoteSubtitleCandidate>[
          for (final Object? item in json['candidates'] as List? ?? <Object?>[])
            if (item is Map)
              VideoRemoteSubtitleCandidate.fromJson(
                Map<String, dynamic>.from(item),
              ),
        ],
      );

  final String query;
  final int? episode;
  final List<VideoRemoteSubtitleCandidate> candidates;
}

/// 让电脑检索：[query] / [episode] 为 null = 用电脑按当前视频推出的默认值。
typedef VideoRemoteSubtitleSearcher =
    Future<VideoRemoteSubtitleSearchResult> Function(
      String? query,
      int? episode,
    );

/// 让电脑下载候选 [candidateId] 并应用为主字幕。
typedef VideoRemoteSubtitleDownloader =
    Future<void> Function(String candidateId);

/// 在线字幕弹层：打开即按电脑的默认检索词搜一次，可改词 / 集号重搜；点一条让电脑
/// 下载并应用，成功后关闭并返回 true。失败原因留在弹层里（[errorText] 把异常转成
/// 本地化文案），不关闭。
Future<bool> showVideoRemoteSubtitleSearchSheet({
  required BuildContext context,
  required VideoRemoteSubtitleSearcher search,
  required VideoRemoteSubtitleDownloader download,
  required String Function(Object error) errorText,
}) async =>
    await adaptiveModalSheet<bool>(
      context: context,
      builder: (BuildContext sheetContext) => VideoRemoteSubtitleSearchSheet(
        search: search,
        download: download,
        errorText: errorText,
        onApplied: () => Navigator.of(sheetContext).pop(true),
      ),
    ) ==
    true;

/// [showVideoRemoteSubtitleSearchSheet] 的内容（单独成组件便于测试）。
class VideoRemoteSubtitleSearchSheet extends StatefulWidget {
  const VideoRemoteSubtitleSearchSheet({
    super.key,
    required this.search,
    required this.download,
    required this.errorText,
    required this.onApplied,
  });

  final VideoRemoteSubtitleSearcher search;
  final VideoRemoteSubtitleDownloader download;
  final String Function(Object error) errorText;
  final VoidCallback onApplied;

  @override
  State<VideoRemoteSubtitleSearchSheet> createState() =>
      _VideoRemoteSubtitleSearchSheetState();
}

class _VideoRemoteSubtitleSearchSheetState
    extends State<VideoRemoteSubtitleSearchSheet> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _episode = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  List<VideoRemoteSubtitleCandidate> _candidates =
      const <VideoRemoteSubtitleCandidate>[];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  /// 正在让电脑下载的那条（期间其余行禁用）。
  String? _downloading;

  /// 只认最近一次检索的结果（改词连点时丢弃旧回包）。
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run(useDefaults: true));
  }

  @override
  void dispose() {
    _query.dispose();
    _episode.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _run({bool useDefaults = false}) async {
    final String query = _query.text.trim();
    if (!useDefaults && query.isEmpty) return;
    final int serial = ++_serial;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final VideoRemoteSubtitleSearchResult result = await widget.search(
        useDefaults ? null : query,
        useDefaults ? null : int.tryParse(_episode.text.trim()),
      );
      if (!mounted || serial != _serial) return;
      setState(() {
        if (useDefaults) {
          _query.text = result.query;
          _episode.text = result.episode?.toString() ?? '';
        }
        _candidates = result.candidates;
        _searching = false;
        _searched = true;
      });
    } catch (error) {
      if (!mounted || serial != _serial) return;
      setState(() {
        _candidates = const <VideoRemoteSubtitleCandidate>[];
        _searching = false;
        _searched = true;
        _error = widget.errorText(error);
      });
    }
  }

  Future<void> _pick(VideoRemoteSubtitleCandidate candidate) async {
    if (_downloading != null) return;
    setState(() {
      _downloading = candidate.id;
      _error = null;
    });
    try {
      await widget.download(candidate.id);
      if (!mounted) return;
      widget.onApplied();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = widget.errorText(error));
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.video_subtitle_search_open,
      leadingIcon: FushiIcons.subtitles,
      maxHeightFactor: 0.86,
      // 整块可滚：横屏手机弹出软键盘后弹层只剩 ~110dp，搜索框一行加结果列表放不下，
      // 原来的 Column 会溢出并把结果列表挤成 0；现在在弹层给的高度内滚动。
      body: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>(
                    'video-remote-subtitle-search-query',
                  ),
                  controller: _query,
                  focusNode: _queryFocus,
                  hintText: t.video_jimaku_query,
                  onChanged: (_) {},
                  onSubmitted: (_) => unawaited(_run()),
                  onClear: _query.clear,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: FushiTextField(
                  key: const ValueKey<String>(
                    'video-remote-subtitle-search-episode',
                  ),
                  controller: _episode,
                  labelText: t.video_jimaku_episode,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  onSubmitted: (_) => unawaited(_run()),
                ),
              ),
              const SizedBox(width: 4),
              FushiIconButton(
                key: const ValueKey<String>('video-remote-subtitle-search-go'),
                icon: FushiIcons.search,
                tooltip: t.video_jimaku_search,
                enabled: !_searching,
                onTap: () => unawaited(_run()),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                _error!,
                key: const ValueKey<String>(
                  'video-remote-subtitle-search-error',
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          _list(context),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: FushiCircularProgressIndicator()),
      );
    }
    if (_candidates.isEmpty) {
      if (!_searched || _error != null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          t.video_jimaku_no_results,
          key: const ValueKey<String>('video-remote-subtitle-search-empty'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return FushiEntranceScope(
      replayKey: _serial,
      child: ListView.builder(
        key: const ValueKey<String>('video-remote-subtitle-search-list'),
        shrinkWrap: true,
        // 外层 ListView 负责滚动，这里只负责按内容撑高。
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _candidates.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => _tile(_candidates[i]),
        ),
      ),
    );
  }

  Widget _tile(VideoRemoteSubtitleCandidate candidate) {
    final bool busy = _downloading == candidate.id;
    final String? language = candidate.language;
    final String subtitle = <String>[
      if (candidate.provider.isNotEmpty) candidate.provider,
      if (language != null && language.isNotEmpty) language,
      if (candidate.aiTranslated) 'AI',
      if (candidate.hearingImpaired) 'SDH',
    ].join(' · ');
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('video-remote-subtitle-${candidate.id}'),
        leading: const FushiIcon(FushiIcons.subtitles),
        title: Text(
          candidate.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: FushiCircularProgressIndicator(),
              )
            : null,
        onTap: _downloading == null ? () => unawaited(_pick(candidate)) : null,
      ),
    );
  }
}
