import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

/// 一条可下载的 Jimaku 字幕候选：所属条目名 + 文件。
class _Candidate {
  const _Candidate({required this.entryName, required this.file});
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
  List<_Candidate> _candidates = const <_Candidate>[];

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
      _candidates = const <_Candidate>[];
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

      final List<_Candidate> candidates = <_Candidate>[];
      for (final JimakuEntry entry in entries) {
        final List<JimakuFile> files = await jimaku.listFiles(entry.id);
        for (final JimakuFile f in files) {
          if (f.isTextSubtitle) {
            candidates.add(_Candidate(entryName: entry.name, file: f));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _candidates = candidates;
        _searched = true;
      });
    } finally {
      anilist.close();
      jimaku.close();
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _download(_Candidate candidate) async {
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_jimaku_fetch),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _apiKeyCtrl,
              decoration: InputDecoration(
                labelText: t.video_jimaku_api_key,
                helperText: t.video_jimaku_api_key_hint,
                helperMaxLines: 2,
              ),
              obscureText: true,
            ),
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
            else if (_candidates.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _candidates.length,
                  itemBuilder: (BuildContext context, int i) {
                    final _Candidate c = _candidates[i];
                    final bool busy = _busyName == c.file.name;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.subtitles_outlined),
                      title: Text(c.file.name, overflow: TextOverflow.ellipsis),
                      subtitle:
                          Text(c.entryName, overflow: TextOverflow.ellipsis),
                      trailing: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      onTap: _busyName == null ? () => _download(c) : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
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
    );
  }
}
