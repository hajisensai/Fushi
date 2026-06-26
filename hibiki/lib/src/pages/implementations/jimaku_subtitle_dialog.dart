import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/utils.dart';

/// 按关键词（大小写不敏感子串）筛选列表；空/纯空白关键词原样返回。纯函数，便于单测。
List<T> filterByKeyword<T>(
    List<T> items, String keyword, String Function(T) text) {
  final String kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return items;
  return items
      .where((T it) => text(it).toLowerCase().contains(kw))
      .toList(growable: false);
}

/// 一条可下载的 Jimaku 字幕候选：所属条目名 + 文件。
class JimakuCandidate {
  const JimakuCandidate({required this.entryName, required this.file});
  final String entryName;
  final JimakuFile file;

  /// 该候选文件名识别出的语言代码（`ja`/`zh`/`en`/`ko`），认不出为 `null`。
  String? get language => detectSubtitleLanguage(file.name);
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

/// 语言代码 → 显示名（chip 文案）。白名单外回退原代码大写。
String jimakuLanguageLabel(String code) {
  switch (code) {
    case 'ja':
      return '日本語';
    case 'zh':
      return '中文';
    case 'en':
      return 'English';
    case 'ko':
      return '한국어';
    default:
      return code.toUpperCase();
  }
}

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
    this.debugInitialCandidates,
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

  /// 仅测试用：预置候选结果，免去联网搜索即可验证「已有结果」时的列表布局/滚动。
  @visibleForTesting
  final List<JimakuCandidate>? debugInitialCandidates;

  @override
  State<JimakuSubtitleDialog> createState() => _JimakuSubtitleDialogState();
}

class _JimakuSubtitleDialogState extends State<JimakuSubtitleDialog> {
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

  /// 上次搜索是否带了集数（用于「该集无结果」时显示「显示全部集」出口）。
  bool _searchedWithEpisode = false;

  @override
  void initState() {
    super.initState();
    _selectedLanguage = widget.initialPreferredLanguage;
    final List<JimakuCandidate>? seed = widget.debugInitialCandidates;
    if (seed != null && seed.isNotEmpty) {
      _candidates = List<JimakuCandidate>.unmodifiable(seed);
      _searched = true;
      _apiKeyCollapsed = widget.initialApiKey.trim().isNotEmpty;
      _reconcileSelectedLanguage();
    }
  }

  /// 把记忆/选中的语言与当前候选对齐：记忆语言本次结果里没出现 → 退回「全部」
  /// （保底：绝不因记忆语言无候选而空屏）。
  void _reconcileSelectedLanguage() {
    final String? lang = _selectedLanguage;
    if (lang != null && !availableLanguages(_candidates).contains(lang)) {
      _selectedLanguage = null;
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
    });

