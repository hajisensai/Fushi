import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/epub_cue_matcher.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_reader.dart';

/// Sasayaki 重匹配入口，被 [AudiobookImportDialog]（已附加视图）和书架
/// 长按菜单复用。把"弹 searchWindow slider" 和"跑 matcher + 落库 + toast"
/// 统一在这里，两处 UI 不再各持一份容易漂移的副本。
class SasayakiRematch {
  const SasayakiRematch._();

  /// 只有 SRT/LRC/VTT/ASS 走 matcher；SMIL/JSON 有硬时间码锚点，与 window 无关。
  static const Set<String> supportedFormats = <String>{'srt', 'lrc', 'vtt', 'ass'};

  /// 硬时间码格式，matcher 无能为力，直接排除。
  static const Set<String> nonMatcherFormats = <String>{'smil', 'json'};

  static bool isEligible(Audiobook ab) {
    final String fmt = ab.alignmentFormat.toLowerCase();
    final String ext = _extFromPath(ab.alignmentPath);
    if (nonMatcherFormats.contains(fmt) || nonMatcherFormats.contains(ext)) {
      return false;
    }
    return true;
  }

  static String _extFromPath(String path) {
    if (path.isEmpty) {
      return '';
    }
    final String last = path.split('.').last.toLowerCase();
    if (last == path.toLowerCase()) {
      return '';
    }
    return last;
  }

  static Future<bool?> promptAndRun({
    required BuildContext context,
    required Audiobook ab,
    required AudiobookRepository repo,
    required int ttuBookId,
    required int serverPort,
    void Function(bool running)? onRunningChanged,
  }) async {
    if (ttuBookId <= 0) {
      Fluttertoast.showToast(msg: '本书未绑定 ttu，无法重跑匹配');
      return null;
    }
    final AudiobookHealth? overlay = await repo.readHealthOverlay(ab.bookUid);
    final _MatchParams? picked = await _pickMatchParams(
      context: context,
      previousReason: overlay?.reason,
      repo: repo,
      bookUid: ab.bookUid,
      ttuBookId: ttuBookId,
      serverPort: serverPort,
    );
    if (picked == null) {
      return false;
    }
    onRunningChanged?.call(true);
    try {
      await _run(
        ab: ab,
        repo: repo,
        ttuBookId: ttuBookId,
        serverPort: serverPort,
        searchWindow: picked.window,
        similarityThreshold: picked.threshold,
      );
      return true;
    } finally {
      onRunningChanged?.call(false);
    }
  }

