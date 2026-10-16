/// 「Fushi 卡片」的混合渲染：词条 / 读音 / 音调 / 图片 / 例句 / 词频 / 来源由 Flutter 原生绘制，
/// 只有释义区（选中文本、释义图、主释义、全部释义——词典 HTML）进 WebView。
///
/// - 只用于内置「Fushi 卡片」且模板 / 样式未改过的卡（引擎在
///   [SrsRenderedCard.fushiCardDefinitions] 给出释义区 HTML 时）；Lapis、用户自建类型、改过
///   模板的 Fushi 卡片仍整面 WebView，与 Anki 一致。导出 .apkg 不受影响。
/// - 区块 → 字段的映射只有一份：`FushiCardBlock`（fushi_anki），原生与导出模板共用。
/// - 正面完全原生（不建 WebView）。背面版式：宽（≥720 逻辑像素，与模板断点相同）= 左栏原生
///   （各自滚动）+ 右栏释义 WebView（自己滚动）；窄 = 一条 Flutter 滚动：原生标题区 → 释义
///   WebView（高度跟内容走，页面上报）→ 原生页脚。内容高于 [kSrsDefsMaxInlineHeight] 时
///   WebView 改为一屏高、内部滚动（平台视图过高时纹理 / 内存开销过大）。
/// - 外观设置（字号 / 行距 / 配色 / 密度 / 区块显隐 / 字体库字体）原生同样生效。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardBlock;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 宽版式断点（与模板 `(min-width: 720px)` 一致）。
const double kSrsFushiCardWideBreakpoint = 720;

/// 窄版式里释义 WebView 跟内容走的最大高度；更高时改为一屏高、内部滚动。
const double kSrsDefsMaxInlineHeight = 4800;

/// 音调类型的配色（与 styling.css `--fc-pitch-*` 默认值同一份）。
@visibleForTesting
Color srsPitchColor(String type, {required bool dark}) => switch (type) {
  'heiban' => dark ? const Color(0xFF4FC0EC) : const Color(0xFF1A8FC4),
  'atamadaka' => dark ? const Color(0xFFF0646B) : const Color(0xFFD93A43),
  'nakadaka' => dark ? const Color(0xFFFF9B52) : const Color(0xFFE0650B),
  'odaka' => dark ? const Color(0xFF7FCC58) : const Color(0xFF4F9A2F),
  _ => dark ? const Color(0xFFB592F6) : const Color(0xFF7E53C4),
};

/// 区块的原生可见性（外观开关 + 字段是否有内容），与模板条件段同一判据。
@visibleForTesting
bool srsFushiBlockVisible(
  FushiCardBlock block,
  Map<String, String> fields,
  SrsCardAppearance a,
) {
  bool any(List<String> names) =>
      names.any((String n) => srsFieldFilled(fields[n]));
  return switch (block) {
    FushiCardBlock.term => true,
    FushiCardBlock.reading => any(block.fields) || any(<String>['Expression']),
    FushiCardBlock.picture => a.showPicture && any(block.fields),
    FushiCardBlock.sentence => srsFieldFilled(fields['Sentence']),
    FushiCardBlock.definitions => any(block.fields),
    FushiCardBlock.frequency => a.showFrequency && any(block.fields),
    FushiCardBlock.source => a.showSource && any(block.fields),
  };
}

/// 卡型（正面）：与模板的 Lapis 卡型开关同一语义，都空 = 单词卡。
enum SrsFushiFrontKind { word, sentence, wordAndSentence, click, audio }

SrsFushiFrontKind srsFushiFrontKind(Map<String, String> f) {
  if (srsFieldFilled(f['IsSentenceCard'])) return SrsFushiFrontKind.sentence;
  if (srsFieldFilled(f['IsWordAndSentenceCard'])) {
    return SrsFushiFrontKind.wordAndSentence;
  }
  if (srsFieldFilled(f['IsClickCard'])) return SrsFushiFrontKind.click;
  if (srsFieldFilled(f['IsAudioCard'])) return SrsFushiFrontKind.audio;
  return SrsFushiFrontKind.word;
}

