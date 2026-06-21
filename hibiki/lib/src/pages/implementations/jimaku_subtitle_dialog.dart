import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

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

  bool _searching = false;
  bool _searched = false;
  String? _busyName; // 正在下载的文件名
  List<JimakuCandidate> _candidates = const <JimakuCandidate>[];

  /// API key 输入区是否折叠（配好 key 且已有候选结果后默认收起腾出列表空间）。
  bool _apiKeyCollapsed = false;
  String _filter = ''; // 候选列表二次关键词筛选（asbplayer 式，按 WEBRip/BD 等过滤）

  @override
  void initState() {
    super.initState();
    final List<JimakuCandidate>? seed = widget.debugInitialCandidates;
    if (seed != null && seed.isNotEmpty) {
      _candidates = List<JimakuCandidate>.unmodifiable(seed);
      _searched = true;
      _apiKeyCollapsed = widget.initialApiKey.trim().isNotEmpty;
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _queryCtrl.dispose();
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
        final List<JimakuFile> files = await jimaku.listFiles(entry.id);
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 用 Dialog（而非 AlertDialog）：Dialog 把它的 child 约束到屏幕减去 inset 的有界高度，
    // 于是 Column(min) 拿到有界的高度天花板，候选列表的 Flexible 能正确分到剩余空间。
    // 旧 AlertDialog 不给 content 固定高度，Column.min 下 Flexible 拿到 0 → 列表被压成
    // 0 高、看不见且吞滚动（BUG-279 根因）。
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(t.video_jimaku_fetch, style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              _buildApiKeySection(),
              const SizedBox(height: 8),
              TextField(
                controller: _queryCtrl,
                decoration: InputDecoration(labelText: t.video_jimaku_query),
                onSubmitted: (_) => _search(),
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
                  child: Text(t.video_jimaku_no_results,
                      textAlign: TextAlign.center),
                )
              else if (_candidates.isNotEmpty) ...<Widget>[
                TextField(
                  decoration: InputDecoration(
                    labelText: t.video_jimaku_filter,
                    isDense: true,
                    prefixIcon: const Icon(Icons.filter_list, size: 18),
                  ),
                  onChanged: (String v) => setState(() => _filter = v),
                ),
                const SizedBox(height: 8),
                // 候选列表吃掉对话框内剩余的高度：外层 Dialog 已把整个对话框高度有界
                // 化，这里的 Flexible 能正确分到剩余空间，内部普通（非 shrinkWrap）
                // ListView 填满后正常滚动。矮屏剩余空间小但仍可滚，高屏自然变高。
                Flexible(
                  child: JimakuCandidateList(
                    candidates: _candidates,
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
        ),
      ),
    );
  }
}

/// 可下载 Jimaku 候选的滚动列表区（从对话框抽出便于在小屏约束下做 widget 测试）。
///
/// 关键不变量：由外层（对话框里的 [Flexible]，其祖先 [Dialog] 已把整个对话框高度有界
/// 化）给定有界高度，内部用普通可滚动 [ListView]（**非** `shrinkWrap`），从而在矮屏上
/// 保持非 0 高度且能正常滚动（BUG-279）。
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
