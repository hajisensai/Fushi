/// 浏览页的卡片预览：正面 / 背面用复习页同一个卡面视图（[srsCardFaceBuilderProvider]）渲染，
/// 带上一张 / 下一张 / 编辑。宽屏嵌在列表右侧（[SrsBrowsePreview]），窄屏单独压一页
/// （浏览页检查器 / 详情页里同一个组件）。
///
/// 键盘（预览页焦点作用域内）：Enter / 空格 = 翻面（与复习页同一个约定：空格只在卡面视图里
/// 有「翻面」含义，全局的裸空格中和挂在根上、本页更近先消费）；← / → = 上一张 / 下一张。
/// 卡面 WebView 持焦时经键盘桥（[kSrsBrowseBridgeKeys]）交回同一入口。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart'
    show SrsFushiCardView;
import 'package:fushi/src/pages/implementations/srs/srs_html_card_view.dart'
    show SrsHtmlCardView, srsNativeHtmlCardFor;
import 'package:fushi/src/srs/srs_html_card.dart' show SrsHtmlCard;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

/// 预览区收到的动作（键盘 / 键盘桥 / 按钮统一走这里）。
enum SrsPreviewCommand { flip, previous, next, undo, escape }

/// 键盘桥 token → 预览动作。
SrsPreviewCommand? srsPreviewCommandOfToken(String token) => switch (token) {
  'Space' || 'Enter' || 'NumpadEnter' => SrsPreviewCommand.flip,
  'ArrowLeft' || 'ArrowUp' => SrsPreviewCommand.previous,
  'ArrowRight' || 'ArrowDown' => SrsPreviewCommand.next,
  'Ctrl+KeyZ' || 'Meta+KeyZ' => SrsPreviewCommand.undo,
  'Escape' => SrsPreviewCommand.escape,
  _ => null,
};

/// 一张卡的预览（正面 / 背面 + 导航按钮）。卡面内容按 [cardId] 与 [revision] 重新加载。
class SrsBrowsePreview extends ConsumerStatefulWidget {
  const SrsBrowsePreview({
    super.key,
    required this.cardId,
    required this.revision,
    required this.showAnswer,
    required this.onCommand,
    required this.onEdit,
    this.position,
    this.hasPrevious = false,
    this.hasNext = false,
    this.lookup,
    this.onLookupClosed,
  });

  final String cardId;

  /// 写操作后递增：同一张卡的内容可能变了，重新渲染。
  final int revision;
  final bool showAnswer;
  final void Function(SrsPreviewCommand command) onCommand;
  final VoidCallback onEdit;

  /// 「3 / 20」之类的位置说明。
  final String? position;
  final bool hasPrevious;
  final bool hasNext;

  /// 卡面查词控制器（页面拿它挡住弹窗打开期间的翻面 / 换卡键）；null = 预览自己建一个。
  final SrsCardLookupController? lookup;

  /// 查词弹窗整栈关掉之后（页面据此回收焦点）。
  final VoidCallback? onLookupClosed;

  @override
  ConsumerState<SrsBrowsePreview> createState() => _SrsBrowsePreviewState();
}

class _SrsBrowsePreviewState extends ConsumerState<SrsBrowsePreview> {
  SrsCardDetail? _detail;
  SrsRenderedCard? _rendered;
  bool _loading = true;
  Object? _error;
  int _loadSeq = 0;
  SrsCardLookupController? _ownLookup;

  SrsCardLookupController get _lookup =>
      widget.lookup ?? (_ownLookup ??= SrsCardLookupController());

  @override
  void dispose() {
    _ownLookup?.dispose();
    super.dispose();
  }

  void _openSource(CardSourceLink link) {
    _lookup.closeAll();
    srsRunLogged(
      'SrsBrowsePreview.openSource',
      () => openCardSource(ref: ref, link: link),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SrsBrowsePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId != widget.cardId ||
        oldWidget.showAnswer != widget.showAnswer) {
      _lookup.closeAll();
    }
    if (oldWidget.cardId != widget.cardId ||
        oldWidget.revision != widget.revision) {
      unawaited(_load());
    }
  }

