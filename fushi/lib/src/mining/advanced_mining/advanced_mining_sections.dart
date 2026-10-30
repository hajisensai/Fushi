import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature, PathMetric;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_mosaic.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_waveform.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningMosaicRegion;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;

/// 制卡时间标签：`mm:ss.ss`（满一小时加 `h:`），与播放器 / 字幕时间轴同一读法。
String formatAdvancedMiningTime(int ms) {
  final int clamped = ms < 0 ? 0 : ms;
  final int hours = clamped ~/ 3600000;
  final int minutes = (clamped ~/ 60000) % 60;
  final double seconds = (clamped % 60000) / 1000;
  final String ss = seconds.toStringAsFixed(2).padLeft(5, '0');
  final String mm = minutes.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// 时长标签：`4.2 s`。
String formatAdvancedMiningDuration(int ms) =>
    '${(ms / 1000).toStringAsFixed(1)} s';

/// 微调按钮文案：`−0.25s` / `+0.25s`（用真正的减号，与「−」字形对齐）。
String formatAdvancedMiningStep(int ms, {required bool forward}) {
  final String value = (ms / 1000).toStringAsFixed(2);
  return forward ? '+${value}s' : '−${value}s';
}

/// 视频图片方式的显示名。
String videoImageModeLabel(VideoMiningImageMode mode) {
  switch (mode) {
    case VideoMiningImageMode.gif:
      return t.popup_advanced_mining_image_mode_animated;
    case VideoMiningImageMode.videoClip:
      return t.popup_advanced_mining_image_mode_clip;
    case VideoMiningImageMode.currentFrame:
      return t.popup_advanced_mining_image_mode_lookup_frame;
    case VideoMiningImageMode.subtitleStart:
      return t.popup_advanced_mining_image_mode_subtitle_start;
  }
}

/// 漫画取景方式的显示名。
String mangaCropChoiceLabel(MangaCropChoice choice) {
  switch (choice) {
    case MangaCropChoice.wholePage:
      return t.popup_advanced_mining_crop_whole_page;
    case MangaCropChoice.panel:
      return t.popup_advanced_mining_crop_panel;
    case MangaCropChoice.textArea:
      return t.popup_advanced_mining_crop_text_area;
    case MangaCropChoice.custom:
      return t.popup_advanced_mining_crop_custom;
    case MangaCropChoice.none:
      return t.popup_advanced_mining_image_none;
  }
}

/// 句子分区标题行右侧的计数：`已选 3 句 · 4.2 s`（有音频区间时带时长）。
String advancedMiningSentenceSummary(AdvancedMiningController c) {
  final String count = t.popup_advanced_mining_sentence_count(
    count: c.sentenceCount,
  );
  final AdvancedMiningAudioWindow? w = c.audioWindow;
  if (w == null || c.omitAudio) return count;
  return '$count · ${formatAdvancedMiningDuration(w.durationMs)}';
}

// ───────────────────────────── 共用外壳 ─────────────────────────────

/// 一个分区的色块卡 + 标题行。[embedded] 时（窄屏摘要行展开后的内容）不画卡、不画
/// 标题——摘要行本身就是标题，再套一层卡会出现「卡里套卡」。
class AdvancedMiningSectionShell extends StatelessWidget {
  const AdvancedMiningSectionShell({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.embedded = false,
    this.expandChild = false,
  });

  final String title;
  final Widget? trailing;
  final Widget child;
  final bool embedded;

  /// 子内容是否撑满剩余高度（宽屏左栏的裁切工作区）。
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: child,
      );
    }
    final Widget header = Row(
      children: <Widget>[
        Expanded(
          child: Text(title, style: context.fushiType.titleSmallEmphasized),
        ),
        if (trailing != null) Flexible(child: trailing!),
      ],
    );
    return FushiCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: Column(
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          const SizedBox(height: 10),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// 分区里的选项胶囊（「跟随句子 / 不要」「动图 / 视频片段 …」）。按下回弹走
/// [FushiPressScale]，与卡片同一套按压语言。
class AdvancedMiningChoiceChip extends StatelessWidget {
  const AdvancedMiningChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;

  /// null = 禁用（锁住 / 该方式此刻不可选）。
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) => FushiPressScale(
    enabled: onSelected != null,
    child: FushiChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: onSelected == null ? null : (_) => onSelected!(),
    ),
  );
}

