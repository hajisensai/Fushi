import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart' show GalgameSourceRow;

import 'package:hibiki/src/mining/galgame_cover_download.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/mining/galgame_scrape_controller.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:hibiki/utils.dart';

/// 游戏「刮削元数据」统一弹窗（对齐视频 `cover_match_dialog.dart` 的单弹窗闭环）。
///
/// 此前游戏刮削是三跳：库页卡菜单 → 详情页编辑 tab → 刮削按钮 → 再串行弹
/// 「输入关键词」「纯文本候选」两个对话框，封面还只在无封面时隐式附带。本弹窗
/// 一步到位：打开即按当前显示名自动首搜，搜索框可改词重搜，候选带封面缩略图 +
/// `源 · ID · 发行日` 副行，每行「使用」行内转圈；点「使用」= `fetchById` 补全
/// → [GalgameRepository.saveScrapeResult]（多源 primarySource 记 mixed 规则不变）
/// → **封面与元数据一起落**：用户显式选中候选即覆盖既有封面（用户 2026-07-28
/// 拍板，对齐视频/书籍手动刮削语义，见 [shouldDownloadExplicitScrapedCover]；
/// 自动/隐式路径仍绝不覆盖）。
///
/// 返回 true = 已成功落库（调用方据此刷新库页 / 重载详情页）；false/取消 = 无写库。
Future<bool> showGalgameScrapeDialog({
  required BuildContext context,
  required GalgameEntry game,
  required GalgameRepository repo,
  String? initialQuery,
}) async {
  final bool? applied = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => GalgameScrapeDialog(
      game: game,
      repo: repo,
      initialQuery: initialQuery,
    ),
  );
  return applied ?? false;
}

