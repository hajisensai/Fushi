import 'dart:io';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/metadata/bangumi_api_client.dart'
    show parseBangumiSubjectUrl;
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/metadata/image_download.dart';
import 'package:fushi/src/media/metadata/scrape_cover_preview.dart';
import 'package:fushi/src/media/metadata/scrape_failure_view.dart';
import 'package:fushi/utils.dart';

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

  /// 上一次搜索失败的异常（null = 没失败）。失败态在结果区显示错误行 + 可行动原因
  /// （区别于「无匹配」空态），用户可再点「搜索」重试——不允许静默塌缩成空列表。
  Object? _searchFailure;

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
      _searchFailure = null;
    });
    List<BookScrapeCandidate> results = const <BookScrapeCandidate>[];
    Object? failure;
    try {
      results = await _resolveCandidates(keyword);
    } catch (e, stack) {
      // BUG-1176：失败要有出口。界面出可见失败行，原始原因落错误日志（用户可在
      // 「错误日志」页查看/上传），不静默塌缩成空列表。
      ErrorLogService.instance.log('BookCoverScrapeDialog.search', e, stack);
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searchFailure = failure;
    });
  }

  /// 把失败折成一句用户可行动的话。底层已把传输失败 / 非 2xx / 非图片响应统一折成带
  /// `statusCode` 的领域异常，「有没有 statusCode」就是「没拿到可用响应」与「拿到了
  /// 但对面报错」的唯一可靠分界——不做更细的假分类，技术细节留在错误日志里。
  String _failureReason(Object failure) {
    final int? status = switch (failure) {
      BookScrapeException(:final int? statusCode) => statusCode,
      ImageDownloadException(:final int? statusCode) => statusCode,
      _ => null,
    };
    return status == null ? t.scrape_reason_network : t.scrape_reason_server;
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
      } catch (e) {
        // 界面上静默：这是尽力而为的第二路，本分支上方那次关键词搜索（未 guard）
        // 失败才会冒泡成可见失败态，所以这里吞掉不会让任何真失败消失。仍落诊断
        // 日志，否则「数字关键词结果时多时少」无从查起。
        direct = null;
        ErrorLogService.instance.logDiagnostic(
          'BookCoverScrapeDialog.fetchById',
          'numeric keyword direct fetch failed: $e',
        );
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
    Object? failure;
    try {
      file = await downloadImageToTempFile(candidate.coverUrl);
    } catch (e, stack) {
      // 下载失败必须可见 + 可查：toast 给「失败了 + 大概因为什么」，原始原因进日志。
      ErrorLogService.instance.log('BookCoverScrapeDialog.download', e, stack);
      failure = e;
    }
    if (!mounted) return;
    if (file == null) {
      setState(() => _applyingCandidate = null);
      FushiToast.show(
        msg: failure == null
            ? t.book_scrape_failed
            : '${t.book_scrape_failed}\n${_failureReason(failure)}',
        severity: ToastSeverity.error,
      );
      return;
    }
    Navigator.of(context).pop(file);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AlertDialog(
      title: Text(t.book_scrape_title),
      content: SizedBox(
        width: 560,
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

  Widget _buildResults(ThemeData theme, FushiDesignTokens tokens) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final Object? failure = _searchFailure;
    if (failure != null) {
      // 搜索失败错误行：可见反馈 + 可行动原因 + 完整技术详情 + 重试指引（搜索按钮
      // 此时已恢复可点）。详情直接进界面而不是只落错误日志，见 [ScrapeFailureView]。
      return ScrapeFailureView(
        title: t.book_scrape_search_failed,
        reason: _failureReason(failure),
        detail: failure.toString(),
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
    FushiDesignTokens tokens,
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
          ScrapeCoverPreview(url: candidate.coverUrl),
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