  /// 载入一张卡。换卡期间旧卡面留在原位（上面压一条进度条），不把卡面换成加载视图：卡面是平台视图，
  /// 从树上摘下再挂回去就是销毁重建 WebView（首帧前整块空白）。出错显示错误态，不永远转圈。
  Future<void> _load() async {
    final int seq = ++_loadSeq;
    if (!_loading) setState(() => _loading = true);
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsCardDetail? detail = await store.cardDetail(widget.cardId);
      final SrsRenderedCard? rendered = await store.renderCard(widget.cardId);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _detail = detail;
        _rendered = rendered;
        _error = null;
        _loading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowsePreview.load', e, stack);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardDetail? detail = _detail;
    final SrsRenderedCard? rendered = _rendered;
    final bool hasFace = detail != null && rendered != null;
    Widget? face;
    if (detail != null && rendered != null) {
      final String language = ref.read(appProvider).defaultContentLanguage;
      final SrsCardFace cardFace = SrsCardFace(
        cardId: detail.card.id,
        showingAnswer: widget.showAnswer,
        bodyHtml: widget.showAnswer ? rendered.answer : rendered.question,
        css: rendered.css,
        languageCode: language.isEmpty ? null : language,
        fushiCard: detail.noteType.builtinKey == kSrsBuiltinFushiCardKey,
        bridgeKeys: kSrsBrowseBridgeKeys,
        onBridgeKey: (String token) {
          if (_lookup.guardBridgeToken(token)) return;
          final SrsPreviewCommand? c = srsPreviewCommandOfToken(token);
          if (c != null) widget.onCommand(c);
        },
        onSourceLink: _openSource,
      );
      // 与复习页同一判据（[SrsRenderedCard.fushiCardDefinitions]）：内置 Fushi 卡片（模板未改、
      // 媒体原生画得全）走原生 + 释义 WebView 的混合卡面，其余整面 WebView。以前预览一律整面
      // WebView，Fushi 卡片在浏览预览里与复习时长得不一样（satv-DI70B）。
      // 非 Fushi 卡片两面都在原生认得的子集里时同复习页走原生 HTML 卡面（[srsNativeHtmlCardFor]）。
      final String? definitions = rendered.fushiCardDefinitions;
      final SrsHtmlCard? html = definitions != null
          ? null
          : srsNativeHtmlCardFor(
              fushiCard: cardFace.fushiCard,
              question: rendered.question,
              answer: rendered.answer,
              css: rendered.css,
              languageCode: cardFace.languageCode,
            );
      face = definitions != null
          ? SrsFushiCardView(
              key: const ValueKey<String>('srs-browse-preview-native'),
              face: cardFace,
              fields: rendered.fields,
              definitionsHtml: definitions,
            )
          : html != null
          ? SrsHtmlCardView(
              key: const ValueKey<String>('srs-browse-preview-html'),
              face: cardFace,
              source: html.face(answerSide: widget.showAnswer),
            )
          : ref.watch(srsCardFaceBuilderProvider)(context, cardFace);
    }
    // 压在卡面上的一层：首次载入转圈 / 出错 / 没有这张卡。卡面始终是 Stack 第 0 格（结构恒定）。
    final Widget? overlay;
    if (_error != null) {
      overlay = Center(
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('srs-browse-preview-error'),
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: t.error_load_failed,
        ),
      );
    } else if (!hasFace) {
      overlay = _loading
          ? const FushiLoadingView()
          : Center(
              child: FushiPlaceholderMessage(
                icon: FushiIcons.searchOff,
                message: t.srs_browse_empty,
              ),
            );
    } else {
      overlay = null;
    }
    final String caption = <String>[
      if (widget.position != null) widget.position!,
      if (detail != null && detail.deckName.isNotEmpty) detail.deckName,
      if (detail?.template != null) detail!.template!.name,
    ].join(' · ');
    final Widget surface = FushiCard(
      key: const ValueKey<String>('srs-browse-preview-surface'),
      padding: EdgeInsets.zero,
      pressScale: false,
      // 卡面查词：与复习页同一套（点词 / 悬停 → 弹窗，弹窗里继续嵌套查）。
      child: SrsCardLookupHost(
        controller: _lookup,
        onClosed: widget.onLookupClosed,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            face ?? const SizedBox.shrink(),
            if (_loading && hasFace)
              const Align(
                alignment: Alignment.topCenter,
                child: IgnorePointer(child: FushiLinearProgressIndicator()),
              ),
            ?overlay,
          ],
        ),
      ),
    );
    final Widget prev = FushiIconButton(
      key: const ValueKey<String>('srs-preview-prev'),
      icon: FushiIcons.chevronLeft,
      tooltip: '${t.srs_browse_preview_prev} (←)',
      enabled: widget.hasPrevious,
      onTap: () => widget.onCommand(SrsPreviewCommand.previous),
    );
    final Widget flip = FushiFilledButton.tonal(
      key: const ValueKey<String>('srs-preview-flip'),
      onPressed: detail == null
          ? null
          : () => widget.onCommand(SrsPreviewCommand.flip),
      child: Text(
        widget.showAnswer
            ? t.srs_browse_preview_question
            : t.srs_review_show_answer,
        textAlign: TextAlign.center,
      ),
    );
    final Widget next = FushiIconButton(
      key: const ValueKey<String>('srs-preview-next'),
      icon: FushiIcons.chevronRight,
      tooltip: '${t.srs_browse_preview_next} (→)',
      enabled: widget.hasNext,
      onTap: () => widget.onCommand(SrsPreviewCommand.next),
    );
    final Widget edit = FushiIconButton(
      key: const ValueKey<String>('srs-preview-edit'),
      icon: FushiIcons.edit,
      tooltip: t.srs_note_edit,
      enabled: detail != null,
      onTap: widget.onEdit,
    );
    return LayoutBuilder(
      key: const ValueKey<String>('srs-browse-preview'),
      builder: (BuildContext context, BoxConstraints constraints) {
        // 横屏矮区域：按钮竖排在卡面右侧，把高度全留给卡面。只换按钮区：卡面所在子树的形状不随横竖
        // 切换（同一个 Flex 的同一格），平台视图不重挂。
        final bool rail = srsIsShortLandscape(constraints);
        return Flex(
          direction: rail ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap * 1.5,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: caption.isEmpty ? 0 : tokens.spacing.gap,
                    ),
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.labelLarge.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(child: surface),
                ],
              ),
            ),
            if (rail)
              SizedBox(
                key: const ValueKey<String>('srs-browse-preview-rail'),
                width: 136,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: tokens.spacing.gap,
                  children: <Widget>[
                    edit,
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[prev, next],
                    ),
                    flip,
                  ],
                ),
              )
            else
              Row(
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  prev,
                  Expanded(child: flip),
                  next,
                  edit,
                ],
              ),
          ],
        );
      },
    );
  }
}
