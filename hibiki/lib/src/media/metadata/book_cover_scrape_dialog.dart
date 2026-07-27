import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/metadata/bangumi_api_client.dart'
    show parseBangumiSubjectUrl;
import 'package:hibiki/src/media/metadata/book_metadata_scraper.dart';
import 'package:hibiki/src/media/metadata/image_download.dart';
import 'package:hibiki/utils.dart';

/// 书籍 / 漫画「在线匹配封面」弹窗（统一刮削 P1b）。
///
/// 搜 Bangumi 书籍条目（[BookMetadataScraper]，`filter.type=[1]`），选中候选后下载其封面
/// 到临时文件并经 `Navigator.pop(file)` 返回给调用方（书籍编辑对话框把它当作新的封面
/// override，走既有 `setOverrideThumbnailFromMediaItem` 落地——不新增任何存储路径）。
///
/// 返回 `null` = 用户取消 / 未选。
Future<File?> showBookCoverScrapeDialog({
  required BuildContext context,
  required String initialQuery,
}) {
  return showAppDialog<File>(
    context: context,
    builder: (BuildContext ctx) =>
        BookCoverScrapeDialog(initialQuery: initialQuery),
  );
}

/// 弹窗主体（导出便于 widget 测试直接构造并注入 [scraperOverride]）。
class BookCoverScrapeDialog extends StatefulWidget {
  const BookCoverScrapeDialog({
    super.key,
    required this.initialQuery,
    this.scraperOverride,
  });

  final String initialQuery;

  /// 测试注入的 scraper（注入时弹窗不负责关闭它）。
  final BookMetadataScraper? scraperOverride;

  @override
  State<BookCoverScrapeDialog> createState() => _BookCoverScrapeDialogState();
}

class _BookCoverScrapeDialogState extends State<BookCoverScrapeDialog> {
  late final TextEditingController _queryCtrl;
  late final BookMetadataScraper _scraper;

  List<BookScrapeCandidate> _results = const <BookScrapeCandidate>[];
  bool _searching = false;
  bool _searched = false;

  /// 上一次搜索是否因网络 / 接口异常失败。失败态在结果区显示错误行（区别于
  /// 「无匹配」空态），用户可再点「搜索」重试——不允许静默塌缩成空列表。
  bool _searchFailed = false;

  /// 正在下载封面的候选（在其「使用」按钮上转圈；null = 无进行中）。
  BookScrapeCandidate? _applyingCandidate;

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(text: widget.initialQuery);
    _scraper = widget.scraperOverride ?? BookMetadataScraper();
    // 首帧后按预填标题自动搜一次。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    if (widget.scraperOverride == null) _scraper.close();
    super.dispose();
  }

  Future<void> _search() async {
    final String keyword = _queryCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _searching = true;
      _searched = true;
      _searchFailed = false;
    });
    List<BookScrapeCandidate> results;
    bool failed = false;
    try {
      results = await _resolveCandidates(keyword);
    } catch (_) {
      results = const <BookScrapeCandidate>[];
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searchFailed = failed;
    });
  }

  /// 关键词 → 候选。添加/修改 Bangumi 映射：贴条目 URL = 按 id 直取（跳过关键词
  /// 搜索）；纯数字既可能是 id 也可能是书名（如《1984》）——搜索 + id 直取并列，
  /// 直取命中置顶、按 subjectId 去重；其余走关键词搜索。
  Future<List<BookScrapeCandidate>> _resolveCandidates(String keyword) async {
    final String? mappedSubjectId = parseBangumiSubjectUrl(keyword);
    if (mappedSubjectId != null) {
      final BookScrapeCandidate? candidate =
          await _scraper.fetchById(mappedSubjectId);
      return candidate == null
          ? const <BookScrapeCandidate>[]
          : <BookScrapeCandidate>[candidate];
    }
    if (RegExp(r'^\d+$').hasMatch(keyword)) {
      final List<BookScrapeCandidate> searched = await _scraper.search(keyword);
      BookScrapeCandidate? direct;
      try {
        direct = await _scraper.fetchById(keyword);
      } catch (_) {
        direct = null; // 直取失败不拖垮关键词结果。
      }
      if (direct == null) return searched;
      final String directId = direct.subjectId;
      return <BookScrapeCandidate>[
        direct,
        ...searched.where((BookScrapeCandidate c) => c.subjectId != directId),
      ];
    }
    return _scraper.search(keyword);
  }

  Future<void> _use(BookScrapeCandidate candidate) async {
    if (_applyingCandidate != null) return;
    setState(() => _applyingCandidate = candidate);
    File? file;
    try {
      file = await downloadImageToTempFile(candidate.coverUrl);
    } catch (_) {
      file = null;
    }
    if (!mounted) return;
    if (file == null) {
      setState(() => _applyingCandidate = null);
      HibikiToast.show(msg: t.book_scrape_failed);
      return;
    }
    Navigator.of(context).pop(file);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AlertDialog(
      title: Text(t.book_scrape_title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.book_scrape_hint,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(t.book_scrape_search),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120),
                child: _buildResults(theme, tokens),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }

  Widget _buildResults(ThemeData theme, HibikiDesignTokens tokens) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchFailed) {
      // 搜索失败错误行：可见反馈 + 重试指引（搜索按钮此时已恢复可点）。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(
              t.book_scrape_search_failed,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ),
      );
    }
    if (_searched && _results.isEmpty) {
      return Center(child: Text(t.book_scrape_empty));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _buildTile(theme, tokens, _results[index]),
    );
  }

  Widget _buildTile(
    ThemeData theme,
    HibikiDesignTokens tokens,
    BookScrapeCandidate candidate,
  ) {
    final List<String> metaParts = <String>[
      if (candidate.year != null) '${candidate.year}',
      if (candidate.originalTitle != null) candidate.originalTitle!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 46,
            height: 66,
            child: ClipRRect(
              // 行内小缩略图与 galgame 首页小封面同级，用 chip 语义圆角。
              borderRadius: HibikiBorderRadius.chip,
              child: Image.network(
                candidate.coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: tokens.surfaces.overlay,
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 20,
                    color: tokens.surfaces.onVariant,
                  ),
                ),
              ),
            ),
          ),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed:
                _applyingCandidate != null ? null : () => _use(candidate),
            child: identical(_applyingCandidate, candidate)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.book_scrape_use),
          ),
        ],
      ),
    );
  }
}