/// 原生 + 释义 WebView 的 Fushi 卡片卡面。
class SrsFushiCardView extends ConsumerStatefulWidget {
  const SrsFushiCardView({
    super.key,
    required this.face,
    required this.fields,
    required this.definitionsHtml,
  });

  /// 这面卡（cardId / 正反面 / 版式 / 按键桥）。[SrsCardFace.css] 是模板样式表，给释义 WebView 用。
  final SrsCardFace face;

  /// 笔记字段（按字段名）。
  final Map<String, String> fields;

  /// 只含释义区的背面 HTML（引擎渲染）。
  final String definitionsHtml;

  @override
  ConsumerState<SrsFushiCardView> createState() => _SrsFushiCardViewState();
}

class _SrsFushiCardViewState extends ConsumerState<SrsFushiCardView> {
  final ScrollController _scroll = ScrollController();
  double? _defsHeight;

  /// 释义 WebView 的子树：翻回正面时挪进 Offstage 保活（GlobalKey 换父不重建平台视图），
  /// 下一次翻面不用重新起 WebView。第一次翻到背面之前正面不建 WebView。
  final GlobalKey _defsKey = GlobalKey(debugLabel: 'srs-fushi-defs');
  bool _defsCreated = false;

  /// 卡面可用高度（LayoutBuilder 给出）：矮视口收小图片；窄版式把长释义收起高度换成像素。
  double _viewport = 800;
  bool _clickOpen = false;
  bool _sentenceRuby = false;

