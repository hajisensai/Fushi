import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pdf/pdf_text_search.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// PDF 全文搜索弹层：输入框 + 搜索键，结果按页流式列出（引文卡：上标页码、片段里
/// 命中词高亮，错峰进场），点结果 = 关面板、跳到该页并高亮命中。无文本层的扫描版
/// PDF 明确提示搜不了（拍板台 KN4kdP4JB8）。
///
/// 外壳是 [FushiModalSheetFrame]（窄屏 M3E 底部弹层 / 宽屏居中浮动面板，Apple 走
/// iOS sheet 观感），结果卡 / 空状态 / 小节标题与小说阅读器书内搜索同一套
/// `reader_panel_kit` 组件，两套设计系统都只从主题取色。
class PdfSearchSheet extends StatefulWidget {
  const PdfSearchSheet({
    super.key,
    required this.controller,
    required this.pageCount,
    required this.onSelect,
  });

  /// 阅读页持有的搜索会话（关掉面板再打开，上次的查询与结果还在）。
  final PdfTextSearchController controller;

  /// 本书总页数（搜索范围）。
  final int pageCount;

  /// 点了第 [index] 条结果（调用方负责关面板、跳页）。
  final ValueChanged<int> onSelect;

  @override
  State<PdfSearchSheet> createState() => _PdfSearchSheetState();
}

