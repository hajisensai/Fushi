import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/metadata/bangumi_api_client.dart'
    show parseBangumiSubjectUrl;
import 'package:hibiki/src/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:hibiki/src/media/metadata/scrape_cover_preview.dart';
import 'package:hibiki/src/media/metadata/scrape_failure_view.dart';
import 'package:hibiki/src/media/video/cover_ui/collection_rename_confirm_dialog.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/collection_scrape_apply.dart'
    show proposedCollectionRename;
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// 「在线匹配封面」弹窗打开时的**合集入口**标识（BUG-1211）。
///
/// 非 null 即表示「用户点的是合集卡，他要换的是**合集自己的封面**」。据此三件事同时
/// 成立，缺一都会退回用户否决的旧语义：
/// - 标题带合集名（否则分不清在给哪个合集换封面）；
/// - 「使用」只写合集自有封面（[applyCover]），**一个成员都不碰**；
/// - 不出「同时应用到本合集全部 N 集」勾选——合集入口下那个选项本身就是错的。
///
/// [applyScrape] 由调用方注入（生产 = 写 `MediaCollections.coverPath` +
/// `collection_scrape_meta` + 回写合集名），弹窗因此不必持有 [HibikiDatabase]，
/// widget 测试也能直接断言「写了合集、没写成员」。
class CoverMatchCollectionTarget {
  const CoverMatchCollectionTarget({
    required this.id,
    required this.name,
    required this.applyScrape,
  });

  /// `MediaCollections.id`（下载落点文件名由它派生）。
  final int id;

  /// 合集名（弹窗标题用）。
  final String name;

  /// 把整份刮削产物（封面 + 横版背景 + 条目资料）写进合集（BUG-1310）。
  ///
  /// 从原先的 `applyCover(String coverPath)` 扩成整份结果：只传封面路径的签名
  /// 结构性地决定了「合集刮削只能有一张图」——资料和背景根本没有参数位可传，
  /// 这正是详情页除标题外一片空白的源头。
  ///
  /// [confirmedTitle] 是**用户在确认弹窗里亲眼看过并点了确认的那个名字**；null =
  /// 用户没确认（或压根不需要问），此时只换封面 + 写资料行，合集名一字不动、也不
  /// 产生旧名同步墓碑。参数 required：调用方必须显式表态，静默改名无路可走。
  final Future<void> Function(
    CollectionScrapeResult result, {
    required String? confirmedTitle,
  }) applyScrape;
}

/// 「在线匹配封面」弹窗。
///
/// 搜索框预填**解析后的标题**（非原始文件名）；**并发查全部可用数据源**（离线库 /
/// Bangumi / TMDB / AniList / MAL）并按置信度合并排序 —— 用户不选源、也不配 key。
/// 候选列表带海报缩略图 + 标题 + 来源 + 年份/类型 + 评分 + 置信度徽标（对每个候选跑
/// [MatchScorer.score]），「使用」即下载落封面。
///
/// 「不让用户选源」是**有意的产品决定**：选源要求用户预先知道「这部番在哪个站收录得
/// 更全」，那是本该由程序承担的知识。来源仍显示在每条候选上（配错可溯源），只是不再
/// 是一个必须先做的**选择**。
///
/// 两种入口语义**互斥**：
/// - [collection] 非 null = 合集入口：只写合集自有封面，成员一个不动；
/// - [collection] 为 null = 单集入口：写 [book]；若该集属于合集
///   （[collectionMemberUids] 长度 > 1），底部仍出「同时应用到本合集全部 N 集」勾选
///   （默认不勾）——那是**从某一集出发**主动批量刷的能力，与合集封面无关，保留。
///
/// TMDB 无 key 时点该分段展开 key 输入行并存偏好（[kVideoScraperTmdbApiKeyPref]）。
Future<void> showCoverMatchDialog({
  required BuildContext context,
  required CoverScraperService service,
  required VideoBookRow book,
  required List<String> collectionMemberUids,
  required VoidCallback onApplied,
  CoverMatchCollectionTarget? collection,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext ctx) => CoverMatchDialog(
      service: service,
      book: book,
      collectionMemberUids: collectionMemberUids,
      onApplied: onApplied,
      collection: collection,
    ),
  );
}

