import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';

/// 在线字幕搜索对话框（provider 无关）：走 [VideoSubtitleRegistry] 一次问遍所有已配置
/// 的在线字幕源，选一条下载到 [saveDirectory]，pop 回本地绝对路径。
///
/// 与 `JimakuSubtitleDialog` 的分工：那个是 Jimaku 专用的精细控制台（条目消歧、集号、
/// 语言/格式筛选）；这个是「一把搜全部源」的通道，OpenSubtitles 之类只有标题/哈希两种
/// 检索键的源走这里。**两者 pop 契约相同**（都返回下载好的本地路径），所以播放页的落地
/// 与挂轨逻辑一份即可，不需要为新源再写一遍。
///
/// [videoPath] 指向本地视频文件时会算 OSDb movie hash 一并发出去——这是 OpenSubtitles
/// 最强的检索键（按文件本身而不是标题匹配，能直接命中该压制版本的字幕）。
class OnlineSubtitleSearchDialog extends StatefulWidget {
  const OnlineSubtitleSearchDialog({
    required this.registry,
    required this.initialQuery,
    required this.saveDirectory,
    this.videoPath,
    this.season,
    this.episode,
    this.preferredLanguages = const <String>[],
    this.debugInitialResult,
    super.key,
  });

  final VideoSubtitleRegistry registry;

  /// 预填的标题（播放页由文件名/远端标题解析而来）。
  final String initialQuery;

  /// 下载落盘目录（绝对路径，函数内确保存在）。
  final String saveDirectory;

  /// 本地视频文件绝对路径；非空且存在时用于计算文件指纹做精确匹配。远端流为 null。
  final String? videoPath;

  final int? season;
  final int? episode;

  /// 语言偏好（空 = 不限），直接透传给各 provider。
  final List<String> preferredLanguages;

  /// 仅测试用：预置搜索结果，免联网即可验证列表渲染与下载路径。
  @visibleForTesting
  final ProviderBatchResult<VideoSubtitleCandidate>? debugInitialResult;

  @override
  State<OnlineSubtitleSearchDialog> createState() =>
      _OnlineSubtitleSearchDialogState();
}

class _OnlineSubtitleSearchDialogState extends State<OnlineSubtitleSearchDialog>
    with FushiPagePlaceholders<OnlineSubtitleSearchDialog> {
  late final TextEditingController _queryCtrl =
      TextEditingController(text: widget.initialQuery);

  bool _searching = false;
  bool _searched = false;
  String? _busyId;
  ProviderBatchResult<VideoSubtitleCandidate>? _result;

  /// 本次搜索是否真的带上了文件指纹（用于给结果区标「按文件哈希精确匹配」）。
  bool _usedFingerprint = false;

  @override
  void initState() {
    super.initState();
    final ProviderBatchResult<VideoSubtitleCandidate>? seed =
        widget.debugInitialResult;
    if (seed != null) {
      _result = seed;
      _searched = true;
      return;
    }
    if (widget.initialQuery.trim().isNotEmpty) {
      // 进来即搜：调用方已经把标题解析好了，再让用户点一次「搜索」纯属多余。
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 计算本地视频的指纹（OSDb movie hash + 体积 + 文件名）；无本地文件或读失败 → null。
  ///
  /// 失败一律降级为「没有指纹」而不是报错：指纹只是让匹配更准的加分项，拿不到就退回按
  /// 标题搜，绝不因此让整次搜索失败。
  Future<LocalVideoFingerprint?> _fingerprint() async {
    final String? path = widget.videoPath;
    if (path == null || path.trim().isEmpty) return null;
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      return LocalVideoFingerprint(
        fileSize: await file.length(),
        openSubtitlesMovieHash: await computeOpenSubtitlesMovieHash(path),
        fileName: p.basename(path),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _search() async {
    final String query = _queryCtrl.text.trim();
    if (_searching) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = true;
      _searched = false;
      _result = null;
    });
    // 先让 loading 完整绘制一帧再做磁盘哈希与联网（与 Jimaku 对话框同一条
    // paint-before-work 约束：慢磁盘下点完没有任何反馈会看起来像卡死）。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      final LocalVideoFingerprint? fingerprint = await _fingerprint();
      if (!mounted) return;
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await widget.registry.search(
        VideoSubtitleSearchRequest(
          query: query,
          languages: widget.preferredLanguages,
          season: widget.season,
          episode: widget.episode,
          fingerprint: fingerprint,
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _searched = true;
        _usedFingerprint = fingerprint?.openSubtitlesMovieHash != null;
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _download(VideoSubtitleCandidate candidate) async {
    if (_busyId != null) return;
    setState(() => _busyId = candidate.identityKey);
    try {
      final VideoSubtitleDownload download =
          await widget.registry.download(candidate);
      final Directory dir = Directory(widget.saveDirectory);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // 只取 basename：provider 给的文件名来自远端，不能让它带路径分隔符逃出目录。
      final String leaf = p.basename(download.fileName.trim());
      final String dest =
          p.join(dir.path, leaf.isEmpty ? 'subtitle.srt' : leaf);
      await File(dest).writeAsBytes(download.bytes);
      if (!mounted) return;
      Navigator.pop(context, dest);
    } on ExternalProviderFailure catch (failure) {
      if (mounted) _snack(failure.message);
    } on Object {
      if (mounted) _snack(t.video_jimaku_download_failed);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 一条候选的副标题：来源 · 语言 · 季集 · 下载量。缺的字段直接不显示，不占位。
  String _subtitleFor(VideoSubtitleCandidate candidate) {
    final List<String> parts = <String>[
      candidate.providerId,
      if (candidate.language.trim().isNotEmpty) candidate.language,
      if (candidate.season != null && candidate.episode != null)
        'S${candidate.season}E${candidate.episode}'
      else if (candidate.episode != null)
        'E${candidate.episode}',
      if (candidate.downloadCount > 0) '↓${candidate.downloadCount}',
      if (candidate.hearingImpaired) 'HI',
    ];
    return parts.join(' · ');
  }

  Widget _buildResults(ThemeData theme) {
    if (_searching) return buildLoading();
    final ProviderBatchResult<VideoSubtitleCandidate>? result = _result;
    if (result == null) {
      return Center(
        child: Icon(
          Icons.subtitles_outlined,
          size: 48,
          color: theme.colorScheme.outlineVariant,
        ),
      );
    }
    if (result.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _searched
                  ? t.video_jimaku_no_results
                  : t.video_subtitle_online_no_source,
              textAlign: TextAlign.center,
            ),
            // provider 级失败单独列出来：「一个源挂了」和「真的没有字幕」对用户是
            // 两件事，混成一句「没找到」会让人白等下去。
            for (final ExternalProviderFailure failure in result.failures)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${failure.providerId}: ${failure.message}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: result.items.length,
      itemBuilder: (BuildContext context, int index) {
        final VideoSubtitleCandidate candidate = result.items[index];
        final bool busy = _busyId == candidate.identityKey;
        return ListTile(
          leading: const Icon(Icons.subtitles_outlined),
          title: Text(candidate.fileName, maxLines: 2),
          subtitle: Text(_subtitleFor(candidate)),
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined),
          enabled: _busyId == null,
          onTap: _busyId == null ? () => _download(candidate) : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.video_subtitle_online_fetch),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _queryCtrl,
              decoration: InputDecoration(
                labelText: t.video_subtitle_online_title,
                isDense: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _searching ? null : _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            if (_usedFingerprint)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  t.video_subtitle_online_hash_matched,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: _buildResults(theme)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}