    final AniListClient anilist = AniListClient();
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey);
    try {
      // ① 先经 AniList 把番名解析成 anilist_id（更准）；② 没命中再用文本直接搜 Jimaku。
      final List<AniListMedia> media = await anilist.searchAnime(query);
      final List<JimakuEntry> entries = <JimakuEntry>[];
      if (media.isNotEmpty) {
        entries.addAll(await jimaku.searchByAnilistId(media.first.id));
      }
      if (entries.isEmpty) {
        entries.addAll(await jimaku.searchByQuery(query));
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
      if (!mounted) return;
      setState(() {
        _candidates = candidates;
        _searched = true;
        _searchedWithEpisode = episode != null;
        // 记忆语言本次无候选 → 退回「全部」，不空屏（保底）。
        _reconcileSelectedLanguage();
        // 配好 key 且搜出结果后，默认收起 API key 输入区腾出列表空间
        // （用户：「apikey 配完是不是可以缩小显示」）。用户仍可点「修改」展开。
        _apiKeyCollapsed = candidates.isNotEmpty;
      });
    } finally {
      anilist.close();
      jimaku.close();
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _download(JimakuCandidate candidate) async {
    final String apiKey = _apiKeyCtrl.text.trim();
    if (apiKey.isEmpty) return;
    setState(() => _busyName = candidate.file.name);
    final JimakuClient jimaku = JimakuClient(apiKey: apiKey);
    try {
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
      jimaku.close();
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
    return TextField(
      controller: _apiKeyCtrl,
      decoration: InputDecoration(
        labelText: t.video_jimaku_api_key,
        helperText: t.video_jimaku_api_key_hint,
        helperMaxLines: 2,
      ),
      obscureText: true,
    );
  }

  /// 选某语言（[lang]=null 即「全部」）：更新筛选 + 选具体语言时持久化记忆（选择即写）。
  Future<void> _selectLanguage(String? lang) async {
    setState(() => _selectedLanguage = lang);
    if (lang != null) {
      await widget.onPreferredLanguageChanged?.call(lang);
    }
  }

  /// 「显示全部集」：清空集数框并重搜（不带 episode），从 Jimaku 启发式误伤里逃生。
  void _showAllEpisodes() {
    _episodeCtrl.clear();
    _search();
  }

  /// 语言筛选 chip 排（含「全部」）：仅在搜出结果里出现 ≥1 个可识别语言时显示。
  Widget _buildLanguageChips() {
    final List<String> langs = availableLanguages(_candidates);
    if (langs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(t.video_jimaku_language,
              style: Theme.of(context).textTheme.labelMedium),
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
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 外壳用仓库标准 HibikiDialogFrame（内部仍是 Dialog）：scrollable:false 仍由
    // maxHeight 给整个对话框有界高度天花板，于是 Column(min) 拿到有界高度，候选列表的
    // Flexible 能正确分到剩余空间，内部普通（非 shrinkWrap）ListView 正常滚动，保留
    // BUG-279 不变量。若用 frame 默认 scrollable:true 包 SingleChildScrollView 给无界
    // 高度，Flexible 会坍缩成 0 高 → 回归 BUG-279，故此处必须 scrollable:false。
    // maxWidth 提到 720 让大屏不再窄；insetPadding 保留 horizontal:16（手机宽=屏宽-32
    // 同现状，大屏由 720 封顶居中），不用 frame 默认 horizontal:40 否则手机变窄。
    return HibikiDialogFrame(
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
          // 头部输入区（api key / query / episode）放进可收缩的 Flexible 滚动视图：矮屏
          // （TODO-674 新增了 episode 必填项后头部更高）时整个头部能内部滚动，不再把固定
          // 兄弟撑出 RenderFlex 溢出；高屏自然贴合内容、不滚。候选列表仍是独立 Flexible，
          // 保留 BUG-279（非 shrinkWrap ListView）不变量。
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildApiKeySection(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _queryCtrl,
                    decoration:
                        InputDecoration(labelText: t.video_jimaku_query),
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_searched && _candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
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
            )
          else if (_candidates.isNotEmpty) ...<Widget>[
            _buildLanguageChips(),
            TextField(
              decoration: InputDecoration(
                labelText: t.video_jimaku_filter,
                isDense: true,
                prefixIcon: const Icon(Icons.filter_list, size: 18),
              ),
              onChanged: (String v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            // 候选列表吃掉对话框内剩余的高度：外层 HibikiDialogFrame（scrollable:false）
            // 已把整个对话框高度有界化，这里的 Flexible 能正确分到剩余空间，内部普通
            //（非 shrinkWrap）ListView 填满后正常滚动。矮屏剩余空间小但仍可滚，高屏自
            // 然变高。先按语言筛选（_selectedLanguage），再交给列表做关键词二次筛选。
            Flexible(
              child: JimakuCandidateList(
                candidates:
                    filterCandidatesByLanguage(_candidates, _selectedLanguage),
                filter: _filter,
                busyName: _busyName,
                onDownload: _busyName == null ? _download : null,
              ),
            ),
          ],
          const SizedBox(height: 8),
          // 用 Wrap 而非 Row：窄屏（如 360dp）下 Cancel + 带图标的 Search 放不下
          // 时自动换行，避免水平 RenderFlex 溢出。
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.dialog_cancel),
              ),
              FilledButton.icon(
                onPressed: _searching ? null : _search,
                icon: const Icon(Icons.search),
                label: Text(t.video_jimaku_search),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 可下载 Jimaku 候选的滚动列表区（从对话框抽出便于在小屏约束下做 widget 测试）。
///
/// 关键不变量：由外层（对话框里的 [Flexible]，其祖先 [HibikiDialogFrame]（内部仍是
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
    final List<JimakuCandidate> shown =
        filterByKeyword(candidates, filter, (JimakuCandidate c) => c.file.name);
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