class _PdfSearchSheetState extends State<PdfSearchSheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.query,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    widget.controller.search(_text.text, pageCount: widget.pageCount);
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      key: const ValueKey<String>('pdf_search_sheet'),
      title: t.pdf_search,
      leadingIcon: FushiIcons.search,
      maxHeightFactor: 0.82,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (BuildContext context, Widget? child) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildQueryRow(context),
            ),
            Flexible(child: _buildResults(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildQueryRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final bool searching =
        widget.controller.status == PdfTextSearchStatus.searching;
    return Row(
      children: <Widget>[
        Expanded(
          child: FushiTextField(
            key: const ValueKey<String>('pdf_search_field'),
            controller: _text,
            autofocus: true,
            hintText: t.book_search_hint,
            textInputAction: TextInputAction.search,
            prefixIcon: FushiIcon(
              FushiIcons.search,
              size: 20,
              color: fushiNeutralSecondaryForeground(context),
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
            style: theme.textTheme.bodyLarge,
            onSubmitted: (_) => _submit(),
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
        SizedBox.square(
          dimension: 48,
          child: Center(
            child: searching
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: adaptiveIndicator(context: context, strokeWidth: 2),
                  )
                : FushiIconButton(
                    key: const ValueKey<String>('pdf_search_submit'),
                    icon: FushiIcons.forward,
                    size: 22,
                    // 与书内搜索同形：M3E 强调色实心圆角方块，Apple 强调色实心圆。
                    backgroundColor: glass
                        ? appleColorsOf(context).accent
                        : theme.colorScheme.primary,
                    enabledColor: glass
                        ? appleColorsOf(context).onAccent
                        : theme.colorScheme.onPrimary,
                    shapeBorder: glass
                        ? const CircleBorder()
                        : const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                    padding: EdgeInsets.all(tokens.spacing.gap + 4),
                    tooltip: t.search,
                    onTap: _submit,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    final PdfTextSearchController search = widget.controller;
    final ThemeData theme = Theme.of(context);
    final List<PdfTextSearchHit> hits = search.hits;
    switch (search.status) {
      case PdfTextSearchStatus.idle:
        return const SizedBox(height: 8);
      case PdfTextSearchStatus.noTextLayer:
        return ReaderPanelEmpty(
          key: const ValueKey<String>('pdf_search_no_text_layer'),
          icon: FushiIcons.imageSearch,
          message: t.pdf_search_no_text_layer,
        );
      case PdfTextSearchStatus.failed:
        return ReaderPanelEmpty(
          key: const ValueKey<String>('pdf_search_failed'),
          icon: FushiIcons.searchOff,
          message: t.book_search_failed,
          actionLabel: t.retry,
          onAction: _submit,
        );
      case PdfTextSearchStatus.done when hits.isEmpty:
        return ReaderPanelEmpty(
          key: const ValueKey<String>('pdf_search_no_results'),
          icon: FushiIcons.searchOff,
          message: t.book_search_no_results,
        );
      case PdfTextSearchStatus.searching:
      case PdfTextSearchStatus.done:
        break;
    }
    final bool searching = search.status == PdfTextSearchStatus.searching;
    final int total = search.pageCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (searching)
          Padding(
            key: const ValueKey<String>('pdf_search_progress'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ReaderPanelProgress(
                  value: total <= 0 ? 0 : search.searchedPages / total,
                ),
                const SizedBox(height: 6),
                Text(
                  t.pdf_search_progress(
                    current: search.searchedPages,
                    total: total,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fushiNeutralSecondaryForeground(context),
                  ),
                ),
              ],
            ),
          ),
        if (hits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ReaderPanelSectionLabel(
              t.book_search_results(n: hits.length),
              trailing: '「${search.query}」',
            ),
          ),
        if (search.truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              t.pdf_search_truncated(n: hits.length),
              key: const ValueKey<String>('pdf_search_truncated'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: fushiNeutralSecondaryForeground(context),
              ),
            ),
          ),
        if (hits.isNotEmpty)
          Flexible(
            child: FushiEntranceScope(
              child: ListView.separated(
                key: const ValueKey<String>('pdf_search_results'),
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: hits.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (BuildContext context, int i) {
                  final PdfTextSearchHit hit = hits[i];
                  return FushiStaggeredEntrance(
                    index: i,
                    child: ReaderQuoteCard(
                      key: ValueKey<String>('pdf_search_result_$i'),
                      overline: t.pdf_search_page(page: hit.pageIndex + 1),
                      accent: i == search.currentIndex
                          ? fushiAccentForeground(context)
                          : null,
                      quote: Text.rich(
                        readerHighlightSpans(
                          context,
                          text: hit.snippet,
                          start: hit.snippetMatchStart,
                          end: hit.snippetMatchEnd,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => widget.onSelect(i),
                      focusIdPrefix: 'pdf-search-result',
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// 有结果时浮在翻页胶囊上方的命中导航胶囊：关闭搜索 / 「3 / 27」（点开结果列表）/
/// 上一个 / 下一个。与翻页胶囊同一套悬浮胶囊 + 弹簧显隐（[FushiChromeReveal]），
/// 按钮走设计系统按钮（[FushiIconButtonControl] / [FushiTextButton]，自带按压反馈）。
class PdfSearchNavigator extends StatelessWidget {
  const PdfSearchNavigator({
    super.key,
    required this.controller,
    required this.visible,
    required this.onPrevious,
    required this.onNext,
    required this.onShowResults,
    required this.onClose,
  });

  final PdfTextSearchController controller;

  /// 外部条件（chrome 显示中）；还要有结果才真正露出。
  final bool visible;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onShowResults;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final bool show = visible && controller.hasHits;
        return FushiChromeReveal(
          key: const ValueKey<String>('pdf_search_navigator'),
          visible: show,
          from: AxisDirection.down,
          child: !show ? const SizedBox.shrink() : _buildPill(context),
        );
      },
    );
  }

  Widget _buildPill(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? current = controller.currentIndex;
    final int total = controller.hits.length;
    final String position = current == null
        ? '$total'
        : '${current + 1} / $total';
    return Padding(
      padding: const EdgeInsets.only(
        bottom: kFushiFloatingToolbarEdgeMargin / 2,
      ),
      child: Center(
        child: FushiFloatingPill(
          color: fushiFloatingToolbarPalette(context).container,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButtonControl(
                key: const ValueKey<String>('pdf_search_close'),
                tooltip: t.pdf_search_close,
                icon: const FushiIcon(FushiIcons.close),
                onPressed: onClose,
              ),
              FushiTooltip(
                message: t.pdf_search_show_results,
                child: FushiTextButton(
                  key: const ValueKey<String>('pdf_search_position'),
                  onPressed: onShowResults,
                  child: Text(
                    position,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fushiFloatingToolbarPalette(context).foreground,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('pdf_search_previous'),
                tooltip: t.pdf_search_previous_match,
                icon: const FushiIcon(FushiIcons.expandLess),
                onPressed: onPrevious,
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('pdf_search_next'),
                tooltip: t.pdf_search_next_match,
                icon: const FushiIcon(FushiIcons.expandMore),
                onPressed: onNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
