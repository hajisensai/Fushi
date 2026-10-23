import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show subtitleProviderDisplayName;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem, FushiModalSheetFrame, FushiSearchField;
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 在线字幕搜索结果里的一条（电脑 `subtitleSearch.candidates` 的一项）。
@immutable
class VideoRemoteSubtitleResult {
  const VideoRemoteSubtitleResult({
    required this.handle,
    required this.provider,
    required this.fileName,
    this.language = '',
    this.episode,
    this.downloadCount = 0,
    this.aiTranslated = false,
    this.hearingImpaired = false,
  });

  factory VideoRemoteSubtitleResult.fromJson(Map<String, dynamic> json) =>
      VideoRemoteSubtitleResult(
        handle: json['handle']?.toString() ?? '',
        provider: json['provider']?.toString() ?? '',
        fileName: json['fileName']?.toString() ?? '',
        language: json['language']?.toString() ?? '',
        episode: (json['episode'] as num?)?.toInt(),
        downloadCount: (json['downloadCount'] as num?)?.toInt() ?? 0,
        aiTranslated: json['aiTranslated'] == true,
        hearingImpaired: json['hearingImpaired'] == true,
      );

  /// 交回电脑 `subtitleDownload` 的句柄（对手机不透明）。
  final String handle;
  final String provider;
  final String fileName;
  final String language;
  final int? episode;
  final int downloadCount;
  final bool aiTranslated;
  final bool hearingImpaired;
}

/// 一次 `subtitleSearch` 的结果。
@immutable
class VideoRemoteSubtitleSearchPage {
  const VideoRemoteSubtitleSearchPage({
    required this.query,
    required this.results,
    this.episode,
    this.error,
  });

  factory VideoRemoteSubtitleSearchPage.fromJson(Map<String, dynamic> json) =>
      VideoRemoteSubtitleSearchPage(
        query: json['query']?.toString() ?? '',
        episode: (json['episode'] as num?)?.toInt(),
        results: <VideoRemoteSubtitleResult>[
          for (final Object? item in json['candidates'] as List? ?? <Object?>[])
            if (item is Map)
              VideoRemoteSubtitleResult.fromJson(
                Map<String, dynamic>.from(item),
              ),
        ],
        error: json['error']?.toString(),
      );

  /// 电脑实际搜的词与集号（手机没给时是电脑自己的预填）。
  final String query;
  final int? episode;
  final List<VideoRemoteSubtitleResult> results;

  /// `no_source` / `search_failed` / `no_query`；null = 正常（可能 0 条）。
  final String? error;
}

/// 搜一次：[query] / [episode] 为 null 时让电脑用自己的预填。
typedef VideoRemoteSubtitleSearchLoader =
    Future<VideoRemoteSubtitleSearchPage> Function(String? query, int? episode);

/// 在线字幕搜索弹层：打开即按电脑的预填（番名 + 当前集）搜一次，可改词 / 集数
/// 重搜；点选一条返回它，关掉返回 null。下载与应用由调用方交给电脑。
Future<VideoRemoteSubtitleResult?> showVideoRemoteSubtitleSearchSheet({
  required BuildContext context,
  required VideoRemoteSubtitleSearchLoader search,
}) => adaptiveModalSheet<VideoRemoteSubtitleResult>(
  context: context,
  builder: (BuildContext sheetContext) => VideoRemoteSubtitleSearchSheet(
    search: search,
    onPick: (VideoRemoteSubtitleResult result) =>
        Navigator.of(sheetContext).pop(result),
  ),
);

/// [showVideoRemoteSubtitleSearchSheet] 的内容（单独成组件便于测试）。
class VideoRemoteSubtitleSearchSheet extends StatefulWidget {
  const VideoRemoteSubtitleSearchSheet({
    super.key,
    required this.search,
    required this.onPick,
  });

  final VideoRemoteSubtitleSearchLoader search;
  final ValueChanged<VideoRemoteSubtitleResult> onPick;

  @override
  State<VideoRemoteSubtitleSearchSheet> createState() =>
      _VideoRemoteSubtitleSearchSheetState();
}