  @override
  void didUpdateWidget(SrsFushiCardView old) {
    super.didUpdateWidget(old);
    if (old.face.cardId != widget.face.cardId) {
      // 内容高度保留上一张的：页面只在高度变化时上报，新卡同高时不会再报。
      _clickOpen = false;
      _sentenceRuby = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (old.face.showingAnswer != widget.face.showingAnswer) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _play(String name) async {
    SrsMediaStore? store;
    try {
      store = await ref.read(srsMediaStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsFushiCardView.mediaStore', e, stack);
    }
    final File? file = store?.resolve(name);
    if (file == null || !await file.exists()) {
      FushiToast.show(msg: t.srs_media_missing(name: name));
      return;
    }
    await ref.read(srsSoundPlayerProvider)(file.path);
  }

  void _onDefsHeight(double h) {
    if (!mounted || h <= 0) return;
    if (_defsHeight != null && (_defsHeight! - h).abs() < 1) return;
    setState(() => _defsHeight = h);
  }

  void _onDefsWheel(double dy) {
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    _scroll.jumpTo(
      (pos.pixels + dy).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SrsCardAppearance a = ref.watch(srsCardAppearanceProvider);
    final List<String> families = ref.watch(srsCardFontFamiliesProvider);
    final ThemeData base = Theme.of(context);
    final ColorScheme scheme = srsCardColorScheme(a, base.colorScheme);
    final _SrsCardStyle style = _SrsCardStyle(
      appearance: a,
      scheme: scheme,
      dark: base.brightness == Brightness.dark,
      fontFamilies: families,
      languageCode: widget.face.languageCode,
    );
    return Theme(
      data: base.copyWith(colorScheme: scheme),
      child: ColoredBox(
        color: scheme.surface,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            if (c.maxHeight.isFinite) _viewport = c.maxHeight;
            final bool wide = switch (widget.face.layout) {
              SrsCardLayout.wide => true,
              SrsCardLayout.narrow => false,
              SrsCardLayout.auto => c.maxWidth >= kSrsFushiCardWideBreakpoint,
            };
            return FushiEntranceScope(
              replayKey:
                  '${widget.face.cardId}-${widget.face.showingAnswer}-$wide',
              child: widget.face.showingAnswer
                  ? (wide
                        ? _buildWideBack(context, style, c)
                        : _buildNarrowBack(context, style, c))
                  : _frontWithWarmDefs(context, style, c, wide: wide),
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 正面

  Widget _buildFront(BuildContext context, _SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final SrsFushiFrontKind kind = srsFushiFrontKind(f);
    final List<Widget> blocks = <Widget>[
      if (s.appearance.frontFrequency && srsFieldFilled(f['FreqSort']))
        _Chip(text: srsPlainText(f['FreqSort']!), style: s),
      ...switch (kind) {
        SrsFushiFrontKind.word => <Widget>[_frontTerm(s, c)],
        SrsFushiFrontKind.sentence => <Widget>[_frontSentence(s, c)],
        SrsFushiFrontKind.wordAndSentence => <Widget>[
          _frontTerm(s, c),
          _frontSentence(s, c, context: true),
        ],
        SrsFushiFrontKind.click => <Widget>[_frontClick(s, c)],
        SrsFushiFrontKind.audio => <Widget>[
          _frontSentence(s, c, masked: true),
          _AudioButton(
            key: const ValueKey<String>('srs-fushi-front-audio'),
            name:
                srsSoundNames(
                  srsFieldFilled(f['SentenceAudio'])
                      ? f['SentenceAudio']!
                      : f['ExpressionAudio'] ?? '',
                ).firstOrNull ??
                '',
            large: true,
            style: s,
            onPlay: _play,
          ),
        ],
      },
      if (srsFieldFilled(f['Hint']))
        Text(
          srsPlainText(f['Hint']!),
          textAlign: TextAlign.center,
          style: s.body(color: s.scheme.onSurfaceVariant, size: 15),
        ),
    ];
    return Center(
      child: SingleChildScrollView(
        key: const ValueKey<String>('srs-fushi-front'),
        controller: _scroll,
        padding: EdgeInsets.all(s.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < blocks.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : s.gap),
                child: FushiStaggeredEntrance(index: i, child: blocks[i]),
              ),
          ],
        ),
      ),
    );
  }

  double _heroSize(BoxConstraints c) =>
      (c.maxWidth * 0.21).clamp(60.0, 112.0) * _termScale;

  double get _termScale => ref.read(srsCardAppearanceProvider).termScale;

  Widget _frontTerm(_SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final bool ruby =
        s.appearance.frontReading && srsFieldFilled(f['ExpressionFurigana']);
    final List<SrsInline> segs = ruby
        ? srsParseInline(f['ExpressionFurigana']!)
        : <SrsInline>[SrsInline(srsPlainText(f['Expression'] ?? ''))];
    return Column(
      key: const ValueKey<String>('srs-fushi-front-term'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SrsRubyText(
          segments: segs,
          style: s.term(size: _heroSize(c)),
          rubyStyle: s.body(size: _heroSize(c) * 0.36, color: s.muted),
          textAlign: TextAlign.center,
        ),
        if (s.appearance.frontReading) ..._pitchRow(s, center: true),
      ],
    );
  }

  Widget _frontSentence(
    _SrsCardStyle s,
    BoxConstraints c, {
    bool context = false,
    bool masked = false,
  }) {
    final double size =
        (c.maxWidth * 0.064).clamp(24.0, 36.0) *
        s.appearance.textScale *
        (context ? 0.74 : 1);
    final String plain = srsKanaFree(widget.fields['Sentence'] ?? '');
    return Text(
      masked ? srsMaskBold(widget.fields['Sentence'] ?? '') : plain,
      key: ValueKey<String>(
        masked ? 'srs-fushi-front-masked' : 'srs-fushi-front-sentence',
      ),
      textAlign: TextAlign.center,
      style: s.body(
        size: size,
        height: (context ? 1.8 : 1.75) * s.appearance.lineSpacing,
        color: context ? s.muted : null,
      ),
    );
  }

  Widget _frontClick(_SrsCardStyle s, BoxConstraints c) {
    final Widget body = AnimatedCrossFade(
      duration: fushiMotionDuration(context, FushiMotion.short),
      firstCurve: FushiMotion.enter,
      secondCurve: FushiMotion.enter,
      crossFadeState: _clickOpen
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      firstChild: Text(
        srsPlainText(widget.fields['Expression'] ?? ''),
        textAlign: TextAlign.center,
        style: s.term(size: _heroSize(c)),
      ),
      secondChild: _frontSentence(s, c),
    );
    // Enter / 手柄 A 走 ActivateIntent（裸空格已被全局中和，不在这里响应）。
    return FocusableActionDetector(
      key: const ValueKey<String>('srs-fushi-front-click'),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => setState(() => _clickOpen = !_clickOpen),
        ),
      },
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyC): ActivateIntent(),
      },
      mouseCursor: SystemMouseCursors.click,
      child: FushiPressScale(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _clickOpen = !_clickOpen),
          child: body,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 背面

  List<Widget> _pitchRow(_SrsCardStyle s, {bool center = false}) {
    final Map<String, String> f = widget.fields;
    final String kana = srsFieldFilled(f['ExpressionFurigana'])
        ? srsKanaOf(srsParseInline(f['ExpressionFurigana']!))
        : srsPlainText(f['ExpressionReading'] ?? '');
    final List<int> positions = srsPitchPositions(
      f['PitchPosition'] ?? '',
      kana,
    );
    if (kana.isEmpty) return const <Widget>[];
    return <Widget>[
      SrsPitchGraph(
        key: const ValueKey<String>('srs-fushi-pitch'),
        kana: kana,
        position: positions.firstOrNull,
        categories: f['PitchCategories'] ?? '',
        style: s.body(size: 19 * s.appearance.textScale, height: 1.3),
        dark: s.dark,
        fallbackColor: s.scheme.onSurface,
      ),
    ];
  }

  Widget _readingRow(_SrsCardStyle s) {
    final Map<String, String> f = widget.fields;
    final String kana = srsFieldFilled(f['ExpressionFurigana'])
        ? srsKanaOf(srsParseInline(f['ExpressionFurigana']!))
        : srsPlainText(f['ExpressionReading'] ?? '');
    final List<int> positions = srsPitchPositions(
      f['PitchPosition'] ?? '',
      kana,
    );
    final int morae = srsMorae(kana).length;
    final String cats = f['PitchCategories'] ?? '';
    return Wrap(
      key: const ValueKey<String>('srs-fushi-reading-row'),
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        ..._pitchRow(s),
        for (final int p in positions)
          _Chip(
            text: '$p',
            style: s,
            color: srsPitchColor(srsPitchType(p, morae, cats), dark: s.dark),
          ),
        for (final String name in srsSoundNames(f['ExpressionAudio'] ?? ''))
          _AudioButton(
            key: const ValueKey<String>('srs-fushi-word-audio'),
            name: name,
            style: s,
            onPlay: _play,
          ),
        if (srsFieldFilled(f['FreqSort']))
          _Chip(text: srsPlainText(f['FreqSort']!), style: s),
      ],
    );
  }

  Widget _term(_SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final List<SrsInline> segs = srsFieldFilled(f['ExpressionFurigana'])
        ? srsParseInline(f['ExpressionFurigana']!)
        : srsParseInline(f['Expression'] ?? '', ankiFurigana: false);
    final double size =
        (c.maxWidth * 0.10).clamp(34.0, 52.0) * s.appearance.termScale;
    return SrsRubyText(
      key: const ValueKey<String>('srs-fushi-term'),
      segments: segs,
      style: s.term(size: size),
      rubyStyle: s.body(size: size * 0.36, color: s.muted),
    );
  }

  Widget? _picture(_SrsCardStyle s, {required bool wide}) {
    if (!srsFushiBlockVisible(
      FushiCardBlock.picture,
      widget.fields,
      s.appearance,
    )) {
      return null;
    }
    final String? name = srsImageSources(widget.fields['Picture']!).firstOrNull;
    if (name == null) return null;
    return _MediaImage(
      key: const ValueKey<String>('srs-fushi-picture'),
      name: name,
      size: wide ? null : s.thumb,
      // 与模板同：左栏图最高 220，矮视口（手机横屏）120。
      maxHeight: wide ? (_viewport <= 520 ? 120 : 220) : null,
      radius: s.radius * 0.6,
    );
  }

  Widget? _sentence(_SrsCardStyle s) {
    final Map<String, String> f = widget.fields;
    if (!srsFushiBlockVisible(FushiCardBlock.sentence, f, s.appearance)) {
      return null;
    }
    final bool showRuby = s.appearance.sentenceFurigana || _sentenceRuby;
    final List<SrsInline> segs = srsParseInline(
      srsFieldFilled(f['SentenceFurigana'])
          ? f['SentenceFurigana']!
          : f['Sentence']!,
    );
    final bool hasRuby = segs.any((SrsInline x) => x.ruby != null);
    final List<String> audio = srsSoundNames(f['SentenceAudio'] ?? '');
    final Widget text = SrsRubyText(
      key: const ValueKey<String>('srs-fushi-sentence'),
      segments: showRuby
          ? segs
          : <SrsInline>[for (final SrsInline x in segs) x.withoutRuby()],
      style: s.body(
        size: 20 * s.appearance.textScale,
        height: 1.9 * s.appearance.lineSpacing,
      ),
      rubyStyle: s.body(size: 10 * s.appearance.textScale, color: s.muted),
      emphasis: s.scheme.primary,
    );
    return FushiCard(
      key: const ValueKey<String>('srs-fushi-sentence-block'),
      padding: EdgeInsets.all(s.pad),
      pressScale: false,
      color: s.scheme.surfaceContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (hasRuby && !s.appearance.sentenceFurigana)
                  // 注音默认收起：点按 / Enter 显示（与模板悬停 / 点按显示同义）。
                  FocusableActionDetector(
                    actions: <Type, Action<Intent>>{
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) =>
                            setState(() => _sentenceRuby = !_sentenceRuby),
                      ),
                    },
                    mouseCursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          setState(() => _sentenceRuby = !_sentenceRuby),
                      child: text,
                    ),
                  )
                else
                  text,
                if (s.appearance.showTranslation &&
                    srsFieldFilled(f['SentenceTranslation']))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      srsPlainText(f['SentenceTranslation']!),
                      key: const ValueKey<String>('srs-fushi-translation'),
                      style: s.body(
                        size: 15 * s.appearance.textScale,
                        height: 1.55,
                        color: s.muted,
                        ui: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final String name in audio)
            _AudioButton(
              key: const ValueKey<String>('srs-fushi-sentence-audio'),
              name: name,
              style: s,
              onPlay: _play,
            ),
        ],
      ),
    );
  }

  List<Widget> _footer(_SrsCardStyle s) {
    final Map<String, String> f = widget.fields;
    final SrsCardLabels labels = srsCardLabels();
    return <Widget>[
      if (srsFushiBlockVisible(FushiCardBlock.frequency, f, s.appearance))
        _MetaRow(
          key: const ValueKey<String>('srs-fushi-frequency'),
          label: labels.frequency,
          style: s,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String item in srsListItems(f['Frequency']!))
                _Chip(text: item, style: s),
            ],
          ),
        ),
      if (srsFushiBlockVisible(FushiCardBlock.source, f, s.appearance))
        _MetaRow(
          key: const ValueKey<String>('srs-fushi-source'),
          label: labels.source,
          style: s,
          child: Text(
            srsPlainText(f['MiscInfo']!),
            style: s.body(size: 13, color: s.muted, ui: true),
          ),
        ),
    ];
  }

  SrsCardFace _defsFace({required bool wide}) => SrsCardFace(
    cardId: '${widget.face.cardId}#defs',
    showingAnswer: true,
    bodyHtml: widget.definitionsHtml,
    css: widget.face.css,
    languageCode: widget.face.languageCode,
    onBridgeKey: widget.face.onBridgeKey,
    bridgeKeys: widget.face.bridgeKeys,
    layout: wide ? SrsCardLayout.wide : SrsCardLayout.narrow,
    pageZoom: widget.face.pageZoom,
    fushiCard: true,
    onContentHeight: wide ? null : _onDefsHeight,
    // 窄版式释义 WebView 跟内容等高，页内 vh 不再是屏高：收起高度按外层视口给像素值。
    hostCss: wide
        ? ''
        : ':root{--fushi-srs-clamp:${(_viewport * 0.52).round()}px;}',
    onWheel: wide ? null : _onDefsWheel,
  );

  Widget? _definitions(BuildContext context, {required bool wide}) {
    if (!srsFushiBlockVisible(
      FushiCardBlock.definitions,
      widget.fields,
      ref.read(srsCardAppearanceProvider),
    )) {
      return null;
    }
    final SrsCardFaceBuilder builder = ref.watch(srsCardFaceBuilderProvider);
    _defsCreated = true;
    return KeyedSubtree(
      key: _defsKey,
      child: KeyedSubtree(
        key: const ValueKey<String>('srs-fushi-definitions'),
        child: builder(context, _defsFace(wide: wide)),
      ),
    );
  }

  /// 正面：原生卡面；释义 WebView 若已建过，挪进 Offstage 保活并预载这张卡的释义。
  Widget _frontWithWarmDefs(
    BuildContext context,
    _SrsCardStyle s,
    BoxConstraints c, {
    required bool wide,
  }) {
    final Widget front = _buildFront(context, s, c);
    if (!_defsCreated) return front;
    final Widget? defs = _definitions(context, wide: wide);
    if (defs == null) return front;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: front),
        Offstage(
          child: SizedBox(
            width: c.maxWidth,
            height: c.maxHeight.isFinite ? c.maxHeight : 600,
            child: defs,
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowBack(
    BuildContext context,
    _SrsCardStyle s,
    BoxConstraints c,
  ) {
    final Widget? picture = _picture(s, wide: false);
    final Widget? sentence = _sentence(s);
    final Widget? defs = _definitions(context, wide: false);
    final double viewport = c.maxHeight.isFinite ? c.maxHeight : 800;
    final double reported = _defsHeight ?? viewport * 0.6;
    final double defsHeight = reported > kSrsDefsMaxInlineHeight
        ? viewport
        : reported;
    final List<Widget> blocks = <Widget>[
      Padding(
        padding: EdgeInsets.fromLTRB(s.pad, s.pad, s.pad, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _term(s, c),
                  const SizedBox(height: 4),
                  _readingRow(s),
                ],
              ),
            ),
            if (picture != null) ...<Widget>[SizedBox(width: s.gap), picture],
          ],
        ),
      ),
      if (sentence != null)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: s.pad),
          child: sentence,
        ),
      if (defs != null)
        // WebView 自带 16px 页边距（外壳 body padding），这里不再加水平边距。
        AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.enter,
          height: defsHeight,
          child: defs,
        ),
      ..._footer(s).map(
        (Widget w) => Padding(
          padding: EdgeInsets.symmetric(horizontal: s.pad),
          child: w,
        ),
      ),
    ];
    return SingleChildScrollView(
      key: const ValueKey<String>('srs-fushi-back-narrow'),
      controller: _scroll,
      padding: EdgeInsets.only(bottom: s.pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < blocks.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : s.gap),
              child: FushiStaggeredEntrance(index: i, child: blocks[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildWideBack(
    BuildContext context,
    _SrsCardStyle s,
    BoxConstraints c,
  ) {
    final Widget? picture = _picture(s, wide: true);
    final Widget? sentence = _sentence(s);
    final Widget? defs = _definitions(context, wide: true);
    final List<Widget> left = <Widget>[
      _term(s, c),
      _readingRow(s),
      ?picture,
      ?sentence,
      ..._footer(s),
    ];
    final double leftWidth = (c.maxWidth * 5 / 12).clamp(260.0, 460.0);
    return Row(
      key: const ValueKey<String>('srs-fushi-back-wide'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: leftWidth,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.all(s.pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < left.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : s.gap),
                    child: FushiStaggeredEntrance(index: i, child: left[i]),
                  ),
              ],
            ),
          ),
        ),
        if (defs != null)
          Expanded(
            child: FushiStaggeredEntrance(index: left.length, child: defs),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 样式

class _SrsCardStyle {
  _SrsCardStyle({
    required this.appearance,
    required this.scheme,
    required this.dark,
    required this.fontFamilies,
    required this.languageCode,
  });

  final SrsCardAppearance appearance;
  final ColorScheme scheme;
  final bool dark;
  final List<String> fontFamilies;
  final String? languageCode;

  Color get muted => scheme.onSurfaceVariant;

  double get gap => switch (appearance.density) {
    SrsCardDensity.compact => 10,
    SrsCardDensity.standard => 16,
    SrsCardDensity.comfortable => 22,
  };

  double get pad => switch (appearance.density) {
    SrsCardDensity.compact => 12,
    SrsCardDensity.standard => 16,
    SrsCardDensity.comfortable => 20,
  };

  double get thumb => 84;

  double get radius => FushiRadii.groupValue;

  Locale? get _locale => languageCode == null || languageCode!.isEmpty
      ? null
      : Locale(languageCode!);

  /// 字体：字体库「复习卡片」链在前，其后交给引擎按 locale 回落。
  TextStyle body({
    double size = 16,
    double? height,
    Color? color,
    bool ui = false,
  }) => TextStyle(
    fontSize: size,
    height: height ?? 1.6 * appearance.lineSpacing,
    color: color ?? scheme.onSurface,
    fontFamily: fontFamilies.firstOrNull,
    fontFamilyFallback: fontFamilies.length > 1
        ? fontFamilies.sublist(1)
        : null,
    locale: ui ? null : _locale,
  );

  TextStyle term({required double size}) =>
      body(size: size, height: 1.25).copyWith(fontWeight: FontWeight.w600);
}

// ---------------------------------------------------------------- 组件

/// 带注音的行内文字：注音段用 WidgetSpan（注音在上、基字在下），其余 TextSpan。
class SrsRubyText extends StatelessWidget {
  const SrsRubyText({
    super.key,
    required this.segments,
    required this.style,
    required this.rubyStyle,
    this.textAlign = TextAlign.start,
    this.emphasis,
  });

  final List<SrsInline> segments;
  final TextStyle style;
  final TextStyle rubyStyle;
  final TextAlign textAlign;

  /// 加粗段（例句里的目标词）的强调色；null = 只加粗。
  final Color? emphasis;

  TextStyle _styleOf(SrsInline s) => style.copyWith(
    fontWeight: s.bold ? FontWeight.w700 : null,
    fontStyle: s.italic ? FontStyle.italic : null,
    decoration: s.underline ? TextDecoration.underline : null,
    color: s.bold && emphasis != null ? emphasis : null,
  );

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (final SrsInline s in segments)
            if (s.ruby == null)
              TextSpan(text: s.text, style: _styleOf(s))
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      s.ruby!,
                      style: rubyStyle.copyWith(height: 1.1),
                      maxLines: 1,
                    ),
                    Text(s.text, style: _styleOf(s), maxLines: 1),
                  ],
                ),
              ),
        ],
      ),
      textAlign: textAlign,
      style: style,
    );
  }
}

