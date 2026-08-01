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
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// TMDB API key 偏好键（存 Drift `preferences` 表，不改 schema）。
const String kVideoScraperTmdbApiKeyPref = 'video_scraper_tmdb_api_key';

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
/// 搜索框预填**解析后的标题**（非原始文件名）；数据源分段选择 Bangumi / TMDB /
/// 离线库（已装载才出现）；候选列表带海报缩略图 + 标题 + 年份/类型 + 评分 + 置信度
/// 徽标（对每个候选跑 [MatchScorer.score]），「使用」即下载落封面。
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
  late final TextEditingController _tmdbKeyCtrl;
  late ScrapeSource _source;
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
  bool _showTmdbKeyField = false;

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
    final int generation = ++_searchGeneration;
    final ScrapeSource source = _source;
    // 添加/修改 Bangumi 映射：贴条目 URL = 直接按 id 取该条目改绑（跳过关键词
    // 搜索与 TMDB key 门，无论当前在哪个数据源分段）。
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
    // TMDB 分段但无 key：展开输入行，不搜。
    if (source == ScrapeSource.tmdb && _storedTmdbKey().isEmpty) {
      setState(() {
        _showTmdbKeyField = true;
        _results = const <ScrapeCandidate>[];
        _scoringQuery = null;
        _searched = false;
        _searchFailure = null;
        _applyFailure = null;
      });
      HibikiToast.show(msg: t.video_scrape_tmdb_key_required);
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
      results = await _searchSource(keyword, source);
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

  /// TMDB 分段用当前 key 现建 client 搜索（服务注入的 client 可能因启动时无 key 而为
  /// null；此处支持用户中途填入 key 后立即可搜）；其余源走注入的 service。
  Future<List<ScrapeCandidate>> _searchSource(
    String keyword,
    ScrapeSource source,
  ) async {
    if (source == ScrapeSource.tmdb) {
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
    // （如动画《86》）：两路依次都试，id 直取命中置顶、与同 id 搜索结果去重——
    // 不牺牲任何一种意图。
    if (source == ScrapeSource.bangumi && RegExp(r'^\d+$').hasMatch(keyword)) {
      List<ScrapeCandidate> searched = const <ScrapeCandidate>[];
      Object? searchError;
      StackTrace? searchStack;
      try {
        searched = await widget.service
            .searchCandidates(source: source, keyword: keyword);
      } catch (e, stack) {
        // 单路失败只是降级（另一路还可能有结果），不打扰用户；但要留取证痕迹，
        // 否则「数字关键词结果时多时少」无从查起。
        searchError = e;
        searchStack = stack;
        ErrorLogService.instance.logDiagnostic(
          'CoverMatchDialog.searchCandidates',
          'numeric keyword search failed: $e',
        );
      }
      ScrapeCandidate? direct;
      Object? directError;
      try {
        direct = await widget.service.fetchBangumiCandidateById(keyword);
      } catch (e) {
        directError = e;
        ErrorLogService.instance.logDiagnostic(
          'CoverMatchDialog.fetchBangumiCandidateById',
          'numeric keyword direct fetch failed: $e',
        );
      }
      // 两路都失败 = 真搜不了：带原始栈重抛给 _search 出可见失败态；只有一路失败
      // 才算可静默降级。
      if (searchError != null && directError != null) {
        Error.throwWithStackTrace(
            searchError, searchStack ?? StackTrace.current);
      }
      if (direct == null) return searched;
      final String directId = direct.entryId;
      return <ScrapeCandidate>[
        direct,
        ...searched.where((ScrapeCandidate c) => c.entryId != directId),
      ];
    }
    return widget.service.searchCandidates(source: source, keyword: keyword);
  }

  MatchConfidence? _confidenceFor(ScrapeCandidate candidate) {
    final ParsedMediaName? parsed = _parsed;
    final String query = _scoringQuery?.trim() ?? '';
    if (parsed == null && query.isEmpty) return null;
    final ParsedMediaName scoringParsed = ParsedMediaName(
      // 手动搜索是用户对“要匹配什么”的显式纠正，置信度必须按搜索框当前值算；
      // 年份/季/集等结构化线索仍沿用路径解析结果。
      title: query.isNotEmpty ? query : parsed!.title,
      secondaryTitle: parsed?.secondaryTitle,
      episode: parsed?.episode,
      season: parsed?.season,
      year: parsed?.year,
      releaseGroup: parsed?.releaseGroup,
      resolution: parsed?.resolution,
      isMovieHint: parsed?.isMovieHint ?? false,
    );
    return widget.service
        .scoreCandidate(parsed: scoringParsed, candidate: candidate)
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
    HibikiToast.show(msg: t.video_scrape_applied);
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
            const SizedBox(height: 8),
            _buildSourceSelector(),
            const SizedBox(height: 6),
            Text(
              collection == null
                  ? t.video_scrape_manual_match_hint
                  : t.video_scrape_collection_match_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
          if (next == _source) return;
          setState(() {
            // 切来源只改变搜索目标，不替用户立刻发网络请求。旧来源结果必须同时清空，
            // 否则 TMDB 无 key 时仍挂着 Bangumi 候选，看起来像「TMDB 也有数据」。
            _searchGeneration++;
            _source = next;
            _results = const <ScrapeCandidate>[];
            _scoringQuery = null;
            _searching = false;
            _searched = false;
            _searchFailure = null;
            _applyFailure = null;
            _showTmdbKeyField =
                next == ScrapeSource.tmdb && _storedTmdbKey().isEmpty;
          });
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
            final String key = _tmdbKeyCtrl.text;
            final ScrapeSource source = _source;
            final int generation = _searchGeneration;
            await _saveTmdbKey(key);
            if (!mounted ||
                source != _source ||
                generation != _searchGeneration) {
              return;
            }
            setState(() => _showTmdbKeyField = key.trim().isEmpty);
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
    if (_source == ScrapeSource.tmdb &&
        _storedTmdbKey().isEmpty &&
        !_searched) {
      return Center(
        child: Text(
          t.video_scrape_tmdb_key_empty,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
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

  String _sourceLabel(ScrapeSource source) {
    return switch (source) {
      ScrapeSource.bangumi => 'Bangumi',
      ScrapeSource.tmdb => 'TMDB',
      ScrapeSource.offlineDb => t.video_scrape_source_offline,
      ScrapeSource.manualUrl => 'URL',
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
