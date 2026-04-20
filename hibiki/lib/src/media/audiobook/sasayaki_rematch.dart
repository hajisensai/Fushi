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

  /// 书架侧决定是否挂"重新匹配"按钮的前置条件。
  ///
  /// 历史坏数据（Isar 长 CJK bookUid 双 put 后出现的 `alignmentFormat = "s"`
  /// 之类脏值，见 `project_hoshi_isar_double_put` 记忆）会同时污染
  /// `alignmentFormat` 和 `alignmentPath`，无法靠白名单命中。所以改成黑名单：
  /// 只要 format / path-ext 都不是 smil/json，就放过去让用户重跑。
  /// 重跑流程本身只读 `bookUid`，不读这两个字段，脏值无害。
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
    // 无扩展名或 split 后等于原路径 → 返回空串，让调用方按"不支持"处理。
    if (last == path.toLowerCase()) {
      return '';
    }
    return last;
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
    required AudiobookRepository repo,
    required String bookUid,
    required int ttuBookId,
    required int serverPort,
  }) async {
    int window = EpubSrtMatcher.defaultSearchWindow;
    if (previousReason != null) {
      // 尝试从上一次 overlay reason 里抠 window= 值，让用户看到"上次用
      // 了多少"，而不是每次从 default 开始。
      final RegExpMatch? m = RegExp(r'window=(\d+)').firstMatch(previousReason);
      final int? prev = m == null ? null : int.tryParse(m.group(1)!);
      if (prev != null) {
        window = prev.clamp(
          SasayakiWindowSlider.minWindow,
          SasayakiWindowSlider.maxWindow,
        );
      }
    }
    // sheet 内部的 probe 缓存 — 反复点「自动匹配」时只读一次 ttu IDB /
    // Isar cues。sheet 关闭即释放。
    bool autoBusy = false;
    List<EpubSection>? probedSections;
    List<AudioCue>? probedCues;
    return showModalBottomSheet<int>(
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
                probedCues ??= repo.cuesForBook(bookUid);
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
                              : () => Navigator.pop(sheetCtx, window),
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

  /// 自动匹配按钮的共享实现：在 isolate 里对多档 searchWindow 探测，挑出命中率
  /// 最高者并 toast。返回选中的 window 值，失败 / 缺数据 / 全 0 → 返回 null
  /// 供调用方保持原值。
  ///
  /// 由 [AudiobookImportDialog] 的导入前 slider 与重跑底表单共用，两边只需
  /// 各自准备好 sections + cues。
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

/// 复用的 searchWindow 选择器。范围 / 步长对齐 iOS Sasayaki
/// `SasayakiMatchView` 的 `Slider(value:$searchWindow, in:50...350, step:25)`，
/// 供重跑底表单与两个导入对话框共用。
///
/// 传入 [onAutoTap] 时在"默认 X"那一行右侧挂「自动匹配」按钮；实际跑
/// [EpubCueMatcher.probeInIsolate] 和回写 value 的逻辑由调用方负责。
/// [autoBusy] 为 true 时 slider 与按钮一并禁用。
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
