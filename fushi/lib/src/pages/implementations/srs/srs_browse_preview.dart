/// 浏览页的卡片预览：正面 / 背面用复习页同一个卡面视图（[srsCardFaceBuilderProvider]）渲染，
/// 带上一张 / 下一张 / 编辑。宽屏嵌在列表右侧（[SrsBrowsePreview]），窄屏单独压一页
/// （[SrsBrowsePreviewPage]）。
///
/// 键盘（预览页焦点作用域内）：Enter / 空格 = 翻面（与复习页同一个约定：空格只在卡面视图里
/// 有「翻面」含义，全局的裸空格中和挂在根上、本页更近先消费）；← / → = 上一张 / 下一张。
/// 卡面 WebView 持焦时经键盘桥（[kSrsBrowseBridgeKeys]）交回同一入口。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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

  Future<void> _load() async {
    final int seq = ++_loadSeq;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsCardDetail? detail = await store.cardDetail(widget.cardId);
    final SrsRenderedCard? rendered = await store.renderCard(widget.cardId);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _detail = detail;
      _rendered = rendered;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardDetail? detail = _detail;
    final SrsRenderedCard? rendered = _rendered;
    final Widget face;
    if (_loading) {
      face = const FushiLoadingView();
    } else if (detail == null || rendered == null) {
      face = Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: t.srs_browse_empty,
        ),
      );
    } else {
      final String language = ref.read(appProvider).defaultContentLanguage;
      face = ref.watch(srsCardFaceBuilderProvider)(
        context,
        SrsCardFace(
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
        ),
      );
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
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        // 卡面查词：与复习页同一套（点词 / 悬停 → 弹窗，弹窗里继续嵌套查）。
        child: SrsCardLookupHost(
          controller: _lookup,
          onClosed: widget.onLookupClosed,
          child: KeyedSubtree(key: ValueKey<bool>(_loading), child: face),
        ),
      ),
    );
    final Widget? captionText = caption.isEmpty
        ? null
        : Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.labelLarge.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        if (srsIsShortLandscape(constraints)) {
          // 横屏矮区域：按钮竖排在卡面右侧，把高度全留给卡面。
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap * 1.5,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (captionText != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                        child: captionText,
                      ),
                    Expanded(child: surface),
                  ],
                ),
              ),
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
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (captionText != null)
              Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                child: captionText,
              ),
            Expanded(child: surface),
            SizedBox(height: tokens.spacing.gap * 1.5),
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

/// 窄屏的预览页：在浏览结果 [result] 的行之间左右切换（行按页向原生会话取）。返回时浏览页刷新（编辑会写库；
/// 没写就直接复用同一份结果）。
class SrsBrowsePreviewPage extends ConsumerStatefulWidget {
  const SrsBrowsePreviewPage({
    super.key,
    required this.result,
    required this.initialIndex,
  });

  final SrsBrowseResult result;
  final int initialIndex;

  @override
  ConsumerState<SrsBrowsePreviewPage> createState() =>
      _SrsBrowsePreviewPageState();
}

class _SrsBrowsePreviewPageState extends ConsumerState<SrsBrowsePreviewPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-browse-preview');
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: (FocusReclaimCause cause) =>
        mounted && (ModalRoute.of(context)?.isCurrent ?? false),
  );
  late int _index = widget.initialIndex.clamp(0, widget.result.length - 1);
  final SrsCardLookupController _lookupCtl = SrsCardLookupController();
  bool _showAnswer = false;
  int _revision = 0;

  @override
  void dispose() {
    _lookupCtl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final int next = _index + delta;
    if (next < 0 || next >= widget.result.length) return;
    setState(() {
      _index = next;
      _showAnswer = false;
    });
    if (widget.result.rowAt(next) == null) {
      srsRunLogged('SrsBrowsePreview.rows', () async {
        await widget.result.ensure(next, next + 1);
        if (mounted) setState(() {});
      });
    }
  }

  void _command(SrsPreviewCommand c) {
    switch (c) {
      case SrsPreviewCommand.flip:
        setState(() => _showAnswer = !_showAnswer);
      case SrsPreviewCommand.previous:
        _go(-1);
      case SrsPreviewCommand.next:
        _go(1);
      case SrsPreviewCommand.undo:
        break;
      case SrsPreviewCommand.escape:
        unawaited(Navigator.of(context).maybePop());
    }
  }

  Future<void> _edit() async {
    final SrsBrowseRow? row = widget.result.rowAt(_index);
    if (row == null) return;
    final String noteId = row.noteId;
    await _focusOwnership.guardOverlay(
      () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => SrsNoteEditorPage(noteId: noteId),
        ),
      ),
    );
    if (!mounted) return;
    bumpSrsRevision(ref);
    setState(() => _revision++);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final KeyEventResult? lookup = _lookupCtl.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final SrsPreviewCommand? c = switch (key) {
      LogicalKeyboardKey.space ||
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter ||
      LogicalKeyboardKey.gameButtonA => SrsPreviewCommand.flip,
      LogicalKeyboardKey.arrowLeft => SrsPreviewCommand.previous,
      LogicalKeyboardKey.arrowRight => SrsPreviewCommand.next,
      _ => null,
    };
    if (c == null) return KeyEventResult.ignored;
    _command(c);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final SrsBrowseRow? item = widget.result.rowAt(_index);
    final String title = item == null || item.sortText.isEmpty
        ? t.srs_browse_preview
        : item.sortText;
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: title,
        header: apple
            ? null
            : Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.gap,
                ),
                child: FushiFloatingTopBar(
                  title: title,
                  subtitle: '${_index + 1} / ${widget.result.length}',
                  leading: <FushiToolbarItem>[
                    if (navigator != null && navigator.canPop())
                      FushiToolbarItem(
                        icon: FushiIcons.back,
                        label: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () => unawaited(navigator.maybePop()),
                      ),
                  ],
                ),
              ),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            child: item == null
                ? const FushiLoadingView()
                : SrsBrowsePreview(
                    cardId: item.cardId,
                    revision: _revision,
                    showAnswer: _showAnswer,
                    position: '${_index + 1} / ${widget.result.length}',
                    hasPrevious: _index > 0,
                    hasNext: _index < widget.result.length - 1,
                    onCommand: _command,
                    onEdit: () => srsRunLogged('SrsBrowsePreview.edit', _edit),
                    lookup: _lookupCtl,
                    onLookupClosed: () => _focusOwnership.reclaim(
                      FocusReclaimCause.overlayClosed,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
