import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/utils.dart';

/// 手动搜索 / 选集匹配面板（TODO-1376）。
///
/// 自动匹配（`matchFile`）失败、或匹配到错集时的用户兜底入口：按番剧名搜索 →
/// 选番剧 → 选集 → 绑定弹幕。搜索与绑定都经注入回调完成（页面持有
/// `DandanplayClient` 与弹幕列表所有权），面板只负责交互与本地状态，便于 widget
/// 测试独立驱动（注入假 [onSearch] 即可断言列表渲染与选集回调）。
class DanmakuManualMatchPanel extends StatefulWidget {
  const DanmakuManualMatchPanel({
    required this.initialKeyword,
    required this.onSearch,
    required this.onEpisodeSelected,
    this.colorScheme,
    super.key,
  });

  /// 初始搜索关键词（通常取当前视频文件名，用户可改）。
  final String initialKeyword;

  /// 按关键词搜索候选集（页面注入，内部调用弹弹play `searchEpisodes`）。
  final Future<DandanplaySearchResult> Function(String keyword) onSearch;

  /// 用户选定某集 → 绑定弹幕（页面注入：拉评论 + 持久化 episodeId + 关面板）。
  final Future<void> Function(DandanplaySearchEpisode episode)
      onEpisodeSelected;

  /// 视频页 chrome 配色（侧栏统一色）；为空时回退主题配色。
  final ColorScheme? colorScheme;

  @override
  State<DanmakuManualMatchPanel> createState() =>
      _DanmakuManualMatchPanelState();
}

class _DanmakuManualMatchPanelState extends State<DanmakuManualMatchPanel> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialKeyword);
  final FocusNode _fieldFocus = FocusNode();
  bool _searching = false;
  bool _binding = false;
  DandanplaySearchResult? _result;
  int _searchSeq = 0;

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final String keyword = _controller.text.trim();
    if (keyword.isEmpty || _searching) return;
    final int seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _result = null;
    });
    final DandanplaySearchResult result = await widget.onSearch(keyword);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _searching = false;
      _result = result;
    });
  }

  Future<void> _select(DandanplaySearchEpisode episode) async {
    if (_binding) return;
    setState(() => _binding = true);
    try {
      await widget.onEpisodeSelected(episode);
    } finally {
      if (mounted) setState(() => _binding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme ?? Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('danmaku-manual-search-field'),
                  controller: _controller,
                  focusNode: _fieldFocus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_runSearch()),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: t.video_danmaku_manual_search_hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('danmaku-manual-search-button'),
                onPressed: _searching ? null : () => unawaited(_runSearch()),
                child: Text(t.video_danmaku_manual_search_action),
              ),
            ],
          ),
        ),
        Expanded(child: _buildResults(cs)),
      ],
    );
  }

  Widget _buildResults(ColorScheme cs) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final DandanplaySearchResult? result = _result;
    if (result == null) {
      return _hint(cs, t.video_danmaku_manual_search_prompt);
    }
    if (result.status != DandanplayFetchStatus.hit || result.animes.isEmpty) {
      final String message = switch (result.status) {
        DandanplayFetchStatus.networkError =>
          t.video_danmaku_manual_network_error,
        DandanplayFetchStatus.serverError =>
          t.video_danmaku_manual_server_error,
        _ => t.video_danmaku_manual_no_result,
      };
      return _hint(cs, message);
    }
    return ListView(
      key: const Key('danmaku-manual-results'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: <Widget>[
        for (final DandanplaySearchAnime anime in result.animes)
          _buildAnime(cs, anime),
      ],
    );
  }

  Widget _hint(ColorScheme cs, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );

  Widget _buildAnime(ColorScheme cs, DandanplaySearchAnime anime) {
    final String subtitle = anime.typeDescription ?? '';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey<int>(anime.animeId),
        initiallyExpanded: true,
        title: Text(anime.animeTitle),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        childrenPadding: const EdgeInsets.only(left: 8),
        children: <Widget>[
          for (final DandanplaySearchEpisode ep in anime.episodes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.play_circle_outline),
              title: Text(
                ep.episodeTitle.isEmpty ? '#${ep.episodeId}' : ep.episodeTitle,
              ),
              enabled: !_binding,
              onTap: () => unawaited(_select(ep)),
            ),
        ],
      ),
    );
  }
}