/// 音调图：读音逐拍，高拍画上线、低拍画下线，降调处画竖线（与模板脚本同一套规则）。
class SrsPitchGraph extends StatelessWidget {
  const SrsPitchGraph({
    super.key,
    required this.kana,
    required this.position,
    required this.categories,
    required this.style,
    required this.dark,
    required this.fallbackColor,
  });

  final String kana;
  final int? position;
  final String categories;
  final TextStyle style;
  final bool dark;
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    final List<String> morae = srsMorae(kana);
    final int? p = position;
    if (p == null) return Text(kana, style: style);
    final Color color = srsPitchColor(
      srsPitchType(p, morae.length, categories),
      dark: dark,
    );
    final BorderSide line = BorderSide(color: color, width: 2);
    Widget mora(String text, {required bool high, required bool drop}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
          decoration: BoxDecoration(
            border: Border(
              top: high ? line : BorderSide.none,
              bottom: high ? BorderSide.none : line,
              right: drop ? line : BorderSide.none,
            ),
          ),
          child: Text(text, style: style),
        );
    return Semantics(
      label: '$kana [$p]',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < morae.length; i++)
            mora(
              morae[i],
              high: p == 0
                  ? i > 0
                  : p == 1
                  ? i == 0
                  : i > 0 && i < p,
              drop: p > 0 && i == p - 1,
            ),
          if (p > 0 && p >= morae.length) mora(' ', high: false, drop: false),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.style, this.color});

  final String text;
  final _SrsCardStyle style;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color fg = color ?? style.scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:
            color?.withValues(alpha: 0.14) ?? style.scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: style.body(size: 12, height: 1.2, color: fg, ui: true),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    super.key,
    required this.label,
    required this.style,
    required this.child,
  });

  final String label;
  final _SrsCardStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        label,
        style: style
            .body(size: 12, color: style.muted, ui: true)
            .copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      child,
    ],
  );
}

