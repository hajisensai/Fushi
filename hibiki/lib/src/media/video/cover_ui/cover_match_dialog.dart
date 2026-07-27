import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/metadata/bangumi_api_client.dart'
    show parseBangumiSubjectUrl;
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// TMDB API key 偏好键（存 Drift `preferences` 表，不改 schema）。
const String kVideoScraperTmdbApiKeyPref = 'video_scraper_tmdb_api_key';

/// 单本「在线匹配海报」弹窗。
///
/// 搜索框预填**解析后的标题**（非原始文件名）；数据源分段选择 Bangumi / TMDB /
/// 离线库（已装载才出现）；候选列表带海报缩略图 + 标题 + 年份/类型 + 评分 + 置信度
/// 徽标（对每个候选跑 [MatchScorer.score]），「使用」即下载落封面。book 在合集内
/// （[collectionMemberUids] 长度 > 1）时底部出「同时应用到本合集全部 N 集」勾选。
///
/// TMDB 无 key 时点该分段展开 key 输入行并存偏好（[kVideoScraperTmdbApiKeyPref]）。
Future<void> showCoverMatchDialog({
  required BuildContext context,
  required CoverScraperService service,
  required VideoBookRow book,
  required List<String> collectionMemberUids,
  required VoidCallback onApplied,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: collectionMemberUids,
      onApplied: onApplied,
    ),
  );
}

/// 单本在线匹配海报对话框主体（导出便于 widget 测试直接构造）。
class CoverMatchDialog extends ConsumerStatefulWidget {
  const CoverMatchDialog({
    super.key,
    required this.service,
    required this.book,
    required this.collectionMemberUids,
    required this.onApplied,
  });

  final CoverScraperService service;
  final VideoBookRow book;

  /// 本合集全部成员 uid（含 [book] 自身）；长度 > 1 才显示合集应用勾选。
  final List<String> collectionMemberUids;

  /// 应用成功后回调（刷新库页）。
  final VoidCallback onApplied;

  @override
  ConsumerState<CoverMatchDialog> createState() => _CoverMatchDialogState();
}

class _CoverMatchDialogState extends ConsumerState<CoverMatchDialog> {
  late final TextEditingController _queryCtrl;
  late final TextEditingController _tmdbKeyCtrl;
  late ScrapeSource _source;
  ParsedMediaName? _parsed;

  List<ScrapeCandidate> _results = const <ScrapeCandidate>[];
  bool _searching = false;
  bool _searched = false;
  bool _showTmdbKeyField = false;
  bool _applyToCollection = false;
  bool _applying = false;

  /// 正在应用的候选（用于在其「使用」按钮上显示转圈；null = 无进行中应用）。
  ScrapeCandidate? _applyingCandidate;

  @override
  void initState() {
    super.initState();
    _parsed = widget.service.parseForPath(widget.book.videoPath);
    final String prefill =
        _parsed?.title.isNotEmpty == true ? _parsed!.title : widget.book.title;
    _queryCtrl = TextEditingController(text: prefill);
    _tmdbKeyCtrl = TextEditingController(text: _storedTmdbKey());
    // 默认数据源：Bangumi（主源）。
    _source = ScrapeSource.bangumi;
    // 首帧后自动搜一次（预填标题直接出结果，省一次手动点击）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _tmdbKeyCtrl.dispose();
    super.dispose();
  }

