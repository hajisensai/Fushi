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

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart' show CardSourceLink;
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardBlock;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 注音字号 / 基字字号（与模板 `rt` 的 0.36em 同一比例）。
const double _kSrsRubyRatio = 0.36;

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

  /// 选区自带的焦点不进 Tab 遍历：焦点驱动（Tab → Enter）照旧落到卡面的可操作控件上。
  final FocusNode _selectionFocus = FocusNode(
    debugLabel: 'srs-fushi-selection',
    skipTraversal: true,
  );

  /// 释义 WebView 的子树：正面时在 Offstage 里预建 / 保活（GlobalKey 换父不重建平台
  /// 视图），翻面只是换父，不用现起 WebView。
  final GlobalKey _defsKey = GlobalKey(debugLabel: 'srs-fushi-defs');

  /// 原生区取词（词条 / 例句 / 翻译 / 提示）：点按 / 悬停查词，见 srs_card_lookup.dart。
  final GlobalKey<SrsNativeLookupRegionState> _lookupRegion =
      GlobalKey<SrsNativeLookupRegionState>(debugLabel: 'srs-fushi-lookup');

  /// 这一下点按已经被原生取词用掉了（点在例句的字上 = 查词，不再切换注音）。
  bool get _tapTookLookup => _lookupRegion.currentState?.tookTap ?? false;

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
    _selectionFocus.dispose();
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
      tokens: SrsCardTokens.of(context),
      dark: base.brightness == Brightness.dark,
      fontFamilies: families,
      languageCode: widget.face.languageCode,
    );
    return Theme(
      data: base.copyWith(colorScheme: scheme),
      // 原生绘制的文字可拖选 / 复制（与 WebView 释义区一致）；点按手势不受影响。
      child: SelectionArea(
        focusNode: _selectionFocus,
        child: SrsNativeLookupRegion(
          key: _lookupRegion,
          child: ColoredBox(
            color: scheme.surface,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                if (c.maxHeight.isFinite) _viewport = c.maxHeight;
                final bool wide = switch (widget.face.layout) {
                  SrsCardLayout.wide => true,
                  SrsCardLayout.narrow => false,
                  SrsCardLayout.auto =>
                    c.maxWidth >= kSrsFushiCardWideBreakpoint,
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
        srsLookupText(
          text: srsPlainText(f['Hint']!),
          child: Text(
            srsPlainText(f['Hint']!),
            textAlign: TextAlign.center,
            style: s.text(
              s.tokens.bodySecondary,
              color: s.scheme.onSurfaceVariant,
            ),
          ),
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

  /// 正面大字词条相对 [SrsCardTokens.hero] 的倍率：随卡面宽度在字阶下限与其两倍之间取，
  /// 再乘用户的词条倍率。
  double _heroScale(_SrsCardStyle s, BoxConstraints c) {
    final double min = s.sizeOf(s.tokens.hero);
    return (c.maxWidth * 0.21).clamp(min, min * 2) /
        min *
        s.appearance.termScale;
  }

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
          style: s.term(s.tokens.hero, scale: _heroScale(s, c)),
          rubyStyle: s.text(
            s.tokens.hero,
            scale: _heroScale(s, c) * _kSrsRubyRatio,
            color: s.muted,
          ),
          textAlign: TextAlign.center,
          lookup: true,
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
    final double min = s.sizeOf(s.tokens.frontSentenceMin);
    final double scale =
        (c.maxWidth * 0.064).clamp(min, s.sizeOf(s.tokens.frontSentenceMax)) /
        min *
        s.appearance.textScale *
        (context ? 0.74 : 1);
    final String plain = srsKanaFree(widget.fields['Sentence'] ?? '');
    final Widget text = Text(
      masked ? srsMaskBold(widget.fields['Sentence'] ?? '') : plain,
      key: ValueKey<String>(
        masked ? 'srs-fushi-front-masked' : 'srs-fushi-front-sentence',
      ),
      textAlign: TextAlign.center,
      style: s.text(
        s.tokens.frontSentenceMin,
        scale: scale,
        height: (context ? 1.8 : 1.75) * s.appearance.lineSpacing,
        color: context ? s.muted : null,
      ),
    );
    // 挖空的听力卡不取词（挖掉的正是答案）。
    return masked ? text : srsLookupText(text: plain, child: text);
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
        style: s.term(s.tokens.hero, scale: _heroScale(s, c)),
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
          // 展开后的例句点在字上 = 查词；点在字外照旧收起。
          onTap: () {
            if (_tapTookLookup) return;
            setState(() => _clickOpen = !_clickOpen);
          },
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
        style: s.text(
          s.tokens.emphasisLine,
          scale: s.appearance.textScale,
          height: 1.3,
        ),
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
    final double min = s.sizeOf(s.tokens.termMin);
    final double scale =
        (c.maxWidth * 0.10).clamp(min, s.sizeOf(s.tokens.termMax)) /
        min *
        s.appearance.termScale;
    return SrsRubyText(
      key: const ValueKey<String>('srs-fushi-term'),
      segments: segs,
      style: s.term(s.tokens.termMin, scale: scale),
      rubyStyle: s.text(
        s.tokens.termMin,
        scale: scale * _kSrsRubyRatio,
        color: s.muted,
      ),
      lookup: true,
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
      radius: s.tokens.radiusSmall,
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
    // 注音收起时第一下点按是「显示注音」（原有操作），不取词；注音显示后点在字上 =
    // 查词，点在字外 = 收起注音。
    final bool rubyToggle = hasRuby && !s.appearance.sentenceFurigana;
    final Widget text = SrsRubyText(
      key: const ValueKey<String>('srs-fushi-sentence'),
      segments: showRuby
          ? segs
          : <SrsInline>[for (final SrsInline x in segs) x.withoutRuby()],
      style: s.text(
        s.tokens.emphasisLine,
        scale: s.appearance.textScale,
        height: 1.9 * s.appearance.lineSpacing,
      ),
      rubyStyle: s.text(
        s.tokens.ruby,
        scale: s.appearance.textScale,
        color: s.muted,
      ),
      emphasis: s.scheme.primary,
      lookup: !rubyToggle || _sentenceRuby,
    );
    return FushiCard(
      key: const ValueKey<String>('srs-fushi-sentence-block'),
      padding: EdgeInsets.all(s.pad),
      pressScale: false,
      color: s.tokens.surface1(s.scheme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (rubyToggle)
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
                      onTap: () {
                        if (_tapTookLookup) return;
                        setState(() => _sentenceRuby = !_sentenceRuby);
                      },
                      child: text,
                    ),
                  )
                else
                  text,
                if (s.appearance.showTranslation &&
                    srsFieldFilled(f['SentenceTranslation']))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: srsLookupText(
                      text: srsPlainText(f['SentenceTranslation']!),
                      child: Text(
                        srsPlainText(f['SentenceTranslation']!),
                        key: const ValueKey<String>('srs-fushi-translation'),
                        style: s.text(
                          s.tokens.bodySecondary,
                          scale: s.appearance.textScale,
                          height: 1.55,
                          color: s.muted,
                          ui: true,
                        ),
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
          child: _sourceText(s, f['MiscInfo']!),
        ),
    ];
  }

  /// 来源：制卡时写进 MiscInfo 的 `fushi://source?...` 链接可点，跳回书 / 漫画 / 视频的
  /// 出处位置（与 Anki 里点 Lapis 的来源同一条 [openCardSource]）；没有链接时纯文本。
  Widget _sourceText(_SrsCardStyle s, String html) {
    final CardSourceLink? link = CardSourceLink.fromHtml(html).firstOrNull;
    final String text = srsPlainText(html);
    if (link == null) {
      return Text(
        text,
        style: s.text(s.tokens.caption, color: s.muted, ui: true),
      );
    }
    return FushiPressScale(
      child: InkWell(
        key: const ValueKey<String>('srs-fushi-source-link'),
        borderRadius: BorderRadius.all(Radius.circular(s.tokens.radiusInner)),
        onTap: () => srsRunLogged(
          'SrsFushiCardView.openSource',
          () => openCardSource(ref: ref, link: link),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                text,
                style: s
                    .text(s.tokens.caption, color: s.scheme.primary, ui: true)
                    .copyWith(decoration: TextDecoration.underline),
              ),
            ),
            const SizedBox(width: 4),
            FushiIcon(FushiIcons.openInNew, size: 14, color: s.scheme.primary),
          ],
        ),
      ),
    );
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
    // 释义页只有释义区：纵向排、撑满宿主给的栏宽（模板的 flex 横排会让释义块按内容
    // 收缩，宽屏下右栏空一大片）。模板 CSS 不动——原生渲染按「笔记类型 CSS 与内置
    // 模板逐字一致」判定，改模板会让库里已有的 Fushi 卡片退回整面 WebView。
    // 窄版式释义 WebView 跟内容等高，页内 vh 不再是屏高：收起高度按外层视口给像素值。
    // 三个类名：宿主 CSS 排在卡片 CSS 之前，同为两类名的模板规则
    // （`.fc-back.fc-layout-wide{max-width:1160px}`）会后来居上，宽屏右侧又空出来。
    hostCss:
        '.fc.fc-back.fc-defs-only{flex-direction:column;max-width:none;margin:0;}'
        '${wide ? '' : ':root{--fushi-srs-clamp:${(_viewport * 0.52).round()}px;}'}',
    onWheel: wide ? null : _onDefsWheel,
    onSourceLink: widget.face.onSourceLink,
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
    return KeyedSubtree(
      key: _defsKey,
      child: KeyedSubtree(
        key: const ValueKey<String>('srs-fushi-definitions'),
        child: builder(context, _defsFace(wide: wide)),
      ),
    );
  }

  /// 正面：原生卡面；释义 WebView 在 Offstage 里预先建好并预载这张卡的释义——
  /// WebView2 起一个控件要几百毫秒，等翻面才建会让背面的释义区明显晚出。
  Widget _frontWithWarmDefs(
    BuildContext context,
    _SrsCardStyle s,
    BoxConstraints c, {
    required bool wide,
  }) {
    final Widget front = _buildFront(context, s, c);
    final Widget? defs = _definitions(context, wide: wide);
    if (defs == null) return front;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: front),
        Offstage(
          // 预热中的释义不在屏上：不登记为取词表面（坐标与正面重叠，会被误查）。
          child: SrsCardLookupScope(
            controller: null,
            child: SizedBox(
              width: c.maxWidth,
              height: c.maxHeight.isFinite ? c.maxHeight : 600,
              child: defs,
            ),
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
    // 宽窗铺满：左栏按比例跟着窗口长（不再 460 封顶），释义栏吃剩下的——桌面最大化时
    // 两栏都更宽、一屏看到的内容更多，而不是居中留出两侧空白。
    final double leftWidth = (c.maxWidth * 0.4).clamp(300.0, 640.0);
    return _wideRow(leftWidth, left, defs, s);
  }

  Widget _wideRow(
    double leftWidth,
    List<Widget> left,
    Widget? defs,
    _SrsCardStyle s,
  ) {
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
    required this.tokens,
    required this.dark,
    required this.fontFamilies,
    required this.languageCode,
  });

  final SrsCardAppearance appearance;
  final ColorScheme scheme;

  /// 当前设计系统的卡面令牌（与注入卡面 WebView 的变量同一份）。
  final SrsCardTokens tokens;
  final bool dark;
  final List<String> fontFamilies;
  final String? languageCode;

  Color get muted => scheme.onSurfaceVariant;

  double get gap => tokens.gap(appearance.density);

  double get pad => tokens.pad(appearance.density);

  double get thumb => 84;

  /// 字阶角色的字号。
  double sizeOf(TextStyle role) => fushiContentTypeSize(role).fontSize!;

  Locale? get _locale => languageCode == null || languageCode!.isEmpty
      ? null
      : Locale(languageCode!);

  /// 内容文字的字体链：字体库「复习卡片」链在前，其后按卡片内容语言接受控的 CJK
  /// 链（与释义区 WebView、视频字幕同一张平台字体表）。只设 `locale` 不够——
  /// Windows 上引擎回落不看 locale、按系统字体序落到微软雅黑，日文汉字会变中文
  /// 字形，且与旁边 WebView 释义区的字体对不上。卡片内容几乎总是 CJK，语言缺省时
  /// 用按内容分布排序（日文在前）的兜底链，而不是交给引擎随机挑。
  late final List<String> _contentFamilies = contentFontFamilies(
    languageTag: languageCode,
    platform: defaultTargetPlatform,
    customFamilies: fontFamilies,
    fallbackWhenUnknown: true,
  );

  /// Windows 的游ゴシック Regular 笔画极细：浏览器靠 DirectWrite hinting 把它画实，
  /// Flutter 自绘没有这一步，同一字体在原生区比旁边 WebView 释义区明显发虚。日文
  /// 网页对游ゴシック的通行做法就是正文用 Medium（500）；只在实际落到系统游ゴシック
  /// （用户没从字体库选字体）时提，用户自选字体保持其原字重。
  late final bool _thinSystemJaFace =
      defaultTargetPlatform == TargetPlatform.windows &&
      fontFamilies.isEmpty &&
      (_contentFamilies.firstOrNull?.startsWith('Yu Gothic') ?? false);

  /// 卡面文字：字号取字阶角色 [role]（当前设计系统）× 内容倍率 [scale]，字族走卡面字体链。
  TextStyle text(
    TextStyle role, {
    double scale = 1,
    double? height,
    Color? color,
    bool ui = false,
  }) {
    final List<String> families = ui ? fontFamilies : _contentFamilies;
    return fushiContentTypeSize(role, scale: scale).copyWith(
      height: height ?? 1.6 * appearance.lineSpacing,
      color: color ?? scheme.onSurface,
      fontFamily: families.firstOrNull,
      fontFamilyFallback: families.length > 1 ? families.sublist(1) : null,
      fontWeight: !ui && _thinSystemJaFace ? FontWeight.w500 : null,
      locale: ui ? null : _locale,
    );
  }

  TextStyle term(TextStyle role, {double scale = 1}) => text(
    role,
    scale: scale,
    height: 1.25,
  ).copyWith(fontWeight: FontWeight.w600);
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
    this.lookup = false,
  });

  final List<SrsInline> segments;
  final TextStyle style;
  final TextStyle rubyStyle;
  final TextAlign textAlign;

  /// 标成可取词（[SrsNativeLookupRegion]）：整段纯文本 = 各段基字拼起来，注音段里点基字 /
  /// 注音都换算回整段偏移。
  final bool lookup;

  /// 加粗段（例句里的目标词）的强调色；null = 只加粗。
  final Color? emphasis;

  TextStyle _styleOf(SrsInline s) => style.copyWith(
    fontWeight: s.bold ? FontWeight.w700 : null,
    fontStyle: s.italic ? FontStyle.italic : null,
    decoration: s.underline ? TextDecoration.underline : null,
    color: s.bold && emphasis != null ? emphasis : null,
  );

  /// 取词标记：各段在外层段落纯文本（注音段只占一个占位符）与整段纯文本里的偏移。
  SrsLookupTextData _lookupData() {
    final StringBuffer full = StringBuffer();
    final List<SrsLookupTextSegment> map = <SrsLookupTextSegment>[];
    int outer = 0;
    for (final SrsInline s in segments) {
      final bool placeholder = s.ruby != null;
      final int outerLength = placeholder ? 1 : s.text.length;
      map.add(
        SrsLookupTextSegment(
          outerStart: outer,
          outerLength: outerLength,
          fullStart: full.length,
          placeholder: placeholder,
        ),
      );
      outer += outerLength;
      full.write(s.text);
    }
    return SrsLookupTextData(full.toString(), segments: map);
  }

  @override
  Widget build(BuildContext context) {
    int fullStart = 0;
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final SrsInline s in segments) {
      if (s.ruby == null) {
        spans.add(TextSpan(text: s.text, style: _styleOf(s)));
      } else {
        Widget tag(Widget child, {required bool isRuby}) => lookup
            ? MetaData(
                metaData: SrsLookupRubySegment(
                  fullStart: fullStart,
                  isRuby: isRuby,
                ),
                child: child,
              )
            : child;
        // 按基线对齐，基线取基字（不是上面的注音）：注音段与旁边的普通字落在
        // 同一条基线上。WidgetSpan 的子组件已由 Text.rich 按 textScaler 整体缩放，
        // 里面的 Text 不能再缩一次（否则带注音的字比旁边的大一圈）。
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _NoBaseline(
                  child: tag(
                    Text(
                      s.ruby!,
                      style: rubyStyle.copyWith(height: 1.1),
                      maxLines: 1,
                      softWrap: false,
                      textScaler: TextScaler.noScaling,
                    ),
                    isRuby: true,
                  ),
                ),
                tag(
                  Text(
                    s.text,
                    style: _styleOf(s),
                    maxLines: 1,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                  ),
                  isRuby: false,
                ),
              ],
            ),
          ),
        );
      }
      fullStart += s.text.length;
    }
    final Widget text = Text.rich(
      TextSpan(children: spans),
      textAlign: textAlign,
      style: style,
    );
    if (!lookup) return text;
    return MetaData(metaData: _lookupData(), child: text);
  }
}

/// 不对外报告基线的包装：Column 取「第一个有基线的孩子」作自己的基线，注音行包上它
/// 后，注音段的基线就是下面基字的基线。
class _NoBaseline extends SingleChildRenderObjectWidget {
  const _NoBaseline({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNoBaseline();
}

class _RenderNoBaseline extends RenderProxyBox {
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => null;
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

  /// 设计系统标签：MD3 = M3E 小标签（圆角小件、语义色淡底）；Apple = 空心胶囊、语义色
  /// 落在圆点上（[FushiTag]）。
  @override
  Widget build(BuildContext context) => FushiTag(
    text: text,
    dense: true,
    backgroundColor:
        color?.withValues(alpha: 0.14) ?? style.scheme.secondaryContainer,
    foregroundColor: color ?? style.scheme.onSecondaryContainer,
  );
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
            .text(style.tokens.label, color: style.muted, ui: true)
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
      borderRadius: BorderRadius.all(Radius.circular(radius)),
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
          showAppDialog<void>(
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
