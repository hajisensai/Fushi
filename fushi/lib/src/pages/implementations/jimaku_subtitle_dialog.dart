import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/src/pages/implementations/jimaku_api_key_field.dart';
import 'package:fushi/utils.dart';

/// 一条可下载的 Jimaku 字幕候选：所属条目名 + 文件。
class JimakuCandidate {
  const JimakuCandidate({required this.entryName, required this.file});
  final String entryName;
  final JimakuFile file;

  /// 该候选文件名识别出的语言代码（`ja`/`zh`/`en`/`ko`），认不出为 `null`。
  String? get language => detectSubtitleLanguage(file.name);

  /// 从文件名解析出的集号（认不出为 null），用于按集升序排列。
  int? get episode => file.episode;

  /// 字幕文件类型（扩展名小写不含点，如 `ass`/`srt`）。候选在入列前已过
  /// [JimakuFile.isTextSubtitle]，故这里恒是四种可解析文本格式之一。
  String get format => file.extension;
}

/// 给候选排序，消除 Jimaku 返回的乱序（用户报「集数是乱的」的根因是全程无排序）。
///
/// 排序键（稳定，越靠前越优先）：
/// 1. 语言权重（[jimakuLanguageRank]，优先语言/ja/zh/en/ko），让常用语言集中在顶部；
/// 2. 集号升序（[JimakuCandidate.episode]，认不出的集排在有集号的之后）；
/// 3. 文件名（大小写不敏感）做最终 tie-break，保证确定性。
///
/// 纯函数（返回新列表，不改入参），便于单测。
List<JimakuCandidate> sortJimakuCandidates(
  List<JimakuCandidate> candidates, {
  String? preferredLanguage,
}) {
  final List<JimakuCandidate> out =
      List<JimakuCandidate>.of(candidates, growable: false);
  out.sort((JimakuCandidate a, JimakuCandidate b) {
    final int la = jimakuLanguageRank(a.language, preferred: preferredLanguage);
    final int lb = jimakuLanguageRank(b.language, preferred: preferredLanguage);
    if (la != lb) return la.compareTo(lb);
    final int ea = a.episode ?? (1 << 30);
    final int eb = b.episode ?? (1 << 30);
    if (ea != eb) return ea.compareTo(eb);
    return a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase());
  });
  return out;
}

/// 按语言代码筛选候选。[language] 为 null（= 全部）时原样返回；非 null 时只留该语言
/// 的候选。纯函数，便于单测。
///
/// 保底：识别不出语言（`candidate.language == null`）的候选在选定具体语言时被过滤掉，
/// 但「全部」永远列出全部——故认不出语言绝不会让候选彻底消失（仍能在「全部」里看到）。
List<JimakuCandidate> filterCandidatesByLanguage(
    List<JimakuCandidate> candidates, String? language) {
  if (language == null) return candidates;
  return candidates
      .where((JimakuCandidate c) => c.language == language)
      .toList(growable: false);
}

/// 候选里出现过的语言代码集合（去重，稳定顺序 ja/zh/en/ko 优先）。用于渲染语言筛选
/// chip。认不出语言（null）不计入（归到「全部」）。纯函数。
List<String> availableLanguages(List<JimakuCandidate> candidates) {
  const List<String> order = <String>['ja', 'zh', 'en', 'ko'];
  final Set<String> present = <String>{};
  for (final JimakuCandidate c in candidates) {
    final String? lang = c.language;
    if (lang != null) present.add(lang);
  }
  final List<String> out = <String>[];
  for (final String lang in order) {
    if (present.remove(lang)) out.add(lang);
  }
  out.addAll(present);
  return out;
}

/// 按字幕类型（扩展名）筛选候选。[format] 为 null（= 全部）时原样返回；非 null 时只留
/// 该类型的候选（如 `ass` 只留 ASS/字幕特效轨）。纯函数，便于单测。
///
/// 与 [filterCandidatesByLanguage] 同构：两个维度各自独立，调用方按「语言 → 类型」串联。
List<JimakuCandidate> filterCandidatesByFormat(
    List<JimakuCandidate> candidates, String? format) {
  if (format == null) return candidates;
  return candidates
      .where((JimakuCandidate c) => c.format == format)
      .toList(growable: false);
}