/// 在线匹配封面对话框主体（导出便于 widget 测试直接构造）。
class CoverMatchDialog extends ConsumerStatefulWidget {
  const CoverMatchDialog({
    super.key,
    required this.service,
    required this.book,
    required this.collectionMemberUids,
    required this.onApplied,
    this.collection,
  });

  final CoverScraperService service;

  /// 搜索种子 + 单集入口的写入目标。**合集入口下它只当搜索种子用**（用它的路径解析
  /// 出片名预填搜索框），绝不会被写封面。
  final VideoBookRow book;

  /// 本合集全部成员 uid（含 [book] 自身）；仅**单集入口**用于「同时应用到本合集全部
  /// N 集」勾选（长度 > 1 才显示）。合集入口下不读它。
  final List<String> collectionMemberUids;

  /// 应用成功后回调（刷新库页）。
  final VoidCallback onApplied;

  /// 非 null = 合集入口，见 [CoverMatchCollectionTarget]。
  final CoverMatchCollectionTarget? collection;

  @override
  ConsumerState<CoverMatchDialog> createState() => _CoverMatchDialogState();
}

class _CoverMatchDialogState extends ConsumerState<CoverMatchDialog> {
  late final TextEditingController _queryCtrl;
  ParsedMediaName? _parsed;

  List<ScrapeCandidate> _results = const <ScrapeCandidate>[];
  bool _searching = false;
  bool _searched = false;
  int _searchGeneration = 0;

  /// 当前展示的候选是用哪个关键词搜回来的（BUG-1251）。置位时机必须与
  /// `_results` 完全同一个 setState，并受 [_searchGeneration] 守护：早一拍写会让
  /// 旧结果在新关键词下被重新评分，晚一拍写又会让新结果沿用旧关键词。
  String? _scoringQuery;

  /// 上一次搜索失败的异常（null = 没失败）。BUG-1176：「搜不到」和「搜不了」是两回
  /// 事，失败必须有出口——失败态在结果区显示错误行 + 可行动原因，绝不塌缩成
  /// 「无匹配」空态骗用户以为条目不存在。
  Object? _searchFailure;

  /// 单集入口下「同时应用到本合集全部 N 集」勾选态。合集入口不显示该勾选、也不读它
  /// （合集入口只改合集自有封面，BUG-1211）。
  bool _applyToCollection = false;
  bool _applying = false;

  /// 正在应用的候选（用于在其「使用」按钮上显示转圈；null = 无进行中应用）。
  ScrapeCandidate? _applyingCandidate;

  /// 上一次应用失败的安全详情。应用链可能抛出带请求 URL 的异常，先脱敏再同时送入
  /// 错误日志与 [ScrapeFailureView]，避免「界面安全、日志仍泄露」的半修复。
  ({Object error, String detail})? _applyFailure;