class _AudioButton extends StatelessWidget {
  const _AudioButton({
    super.key,
    required this.name,
    required this.style,
    required this.onPlay,
    this.large = false,
  });

  final String name;
  final _SrsCardStyle style;
  final Future<void> Function(String name) onPlay;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) return const SizedBox.shrink();
    return FushiIconButton(
      icon: FushiIcons.volumeUp,
      tooltip: t.play,
      size: large ? 32 : 22,
      backgroundColor: style.scheme.secondaryContainer,
      enabledColor: style.scheme.onSecondaryContainer,
      onTap: () => srsRunLogged('SrsFushiCardView.play', () => onPlay(name)),
    );
  }
}

/// 媒体库里的图片：点按全屏查看。
class _MediaImage extends ConsumerWidget {
  const _MediaImage({
    super.key,
    required this.name,
    required this.radius,
    this.size,
    this.maxHeight,
  });

  final String name;
  final double radius;
  final double? size;
  final double? maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ImageProvider<Object>? provider = srsCardImageProvider(
      name,
      ref.watch(srsMediaStoreProvider).valueOrNull,
    );
    final Widget image = provider == null
        ? const SizedBox.shrink()
        : Image(
            image: provider,
            fit: BoxFit.cover,
            width: size,
            height: size,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );
    final Widget box = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: size != null
          ? SizedBox.square(dimension: size, child: image)
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight ?? 220),
              child: image,
            ),
    );
    if (provider == null) return box;
    return FushiPressScale(
      child: GestureDetector(
        onTap: () => unawaited(
          showDialog<void>(
            context: context,
            builder: (BuildContext context) => GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(child: Image(image: provider)),
            ),
          ),
        ),
        child: box,
      ),
    );
  }
}

/// 卡面图片来源：媒体库文件名 → 文件；`data:image/<光栅格式>;base64` → 内存（样例卡用）。
/// SVG、远程 URL 与解析失败一律 null（原生侧不渲染，不报错）。
@visibleForTesting
ImageProvider<Object>? srsCardImageProvider(String src, SrsMediaStore? store) {
  if (src.startsWith('data:')) {
    if (!src.startsWith('data:image/') || src.startsWith('data:image/svg')) {
      return null;
    }
    try {
      return MemoryImage(UriData.parse(src).contentAsBytes());
    } on FormatException {
      return null;
    }
  }
  if (src.contains('://')) return null;
  final File? file = store?.resolve(src);
  return file == null ? null : FileImage(file);
}