/// 候选里出现过的字幕类型集合（去重，稳定顺序 ass/srt/ssa/vtt 优先，未知格式按字典序
/// 追在后面）。用于渲染类型筛选 chip；只出现一种类型时调用方不必渲染该区。纯函数。
List<String> availableFormats(List<JimakuCandidate> candidates) {
  const List<String> order = <String>['ass', 'srt', 'ssa', 'vtt'];
  final Set<String> present = <String>{};
  for (final JimakuCandidate c in candidates) {
    if (c.format.isNotEmpty) present.add(c.format);
  }
  final List<String> out = <String>[];
  for (final String format in order) {
    if (present.remove(format)) out.add(format);
  }
  final List<String> rest = present.toList()..sort();
  out.addAll(rest);
  return out;
}

// `jimakuLanguageLabel` 已下沉到 jimaku_client.dart（数据层单一真相源，设置页也要用）。
// 四处共用（本对话框 / 下载对话框 / 批量对话框 / 设置页），各自直接 import 数据层。

/// 「自动获取字幕（Jimaku）」对话框（参照 asbplayer）：填 API key → 用番名经 AniList
/// 找 anilist_id → Jimaku 列字幕文件 → 选一个下载到 [saveDirectory] → pop 回本地路径。
///
/// 网络/解析失败一律降级为「无结果」，不抛。API key 变化经 [onApiKeyChanged] 持久化。
/// 真实拉取需有效 key + 联网（device/network 验证待用户）。
class JimakuSubtitleDialog extends StatefulWidget {
  const JimakuSubtitleDialog({
    required this.initialQuery,
    required this.initialApiKey,
    required this.onApiKeyChanged,
    required this.saveDirectory,
    this.initialPreferredLanguage,
    this.onPreferredLanguageChanged,
    this.httpClientFactory,
    this.debugInitialCandidates,
    this.debugInitialSeriesMatches,
    super.key,
  });

  /// 预填的搜索词（由视频文件名解析出的番名）。
  final String initialQuery;

  /// 预填的 Jimaku API key。
  final String initialApiKey;

  /// API key 变化时持久化回调。
  final Future<void> Function(String key) onApiKeyChanged;

  /// 下载字幕保存目录（绝对路径，函数内确保存在）。
  final String saveDirectory;

  /// 上次为该系列选过的字幕语言代码（按系列记忆，调起处从偏好读出）；null = 无记忆。
  final String? initialPreferredLanguage;

  /// 选中语言时的持久化回调（TODO-674，与 [onApiKeyChanged] 同范式）；null = 不持久化。
  final Future<void> Function(String langCode)? onPreferredLanguageChanged;

  /// Production injects the download proxy policy; tests/legacy callers use a
  /// plain client.
  final Future<http.Client> Function()? httpClientFactory;

  /// 仅测试用：预置候选结果，免去联网搜索即可验证「已有结果」时的列表布局/滚动。
  @visibleForTesting
  final List<JimakuCandidate>? debugInitialCandidates;

  /// 仅测试用：预置 AniList 系列候选，免联网验证系列选择区在窄/宽两种布局下的渲染
  /// 与滚动（多系列曾把候选列表挤成 0 高、整个中段不可滚，见两栏布局回归测试）。
  @visibleForTesting
  final List<AniListMedia>? debugInitialSeriesMatches;

  @override
  State<JimakuSubtitleDialog> createState() => _JimakuSubtitleDialogState();
}

