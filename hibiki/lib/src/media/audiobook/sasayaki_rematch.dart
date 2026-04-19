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

  /// 书架侧决定是否挂"重新匹配"按钮的前置条件。
  static bool isEligible(Audiobook ab) {
    return supportedFormats.contains(ab.alignmentFormat);
  }

  /// 弹 bottom sheet 让用户调 window → 跑 matcher → toast 结果。
  ///
  /// - 用户取消 → 返回 false，不会触发 onRunningChanged。
  /// - ttu 绑定缺失 → 提前 toast 并返回 null。
  /// - 跑完（无论命中率高低还是异常） → 返回 true，caller 可据此刷新 UI。
  ///
  /// [onRunningChanged] 用于外部显示进度（dialog 本身的 `_importing`
  /// 灰化 / 书架的 loading barrier 等）。
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
    final AudiobookHealth? overlay = repo.readHealthOverlay(ab.bookUid);
    final int? picked = await _pickSearchWindow(
      context: context,
      previousReason: overlay?.reason,
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
        searchWindow: picked,
      );
      return true;
    } finally {
      onRunningChanged?.call(false);
    }
  }

  static Future<int?> _pickSearchWindow({
    required BuildContext context,
    required String? previousReason,
  }) async {
    int window = EpubSrtMatcher.defaultSearchWindow;
    if (previousReason != null) {
      // 尝试从上一次 overlay reason 里抠 window= 值，让用户看到"上次用
      // 了多少"，而不是每次从 default 开始。
      final RegExpMatch? m = RegExp(r'window=(\d+)').firstMatch(previousReason);
      final int? prev = m == null ? null : int.tryParse(m.group(1)!);
      if (prev != null) {
        window = prev.clamp(300, 5000);
      }
    }
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetCtx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheet) {
            final ThemeData theme = Theme.of(ctx);
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
                    Text('搜索窗口', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '每条 cue 在正文里向前找的字符数。命中率低时加大；'
                      '文本重复段多可收紧避免误匹配。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            min: 300,
                            max: 5000,
                            divisions: 47,
                            value: window.toDouble(),
                            label: '$window',
                            onChanged: (double v) {
                              setSheet(() => window = v.round());
                            },
                          ),
                        ),
                        SizedBox(
                          width: 64,
                          child: Text(
                            '$window',
                            textAlign: TextAlign.end,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '默认 ${EpubSrtMatcher.defaultSearchWindow}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('重跑匹配'),
                          onPressed: () => Navigator.pop(sheetCtx, window),
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

  static Future<void> _run({
    required Audiobook ab,
    required AudiobookRepository repo,
    required int ttuBookId,
    required int serverPort,
    required int searchWindow,
  }) async {
    try {
      final List<AudioCue> cues = repo.cuesForBook(ab.bookUid);
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
      );
      SasayakiMatchCodec.applyToCues(cues: cues, result: result);
      // 保持原章节分组；saveCues 要求按 chapterHref 分批写（同 chapterHref
      // 的旧数据会被清掉再重写）。
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
            '(window=$searchWindow)',
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