  @override
  void initState() {
    super.initState();
    _parsed = widget.service.parseForPath(widget.book.videoPath);
    final String prefill =
        _parsed?.title.isNotEmpty == true ? _parsed!.title : widget.book.title;
    _queryCtrl = TextEditingController(text: prefill);
    // 首帧后自动搜一次（预填标题直接出结果，省一次手动点击）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String keyword = _queryCtrl.text.trim();
    if (keyword.isEmpty) return;
    final int generation = ++_searchGeneration;
    // 添加/修改 Bangumi 映射：贴条目 URL = 直接按 id 取该条目改绑（跳过多源搜索，
    // 用户已经显式指名了要哪一条）。
    final String? mappedSubjectId = parseBangumiSubjectUrl(keyword);
    if (mappedSubjectId != null) {
      setState(() {
        _searching = true;
        _searched = true;
        _searchFailure = null;
        _applyFailure = null;
      });
      List<ScrapeCandidate> results = const <ScrapeCandidate>[];
      Object? failure;
      try {
        final ScrapeCandidate? candidate =
            await widget.service.fetchBangumiCandidateById(mappedSubjectId);
        results = candidate == null
            ? const <ScrapeCandidate>[]
            : <ScrapeCandidate>[candidate];
      } catch (e, stack) {
        // 直取失败 ≠ 条目不存在（不存在走 404 → null）：原始原因落错误日志（用户可在
        // 「错误日志」页查看/上传），界面出可见失败态，不静默塌缩成「无匹配」。
        ErrorLogService.instance
            .log('CoverMatchDialog.fetchBangumiCandidateById', e, stack);
        failure = e;
      }
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = results;
        _scoringQuery = keyword;
        _searching = false;
        _searchFailure = failure;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searched = true;
      _searchFailure = null;
      _applyFailure = null;
    });
    List<ScrapeCandidate> results = const <ScrapeCandidate>[];
    Object? failure;
    try {
      final ({List<ScrapeCandidate> results, Object? failure}) outcome =
          await _searchAllSources(keyword);
      results = outcome.results;
      failure = outcome.failure;
      if (failure != null) {
        ErrorLogService.instance
            .log('CoverMatchDialog.search', failure, StackTrace.current);
      }
    } catch (e, stack) {
      // 同上：搜索失败与「零结果」必须分开，否则用户以为片名搜不到而放弃重试。
      ErrorLogService.instance.log('CoverMatchDialog.search', e, stack);
      failure = e;
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _results = results;
      _scoringQuery = keyword;
      _searching = false;
      _searchFailure = failure;
    });
  }

  /// 把失败折成一句用户可行动的话。底层已把传输失败 / 非 2xx / JSON 异常统一折成带
  /// `statusCode` 的领域异常，「有没有 statusCode」就是「没拿到可用响应」与「拿到了
  /// 但对面报错」的唯一可靠分界——不做更细的假分类，技术细节留在错误日志里。
  String _failureReason(Object failure) {
    final int? status =
        failure is ScrapeNetworkException ? failure.statusCode : null;
    return status == null ? t.scrape_reason_network : t.scrape_reason_server;
  }

  /// **并发查全部可用源并合并排序** —— 用户不必再挑数据源。
  ///
  /// 部分源失败只留取证痕迹、静默降级（其余源结果照常展示）；**全部源都失败**才把
  /// 异常抛给 [_search] 出可见失败态。这条分界是 BUG-1176 的「搜不到 ≠ 搜不了」在
  /// 多源下的推广：任一源还活着，用户就该看到它的候选，而不是一句「搜索失败」。
  /// 返回值里的 `failure` 非 null = **全部源都失败**（真搜不了）。刻意用返回值而非
  /// 抛异常：各源的失败原因是 `Object`（底层异常类型不受本层约束），把它重新 throw
  /// 出去既触发 `only_throw_errors`，也让「全失败」这个**正常控制流**伪装成异常。
  Future<({List<ScrapeCandidate> results, Object? failure})> _searchAllSources(
    String keyword,
  ) async {
    final AggregatedSearchResult aggregated =
        await widget.service.searchAllSources(
      keyword: keyword,
      year: _parsed?.year,
    );

    // 逐源失败明细进诊断日志：界面上看不见（不打扰），但「某源结果时有时无」必须可查。
    for (final MapEntry<ScrapeSource, Object> entry
        in aggregated.failures.entries) {
      ErrorLogService.instance.logDiagnostic(
        'CoverMatchDialog.searchAllSources',
        '${entry.key.name} search failed: ${entry.value}',
      );
    }
    if (aggregated.allFailed) {
      return (
        results: const <ScrapeCandidate>[],
        failure: aggregated.anyFailure
      );
    }

    List<ScrapeCandidate> results =
        _sortByScore(aggregated.candidates, keyword);

    // 纯数字输入既可能是 Bangumi subject id（用户改绑映射）也可能就是标题（如动画
    // 《86》）：关键词搜索已在上面跑过，这里再补一次 id 直取，命中则置顶去重——
    // 不牺牲任何一种意图。直取失败只是降级（关键词那路可能已有结果），不抛。
    if (RegExp(r'^\d+$').hasMatch(keyword)) {
      ScrapeCandidate? direct;
      try {
        direct = await widget.service.fetchBangumiCandidateById(keyword);
      } catch (e) {
        ErrorLogService.instance.logDiagnostic(
          'CoverMatchDialog.fetchBangumiCandidateById',
          'numeric keyword direct fetch failed: $e',
        );
      }
      if (direct != null) {
        final String directKey = '${direct.source.name}/${direct.entryId}';
        results = <ScrapeCandidate>[
          direct,
          ...results.where((ScrapeCandidate c) =>
              '${c.source.name}/${c.entryId}' != directKey),
        ];
      }
    }
    return (results: results, failure: null);
  }

  /// 按「置信度 → 标题相似度」降序重排聚合结果。
  ///
  /// 排序是「用户不用关心数据源」的**前提**：聚合后候选天然按源分块，不排的话用户
  /// 要在几十条里自己找，等于把选源的负担换成了翻列表的负担。排序替他做了选择。
  ///
  /// 稳定排序（[List.sort] 非稳定，故显式带 index 兜底）：同分候选保持源顺序，
  /// 否则每次搜索同一关键词的列表次序都可能变，用户会以为结果在跳。
  List<ScrapeCandidate> _sortByScore(
    List<ScrapeCandidate> candidates,
    String keyword,
  ) {
    final ParsedMediaName scoringParsed = _scoringParsedFor(keyword);
    final List<({ScrapeCandidate candidate, MatchDecision decision, int index})>
        scored =
        <({ScrapeCandidate candidate, MatchDecision decision, int index})>[];
    for (int i = 0; i < candidates.length; i++) {
      scored.add((
        candidate: candidates[i],
        decision: widget.service
            .scoreCandidate(parsed: scoringParsed, candidate: candidates[i]),
        index: i,
      ));
    }
    scored.sort((
      ({ScrapeCandidate candidate, MatchDecision decision, int index}) a,
      ({ScrapeCandidate candidate, MatchDecision decision, int index}) b,
    ) {
      // MatchConfidence 声明序即 high → medium → low，index 直接就是优先级。
      final int byConfidence =
          a.decision.confidence.index.compareTo(b.decision.confidence.index);
      if (byConfidence != 0) return byConfidence;
      final int byScore =
          b.decision.titleScore.compareTo(a.decision.titleScore);
      if (byScore != 0) return byScore;
      return a.index.compareTo(b.index);
    });
    return scored
        .map((({
                  ScrapeCandidate candidate,
                  MatchDecision decision,
                  int index
                }) e) =>
            e.candidate)
        .toList();
  }

  /// 构造打分用的 [ParsedMediaName]：标题取 [query]（用户对「要匹配什么」的显式
  /// 纠正），年份/季/集等结构化线索仍沿用路径解析结果。
  ///
  /// 抽出来是因为**排序与徽标必须用同一份打分输入**——两处各拼一次的话，一旦有人
  /// 只改了其中一处，就会出现「列表按 A 排、徽标按 B 显示」的自相矛盾。
  ParsedMediaName _scoringParsedFor(String query) {
    final ParsedMediaName? parsed = _parsed;
    final String trimmed = query.trim();
    return ParsedMediaName(
      title: trimmed.isNotEmpty ? trimmed : (parsed?.title ?? ''),
      secondaryTitle: parsed?.secondaryTitle,
      episode: parsed?.episode,
      season: parsed?.season,
      year: parsed?.year,
      releaseGroup: parsed?.releaseGroup,
      resolution: parsed?.resolution,
      isMovieHint: parsed?.isMovieHint ?? false,
    );
  }

  MatchConfidence? _confidenceFor(ScrapeCandidate candidate) {
    final ParsedMediaName? parsed = _parsed;
    final String query = _scoringQuery?.trim() ?? '';
    if (parsed == null && query.isEmpty) return null;
    return widget.service
        .scoreCandidate(
          parsed: _scoringParsedFor(query),
          candidate: candidate,
        )
        .confidence;
  }

  Future<void> _use(ScrapeCandidate candidate) async {
    if (_applying) return;
    // 记录进行中的候选：按钮转圈给用户明确「正在应用」反馈（下载海报最长 30s，无反馈
    // 会被误当成「点了没反应」，BUG-1081）。
    setState(() {
      _applying = true;
      _applyingCandidate = candidate;
      _applyFailure = null;
    });
    final CoverMatchCollectionTarget? collection = widget.collection;
    ({Object error, String detail})? failure;
    try {
      if (collection != null) {
        // 合集入口：下载封面 + 横版背景 + 拉条目资料 → 只写合集自己。**刻意不调
        // applyCandidateToBooks**——那条路会逐成员写 cover_path / cover_meta /
        // video_scrape_meta，正是用户否决的「改合集封面却刷了每一集」（BUG-1211）。
        final CollectionScrapeResult result =
            await widget.service.applyCandidateToCollection(
          collectionId: collection.id,
          candidate: candidate,
        );
        // 改名要单独问一次（BUG-1310 复议）：换封面和改名是两件事，后者还会经同步
        // 把其他设备上的旧名副本删掉。用户不确认 → confirmedTitle 保持 null，
        // 落库层只写封面 + 资料行。弹窗期间 _applying 仍为 true，重复点「使用」进不来。
        final String? proposed = proposedCollectionRename(
          currentName: collection.name,
          scrapedTitle: result.metadata.title,
        );
        String? confirmedTitle;
        if (proposed != null && mounted) {
          confirmedTitle = await showCollectionRenameConfirmDialog(
            context: context,
            currentName: collection.name,
            proposedName: proposed,
          );
        }
        await collection.applyScrape(result, confirmedTitle: confirmedTitle);
      } else {
        final List<String> targets =
            _applyToCollection && widget.collectionMemberUids.length > 1
                ? widget.collectionMemberUids
                : <String>[widget.book.bookUid];
        await widget.service.applyCandidateToBooks(
          bookUids: targets,
          candidate: candidate,
          aliasKey: _parsed?.title,
        );
      }
    } catch (e, stack) {
      // 走下方失败分支——绝不吞成静默无反馈。与搜索失败共用完整详情视图；
      // 日志和界面都只接收同一份脱敏文本，避免异常 URL 的 query 凭据泄露。
      final String detail = redactCredentialsInText(e.toString());
      ErrorLogService.instance
          .log('CoverMatchDialog.applyCandidate', detail, stack);
      failure = (error: e, detail: detail);
    }
    if (!mounted) return;
    if (failure != null) {
      // 失败：复位 _applying（否则按钮永久禁用），弹可见失败提示，弹窗保留让用户改选。
      setState(() {
        _applying = false;
        _applyingCandidate = null;
        _applyFailure = failure;
      });
      return;
    }
    // 成功：刷新库页 + 关弹窗 + 成功提示。onApplied 单独 guard，任何异常都不得阻断关闭
    // 弹窗（否则 _applying 卡在 true、按钮永久禁用 = 「使用没反应」的另一条成因）。
    try {
      widget.onApplied();
    } catch (e, stack) {
      // 界面上吞掉：刷新回调异常不影响「已应用」这一既成事实，不该拦住关弹窗。但必须
      // 留日志，否则「封面应用了、库页没刷新」这条路永远查不出原因。
      ErrorLogService.instance.log('CoverMatchDialog.onApplied', e, stack);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    HibikiToast.show(
      msg: t.video_scrape_applied,
      severity: ToastSeverity.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CoverMatchCollectionTarget? collection = widget.collection;
    // 合集入口不出「应用到全部 N 集」：那里换的是合集自己的封面，成员一个不动
    // （BUG-1211）。只有单集入口才可能出（且默认不勾）。
    final bool showCollectionToggle =
        collection == null && widget.collectionMemberUids.length > 1;
    return AlertDialog(
      title: Text(
        collection == null
            ? t.video_scrape_online_match
            : t.video_scrape_online_match_collection(name: collection.name),
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildSearchRow(),
            const SizedBox(height: 6),
            Text(
              collection == null
                  ? t.video_scrape_manual_match_hint
                  : t.video_scrape_collection_match_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            // Flexible（而非固定高）：AlertDialog content 高度受视口上界约束，固定
            // 320 会与搜索行/勾选叠加溢出；让结果区吃剩余空间即可。
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
                subtitle: Text(t.video_scrape_apply_to_collection_hint),
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

  Widget _buildResults(ThemeData theme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final Object? failure = _searchFailure;
    if (failure != null) return _buildSearchFailure(failure);
    if (_searched && _results.isEmpty) {
      return Center(child: Text(t.video_scrape_no_results));
    }
    final ({Object error, String detail})? applyFailure = _applyFailure;
    final int firstCandidateIndex = applyFailure == null ? 0 : 1;
    return ListView.separated(
      key: ValueKey<String>(
        applyFailure == null
            ? 'cover_match_results'
            : 'cover_match_apply_failure',
      ),
      itemCount: _results.length + firstCandidateIndex,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        if (applyFailure != null && index == 0) {
          return ScrapeFailureView(
            title: t.video_scrape_apply_failed,
            reason: _failureReason(applyFailure.error),
            detail: applyFailure.detail,
          );
        }
        return _buildCandidateTile(
          theme,
          _results[index - firstCandidateIndex],
        );
      },
    );
  }

  /// 搜索失败行：可见失败 + 可行动原因 + 完整技术详情 + 重试指引（此时「搜索」
  /// 按钮已恢复可点）。详情直接进界面而不是只落错误日志，见 [ScrapeFailureView]。
  Widget _buildSearchFailure(Object failure) {
    return ScrapeFailureView(
      title: t.video_scrape_search_failed,
      reason: _failureReason(failure),
      detail: failure.toString(),
    );
  }

  Widget _buildCandidateTile(ThemeData theme, ScrapeCandidate candidate) {
    final MatchConfidence? confidence = _confidenceFor(candidate);
    final List<String> metaParts = <String>[
      '${_sourceLabel(candidate.source)} #${candidate.entryId}',
      if (candidate.year != null) '${candidate.year}',
      if (candidate.type != ScrapeEntryType.unknown) candidate.type.name,
      if (candidate.ratingText != null) candidate.ratingText!,
    ];
    // 自绘 Row（不用 ListTile.subtitle 叠两行——会撞 ListTile 固定 subtitle 高度而
    // 竖向溢出）：缩略图 + 标题/元信息/置信度纵列 + 「使用」按钮。
    return Padding(
      key: ValueKey<String>(
        'cover_match_candidate_${candidate.source.name}_${candidate.entryId}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ScrapeCoverPreview(url: candidate.posterUrl),
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

  /// 结果行的来源标签。用户**不用选**数据源，但必须**看得见**候选来自哪——配错时
  /// 能溯源，也解释了「为什么同一部片出现了两条」（不同源的不同语言条目）。
  ///
  /// 站点专有名词统一取 [kScrapeSourceLabels]（不进 i18n，17 种语言写法相同）；
  /// 离线库是本地概念，是这里唯一需要翻译的一项。
  String _sourceLabel(ScrapeSource source) {
    return switch (source) {
      ScrapeSource.offlineDb => t.video_scrape_source_offline,
      ScrapeSource.manualUrl => 'URL',
      _ => kScrapeSourceLabels[source] ?? source.name,
    };
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