  static Future<_MatchParams?> _pickMatchParams({
    required BuildContext context,
    required String? previousReason,
    required AudiobookRepository repo,
    required String bookUid,
    required int ttuBookId,
    required int serverPort,
  }) async {
    int window = EpubSrtMatcher.defaultSearchWindow;
    double threshold = EpubSrtMatcher.defaultSimilarityThreshold;
    if (previousReason != null) {
      final RegExpMatch? mw =
          RegExp(r'window=(\d+)').firstMatch(previousReason);
      final int? prev = mw == null ? null : int.tryParse(mw.group(1)!);
      if (prev != null) {
        window = prev.clamp(
          SasayakiWindowSlider.minWindow,
          SasayakiWindowSlider.maxWindow,
        );
      }
      final RegExpMatch? mt =
          RegExp(r'threshold=([\d.]+)').firstMatch(previousReason);
      final double? prevT = mt == null ? null : double.tryParse(mt.group(1)!);
      if (prevT != null) {
        threshold = prevT.clamp(0.1, 1.0);
      }
    }
    bool autoBusy = false;
    List<EpubSection>? probedSections;
    List<AudioCue>? probedCues;
    return showModalBottomSheet<_MatchParams>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetCtx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheet) {
            Future<void> handleAuto() async {
              setSheet(() => autoBusy = true);
              try {
                probedSections ??= await _loadSections(
                  ttuBookId: ttuBookId,
                  serverPort: serverPort,
                );
                probedCues ??= await repo.cuesForBook(bookUid);
                final int? best = await runAutoProbe(
                  sections: probedSections ?? const <EpubSection>[],
                  cues: probedCues ?? const <AudioCue>[],
                );
                if (best != null) {
                  setSheet(() => window = best);
                }
              } finally {
                setSheet(() => autoBusy = false);
              }
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 4,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SasayakiWindowSlider(
                      value: window,
                      onChanged: (int v) => setSheet(() => window = v),
                      onAutoTap: handleAuto,
                      autoBusy: autoBusy,
                    ),
                    const SizedBox(height: 12),
                    SasayakiThresholdSlider(
                      value: threshold,
                      onChanged: (double v) =>
                          setSheet(() => threshold = v),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: autoBusy
                              ? null
                              : () => Navigator.pop(sheetCtx),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('重跑匹配'),
                          onPressed: autoBusy
                              ? null
                              : () => Navigator.pop(
                                    sheetCtx,
                                    _MatchParams(window, threshold),
                                  ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Future<int?> runAutoProbe({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = EpubCueMatcher.defaultProbeWindows,
  }) async {
    if (sections.isEmpty) {
      Fluttertoast.showToast(msg: '未读到 ttu 章节文本，无法自动匹配');
      return null;
    }
    if (cues.isEmpty) {
      Fluttertoast.showToast(msg: '没有 cue 可供匹配');
      return null;
    }
    try {
      final ProbeResult r = await EpubCueMatcher.probeInIsolate(
        sections: sections,
        cues: cues,
        windows: windows,
      );
      final MapEntry<int, double>? best = r.best;
      if (best == null || best.value <= 0) {
        Fluttertoast.showToast(msg: '所有窗口命中率都是 0，请人工调整');
        return null;
      }
      final int pct = (best.value * 100).round();
      Fluttertoast.showToast(msg: '自动选定 ${best.key}（命中 $pct%）');
      return best.key;
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] autoProbe failed: $e\n$st');
      Fluttertoast.showToast(msg: '自动匹配失败：$e');
      return null;
    }
  }

  static Future<List<EpubSection>> _loadSections({
    required int ttuBookId,
    required int serverPort,
  }) async {
    try {
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: ttuBookId,
        serverPort: serverPort,
      );
      return rec.sections;
    } catch (e) {
      debugPrint('[hibiki-audiobook] loadSections failed: $e');
      return const <EpubSection>[];
    }
  }

  static Future<void> _run({
    required Audiobook ab,
    required AudiobookRepository repo,
    required int ttuBookId,
    required int serverPort,
    required int searchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
  }) async {
    try {
      final List<AudioCue> cues = await repo.cuesForBook(ab.bookUid);
      if (cues.isEmpty) {
        Fluttertoast.showToast(msg: '没有已存 cue，无法重跑');
        return;
      }
      final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
        ttuBookId: ttuBookId,
        serverPort: serverPort,
      );
      if (rec.sections.isEmpty) {
        Fluttertoast.showToast(msg: 'ttu IDB 没有章节文本');
        return;
      }
      final MatchResult result = await EpubCueMatcher.matchInIsolate(
        sections: rec.sections,
        cues: cues,
        searchWindow: searchWindow,
        similarityThreshold: similarityThreshold,
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
      final Map<String, List<AudioCue>> byChapter = <String, List<AudioCue>>{};
      for (final AudioCue c in cues) {
        byChapter.putIfAbsent(c.chapterHref, () => <AudioCue>[]).add(c);
      }
      for (final MapEntry<String, List<AudioCue>> entry in byChapter.entries) {
        await repo.saveCues(
          bookUid: ab.bookUid,
          chapterHref: entry.key,
          cues: entry.value,
        );
      }
      final int pct = (result.matchRate * 100).round();
      final AudiobookHealth health = AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${result.matchedCues}/${result.totalCues} cues matched '
            '(window=$searchWindow threshold=$similarityThreshold)',
      );
      await repo.updateHealthOverlay(bookUid: ab.bookUid, health: health);
      Fluttertoast.showToast(
        msg: 'Sasayaki $pct% (window=$searchWindow)',
      );
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] SasayakiRematch failed: $e\n$st');
      Fluttertoast.showToast(msg: '重跑失败：$e');
    }
  }
}

class _MatchParams {
  const _MatchParams(this.window, this.threshold);
  final int window;
  final double threshold;
}

/// 复用的 searchWindow 选择器。
class SasayakiWindowSlider extends StatelessWidget {
  const SasayakiWindowSlider({
    required this.value,
    required this.onChanged,
    this.onAutoTap,
    this.autoBusy = false,
    super.key,
  });

  static const int minWindow = 50;
  static const int maxWindow = 350;
  static const int step = 25;
  static const int divisions = (maxWindow - minWindow) ~/ step;

  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback? onAutoTap;
  final bool autoBusy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('搜索窗口', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '每条 cue 在正文里向前找的字符数。命中率低时可左右调整，'
          '过大容易被短噪声 cue 拉偏 cursor。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Slider(
                min: minWindow.toDouble(),
                max: maxWindow.toDouble(),
                divisions: divisions,
                value: value.toDouble(),
                label: '$value',
                onChanged:
                    autoBusy ? null : (double v) => onChanged(v.round()),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                '$value',
                textAlign: TextAlign.end,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '默认 ${EpubSrtMatcher.defaultSearchWindow}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onAutoTap != null)
              TextButton.icon(
                onPressed: autoBusy ? null : onAutoTap,
                icon: autoBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 16),
                label: Text(autoBusy ? '匹配中…' : '自动匹配'),
              ),
          ],
        ),
      ],
    );
  }
}

/// 复用的 similarityThreshold 选择器。
class SasayakiThresholdSlider extends StatelessWidget {
  const SasayakiThresholdSlider({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('相似度阈值', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '模糊匹配的最低相似度（Dice 系数）。降低可容忍更多文本差异，'
          '但太低会误匹配。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Slider(
                min: 0.1,
                max: 1.0,
                divisions: 9,
                value: value,
                label: value.toStringAsFixed(1),
                onChanged: (double v) =>
                    onChanged(double.parse(v.toStringAsFixed(1))),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                value.toStringAsFixed(1),
                textAlign: TextAlign.end,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        Text(
          '默认 ${EpubSrtMatcher.defaultSimilarityThreshold}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