/// 「标签」小字（labelMedium + onSurfaceVariant）。
Widget _caption(BuildContext context, String text, {TextAlign? align}) => Text(
  text,
  textAlign: align,
  style: context.fushiType.labelMedium.copyWith(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// 起止 / 首尾帧的小号微调按钮（tonal XS 胶囊）。[child] 是文案或图标。
Widget _nudgeButton({
  required Widget child,
  required String tooltip,
  required VoidCallback? onPressed,
}) => FushiTooltip(
  message: tooltip,
  child: FushiFilledButton.tonal(
    size: FushiButtonSize.xs,
    onPressed: onPressed,
    child: child,
  ),
);

// ───────────────────────────── 句子 ─────────────────────────────

/// 句子分区：前文 / 当前句 / 后文一句一卡，两端是「加前一句 / 加后一句」虚线按钮，
/// 每句右侧编辑与 ×（最外侧 × = 少要一句；中间 × = 移除，留删除线 + 恢复）。
///
/// 行为沿用原「调整上下文」对话框：当前句 primary 色块 + 查词高亮（offset 命中优先、
/// 失配回退 indexOf）、同一时刻只编辑一句、编辑态锁住外层控件。
class AdvancedMiningSentencePanel extends StatelessWidget {
  const AdvancedMiningSentencePanel({
    super.key,
    required this.controller,
    required this.matched,
    this.showShortcutHint = false,
    this.embedded = false,
  });

  final AdvancedMiningController controller;
  final String matched;
  final bool showShortcutHint;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    if (c.sentenceLoading) {
      return AdvancedMiningSectionShell(
        title: t.popup_advanced_mining_sentence_section,
        embedded: embedded,
        child: const SizedBox(
          height: 80,
          child: FushiLoadingView(compact: true),
        ),
      );
    }
    final List<Widget> cards = <Widget>[
      for (int i = 0; i < c.prev.length; i++)
        _sentenceCard(
          context,
          slot: SentenceContextSlot.prev,
          index: i,
          text: c.prev[i],
          removed: c.prevRemoved[i],
        ),
      _sentenceCard(
        context,
        slot: SentenceContextSlot.current,
        index: 0,
        text: c.current,
        removed: false,
      ),
      for (int i = 0; i < c.next.length; i++)
        _sentenceCard(
          context,
          slot: SentenceContextSlot.next,
          index: i,
          text: c.next[i],
          removed: c.nextRemoved[i],
        ),
    ];
    final List<Widget> column = <Widget>[
      Center(
        child: _DashedAddButton(
          label: t.popup_ctx_prev_plus,
          onPressed: c.locked || c.prevAtMax
              ? null
              : () => unawaited(c.adjustContext(prevDir: true, plus: true)),
        ),
      ),
    ];
    for (int i = 0; i < cards.length; i++) {
      column.add(const SizedBox(height: 8));
      // 首屏错峰进场；加减句后补进来的卡在进场窗口外，瞬间出现不拖影。
      column.add(FushiStaggeredEntrance(index: i + 1, child: cards[i]));
    }
    column
      ..add(const SizedBox(height: 8))
      ..add(
        Center(
          child: _DashedAddButton(
            label: t.popup_ctx_next_plus,
            onPressed: c.locked || c.nextAtMax
                ? null
                : () => unawaited(c.adjustContext(prevDir: false, plus: true)),
          ),
        ),
      );
    if (showShortcutHint) {
      column
        ..add(const SizedBox(height: 12))
        ..add(
          _caption(
            context,
            t.popup_advanced_mining_sentence_shortcut_hint,
            align: TextAlign.center,
          ),
        );
    }
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_sentence_section,
      embedded: embedded,
      trailing: _caption(context, advancedMiningSentenceSummary(c)),
      // 加减句子时整列高度跟着长缩（M3E spatial 弹簧），而不是跳变。
      child: FushiAnimatedSize(
        duration: context.fushiMotion.spatialDefault.duration,
        curve: context.fushiMotion.spatialDefault.curve,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: column,
        ),
      ),
    );
  }

  Widget _sentenceCard(
    BuildContext context, {
    required SentenceContextSlot slot,
    required int index,
    required String text,
    required bool removed,
  }) {
    final AdvancedMiningController c = controller;
    final bool current = slot == SentenceContextSlot.current;
    final bool editingThis = c.editSlot == slot && c.editIndex == index;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String label = switch (slot) {
      SentenceContextSlot.prev => t.popup_ctx_box_prev,
      SentenceContextSlot.current => t.popup_ctx_box_current,
      SentenceContextSlot.next => t.popup_ctx_box_next,
    };
    final Color? onPrimary = fushiCardToneColors(
      context,
      FushiCardTone.primary,
    )?.onContainer;
    final Widget body = editingThis
        ? _SentenceEditor(controller: c)
        : current
        ? _highlightedCurrent(context)
        : Text(
            text,
            style: removed
                ? context.fushiType.bodyMedium.copyWith(
                    decoration: TextDecoration.lineThrough,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  )
                : context.fushiType.bodyMedium.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
          );
    final List<Widget> actions = <Widget>[
      // 已移除的句子不给编辑——先恢复再改，免得改了一句看不见效果的文本。
      if (c.sentenceSection?.editSentence != null && !removed && !editingThis)
        _iconAction(
          tooltip: t.popup_ctx_edit_start,
          icon: FushiIcons.edit,
          onPressed: c.locked ? null : () => c.startEdit(slot, index, text),
        ),
      if (!current && !editingThis && removed)
        _iconAction(
          tooltip: t.popup_ctx_sentence_restore,
          icon: FushiIcons.undo,
          onPressed: c.locked
              ? null
              : () => unawaited(c.setSentenceRemoved(slot, index, false)),
        )
      else if (!current && !editingThis && c.canDismiss(slot, index))
        _iconAction(
          tooltip: t.popup_ctx_sentence_remove,
          icon: FushiIcons.close,
          onPressed: c.locked
              ? null
              : () => unawaited(c.dismissSentence(slot, index)),
        ),
    ];
    return FushiCard(
      padding: EdgeInsets.fromLTRB(16, current ? 12 : 10, 8, current ? 12 : 10),
      tone: current ? FushiCardTone.primary : FushiCardTone.neutral,
      // 句子卡嵌在分区卡里：取设计令牌的「分组里再嵌一层」面，与分区卡分得开。
      color: current ? null : FushiDesignTokens.of(context).surfaces.card,
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: current
                      ? context.fushiType.labelMediumEmphasized.copyWith(
                          color: onPrimary,
                        )
                      : context.fushiType.labelSmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                ),
                const SizedBox(height: 4),
                // 进入 / 退出编辑态：输入框与正文之间做尺寸切换（M3E spring）。
                FushiAnimatedSize(
                  duration: context.fushiMotion.spatialDefault.duration,
                  curve: context.fushiMotion.spatialDefault.curve,
                  alignment: Alignment.topCenter,
                  child: body,
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  /// 句子卡右侧的小图标按钮。取 M3E 图标按钮 XS 档（32）：默认 48 的命中框会把
  /// 每张卡都顶高一截，矮窗里几张卡就把句子挤出屏。
  Widget _iconAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => FushiIconButtonControl(
    tooltip: tooltip,
    size: ButtonSizeVariant.xSmall,
    onPressed: onPressed,
    icon: FushiIcon(icon, size: 18),
  );

  /// 当前句里把查到的词高亮：offset 命中优先（offset 处正好是 matched），失配回退
  /// indexOf，再失配整句无高亮——与旧 popup.js `buildHighlightedCurrentText` 同容错。
  Widget _highlightedCurrent(BuildContext context) {
    final String text = controller.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 当前句卡是 primary 色块：正文跟随卡片配对前景（bodyMedium 自带页面前景色，
    // 不覆盖会在自定义主题下深底黑字，HBK-AUDIT-022）。
    final TextStyle base = context.fushiType.bodyMedium.copyWith(
      fontWeight: FontWeight.w500,
      color: fushiCardToneColors(context, FushiCardTone.primary)?.onContainer,
    );
    // M3E：命中词用 tertiaryContainer 饱和色块，落在 primaryContainer 的当前句卡上
    // 仍分得清层次。
    final TextStyle hl = base.copyWith(
      color: scheme.onTertiaryContainer,
      fontWeight: FontWeight.w700,
      backgroundColor: scheme.tertiaryContainer,
    );
    int start = -1;
    if (matched.isNotEmpty && text.isNotEmpty) {
      final int? off = controller.currentOffset;
      if (off != null &&
          off >= 0 &&
          off + matched.length <= text.length &&
          text.substring(off, off + matched.length) == matched) {
        start = off;
      } else {
        start = text.indexOf(matched);
      }
    }
    if (start < 0) return Text(text, style: base);
    return Text.rich(
      TextSpan(
        style: base,
        children: <TextSpan>[
          TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, start + matched.length),
            style: hl,
          ),
          TextSpan(text: text.substring(start + matched.length)),
        ],
      ),
    );
  }
}