  String _storedTmdbKey() {
    final AppModel app = ref.read(appProvider);
    return app.prefsRepo.getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '')
        as String;
  }

  Future<void> _saveTmdbKey(String key) async {
    await ref
        .read(appProvider)
        .prefsRepo
        .setPref(kVideoScraperTmdbApiKeyPref, key.trim());
  }

  Future<void> _search() async {
    final String keyword = _queryCtrl.text.trim();
    if (keyword.isEmpty) return;
    // 添加/修改 Bangumi 映射：贴条目 URL = 直接按 id 取该条目改绑（跳过关键词
    // 搜索与 TMDB key 门，无论当前在哪个数据源分段）。
    final String? mappedSubjectId = parseBangumiSubjectUrl(keyword);
    if (mappedSubjectId != null) {
      setState(() {
        _searching = true;
        _searched = true;
      });
      List<ScrapeCandidate> results;
      try {
        final ScrapeCandidate? candidate =
            await widget.service.fetchBangumiCandidateById(mappedSubjectId);
        results = candidate == null
            ? const <ScrapeCandidate>[]
            : <ScrapeCandidate>[candidate];
      } catch (_) {
        results = const <ScrapeCandidate>[];
      }
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
      return;
    }
    // TMDB 分段但无 key：展开输入行，不搜。
    if (_source == ScrapeSource.tmdb && _storedTmdbKey().isEmpty) {
      setState(() => _showTmdbKeyField = true);
      HibikiToast.show(msg: t.video_scrape_tmdb_key_required);
      return;
    }
    setState(() {
      _searching = true;
      _searched = true;
    });
    List<ScrapeCandidate> results;
    try {
      results = await _searchSource(keyword);
    } catch (_) {
      results = const <ScrapeCandidate>[];
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  /// TMDB 分段用当前 key 现建 client 搜索（服务注入的 client 可能因启动时无 key 而为
  /// null；此处支持用户中途填入 key 后立即可搜）；其余源走注入的 service。
  Future<List<ScrapeCandidate>> _searchSource(String keyword) async {
    if (_source == ScrapeSource.tmdb) {
      final String key = _storedTmdbKey();
      if (key.isEmpty) return const <ScrapeCandidate>[];
      final TmdbClient client = TmdbClient(apiKey: key);
      try {
        return await client.search(keyword, year: _parsed?.year);
      } finally {
        client.close();
      }
    }
    // 纯数字输入既可能是 Bangumi subject id（用户改绑映射）也可能就是标题
    // （如动画《86》）：两路并发，id 直取命中置顶、与同 id 搜索结果去重——
    // 不牺牲任何一种意图。
    if (_source == ScrapeSource.bangumi && RegExp(r'^\d+$').hasMatch(keyword)) {
      final List<ScrapeCandidate> searched = await widget.service
          .searchCandidates(source: _source, keyword: keyword)
          .catchError((Object _) => const <ScrapeCandidate>[]);
      ScrapeCandidate? direct;
      try {
        direct = await widget.service.fetchBangumiCandidateById(keyword);
      } catch (_) {
        direct = null;
      }
      if (direct == null) return searched;
      final String directId = direct.entryId;
      return <ScrapeCandidate>[
        direct,
        ...searched.where((ScrapeCandidate c) => c.entryId != directId),
      ];
    }
    return widget.service.searchCandidates(source: _source, keyword: keyword);
  }

  MatchConfidence? _confidenceFor(ScrapeCandidate candidate) {
    final ParsedMediaName? parsed = _parsed;
    if (parsed == null) return null;
    return widget.service
        .scoreCandidate(parsed: parsed, candidate: candidate)
        .confidence;
  }

  Future<void> _use(ScrapeCandidate candidate) async {
    if (_applying) return;
    // 记录进行中的候选：按钮转圈给用户明确「正在应用」反馈（下载海报最长 30s，无反馈
    // 会被误当成「点了没反应」，BUG-1081）。
    setState(() {
      _applying = true;
      _applyingCandidate = candidate;
    });
    final List<String> targets =
        _applyToCollection && widget.collectionMemberUids.length > 1
            ? widget.collectionMemberUids
            : <String>[widget.book.bookUid];
    bool ok = false;
    try {
      await widget.service.applyCandidateToBooks(
        bookUids: targets,
        candidate: candidate,
        aliasKey: _parsed?.title,
      );
      ok = true;
    } catch (_) {
      // ok 保持 false，走下方失败分支——绝不吞成静默无反馈。
    }
    if (!mounted) return;
    if (!ok) {
      // 失败：复位 _applying（否则按钮永久禁用），弹可见失败提示，弹窗保留让用户改选。
      setState(() {
        _applying = false;
        _applyingCandidate = null;
      });
      HibikiToast.show(msg: t.video_scrape_apply_failed);
      return;
    }
    // 成功：刷新库页 + 关弹窗 + 成功提示。onApplied 单独 guard，任何异常都不得阻断关闭
    // 弹窗（否则 _applying 卡在 true、按钮永久禁用 = 「使用没反应」的另一条成因）。
    try {
      widget.onApplied();
    } catch (_) {
      // 刷新回调异常不影响「已应用」这一既成事实，吞掉即可。
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    HibikiToast.show(msg: t.video_scrape_applied);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool showCollectionToggle = widget.collectionMemberUids.length > 1;
    return AlertDialog(
      title: Text(t.video_scrape_online_match),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildSearchRow(),
            const SizedBox(height: 8),
            _buildSourceSelector(),
            if (_showTmdbKeyField) ...<Widget>[
              const SizedBox(height: 8),
              _buildTmdbKeyRow(),
            ],
            const SizedBox(height: 8),
            // Flexible（而非固定高）：AlertDialog content 高度受视口上界约束，固定
            // 320 会与搜索行/分段/勾选叠加溢出；让结果区吃剩余空间即可。
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120),
                child: _buildResults(theme),
              ),
            ),
            if (showCollectionToggle)
              CheckboxListTile(
                key: const ValueKey<String>('cover_match_apply_collection'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _applyToCollection,
                onChanged: (bool? v) =>
                    setState(() => _applyToCollection = v ?? false),
                title: Text(
                  t.video_scrape_apply_to_collection(
                    n: widget.collectionMemberUids.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.video_scrape_batch_close),
        ),
      ],
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _queryCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: t.video_scrape_search_hint,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _searching ? null : _search,
          child: Text(t.video_scrape_search),
        ),
      ],
    );
  }

  Widget _buildSourceSelector() {
    final List<ButtonSegment<ScrapeSource>> segments =
        <ButtonSegment<ScrapeSource>>[
      const ButtonSegment<ScrapeSource>(
        value: ScrapeSource.bangumi,
        label: Text('Bangumi'),
      ),
      const ButtonSegment<ScrapeSource>(
        value: ScrapeSource.tmdb,
        label: Text('TMDB'),
      ),
      if (widget.service.hasOfflineIndex)
        ButtonSegment<ScrapeSource>(
          value: ScrapeSource.offlineDb,
          label: Text(t.video_scrape_source_offline),
        ),
    ];
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ScrapeSource>(
        segments: segments,
        selected: <ScrapeSource>{_source},
        showSelectedIcon: false,
        onSelectionChanged: (Set<ScrapeSource> selected) {
          final ScrapeSource next = selected.first;
          setState(() {
            _source = next;
            _showTmdbKeyField =
                next == ScrapeSource.tmdb && _storedTmdbKey().isEmpty;
          });
          _search();
        },
      ),
    );
  }

  Widget _buildTmdbKeyRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _tmdbKeyCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: t.video_scrape_tmdb_key_hint,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () async {
            await _saveTmdbKey(_tmdbKeyCtrl.text);
            if (!mounted) return;
            setState(
                () => _showTmdbKeyField = _tmdbKeyCtrl.text.trim().isEmpty);
            await _search();
          },
          child: Text(t.video_scrape_tmdb_key_save),
        ),
      ],
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searched && _results.isEmpty) {
      return Center(child: Text(t.video_scrape_no_results));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _buildCandidateTile(theme, _results[index]),
    );
  }

  Widget _buildCandidateTile(ThemeData theme, ScrapeCandidate candidate) {
    final MatchConfidence? confidence = _confidenceFor(candidate);
    final List<String> metaParts = <String>[
      if (candidate.year != null) '${candidate.year}',
      if (candidate.type != ScrapeEntryType.unknown) candidate.type.name,
      if (candidate.ratingText != null) candidate.ratingText!,
    ];
    // 自绘 Row（不用 ListTile.subtitle 叠两行——会撞 ListTile 固定 subtitle 高度而
    // 竖向溢出）：缩略图 + 标题/元信息/置信度纵列 + 「使用」按钮。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _buildThumb(theme, candidate.posterUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(candidate.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                if (metaParts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      metaParts.join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (confidence != null)
                  _buildConfidenceBadge(theme, confidence),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _applying ? null : () => _use(candidate),
            child: identical(_applyingCandidate, candidate)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.video_scrape_use),
          ),
        ],
      ),
    );
  }

  Widget _buildThumb(ThemeData theme, String url) {
    return SizedBox(
      width: 46,
      height: 66,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfidenceBadge(ThemeData theme, MatchConfidence confidence) {
    final (Color color, String label) = switch (confidence) {
      MatchConfidence.high => (Colors.green, t.video_scrape_confidence_high),
      MatchConfidence.medium => (
          Colors.orange,
          t.video_scrape_confidence_medium
        ),
      MatchConfidence.low => (
          theme.colorScheme.outline,
          t.video_scrape_confidence_low
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}