class _VideoRemoteSubtitleSearchSheetState
    extends State<VideoRemoteSubtitleSearchSheet> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _episode = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final FocusNode _episodeFocus = FocusNode();
  List<VideoRemoteSubtitleResult> _results =
      const <VideoRemoteSubtitleResult>[];
  String? _error;
  bool _loading = false;
  bool _failed = false;

  /// 新一次搜索作废在飞的旧请求（结果按序号丢弃）。
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run(prefill: true));
  }

  @override
  void dispose() {
    _query.dispose();
    _episode.dispose();
    _queryFocus.dispose();
    _episodeFocus.dispose();
    super.dispose();
  }

  Future<void> _run({bool prefill = false}) async {
    final int serial = ++_serial;
    final String query = _query.text.trim();
    final int? episode = int.tryParse(_episode.text.trim());
    setState(() {
      _loading = true;
      _failed = false;
      _error = null;
    });
    try {
      final VideoRemoteSubtitleSearchPage page = await widget.search(
        prefill ? null : query,
        prefill ? null : episode,
      );
      if (!mounted || serial != _serial) return;
      setState(() {
        if (prefill) {
          _query.text = page.query;
          _episode.text = page.episode?.toString() ?? '';
        }
        _results = page.results;
        _error = page.error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || serial != _serial) return;
      setState(() {
        _results = const <VideoRemoteSubtitleResult>[];
        _loading = false;
        _failed = true;
      });
    }
  }

  void _submit([String _ = '']) {
    if (_query.text.trim().isEmpty) {
      setState(() {
        _results = const <VideoRemoteSubtitleResult>[];
        _error = 'no_query';
      });
      return;
    }
    unawaited(_run());
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.video_remote_control_subtitle_search,
      leadingIcon: FushiIcons.manageSearch,
      maxHeightFactor: 0.9,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>(
                    'video-remote-subtitle-search-query',
                  ),
                  controller: _query,
                  focusNode: _queryFocus,
                  hintText: t.video_remote_subtitle_search_hint,
                  onChanged: (String _) {},
                  onSubmitted: _submit,
                  onClear: _query.clear,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>(
                    'video-remote-subtitle-search-episode',
                  ),
                  controller: _episode,
                  focusNode: _episodeFocus,
                  hintText: t.video_remote_subtitle_search_episode,
                  keyboardType: TextInputType.number,
                  leading: const FushiIcon(FushiIcons.playlist, size: 20),
                  onChanged: (String _) {},
                  onSubmitted: _submit,
                  onClear: _episode.clear,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(child: _list(context)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: FushiCircularProgressIndicator()),
      );
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _emptyMessage(),
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
        itemCount: _results.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => _tile(context, _results[i]),
        ),
      ),
    );
  }

  String _emptyMessage() {
    if (_failed) return t.video_remote_error_unreachable;
    return switch (_error) {
      'no_source' => t.video_remote_subtitle_search_no_source,
      'search_failed' => t.video_remote_subtitle_search_failed,
      'no_query' => t.video_remote_subtitle_search_no_query,
      _ => t.video_remote_subtitle_search_empty,
    };
  }

  Widget _tile(BuildContext context, VideoRemoteSubtitleResult result) {
    final int? episode = result.episode;
    final String subtitle = <String>[
      subtitleProviderDisplayName(result.provider),
      if (result.language.isNotEmpty) result.language,
      if (episode != null) t.video_remote_subtitle_search_episode_n(n: episode),
      if (result.aiTranslated) 'AI',
      if (result.hearingImpaired) 'SDH',
      if (result.downloadCount > 0)
        t.video_remote_subtitle_search_downloads(n: result.downloadCount),
    ].join(' · ');
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('video-remote-subtitle-${result.handle}'),
        leading: const FushiIcon(FushiIcons.subtitles),
        title: Text(
          result.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(subtitle),
        onTap: () {
          fushiSelectionHaptic(context);
          widget.onPick(result);
        },
      ),
    );
  }
}