/// 编辑态的卡内容：多行输入框 + 「放弃修改 / 确认修改」。确认按钮独立于底部主按钮：
/// 用户要的是「先确认这一句改完了」，改完还能继续加减句子、再改别的句子。
class _SentenceEditor extends StatelessWidget {
  const _SentenceEditor({required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      FushiTextFieldControl(
        controller: controller.editController,
        autofocus: true,
        minLines: 2,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        style: context.fushiType.bodyMedium,
        decoration: const InputDecoration(
          border: FushiOutlinedFieldBorder(),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          FushiTextButton(
            onPressed: controller.busy ? null : controller.cancelEdit,
            child: Text(t.popup_ctx_edit_cancel),
          ),
          FushiFilledButton(
            onPressed: controller.busy
                ? null
                : () => unawaited(controller.commitEdit()),
            child: Text(t.popup_ctx_edit_confirm),
          ),
        ],
      ),
    ],
  );
}

/// 列表两端的「加前一句 / 加后一句」：虚线描边胶囊（交互稿 ①），表达「这里还能再接
/// 一句」的占位感，与实线的句子卡区分开。
class _DashedAddButton extends StatelessWidget {
  const _DashedAddButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool enabled = onPressed != null;
    return FushiPressScale(
      enabled: enabled,
      child: CustomPaint(
        painter: _DashedRRectPainter(
          color: enabled
              ? scheme.outline
              : scheme.outline.withValues(alpha: 0.38),
        ),
        child: FushiTextButton.icon(
          onPressed: onPressed,
          size: FushiButtonSize.xs,
          // BUG-3211：XS 档把高度钉死在 32，长文案一折行第二行就被裁掉。放开最大
          // 高度，单行时仍是 32 高，折行时跟着文字长。
          style: const ButtonStyle(
            maximumSize: WidgetStatePropertyAll<Size>(Size.infinite),
            padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            ),
          ),
          icon: const FushiIcon(FushiIcons.add, size: 18),
          label: Text(label, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(math.min(size.height / 2, 16)),
        ),
      );
    const double dash = 4;
    const double gap = 3;
    for (final PathMetric metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ───────────────────────────── 卡组 ─────────────────────────────

/// 卡组分区：下拉（没连过 Anki 时只显示默认名 + 提示）、「同时设为默认卡组」、
/// 覆写提示。
class AdvancedMiningDeckPanel extends StatelessWidget {
  const AdvancedMiningDeckPanel({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final AdvancedMiningController controller;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final AdvancedMiningDeckSection deck = c.deckSection!;
    final List<String> options = <String>[
      ...deck.decks,
      if (c.deckName != null && !deck.decks.contains(c.deckName)) c.deckName!,
    ];
    final List<Widget> children = <Widget>[
      if (deck.decks.isEmpty) ...<Widget>[
        Text(c.deckName ?? '—', style: context.fushiType.bodyLargeEmphasized),
        const SizedBox(height: 4),
        _caption(context, t.popup_advanced_mining_deck_unavailable),
      ] else
        // 受控下拉（selected 跟着控制器走）：「恢复默认」后不用重建控件就能回到默认值。
        GamepadMenuDropdown<String>(
          entries: <GamepadDropdownEntry<String>>[
            for (final String name in options) (value: name, label: name),
          ],
          selected: c.deckName,
          enabled: !c.locked,
          onChanged: c.selectDeck,
        ),
      if (deck.setDefaultDeck != null && deck.decks.isNotEmpty)
        _DefaultDeckToggle(controller: c),
      const SizedBox(height: 4),
      _caption(context, t.popup_advanced_mining_deck_overwrite_hint),
    ];
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_deck_section,
      embedded: embedded,
      trailing: _caption(context, t.popup_advanced_mining_deck_scope_hint),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _DefaultDeckToggle extends StatelessWidget {
  const _DefaultDeckToggle({required this.controller});

  final AdvancedMiningController controller;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    // 选的就是当前默认卡组时这个选项没有意义（设成它自己），禁用而不是隐藏：
    // 隐藏会让控件在用户切换下拉时跳来跳去。
    final bool changed =
        c.deckName != null && c.deckName != c.deckSection?.defaultDeckName;
    final bool enabled = changed && !c.locked;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: MergeSemantics(
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: enabled
              ? () => c.toggleDeckAsDefault(!c.setDeckAsDefault)
              : null,
          child: Row(
            children: <Widget>[
              FushiCheckbox(
                value: changed && c.setDeckAsDefault,
                onChanged: enabled
                    ? (bool? v) => c.toggleDeckAsDefault(v ?? false)
                    : null,
              ),
              Flexible(
                child: Text(
                  t.popup_advanced_mining_deck_set_default,
                  style: context.fushiType.bodyMedium.copyWith(
                    color: enabled
                        ? null
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── 句子音频 ─────────────────────────────

/// 句子音频分区：「跟随句子 / 不要」、区间条、起止各 ±一步、时间标签、试听。
class AdvancedMiningAudioPanel extends StatelessWidget {
  const AdvancedMiningAudioPanel({
    super.key,
    required this.controller,
    required this.onTogglePreview,
    this.embedded = false,
  });

  final AdvancedMiningController controller;

  /// 试听 / 停止（由对话框统一处理「没有可试听的音频」提示）。
  final VoidCallback onTogglePreview;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final Widget choices = Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: <Widget>[
        AdvancedMiningChoiceChip(
          label: t.popup_advanced_mining_audio_follow,
          selected: !c.omitAudio,
          onSelected: c.locked ? null : () => c.setOmitAudio(false),
        ),
        AdvancedMiningChoiceChip(
          label: t.popup_advanced_mining_audio_none,
          selected: c.omitAudio,
          onSelected: c.locked ? null : () => c.setOmitAudio(true),
        ),
      ],
    );
    final Widget details;
    if (c.omitAudio) {
      details = const SizedBox.shrink();
    } else if (!c.audioLoaded) {
      details = const SizedBox(
        height: 56,
        child: Center(child: FushiLoadingView(compact: true)),
      );
    } else if (c.audioWindow == null) {
      details = Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _caption(context, t.popup_advanced_mining_audio_unavailable),
      );
    } else {
      details = _AudioDetails(controller: c, onTogglePreview: onTogglePreview);
    }
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_audio_section,
      embedded: embedded,
      trailing: embedded ? null : choices,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (embedded) ...<Widget>[choices, const SizedBox(height: 10)],
          FushiAnimatedSize(
            duration: context.fushiMotion.spatialDefault.duration,
            curve: context.fushiMotion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: details,
          ),
        ],
      ),
    );
  }
}

class _AudioDetails extends StatelessWidget {
  const _AudioDetails({
    required this.controller,
    required this.onTogglePreview,
  });

  final AdvancedMiningController controller;
  final VoidCallback onTogglePreview;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final AdvancedMiningAudioWindow w = c.audioWindow!;
    final int step = c.audioSection!.nudgeStepMs;
    VoidCallback? nudge(bool start, bool forward) => c.locked
        ? null
        : () => c.nudgeAudioEdge(start: start, deltaMs: forward ? step : -step);
    Widget edge(String label, {required bool start}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _caption(context, label),
        const SizedBox(width: 6),
        _nudgeButton(
          child: Text(formatAdvancedMiningStep(step, forward: false)),
          tooltip:
              '$label · ${t.popup_advanced_mining_audio_earlier} '
              '${formatAdvancedMiningStep(step, forward: false)}',
          onPressed: nudge(start, false),
        ),
        const SizedBox(width: 4),
        _nudgeButton(
          child: Text(formatAdvancedMiningStep(step, forward: true)),
          tooltip:
              '$label · ${t.popup_advanced_mining_audio_later} '
              '${formatAdvancedMiningStep(step, forward: true)}',
          onPressed: nudge(start, true),
        ),
      ],
    );
    final Widget rangeBar = AdvancedMiningRangeBar(
      window: w,
      startDeltaMs: c.audioStartDeltaMs,
      endDeltaMs: c.audioEndDeltaMs,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            AdvancedMiningPreviewButton(
              previewing: c.previewing,
              onPressed: c.locked ? null : onTogglePreview,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: c.audioSection!.loadWaveform == null
                  ? rangeBar
                  // 本机文件：画波形、直接拖起止点；抽不出来时自己退回区间条。
                  : AdvancedMiningWaveformSelector(
                      controller: c,
                      fallback: rangeBar,
                    ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            edge(t.popup_advanced_mining_audio_start, start: true),
            edge(t.popup_advanced_mining_audio_end, start: false),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${formatAdvancedMiningTime(w.startMs)} – '
          '${formatAdvancedMiningTime(w.endMs)} · '
          '${t.popup_advanced_mining_audio_range_hint}',
          style: context.fushiType.labelMedium.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 试听 / 停止圆钮。图标切换带缩放淡入（停止态一眼可辨，免得用户以为还没开始播）。
class AdvancedMiningPreviewButton extends StatelessWidget {
  const AdvancedMiningPreviewButton({
    super.key,
    required this.previewing,
    required this.onPressed,
    this.size = 40,
  });

  final bool previewing;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => FushiPressScale(
    enabled: onPressed != null,
    child: FushiIconButtonControl.filled(
      tooltip: previewing
          ? t.popup_ctx_preview_stop
          : t.popup_ctx_preview_audio,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        transitionBuilder: (Widget child, Animation<double> a) =>
            ScaleTransition(
              scale: a,
              child: FadeTransition(opacity: a, child: child),
            ),
        child: FushiIcon(
          previewing ? FushiIcons.stop : FushiIcons.play,
          key: ValueKey<bool>(previewing),
          size: 20,
        ),
      ),
    ),
  );
}

/// 区间条：没有波形数据，画一条「原区间 ± 余量」的轨道，高亮写进卡片的那一段，起止
/// 各一根标记。标记位置随偏移补间（M3E spatial），用户按 ±0.25s 时能看见它挪了多少。
class AdvancedMiningRangeBar extends StatelessWidget {
  const AdvancedMiningRangeBar({
    super.key,
    required this.window,
    required this.startDeltaMs,
    required this.endDeltaMs,
  });

  final AdvancedMiningAudioWindow window;
  final int startDeltaMs;
  final int endDeltaMs;

  @override
  Widget build(BuildContext context) {
    // 轨道域取「未偏移的原区间」外扩：域跟着原区间走、不跟着当前区间走，起止标记
    // 才会在用户微调时真的移动（域若跟当前区间，标记永远停在同一位置）。
    final int baseStart = window.startMs - startDeltaMs;
    final int baseEnd = window.endMs - endDeltaMs;
    final int margin = math.max(
      1000,
      math.max(startDeltaMs.abs(), endDeltaMs.abs()) + 500,
    );
    final double domainStart = (math.min(baseStart, window.startMs) - margin)
        .toDouble();
    final double domainEnd = (math.max(baseEnd, window.endMs) + margin)
        .toDouble();
    final double span = math.max(1, domainEnd - domainStart);
    final double a = ((window.startMs - domainStart) / span).clamp(0.0, 1.0);
    final double b = ((window.endMs - domainStart) / span).clamp(0.0, 1.0);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(end: Offset(a, b)),
        duration: context.fushiMotion.spatialFast.duration,
        curve: context.fushiMotion.spatialFast.curve,
        builder: (BuildContext context, Offset range, Widget? _) => CustomPaint(
          painter: _RangeBarPainter(
            start: range.dx,
            end: range.dy,
            track: scheme.outlineVariant,
            fill: scheme.primary.withValues(alpha: 0.45),
            marker: scheme.primary,
          ),
        ),
      ),
    );
  }
}

class _RangeBarPainter extends CustomPainter {
  const _RangeBarPainter({
    required this.start,
    required this.end,
    required this.track,
    required this.fill,
    required this.marker,
  });

  final double start;
  final double end;
  final Color track;
  final Color fill;
  final Color marker;

  @override
  void paint(Canvas canvas, Size size) {
    final double cy = size.height / 2;
    final RRect trackRect = RRect.fromLTRBR(
      0,
      cy - 6,
      size.width,
      cy + 6,
      const Radius.circular(6),
    );
    canvas.drawRRect(trackRect, Paint()..color = track);
    final double x0 = start * size.width;
    final double x1 = math.max(x0, end * size.width);
    canvas.drawRRect(
      RRect.fromLTRBR(x0, cy - 10, x1, cy + 10, const Radius.circular(4)),
      Paint()..color = fill,
    );
    final Paint m = Paint()..color = marker;
    for (final double x in <double>[x0, x1]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          x - 1.5,
          0,
          x + 1.5,
          size.height,
          const Radius.circular(2),
        ),
        m,
      );
    }
  }

  @override
  bool shouldRepaint(_RangeBarPainter old) =>
      old.start != start ||
      old.end != end ||
      old.track != track ||
      old.fill != fill ||
      old.marker != marker;
}

// ───────────────────────────── 视频图片 ─────────────────────────────

/// 视频图片分区：方式选项（动图 / 片段 / 查词时画面 / 字幕开头 / 不要），动图与片段
/// 显示首尾帧并可逐帧挪动（挪的是与音频共用的起止偏移），静态方式显示一帧并可挪动。
class AdvancedMiningVideoImagePanel extends StatelessWidget {
  const AdvancedMiningVideoImagePanel({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final AdvancedMiningController controller;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningController c = controller;
    final List<VideoMiningImageMode> modes = c.availableImageModes;
    final VideoMiningImageMode? mode = c.videoImageMode;
    final bool clipBlocked =
        c.omitAudio && modes.contains(VideoMiningImageMode.videoClip);
    final Widget chips = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final VideoMiningImageMode m in modes)
          AdvancedMiningChoiceChip(
            label: videoImageModeLabel(m),
            selected: mode == m,
            onSelected: c.locked || !c.isImageModeEnabled(m)
                ? null
                : () => c.selectVideoImageMode(m),
          ),
        AdvancedMiningChoiceChip(
          label: t.popup_advanced_mining_image_none,
          selected: mode == null,
          onSelected: c.locked ? null : () => c.selectVideoImageMode(null),
        ),
      ],
    );
    return AdvancedMiningSectionShell(
      title: t.popup_advanced_mining_image_section,
      embedded: embedded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          chips,
          if (clipBlocked) ...<Widget>[
            const SizedBox(height: 6),
            _caption(context, t.popup_advanced_mining_image_clip_needs_audio),
          ],
          FushiAnimatedSize(
            duration: context.fushiMotion.spatialDefault.duration,
            curve: context.fushiMotion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              child: KeyedSubtree(
                key: ValueKey<VideoMiningImageMode?>(mode),
                child: _frames(context, mode),
              ),
            ),
          ),
          // 打码对着「会进卡的那一帧」框：静态方式 = 那一帧（挪了帧再打开，看到的就是
          // 新的那一帧）；动图 / 片段 = 降级后的字幕开头那一帧，并提示改出静图。
          if (c.mosaicApplicable) ...<Widget>[
            const SizedBox(height: 8),
            AdvancedMiningMosaicBar(
              controller: c,
              loadBytes: () async {
                final Future<Uint8List?> Function(int atMs)? frameAt =
                    c.videoSection?.frameAt;
                final int? at = c.mosaicFrameMs;
                return frameAt == null || at == null ? null : frameAt(at);
              },
              note: c.mosaicForcesStill
                  ? t.popup_advanced_mining_mosaic_forces_still
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _frames(BuildContext context, VideoMiningImageMode? mode) {
    final AdvancedMiningController c = controller;
    final AdvancedMiningVideoImageSection section = c.videoSection!;
    if (mode == null) return const SizedBox(width: double.infinity);
    if (mode.isStill) {
      final int? at = c.stillFrameMs;
      if (at == null) return const SizedBox(width: double.infinity);
      final Future<Uint8List?> Function(int atMs)? frameAt = section.frameAt;
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: AdvancedMiningFrameTile(
                    caption:
                        '${videoImageModeLabel(mode)} ${formatAdvancedMiningTime(at)}',
                    atMs: at,
                    frameAt: frameAt,
                    mosaic: c.mosaicRegions,
                    onBack: c.locked
                        ? null
                        : () => c.nudgeStillFrame(forward: false),
                    onForward: c.locked
                        ? null
                        : () => c.nudgeStillFrame(forward: true),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ],
        ),
      );
    }
    final AdvancedMiningAudioWindow? w = c.audioWindow;
    if (w == null) return const SizedBox(width: double.infinity);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: AdvancedMiningFrameTile(
              caption: t.popup_advanced_mining_image_first_frame(
                time: formatAdvancedMiningTime(w.startMs),
              ),
              atMs: w.startMs,
              frameAt: section.frameAt,
              onBack: c.locked
                  ? null
                  : () => c.nudgeVideoEdge(first: true, forward: false),
              onForward: c.locked
                  ? null
                  : () => c.nudgeVideoEdge(first: true, forward: true),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AdvancedMiningFrameTile(
              caption: t.popup_advanced_mining_image_last_frame(
                time: formatAdvancedMiningTime(w.endMs),
              ),
              atMs: w.endMs,
              frameAt: section.frameAt,
              onBack: c.locked
                  ? null
                  : () => c.nudgeVideoEdge(first: false, forward: false),
              onForward: c.locked
                  ? null
                  : () => c.nudgeVideoEdge(first: false, forward: true),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一帧缩略图 + 时间角标 + 「上一帧 / 下一帧」。
class AdvancedMiningFrameTile extends StatelessWidget {
  const AdvancedMiningFrameTile({
    super.key,
    required this.caption,
    required this.atMs,
    required this.frameAt,
    required this.onBack,
    required this.onForward,
    this.mosaic = const <MiningMosaicRegion>[],
  });

  final String caption;
  final int atMs;
  final Future<Uint8List?> Function(int atMs)? frameAt;

  /// 打码区域（静态封面帧）：缩略图按卡上的样子画出马赛克。
  final List<MiningMosaicRegion> mosaic;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          child: SizedBox(
            height: 72,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: FushiDesignTokens.of(context).surfaces.overlay,
                ),
                if (frameAt != null)
                  AdvancedMiningFrameThumb(
                    atMs: atMs,
                    frameAt: frameAt!,
                    mosaic: mosaic,
                  ),
                Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0x99000000),
                        borderRadius: BorderRadius.all(Radius.circular(4)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        child: Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.labelSmall.copyWith(
                            color: Colors.white,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Expanded(
              child: _nudgeButton(
                tooltip: t.popup_advanced_mining_image_frame_back,
                child: const FushiIcon(FushiIcons.stepBackward, size: 16),
                onPressed: onBack,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _nudgeButton(
                tooltip: t.popup_advanced_mining_image_frame_forward,
                child: const FushiIcon(FushiIcons.stepForward, size: 16),
                onPressed: onForward,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 某一时刻的缩略图。请求**防抖约 100ms、只保留最新一次**：连按「下一帧」时每次都
/// 去解一帧会把宿主（mpv 截图 / ffmpeg）排成长队，而用户只关心停下来那一帧。
class AdvancedMiningFrameThumb extends StatefulWidget {
  const AdvancedMiningFrameThumb({
    super.key,
    required this.atMs,
    required this.frameAt,
    this.mosaic = const <MiningMosaicRegion>[],
  });

  static const Duration debounce = Duration(milliseconds: 100);

  final int atMs;
  final Future<Uint8List?> Function(int atMs) frameAt;
  final List<MiningMosaicRegion> mosaic;

  @override
  State<AdvancedMiningFrameThumb> createState() =>
      _AdvancedMiningFrameThumbState();
}

class _AdvancedMiningFrameThumbState extends State<AdvancedMiningFrameThumb> {
  Timer? _timer;
  int _gen = 0;
  Uint8List? _bytes;
  int? _bytesAt;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(AdvancedMiningFrameThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.atMs != widget.atMs) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    final int gen = ++_gen;
    _timer = Timer(AdvancedMiningFrameThumb.debounce, () => _fetch(gen));
  }

  Future<void> _fetch(int gen) async {
    final int at = widget.atMs;
    Uint8List? bytes;
    try {
      bytes = await widget.frameAt(at);
    } catch (_) {
      bytes = null;
    }
    if (!mounted || gen != _gen) return;
    // 这一帧没取到：保留上一张（只显示时间戳的角标照样更新），不闪回空白。
    if (bytes == null) return;
    setState(() {
      _bytes = bytes;
      _bytesAt = at;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: bytes == null
          ? const SizedBox.expand()
          : widget.mosaic.isNotEmpty
          ? MiningMosaicImage(
              key: ValueKey<int?>(_bytesAt),
              bytes: bytes,
              regions: widget.mosaic,
              fit: BoxFit.cover,
            )
          : Image.memory(
              bytes,
              key: ValueKey<int?>(_bytesAt),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  const SizedBox.expand(),
            ),
    );
  }
}