/// 纯函数：把用户贴进搜索框的**条目页 URL** 归一化成源裸 ID，其余输入原样透传。
///
/// 「添加/修改 Bangumi 映射」需求的游戏侧一环：用户从浏览器地址栏复制条目 URL
/// 直接贴进来即可改绑，无需自己抠 ID。[GalgameScrapeController.search] 的
/// validateId 链路已认裸 ID（命中即跳过搜索直取详情），缺的只是 URL 形态——
/// 本函数补上这一步，归一化后交给既有链路，controller 零改动。
///
/// - Bangumi 条目页（`bgm.tv` / `bangumi.tv` / `chii.in` 的 `/subject/<数字>`，
///   允许尾随斜杠/多余路径段/query/fragment）→ 数字串裸 ID；
/// - VNDB 条目页（`vndb.org` 的 `/v<数字>`，同样宽容尾随内容）→ `v<数字>`；
/// - 其它输入（裸 ID、普通关键词、非条目 URL）**原样返回，零行为变化**。
String normalizeGalgameScrapeQuery(String input) {
  final Uri? uri = _tryParseEntryUrl(input);
  if (uri == null) return input;
  final String rawHost = uri.host.toLowerCase();
  final String host =
      rawHost.startsWith('www.') ? rawHost.substring(4) : rawHost;
  final List<String> segments = <String>[
    for (final String s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  const Set<String> bangumiHosts = <String>{'bgm.tv', 'bangumi.tv', 'chii.in'};
  if (bangumiHosts.contains(host) &&
      segments.length >= 2 &&
      segments[0] == 'subject' &&
      RegExp(r'^\d+$').hasMatch(segments[1])) {
    return segments[1];
  }
  if (host == 'vndb.org' && segments.isNotEmpty) {
    final RegExpMatch? m =
        RegExp(r'^v(\d+)$', caseSensitive: false).firstMatch(segments[0]);
    if (m != null) return 'v${m.group(1)!}';
  }
  return input;
}

/// 把输入解析成 http/https URL；解析不出（裸词/裸 ID/含空格）返回 null。
/// 用户从地址栏复制偶尔丢协议（`bgm.tv/subject/4885`）：无 scheme 但长得像
/// 「域名/路径」时补 `https://` 再试一次。
Uri? _tryParseEntryUrl(String input) {
  final String trimmed = input.trim();
  if (trimmed.isEmpty || trimmed.contains(' ')) return null;
  final Uri? direct = Uri.tryParse(trimmed);
  if (direct != null &&
      (direct.isScheme('http') || direct.isScheme('https')) &&
      direct.host.isNotEmpty) {
    return direct;
  }
  if (!trimmed.contains('://') &&
      trimmed.contains('.') &&
      trimmed.contains('/')) {
    final Uri? prefixed = Uri.tryParse('https://$trimmed');
    if (prefixed != null && prefixed.host.isNotEmpty) return prefixed;
  }
  return null;
}

/// 落库一条**用户显式选中**的候选（库页与详情页共用，取代旧 `_scrape()` 的落库段）：
/// `fetchById` 补全 draft → [GalgameRepository.saveScrapeResult]（多源快照时
/// primarySource 记 [kGalgamePrimarySourceMixed]，单源记该源 key——规则不变）→
/// 封面下载（显式语义：有 URL 即下载并**覆盖**既有封面；下载失败静默降级，
/// 不影响返回值）。[coverHttpClient] / [coverDirectory] 是测试接缝。
///
/// 返回 false = 该 ID 在源上未找到（draft 为 null）；网络/解析失败由
/// [GalgameMetadataException] 上抛给调用方提示。
Future<bool> applyGalgameScrapeCandidate({
  required GalgameRepository repo,
  required String gameId,
  required SourceCandidate candidate,
  GalgameScrapeController? controller,
  HttpClient? coverHttpClient,
  Directory? coverDirectory,
}) async {
  final GalgameScrapeController used =
      controller ?? GalgameScrapeController.instance;
  final GalgameMetadataDraft? draft =
      await used.fetchById(candidate.source, candidate.externalId);
  if (draft == null) return false;
  // 多个源都有快照时主显示源记 mixed（契约 §1.1）。
  final List<GalgameSourceRow> existing = await repo.sourcesOf(gameId);
  final Set<String> sources = <String>{
    for (final GalgameSourceRow row in existing) row.source,
    candidate.source.key,
  };
  await repo.saveScrapeResult(
    gameId: gameId,
    source: candidate.source,
    draft: draft,
    primarySource:
        sources.length > 1 ? kGalgamePrimarySourceMixed : candidate.source.key,
  );
  await _downloadScrapedCover(
    repo: repo,
    gameId: gameId,
    draft: draft,
    candidate: candidate,
    httpClient: coverHttpClient,
    coverDirectory: coverDirectory,
  );
  return true;
}

/// 刮削候选落地后的封面应用：优先 draft 的完整封面 URL，缺了退回候选缩略图 URL。
///
/// 决策走 [shouldDownloadExplicitScrapedCover]——本函数只服务统一刮削弹窗的
/// 显式「使用」路径：用户亲手选中候选 = 明确要绑到这个条目，封面随元数据一起
/// 换（**覆盖**既有封面；与视频「在线匹配封面」、书籍「在线刮削封面」的显式
/// 语义一致，用户 2026-07-28 拍板）。自动/隐式补齐路径请走
/// [shouldAutoDownloadScrapedCover]（绝不覆盖）。
/// 下载失败静默降级不打断（原因由 [downloadGalgameCoverToFile] 记 debug 日志，
/// 既有封面此时原样保留）。
Future<void> _downloadScrapedCover({
  required GalgameRepository repo,
  required String gameId,
  required GalgameMetadataDraft draft,
  required SourceCandidate candidate,
  HttpClient? httpClient,
  Directory? coverDirectory,
}) async {
  // 条目可能在弹窗打开期间被移除：行不在就不下载。
  if (repo.byId(gameId) == null) return;
  final String? coverUrl = (draft.coverUrl?.trim().isNotEmpty ?? false)
      ? draft.coverUrl
      : candidate.coverUrl;
  if (!shouldDownloadExplicitScrapedCover(coverUrl: coverUrl)) return;
  final String? saved = await downloadGalgameCoverToFile(
    gameId: gameId,
    url: coverUrl!,
    client: httpClient,
    coverDirectory: coverDirectory,
  );
  if (saved == null) return; // 失败静默：原因已进 debug 日志，旧封面保留。
  // 下载期间条目可能已被移除：仓储按 id 更新，行不在就不写。
  if (repo.byId(gameId) == null) return;
  await repo.setCoverPath(gameId, saved);
}

/// 弹窗主体（导出便于 widget 测试直接构造并注入 [controllerOverride]）。
class GalgameScrapeDialog extends StatefulWidget {
  const GalgameScrapeDialog({
    super.key,
    required this.game,
    required this.repo,
    this.initialQuery,
    this.controllerOverride,
    this.coverHttpClientOverride,
    this.coverDirectoryOverride,
  });

  final GalgameEntry game;
  final GalgameRepository repo;

  /// 搜索框预填词；null 用 [GalgameEntry.displayName]。
  final String? initialQuery;

  /// 测试注入的编排层；null 用 [GalgameScrapeController.instance]。
  final GalgameScrapeController? controllerOverride;

  /// 测试注入的封面下载 HttpClient / 落盘目录（验证显式覆盖语义时喂假响应）。
  final HttpClient? coverHttpClientOverride;
  final Directory? coverDirectoryOverride;

  @override
  State<GalgameScrapeDialog> createState() => _GalgameScrapeDialogState();
}

class _GalgameScrapeDialogState extends State<GalgameScrapeDialog> {
  late final TextEditingController _queryCtrl = TextEditingController(
    text: (widget.initialQuery?.trim().isNotEmpty ?? false)
        ? widget.initialQuery!.trim()
        : widget.game.displayName,
  );

  GalgameScrapeController get _controller =>
      widget.controllerOverride ?? GalgameScrapeController.instance;

  List<SourceCandidate> _candidates = const <SourceCandidate>[];
  bool _searching = false;
  bool _searched = false;

  /// 上一次搜索是否整体失败（全源失败 / 网络异常）。失败态在结果区显示错误行
  /// （区别于「无匹配」空态），用户可改词或直接重搜——不允许静默塌缩成空列表，
  /// 也不再是旧实现那样弹个 toast 后无处重试。
  bool _searchFailed = false;

  /// 正在应用的候选（在其「使用」按钮上转圈；null = 无进行中）。
  SourceCandidate? _applyingCandidate;

  @override
  void initState() {
    super.initState();
    // 首帧后按预填词自动首搜（与书/视频刮削弹窗同款省一次点击）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    // 贴条目 URL 先归一成源裸 ID（validateId 命中即直取详情），其余输入原样。
    final String keyword = normalizeGalgameScrapeQuery(_queryCtrl.text.trim());
    if (keyword.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searched = true;
      _searchFailed = false;
    });
    List<SourceCandidate> candidates;
    bool failed = false;
    try {
      // 单源失败已在编排层降级为空（§2.5）；抛出 = 全源失败，必须给可重试的错误态。
      candidates = (await _controller.search(keyword)).candidates;
    } catch (_) {
      candidates = const <SourceCandidate>[];
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _searching = false;
      _searchFailed = failed;
    });
  }

  Future<void> _use(SourceCandidate candidate) async {
    if (_applyingCandidate != null) return; // 再入守卫：一次应用含多次网络往返。
    setState(() => _applyingCandidate = candidate);
    bool applied = false;
    String? failureMessage;
    try {
      applied = await applyGalgameScrapeCandidate(
        repo: widget.repo,
        gameId: widget.game.id,
        candidate: candidate,
        controller: _controller,
        coverHttpClient: widget.coverHttpClientOverride,
        coverDirectory: widget.coverDirectoryOverride,
      );
    } on GalgameMetadataException catch (e) {
      failureMessage = '${t.game_scrape_failed}: ${e.message}';
    } catch (e) {
      failureMessage = '${t.game_scrape_failed}: $e';
    }
    if (!mounted) return;
    if (!applied) {
      // 失败：复位转圈（否则按钮永久禁用），弹窗保留让用户改选/重试。
      setState(() => _applyingCandidate = null);
      HibikiToast.show(msg: failureMessage ?? t.game_scrape_no_result);
      return;
    }
    Navigator.of(context).pop(true);
    HibikiToast.show(msg: t.game_scrape_applied);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 480,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.game_scrape,
        leadingIcon: Icons.cloud_download_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildSearchRow(),
            SizedBox(height: tokens.spacing.gap),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120),
                child: _buildResults(Theme.of(context), tokens),
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_cancel),
            ),
          ],
        ),
      ),
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
              hintText: t.game_scrape_query,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _searching ? null : _search,
          child: Text(t.game_scrape_search),
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
              t.game_scrape_search_failed,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ),
      );
    }
    if (_searched && _candidates.isEmpty) {
      // 空态收进弹窗内（旧实现 toast 完就散场，用户无处改词重试）。
      return Center(child: Text(t.game_scrape_no_result));
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _candidates.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _buildCandidateTile(theme, tokens, _candidates[index]),
    );
  }

  Widget _buildCandidateTile(
    ThemeData theme,
    HibikiDesignTokens tokens,
    SourceCandidate candidate,
  ) {
    final String metaLine = <String>[
      candidate.source.label,
      candidate.externalId,
      if (candidate.releaseDate != null) candidate.releaseDate!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _buildThumb(tokens, candidate.coverUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  candidate.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    metaLine,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
                : Text(t.game_scrape_use),
          ),
        ],
      ),
    );
  }

  /// 46×66 封面缩略图：无 URL / 加载失败降级为占位图标（不进网络加载路径）。
  Widget _buildThumb(HibikiDesignTokens tokens, String? coverUrl) {
    final Widget placeholder = Container(
      color: tokens.surfaces.overlay,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 20,
        color: tokens.surfaces.onVariant,
      ),
    );
    return SizedBox(
      width: 46,
      height: 66,
      child: ClipRRect(
        // 行内小缩略图与书籍刮削弹窗同级，用 chip 语义圆角。
        borderRadius: HibikiBorderRadius.chip,
        child: (coverUrl == null || coverUrl.trim().isEmpty)
            ? placeholder
            : Image.network(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}