class _JimakuSubtitleDialogState extends State<JimakuSubtitleDialog>
    with FushiPagePlaceholders<JimakuSubtitleDialog> {
  late final TextEditingController _apiKeyCtrl =
      TextEditingController(text: widget.initialApiKey);
  late final TextEditingController _queryCtrl =
      TextEditingController(text: widget.initialQuery);
  // 集数输入框：初值空（用户决策「默认空」）。空 → 不传 episode（= 现状列全部）。
  final TextEditingController _episodeCtrl = TextEditingController();

  bool _searching = false;
  bool _searched = false;
  String? _busyName; // 正在下载的文件名
  List<JimakuCandidate> _candidates = const <JimakuCandidate>[];

  /// API key 输入区是否折叠（配好 key 且已有候选结果后默认收起腾出列表空间）。
  bool _apiKeyCollapsed = false;
  String _filter = ''; // 候选列表二次关键词筛选（asbplayer 式，按 WEBRip/BD 等过滤）

  /// 当前选中的语言筛选；null = 「全部」（不过滤）。
  String? _selectedLanguage;

  /// 当前选中的字幕类型筛选（扩展名，如 `ass`）；null = 「全部」（不过滤）。
  /// 与语言不同，**不做跨会话记忆**：同一番不同来源的可用类型差别很大，记住一个类型
  /// 反而常让下次搜索空屏。
  String? _selectedFormat;

  /// 上次搜索是否带了集数（用于「该集无结果」时显示「显示全部集」出口）。
  bool _searchedWithEpisode = false;

  /// AniList 对当前 query 的候选系列（romaji/english/native 都能匹上）。用户报「搜索
  /// 一般用罗马音或者英语」——旧实现只盲取 `media.first`，首条猜错就整个搜空且无从纠正。
  /// 存全部候选并渲染系列 chip，用户可切换正确的番。空 = AniList 无命中（回退文本搜）。
  List<AniListMedia> _seriesMatches = const <AniListMedia>[];

  /// 当前选中的 AniList 系列 id（用它按 anilist_id 搜 Jimaku）；null = 未经 AniList
  /// 解析（纯文本回退）。
  int? _selectedSeriesId;

  @override
  void initState() {
    super.initState();
    _selectedLanguage = widget.initialPreferredLanguage;
    final List<JimakuCandidate>? seed = widget.debugInitialCandidates;
    if (seed != null && seed.isNotEmpty) {
      _candidates = List<JimakuCandidate>.unmodifiable(seed);
      _searched = true;
      _apiKeyCollapsed = widget.initialApiKey.trim().isNotEmpty;
      _reconcileSelectedFilters();
    }
    final List<AniListMedia>? seedSeries = widget.debugInitialSeriesMatches;
    if (seedSeries != null && seedSeries.isNotEmpty) {
      _seriesMatches = List<AniListMedia>.unmodifiable(seedSeries);
      _selectedSeriesId = seedSeries.first.id;
    }
  }

  /// 把记忆/选中的筛选（语言 + 类型）与当前候选对齐：本次结果里没出现的值 → 退回
  /// 「全部」（保底：绝不因上一轮的筛选值在新结果里无候选而空屏）。
  void _reconcileSelectedFilters() {
    final String? lang = _selectedLanguage;
    if (lang != null && !availableLanguages(_candidates).contains(lang)) {
      _selectedLanguage = null;
    }
    final String? format = _selectedFormat;
    if (format != null && !availableFormats(_candidates).contains(format)) {
      _selectedFormat = null;
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _queryCtrl.dispose();
    _episodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String apiKey = _apiKeyCtrl.text.trim();
    final String query = _queryCtrl.text.trim();
    if (apiKey.isEmpty) {
      _snack(t.video_jimaku_no_key);
      return;
    }
    if (query.isEmpty) return;
    // 集数：空或非法 → null（不传 episode = 现状列全部），保底逻辑见 §1.2。
    final int? episode = int.tryParse(_episodeCtrl.text.trim());
    await widget.onApiKeyChanged(apiKey);

    setState(() {
      _searching = true;
      _searched = false;
      _candidates = const <JimakuCandidate>[];
      _seriesMatches = const <AniListMedia>[];
      _selectedSeriesId = null;
    });

    AniListClient? anilist;
    try {
      anilist = AniListClient(
        client: await _createHttpClient(),
      );
      // ① 先经 AniList 把番名解析成候选系列（romaji/english/native 都能匹上）；存全部
      //   候选供用户消歧，默认取首条（相关度最高）。② AniList 无命中时回退文本直接搜。
      final List<AniListMedia> media = await anilist.searchAnime(query);
      if (!mounted) return;
      setState(() => _seriesMatches = media);
      await _fetchCandidates(
        anilistId: media.isNotEmpty ? media.first.id : null,
        queryFallback: query,
        episode: episode,
      );
    } finally {
      anilist?.close();
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 用户点某个系列 chip：以该系列 id 重搜 Jimaku（不再重跑 AniList，保留已展示的候选
  /// 系列列表）。query/episode 从当前输入框读取，与首搜一致。
  Future<void> _selectSeries(AniListMedia media) async {
    if (_selectedSeriesId == media.id || _searching) return;
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) return;
    final int? episode = int.tryParse(_episodeCtrl.text.trim());
    setState(() {
      _searching = true;
      _candidates = const <JimakuCandidate>[];
    });
    try {
      await _fetchCandidates(
        anilistId: media.id,
        queryFallback: _queryCtrl.text.trim(),
        episode: episode,
      );
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 用给定 [anilistId]（null 时回退文本 [queryFallback]）搜 Jimaku 条目 → 列文件 →
  /// 过滤文本字幕 → **排序**（[sortJimakuCandidates]，消除「集数乱序」）→ 落状态。
  /// 自带 JimakuClient 生命周期（本函数创建并关闭）。
  Future<void> _fetchCandidates({
    required int? anilistId,
    required String queryFallback,
    required int? episode,
  }) async {
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: _apiKeyCtrl.text.trim(),
        client: await _createHttpClient(),
      );
      final List<JimakuEntry> entries = <JimakuEntry>[];
      if (anilistId != null) {
        entries.addAll(await jimaku.searchByAnilistId(anilistId));
      }
      if (entries.isEmpty) {
        entries.addAll(await jimaku.searchByQuery(queryFallback));
      }

      final List<JimakuCandidate> candidates = <JimakuCandidate>[];
      for (final JimakuEntry entry in entries) {
        final List<JimakuFile> files =
            await jimaku.listFiles(entry.id, episode: episode);
        for (final JimakuFile f in files) {
          if (f.isTextSubtitle) {
            candidates.add(JimakuCandidate(entryName: entry.name, file: f));
          }
        }
      }
      final List<JimakuCandidate> sorted = sortJimakuCandidates(
        candidates,
        preferredLanguage: _selectedLanguage,
      );
      if (!mounted) return;
      setState(() {
        _candidates = sorted;
        _searched = true;
        _searchedWithEpisode = episode != null;
        _selectedSeriesId = anilistId;
        // 记忆语言 / 上轮类型本次无候选 → 退回「全部」，不空屏（保底）。
        _reconcileSelectedFilters();
        // 配好 key 且搜出结果后，默认收起 API key 输入区腾出列表空间
        // （用户：「apikey 配完是不是可以缩小显示」）。用户仍可点「修改」展开。
        _apiKeyCollapsed = sorted.isNotEmpty;
      });
    } finally {
      jimaku?.close();
    }
  }

  Future<http.Client> _createHttpClient() {
    final Future<http.Client> Function()? factory = widget.httpClientFactory;
    return factory == null
        ? Future<http.Client>.value(http.Client())
        : factory();
  }

  Future<void> _download(JimakuCandidate candidate) async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) return;
    setState(() => _busyName = candidate.file.name);
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await _createHttpClient(),
      );
      final Uint8List? bytes = await jimaku.downloadFile(candidate.file.url);
      if (bytes == null) {
        _snack(t.video_jimaku_download_failed);
        return;
      }
      final Directory dir = Directory(widget.saveDirectory);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final String dest = p.join(dir.path, candidate.file.name);
      await File(dest).writeAsBytes(bytes);
      if (!mounted) return;
      Navigator.pop(context, dest);
    } finally {
      jimaku?.close();
      if (mounted) setState(() => _busyName = null);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// API key 输入区：未折叠时为完整密码框（含获取链接提示）；折叠时为一行紧凑
  /// 摘要 + 「修改」按钮，腾出垂直空间给候选列表（用户：配好 key 后缩小显示）。
  Widget _buildApiKeySection() {
    if (_apiKeyCollapsed && _apiKeyCtrl.text.trim().isNotEmpty) {
      return Row(
        children: <Widget>[
          const Icon(Icons.vpn_key, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.video_jimaku_api_key_set,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _apiKeyCollapsed = false),
            child: Text(t.dialog_edit),
          ),
        ],
      );
    }
    return JimakuApiKeyField(controller: _apiKeyCtrl);
  }

  /// 选某语言（[lang]=null 即「全部」）：更新筛选 + 选具体语言时持久化记忆（选择即写）。
  Future<void> _selectLanguage(String? lang) async {
    setState(() => _selectedLanguage = lang);
    if (lang != null) {
      await widget.onPreferredLanguageChanged?.call(lang);
    }
  }

  /// 选某字幕类型（[format]=null 即「全部」）：只更新筛选，不持久化（见 [_selectedFormat]）。
  void _selectFormat(String? format) {
    setState(() => _selectedFormat = format);
  }

  /// 「显示全部集」：清空集数框并重搜（不带 episode），从 Jimaku 启发式误伤里逃生。
  void _showAllEpisodes() {
    _episodeCtrl.clear();
    _search();
  }

  /// AniList 系列消歧区：命中 ≥2 个候选番时显示，让用户从罗马音/英文/日文标题里挑对
  /// 正确的番（旧实现盲取首条，首条猜错就整搜空且无从纠正）。只命中 1/0 个时不显示。
  ///
  /// 竖排 dense 行而非 chip Wrap：长罗马音标题在窄面板里两行省略可控、行高可预期，
  /// 不再像 chip 那样一系列换出五六行把结果列表挤没（「手机滑不动」根因之一）。
  Widget _buildSeriesSection(ThemeData theme) {
    if (_seriesMatches.length < 2) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child:
              Text(t.video_jimaku_series, style: theme.textTheme.labelMedium),
        ),
        for (final AniListMedia media in _seriesMatches)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            selected: _selectedSeriesId == media.id,
            selectedTileColor: theme.colorScheme.secondaryContainer,
            title: Text(
              media.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: _searching ? null : () => _selectSeries(media),
          ),
      ],
    );
  }

  /// 统一的「标签在上、chip 在下」分区：消除旧版把标题标签塞进同一个 Wrap 里、长
  /// 番名 chip 换行后标签和 chip 高低错落的丑排版。标签走 labelMedium + onSurfaceVariant
  /// 弱化，chip 用 8/8 均匀间距。
  Widget _chipSection(String label, List<Widget> chips) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }

  /// 语言筛选分区（含「全部」）：仅在搜出结果里出现 ≥1 个可识别语言时显示。
  Widget _buildLanguageChips() {
    final List<String> langs = availableLanguages(_candidates);
    if (langs.isEmpty) return const SizedBox.shrink();
    return _chipSection(t.video_jimaku_language, <Widget>[
      ChoiceChip(
        label: Text(t.video_jimaku_language_all),
        selected: _selectedLanguage == null,
        onSelected: (_) => _selectLanguage(null),
      ),
      for (final String lang in langs)
        ChoiceChip(
          label: Text(jimakuLanguageLabel(lang)),
          selected: _selectedLanguage == lang,
          onSelected: (_) => _selectLanguage(lang),
        ),
    ]);
  }

  /// 字幕类型筛选分区（含「全部」）：用户按 ass / srt 挑格式（ASS 带样式特效、
  /// srt 纯文本）。只有一种类型时整区不渲染——单选项的筛选器是纯噪声。
  Widget _buildFormatChips() {
    final List<String> formats = availableFormats(_candidates);
    if (formats.length < 2) return const SizedBox.shrink();
    return _chipSection(t.video_jimaku_format, <Widget>[
      ChoiceChip(
        label: Text(t.video_jimaku_format_all),
        selected: _selectedFormat == null,
        onSelected: (_) => _selectFormat(null),
      ),
      for (final String format in formats)
        ChoiceChip(
          // 类型名是文件扩展名本身（ASS / SRT），不进 i18n：它是格式标识不是可译词。
          label: Text(format.toUpperCase()),
          selected: _selectedFormat == format,
          onSelected: (_) => _selectFormat(format),
        ),
    ]);
  }

  /// 宽屏两栏的最小内容宽（dp）：≥ 此宽度筛选面板与结果列表左右并排，否则退化为
  /// 上下两段（手机竖屏）。720 顶宽减 48 padding 后 672 必两栏；360dp 手机竖屏内容
  /// 宽 ~296 必单栏；横屏手机（640+）正好用两栏吃掉「矮而宽」。
  static const double _twoPaneMinWidth = 560;

  /// 宽屏左侧筛选面板宽（dp）。
  static const double _filterPaneWidth = 252;

  /// 筛选面板（宽屏左栏 / 窄屏上段），配置项按操作顺序分组：① API key（可折叠）
  /// ② 搜索（番名/集数/搜索按钮）③ 系列消歧 ④ 结果筛选（语言/关键词，有结果才显示）。
  ///
  /// 整个面板一体滚动——系列/语言条目再多也只在面板内滚，绝不把结果列表挤成 0 高
  /// （「手机滑不动」根因：系列 chip 区曾是外层 Column 的固定槽位，不可滚也不收缩）。
  Widget _buildFilterPane(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildApiKeySection(),
          const SizedBox(height: 8),
          TextField(
            controller: _queryCtrl,
            decoration: InputDecoration(labelText: t.video_jimaku_query),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 8),
          // 集数输入：默认空 → 列全部（现状）；填数字 → 只搜该集（Jimaku 服务端
          // 启发式）。hint（而非 helperText）内联在框里，不额外占一行垂直空间。
          TextField(
            controller: _episodeCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t.video_jimaku_episode,
              hintText: t.video_jimaku_episode_hint,
              isDense: true,
              prefixIcon: const Icon(Icons.tag, size: 18),
            ),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 12),
          // 搜索按钮跟着搜索输入走（手绘稿：左栏 KEY→TITLE→SEARCH），不再窝在对话框
          // 右下角和「取消」挤一排。
          FilledButton.icon(
            onPressed: _searching ? null : _search,
            icon: const Icon(Icons.search),
            label: Text(t.video_jimaku_search),
          ),
          _buildSeriesSection(theme),
          if (_candidates.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _buildLanguageChips(),
            _buildFormatChips(),
            TextField(
              decoration: InputDecoration(
                labelText: t.video_jimaku_filter,
                isDense: true,
                prefixIcon: const Icon(Icons.filter_list, size: 18),
              ),
              onChanged: (String v) => setState(() => _filter = v),
            ),
          ],
        ],
      ),
    );
  }

  /// 结果区（宽屏右栏 / 窄屏下段）：搜索中 spinner → 无结果提示（含「显示全部集」
  /// 逃生口）→ 候选列表。列表由外层给定有界高度、内部普通（非 shrinkWrap）ListView
  /// 滚动，保留 BUG-279 不变量。
  Widget _buildResultsArea(ThemeData theme) {
    if (_searching) {
      return buildLoading();
    }
    if (_searched && _candidates.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.video_jimaku_no_results, textAlign: TextAlign.center),
            // 带了集数却 0 结果：Jimaku 文件名启发式可能误伤整季打包字幕，给一键
            // 「显示全部集」逃生口（清集数框重搜）。
            if (_searchedWithEpisode) ...<Widget>[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _showAllEpisodes,
                icon: const Icon(Icons.list, size: 18),
                label: Text(t.video_jimaku_show_all_episodes),
              ),
            ],
          ],
        ),
      );
    }
    if (_candidates.isEmpty) {
      // 未搜索的初始态（宽屏右栏占位）：淡图标示意结果将显示在这里，不引入新文案。
      return Center(
        child: Icon(
          Icons.subtitles_outlined,
          size: 48,
          color: theme.colorScheme.outlineVariant,
        ),
      );
    }
    // 先按语言筛选（_selectedLanguage）、再按类型筛选（_selectedFormat），最后交给
    // 列表做关键词二次筛选。三层各自独立、顺序不影响结果集。
    return JimakuCandidateList(
      candidates: filterCandidatesByFormat(
        filterCandidatesByLanguage(_candidates, _selectedLanguage),
        _selectedFormat,
      ),
      filter: _filter,
      busyName: _busyName,
      onDownload: _busyName == null ? _download : null,
    );
  }

  /// 宽屏（≥[_twoPaneMinWidth]）两栏：左筛选面板（定宽、面板内滚动）+ 竖分隔线 +
  /// 右结果区吃满剩余宽度。stretch 让两栏同高，列表拿到有界高度正常滚动。
  Widget _buildWideBody(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: _filterPaneWidth, child: _buildFilterPane(theme)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: VerticalDivider(width: 1),
        ),
        Expanded(child: _buildResultsArea(theme)),
      ],
    );
  }

  /// 窄屏（手机竖屏）上下两段：筛选面板与结果区各自 [Flexible]（结果区权重更大），
  /// 面板内容再高也只在自身内滚动，结果列表永远分得到空间且可滚——修「手机滑动不了」。
  /// 尚无任何结果态（未搜索）时不渲染结果槽，面板拿满高度、对话框贴合内容。
  Widget _buildNarrowBody(ThemeData theme) {
    final bool showResults = _searching || _searched || _candidates.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(child: _buildFilterPane(theme)),
        if (showResults) ...<Widget>[
          const SizedBox(height: 8),
          Flexible(flex: 2, child: _buildResultsArea(theme)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 外壳用仓库标准 FushiDialogFrame（内部仍是 Dialog）：scrollable:false 仍由
    // maxHeight 给整个对话框有界高度天花板，于是 Column(min) 拿到有界高度，正文的
    // Flexible 能正确分到剩余空间，候选列表内部普通（非 shrinkWrap）ListView 正常
    // 滚动，保留 BUG-279 不变量。若用 frame 默认 scrollable:true 包
    // SingleChildScrollView 给无界高度，Flexible 会坍缩成 0 高 → 回归 BUG-279，故此
    // 处必须 scrollable:false。maxWidth 720 让大屏走两栏；insetPadding 保留
    // horizontal:16（手机宽=屏宽-32，大屏由 720 封顶居中）。
    return FushiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_jimaku_fetch, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          // 正文按内容宽自适应：宽屏左右两栏（筛选|结果，手绘稿布局），窄屏上下两段。
          Flexible(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return constraints.maxWidth >= _twoPaneMinWidth
                    ? _buildWideBody(theme)
                    : _buildNarrowBody(theme);
              },
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可下载 Jimaku 候选的滚动列表区（从对话框抽出便于在小屏约束下做 widget 测试）。
///
/// 关键不变量：由外层（对话框里的 [Flexible]，其祖先 [FushiDialogFrame]（内部仍是
/// [Dialog]，且 `scrollable:false` 仍由 maxHeight 给 [Flexible] 有界高度）已把整个对话框
/// 高度有界化）给定有界高度，内部用普通可滚动 [ListView]（**非** `shrinkWrap`），从而在矮屏
/// 上保持非 0 高度且能正常滚动，保留 BUG-279 不变量。
class JimakuCandidateList extends StatelessWidget {
  const JimakuCandidateList({
    required this.candidates,
    required this.filter,
    required this.busyName,
    required this.onDownload,
    super.key,
  });

  /// 全部候选（未经关键词二次筛选）。
  final List<JimakuCandidate> candidates;

  /// 关键词二次筛选（asbplayer 式，按 WEBRip/BD 等过滤）。
  final String filter;

  /// 正在下载的文件名（用于行内进度指示）；无则为 null。
  final String? busyName;

  /// 点击某行下载的回调；为 null 时禁用所有行点击（下载进行中）。
  final void Function(JimakuCandidate candidate)? onDownload;

  @override
  Widget build(BuildContext context) {
    // G6：与库页搜索同一归一化口径（全角/片假名/标点差异不挡命中），不再是
    // 裸 toLowerCase 子串。
    final List<JimakuCandidate> shown = filterByMediaSearch(
        candidates, filter, (JimakuCandidate c) => <String>[c.file.name]);
    // 不用 shrinkWrap：外层 [ConstrainedBox] 给了有界 maxHeight，普通 ListView 会
    // 填满该高度并在内容超出时正常滚动。shrinkWrap 反而会让它贴合内容/不产生可滚
    // 余量（maxScrollExtent=0），正是「滚不动」的来源。
    return ListView.builder(
      itemCount: shown.length,
      itemBuilder: (BuildContext context, int i) {
        final JimakuCandidate c = shown[i];
        final bool busy = busyName == c.file.name;
        // 文件名（含集数，如 第01話/E01）整段可见才能区分是第几集：换行而非单行截断
        // （TODO-673：番名都一样，区分集数的部分原本被省略号吃掉）。文件名给多行
        // 软换行，仍给一个上限避免极长名把单条撑满整个列表区，超限再 fade 兜底。
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          isThreeLine: true,
          leading: const Icon(Icons.subtitles_outlined),
          title: Text(
            c.file.name,
            maxLines: 3,
            softWrap: true,
            overflow: TextOverflow.fade,
          ),
          subtitle: Text(
            c.entryName,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.fade,
          ),
          trailing: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          onTap: onDownload == null ? null : () => onDownload!(c),
        );
      },
    );
  }
}
