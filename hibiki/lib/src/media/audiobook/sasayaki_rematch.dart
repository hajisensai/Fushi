import 'package:flutter/material.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart'
    show AudiobookImportDialog;

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/utils.dart';

/// Sasayaki 重匹配入口，被 [AudiobookImportDialog]（已附加视图）和书架
/// 长按菜单复用。把"弹 searchWindow slider" 和"跑 matcher + 落库 + toast"
/// 统一在这里，两处 UI 不再各持一份容易漂移的副本。
class SasayakiRematch {
  const SasayakiRematch._();

  /// 只有 SRT/LRC/VTT/ASS 走 matcher；SMIL/JSON 有硬时间码锚点，与 window 无关。
  static const Set<String> supportedFormats = <String>{
    'srt',
    'lrc',
    'vtt',
    'ass'
  };

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
    void Function(bool running)? onRunningChanged,
  }) async {
    if (ttuBookId <= 0) {
      HibikiToast.show(msg: t.ttu_not_bound_cannot_rematch);
      return null;
    }
    final AudiobookHealth? overlay = await repo.readHealthOverlay(ab.bookUid);
    if (!context.mounted) return null;
    final _MatchParams? picked = await _pickMatchParams(
      context: context,
      previousReason: overlay?.reason,
      repo: repo,
      bookUid: ab.bookUid,
      ttuBookId: ttuBookId,
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
    Widget buildSheetBody(BuildContext sheetCtx, StateSetter setSheet) {
      Future<void> handleAuto() async {
        setSheet(() => autoBusy = true);
        try {
          probedSections ??= await _loadSections(
            ttuBookId: ttuBookId,
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
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SasayakiWindowSlider(
                value: window,
                onChanged: (v) => setSheet(() => window = v),
                onAutoTap: handleAuto,
                autoBusy: autoBusy,
              ),
              const SizedBox(height: 12),
              SasayakiThresholdSlider(
                value: threshold,
                onChanged: (v) => setSheet(() => threshold = v),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: autoBusy ? null : () => Navigator.pop(sheetCtx),
                    child: Text(t.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_outlined, size: 18),
                    label: Text(t.rematch_run),
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
    }

    if (isDesktopPlatform) {
      return showAppDialog<_MatchParams>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 400),
            child: StatefulBuilder(builder: buildSheetBody),
          ),
        ),
      );
    }
    return showModalBottomSheet<_MatchParams>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: buildSheetBody),
    );
  }

  static Future<int?> runAutoProbe({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    List<int> windows = EpubCueMatcher.defaultProbeWindows,
  }) async {
    if (sections.isEmpty) {
      HibikiToast.show(msg: t.sasayaki_no_sections);
      return null;
    }
    if (cues.isEmpty) {
      HibikiToast.show(msg: t.sasayaki_no_cues_to_match);
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
        HibikiToast.show(msg: t.sasayaki_all_zero);
        return null;
      }
      final int pct = (best.value * 100).round();
      HibikiToast.show(msg: t.sasayaki_auto_picked(window: best.key, pct: pct));
      return best.key;
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] autoProbe failed: $e\n$st');
      HibikiToast.show(msg: t.sasayaki_auto_failed(error: e));
      return null;
    }
  }

  static Future<List<EpubSection>> _loadSections({
    required int ttuBookId,
  }) async {
    try {
      final String extractDir = await EpubStorage.bookDirectory(ttuBookId);
      final EpubBook book = EpubParser.parseFromExtracted(extractDir);
      return List<EpubSection>.generate(
        book.chapters.length,
        (i) => EpubSection(
          index: i,
          href: book.chapters[i].href,
          text: book.chapterPlainText(i),
        ),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SasayakiRematch.loadSections', e, stack);
      debugPrint('[hibiki-audiobook] loadSections failed: $e');
      return const <EpubSection>[];
    }
  }

  static Future<void> _run({
    required Audiobook ab,
    required AudiobookRepository repo,
    required int ttuBookId,
    required int searchWindow,
    double similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold,
  }) async {
    try {
      final List<AudioCue> cues = await repo.cuesForBook(ab.bookUid);
      if (cues.isEmpty) {
        HibikiToast.show(msg: t.sasayaki_no_stored_cues);
        return;
      }
      final String extractDir = await EpubStorage.bookDirectory(ttuBookId);
      final EpubBook book = EpubParser.parseFromExtracted(extractDir);
      final List<EpubSection> sections = List<EpubSection>.generate(
        book.chapters.length,
        (i) => EpubSection(
          index: i,
          href: book.chapters[i].href,
          text: book.chapterPlainText(i),
        ),
      );
      if (sections.isEmpty) {
        HibikiToast.show(msg: t.sasayaki_no_chapters);
        return;
      }
      final MatchResult result = await EpubCueMatcher.matchInIsolate(
        sections: sections,
        cues: cues,
        searchWindow: searchWindow,
        similarityThreshold: similarityThreshold,
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
      await repo.saveCues(
        bookUid: ab.bookUid,
        cues: cues,
      );
      final int pct = (result.matchRate * 100).round();
      final AudiobookHealth health = AudiobookHealth.fromRatePct(
        ratePct: pct,
        reason: '${result.matchedCues}/${result.totalCues} cues matched '
            '(window=$searchWindow threshold=$similarityThreshold)',
      );
      await repo.updateHealthOverlay(bookUid: ab.bookUid, health: health);
      HibikiToast.show(
        msg: t.sasayaki_rematch_result(pct: pct, window: searchWindow),
      );
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] SasayakiRematch failed: $e\n$st');
      HibikiToast.show(msg: t.sasayaki_rematch_failed(error: e));
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
  static const int maxWindow = 1000;
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
        Text(t.sasayaki_search_window, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          t.sasayaki_window_hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: adaptiveSlider(
                context: context,
                min: minWindow.toDouble(),
                max: maxWindow.toDouble(),
                divisions: divisions,
                value: value.toDouble(),
                label: '$value',
                onChanged: autoBusy ? null : (v) => onChanged(v.round()),
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
          children: [
            Expanded(
              child: Text(
                t.sasayaki_default_value(n: EpubSrtMatcher.defaultSearchWindow),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onAutoTap != null)
              TextButton.icon(
                onPressed: autoBusy ? null : onAutoTap,
                icon: autoBusy
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 16),
                label: Text(
                    autoBusy ? t.sasayaki_matching : t.sasayaki_auto_match),
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
        Text(t.sasayaki_similarity_threshold,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          t.sasayaki_threshold_hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: adaptiveSlider(
                context: context,
                min: 0.1,
                divisions: 9,
                value: value,
                label: value.toStringAsFixed(1),
                onChanged: (v) => onChanged(double.parse(v.toStringAsFixed(1))),
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
          t.sasayaki_default_value(
              n: EpubSrtMatcher.defaultSimilarityThreshold),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
