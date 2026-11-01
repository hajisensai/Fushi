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
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/rendering.dart' show RenderProxyBox, SelectedContent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart' show CardSourceLink;
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardBlock;
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_origin.dart'
    show CardSourceLocatorText, cardSourceKindIcon;
import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_review_edit.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart'
    show SrsFushiCardMedia, srsFushiCardMedia;
import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_card_defs_layout.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show AvifFileImage, isAvifPath;
import 'package:fushi/src/utils/animated_avif_image.dart';
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
    FushiCardBlock.reading => any(block.fields) || any(<String>['Term']),
    FushiCardBlock.picture => a.showPicture && any(block.fields),
    FushiCardBlock.sentence => srsFieldFilled(fields['Sentence']),
    FushiCardBlock.definitions => any(block.fields),
    // 跟随查词的「词频聚合」：聚合且有平均值（FreqSort）时只在读音行显示平均值，
    // 不出明细区；否则出按词典合并的明细区。两者永不同时出现（模板同一规则）。
    FushiCardBlock.frequency =>
      a.showFrequency &&
          any(block.fields) &&
          !(a.aggregateFrequency && srsFieldFilled(fields['FrequencyRank'])),
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

// ---------------------------------------------------------------- 例句目标词（#9）

final RegExp _boldBlock = RegExp(
  r'<(b|strong)\b[^>]*>([\s\S]*?)</\1\s*>',
  caseSensitive: false,
);
final RegExp _cloze = RegExp(r'\{\{c\d+::([\s\S]*?)(?:::[\s\S]*?)?\}\}');

/// Anki 挖空 `{{c1::词::提示}}` → `<b>词</b>`（卡面上显示答案、按目标词强调；Anki 迁移来的
/// 挖空笔记直接把这串写在例句字段里）。
@visibleForTesting
String srsClozeToBold(String html) =>
    html.replaceAllMapped(_cloze, (Match m) => '<b>${m.group(1)}</b>');

/// 字段里显式标出的目标词（`<b>` / `<strong>` / 挖空），纯文本（去振假名与标签）。
@visibleForTesting
List<String> srsMarkedTargets(String html) => <String>[
  for (final Match m in _boldBlock.allMatches(srsClozeToBold(html)))
    if (srsKanaFree(m.group(2)!).trim() case final String t when t.isNotEmpty)
      t,
];

bool _isHiragana(int c) => c >= 0x3041 && c <= 0x309F;

/// 片假名 → 平假名（逐字一一对应，下标不变）：例句把词写成片假名时照样对得上。
String _hiraganaOf(String s) => String.fromCharCodes(<int>[
  for (final int c in s.codeUnits) c >= 0x30A1 && c <= 0x30F6 ? c - 0x60 : c,
]);

/// 在例句纯文本 [text] 里找目标词的位置（UTF-16 区间），找不到返回 null。按序尝试：
///
/// 1. [marked]（字段里 `<b>` / 挖空标出的写法）或 [terms]（词条写法、读音）逐字出现
///    （平 / 片假名视为同一字）；
/// 2. 活用形：去掉词尾送假名的词干（全假名的词去掉最后一拍）出现在句子里，再向后吞掉紧跟的
///    平假名（最多吞「原送假名长度 + 4」个）——`くっつく` 认出 `くっつこう`、`言う` 认出
///    `言った`。这是卡面显示的启发式，不是词形还原；多吞一两个假名只影响强调范围。
@visibleForTesting
(int, int)? srsSentenceTargetRange(
  String text, {
  List<String> marked = const <String>[],
  List<String> terms = const <String>[],
}) {
  final String hay = _hiraganaOf(text);
  for (final String raw in <String>[...marked, ...terms]) {
    final String needle = _hiraganaOf(raw.trim());
    if (needle.isEmpty) continue;
    final int i = hay.indexOf(needle);
    if (i >= 0) return (i, i + needle.length);
  }
  for (final String raw in terms) {
    final String term = _hiraganaOf(raw.trim());
    if (term.isEmpty) continue;
    int cut = term.length;
    while (cut > 0 && _isHiragana(term.codeUnitAt(cut - 1))) {
      cut--;
    }
    // 全假名的词：去掉最后一拍当词干（至少留两个字，单字词干太容易撞上别的词）。
    if (cut == 0) cut = term.length >= 3 ? term.length - 1 : 0;
    if (cut == 0 || cut == term.length) continue;
    final String stem = term.substring(0, cut);
    final int i = hay.indexOf(stem);
    if (i < 0) continue;
    final int maxExtra = term.length - cut + 4;
    int end = i + stem.length;
    while (end < hay.length &&
        end - (i + stem.length) < maxExtra &&
        _isHiragana(hay.codeUnitAt(end))) {
      end++;
    }
    return (i, end);
  }
  return null;
}

/// 例句没有任何加粗段时补上目标词强调（#9）。
///
/// 制卡链路只在「查到的那串」逐字出现在例句里时才写 `<b>`（`anki_models.dart`
/// `_sentenceValue`），以下情形卡面上没有蓝色强调：例句字段里没 `<b>`（Anki 迁移的笔记、
/// 字幕句与上下文句不同的视频卡）、例句里有
/// 白名单外的标签让解析退回纯文本（`<b>` 一起丢了）、挖空 `{{c1::…}}`。这里按
/// [srsSentenceTargetRange] 在显示的段落里重新定位目标词并标成加粗段（注音段整段标）。
@visibleForTesting
List<SrsInline> srsEmphasizeSentenceTarget(
  List<SrsInline> segs, {
  List<String> marked = const <String>[],
  List<String> terms = const <String>[],
}) {
  if (segs.isEmpty || segs.any((SrsInline x) => x.bold)) return segs;
  final String full = segs.map((SrsInline x) => x.text).join();
  final (int, int)? range = srsSentenceTargetRange(
    full,
    marked: marked,
    terms: terms,
  );
  if (range == null) return segs;
  final (int from, int to) = range;
  final List<SrsInline> out = <SrsInline>[];
  int at = 0;
  for (final SrsInline x in segs) {
    final int start = at;
    final int end = at + x.text.length;
    at = end;
    if (end <= from || start >= to || x.isBreak) {
      out.add(x);
      continue;
    }
    if (x.ruby != null) {
      out.add(
        SrsInline(
          x.text,
          ruby: x.ruby,
          bold: true,
          italic: x.italic,
          underline: x.underline,
        ),
      );
      continue;
    }
    final int a = math.max(from, start) - start;
    final int b = math.min(to, end) - start;
    SrsInline piece(String text, {required bool bold}) =>
        SrsInline(text, bold: bold, italic: x.italic, underline: x.underline);
    if (a > 0) out.add(piece(x.text.substring(0, a), bold: false));
    out.add(piece(x.text.substring(a, b), bold: true));
    if (b < x.text.length) {
      out.add(piece(x.text.substring(b), bold: false));
    }
  }
  return out;
}

/// 原生 + 释义 WebView 的 Fushi 卡片卡面。
class SrsFushiCardView extends ConsumerStatefulWidget {
  const SrsFushiCardView({
    super.key,
    required this.face,
    required this.fields,
    required this.definitionsHtml,
    this.topInset = 0,
    this.bottomInset,
  });

  /// 这面卡（cardId / 正反面 / 版式 / 按键桥）。[SrsCardFace.css] 是模板样式表，给释义 WebView 用。
  final SrsCardFace face;

  /// 笔记字段（按字段名）。
  final Map<String, String> fields;

  /// 只含释义区的背面 HTML（引擎渲染）。
  final String definitionsHtml;

  /// 卡面顶端被浮动页头盖住的高度（状态栏 + 页头）。卡面铺到页头底下，这段只作滚动
  /// 内边距：开头的内容从页头下沿开始，往下翻时滚进页头底下，页头收起后不留空带。
  final double topInset;

  /// 卡面底端被浮在上面的底栏（显示答案 / 评分 / 重播）盖住的高度。与 [topInset] 同理：
  /// 卡面铺到底栏背后，这段只作滚动内边距，末尾的内容能滚到底栏上沿以上。
  ///
  /// 用可监听值而不是 double：底栏随翻面 / 换卡变高变矮时只让卡面自己重排，复习页缓存的
  /// 卡面 widget（见复习页 `_cardFace`）不必因此重建。null = 0。
  final ValueListenable<double>? bottomInset;

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

  /// 「翻译点按显示」开着时，这张卡的翻译是否已点开（换卡复位）。
  bool _translationRevealed = false;

  /// 复习页的片段通道（声明这张卡的陪播例句音频用，见 [_declareSentenceAudio]）。
  late final SrsCardVideoChannel _channel = ref.read(
    srsCardVideoChannelProvider,
  );

  /// 这张卡实际画出来的发音键 / 片段（与复习页的自动播放、底栏重播同一份，#10 / #15）。
  SrsFushiCardMedia get _media => srsFushiCardMedia(
    widget.fields,
    audioCardFront: srsFushiFrontKind(widget.fields) == SrsFushiFrontKind.audio,
  );

  /// 只在复习页（卡面发音交给宿主序列时）声明陪播例句音频：外观页预览等别的卡面不碰复习页
  /// 的通道。
  void _declareSentenceAudio() {
    if (widget.face.onPlayAudio == null) {
      _channel.clearSentenceAudio(this);
      return;
    }
    _channel.setSentenceAudio(this, _media.companionSentence);
  }

  /// 底栏让位高度（[SrsFushiCardView.bottomInset]）。
  double get _bottomInset => widget.bottomInset?.value ?? 0;

  void _onBottomInset() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _declareSentenceAudio();
    widget.bottomInset?.addListener(_onBottomInset);
  }

  @override
  void didUpdateWidget(SrsFushiCardView old) {
    super.didUpdateWidget(old);
    if (old.bottomInset != widget.bottomInset) {
      old.bottomInset?.removeListener(_onBottomInset);
      widget.bottomInset?.addListener(_onBottomInset);
    }
    _declareSentenceAudio();
    if (old.face.cardId != widget.face.cardId) {
      // 内容高度保留上一张的：页面只在高度变化时上报，新卡同高时不会再报。
      _clickOpen = false;
      _sentenceRuby = false;
      _translationRevealed = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (old.face.showingAnswer != widget.face.showingAnswer) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    widget.bottomInset?.removeListener(_onBottomInset);
    _channel.clearSentenceAudio(this);
    _scroll.dispose();
    _selectionFocus.dispose();
    super.dispose();
  }

  /// 卡面发音键：复习页里交给它的播放序列（与底栏重播 / 自动播放同一路，新的打断旧的，
  /// 片段带声时在画面上播），否则（外观预览）直接播第一段。
  Future<void> _playNames(List<String> names) async {
    final void Function(List<String>)? host = widget.face.onPlayAudio;
    if (host != null) {
      host(names);
      return;
    }
    if (names.isNotEmpty) await _play(names.first);
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
        // 复习时编辑：原生区选中的文字交给复习页（没有序号；整页清空选区不报）。
        onSelectionChanged: widget.face.onEditSelection == null
            ? null
            : (SelectedContent? content) {
                final String text = content?.plainText ?? '';
                if (text.trim().isEmpty) return;
                widget.face.onEditSelection!(SrsCardSelection(text));
              },
        // 包在取词区外面：抬起时取词区先处理（[SrsNativeLookupRegionState.tookTap] 已定）。
        child: SrsCardGestureRegion(
          onGesture: widget.face.onCardGesture,
          arming: widget.face.gestureArming,
          tapTookLookup: () => _tapTookLookup,
          scrollController: _scroll,
          child: SrsNativeLookupRegion(
            key: _lookupRegion,
            child: ColoredBox(
              // 跟随 app 主题时不铺底，透出复习页背景（与 WebView 外壳同一判据）。
              color: srsCardPaintsOwnSurface(widget.face, a)
                  ? scheme.surface
                  : Colors.transparent,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  if (c.maxHeight.isFinite) {
                    _viewport = math.max(
                      0,
                      c.maxHeight - widget.topInset - _bottomInset,
                    );
                  }
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
      ),
    );
  }

  // ---------------------------------------------------------------- 正面

  Widget _buildFront(BuildContext context, _SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final SrsFushiFrontKind kind = srsFushiFrontKind(f);
    final List<Widget> blocks = <Widget>[
      if (s.appearance.frontFrequency && srsFieldFilled(f['FrequencyRank']))
        _Chip(text: srsPlainText(f['FrequencyRank']!), style: s),
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
            name: _media.front.firstOrNull ?? '',
            large: true,
            style: s,
            onPlay: (String name) => _playNames(<String>[name]),
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
        padding: EdgeInsets.all(
          s.pad,
        ).copyWith(top: s.pad + widget.topInset, bottom: s.pad + _bottomInset),
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
  /// 再乘用户的正面词条倍率（没单独设置时与背面共用）。
  double _heroScale(_SrsCardStyle s, BoxConstraints c) {
    final double min = s.sizeOf(s.tokens.hero);
    return (c.maxWidth * 0.21).clamp(min, min * 2) /
        min *
        s.appearance.effectiveFrontTermScale;
  }

  Widget _frontTerm(_SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final bool ruby =
        s.appearance.frontReading && srsFieldFilled(f['TermFurigana']);
    final List<SrsInline> segs = ruby
        ? srsParseInline(f['TermFurigana']!)
        : <SrsInline>[SrsInline(srsPlainText(f['Term'] ?? ''))];
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
        if (s.appearance.frontReading)
          ..._pitchRow(
            s,
            center: true,
            scale: s.appearance.effectiveFrontTextScale,
          ),
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
        s.appearance.effectiveFrontTextScale *
        (context ? 0.74 : 1);
    final String plain = srsKanaFree(widget.fields['Sentence'] ?? '');
    final TextStyle style = s.text(
      s.tokens.frontSentenceMin,
      scale: scale,
      height: (context ? 1.8 : 1.75) * s.appearance.lineSpacing,
      color: context ? s.muted : null,
    );
    // 例句对齐：默认（模板）正面居中。左对齐时占满栏宽，短句也从左边起。
    final bool centered = s.appearance.sentenceAlign != SrsCardTextAlign.start;
    final Widget text = SrsRubyText(
      key: ValueKey<String>(
        masked ? 'srs-fushi-front-masked' : 'srs-fushi-front-sentence',
      ),
      segments: <SrsInline>[
        SrsInline(
          masked ? srsMaskBold(widget.fields['Sentence'] ?? '') : plain,
        ),
      ],
      style: style,
      rubyStyle: style,
      textAlign: centered ? TextAlign.center : TextAlign.start,
      indent: s.indentOf(style, s.appearance.sentenceIndent),
      // 挖空的听力卡不取词（挖掉的正是答案）。
      lookup: !masked,
    );
    return centered ? text : SizedBox(width: double.infinity, child: text);
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
        srsPlainText(widget.fields['Term'] ?? ''),
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

  /// 读音 + 音调图。[scale] = 正文倍率（正面传正面倍率）；[badge] = 声调核序号画成假名右上角的
  /// 小角标（背面读音行；正面只画图，与原来一致）。只画字段里已有的读音与声调，不推断。
  List<Widget> _pitchRow(
    _SrsCardStyle s, {
    bool center = false,
    double? scale,
    bool badge = false,
  }) {
    final Map<String, String> f = widget.fields;
    final String kana = srsFieldFilled(f['TermFurigana'])
        ? srsKanaOf(srsParseInline(f['TermFurigana']!))
        : srsPlainText(f['TermReading'] ?? '');
    final List<int> positions = srsPitchPositions(
      f['PitchPosition'] ?? '',
      kana,
    );
    if (kana.isEmpty) return const <Widget>[];
    final TextStyle style = s.text(
      s.tokens.emphasisLine,
      scale: scale ?? s.appearance.textScale,
      height: 1.3,
    );
    // 一个读音有几种声调就画几张图（没有可解析的声调时只显示读音本身）；key 各不相同，
    // 同一个 Wrap 里重复 key 会直接抛错。每张图放不下一行时整体等比缩小（长假名 /
    // 窄屏不溢出），几张图并排放不下由外层 Wrap 折行。
    final List<int?> graphs = positions.isEmpty
        ? const <int?>[null]
        : positions;
    final List<Widget> out = <Widget>[
      for (int i = 0; i < graphs.length; i++)
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: SrsPitchGraph(
            key: ValueKey<String>(
              i == 0 ? 'srs-fushi-pitch' : 'srs-fushi-pitch-$i',
            ),
            kana: kana,
            position: graphs[i],
            categories: f['PitchCategories'] ?? '',
            style: style,
            dark: s.dark,
            fallbackColor: s.scheme.onSurface,
            showPosition: badge,
          ),
        ),
    ];
    if (!center || out.length < 2) return out;
    // 正面居中竖排的 Column 里：多张图横向并排、放不下再折行。
    return <Widget>[
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: out,
      ),
    ];
  }

  Widget _readingRow(_SrsCardStyle s) {
    final Map<String, String> f = widget.fields;
    return Wrap(
      key: const ValueKey<String>('srs-fushi-reading-row'),
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // 声调核序号是每张图右上角的小角标（不再与词频同一个大标签，多声调时一一对应）。
        ..._pitchRow(s, badge: true),
        // 平均词频（聚合）：关了「显示词频」不出；下方明细区在时不重复。
        if (s.appearance.showFrequency &&
            srsFieldFilled(f['FrequencyRank']) &&
            !srsFushiBlockVisible(FushiCardBlock.frequency, f, s.appearance))
          _Chip(
            key: const ValueKey<String>('srs-fushi-frequency-aggregate'),
            text: srsPlainText(f['FrequencyRank']!),
            style: s,
          ),
      ],
    );
  }

  /// 词条区：「发音键｜词条 + 读音行」。左栏统一网格——卡片 / 图片通栏，词条区与底部
  /// 元信息缩进一个卡片内边距，发音键与例句卡里的发音键落在同一条竖线上、后面的文字
  /// 也从同一个 x 起头。词条独占整行宽：手机上不再与右侧缩略图抢宽度（短词被折成两行）。
  Widget _header(_SrsCardStyle s, BoxConstraints c) {
    final List<String> audio = srsAudioSources(
      widget.fields['TermAudio'] ?? '',
    );
    final Widget main = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _term(s, c),
        const SizedBox(height: 4),
        _readingRow(s),
      ],
    );
    final Widget body = audio.isEmpty
        ? main
        : Row(
            children: <Widget>[
              Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: <Widget>[
                  for (int i = 0; i < audio.length; i++)
                    _AudioButton(
                      // 单词音频可能有好几段（多个发音来源）：key 各不相同，否则同一个
                      // Column 里重复 key 直接抛错、整张卡面渲染失败。
                      key: ValueKey<String>(
                        i == 0
                            ? 'srs-fushi-word-audio'
                            : 'srs-fushi-word-audio-$i',
                      ),
                      name: audio[i],
                      style: s,
                      onPlay: (String name) => _playNames(<String>[name]),
                    ),
                ],
              ),
              SizedBox(width: s.gap),
              Expanded(child: main),
            ],
          );
    return Padding(
      key: const ValueKey<String>('srs-fushi-header'),
      padding: EdgeInsets.symmetric(horizontal: s.pad),
      child: body,
    );
  }

  Widget _term(_SrsCardStyle s, BoxConstraints c) {
    final Map<String, String> f = widget.fields;
    final List<SrsInline> segs = srsFieldFilled(f['TermFurigana'])
        ? srsParseInline(f['TermFurigana']!)
        : srsParseInline(f['Term'] ?? '', ankiFurigana: false);
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

  /// 图片 / 视频片段：宽版式左栏与窄版式同一套规则——常见比例铺满栏宽（窄版式就是整屏
  /// 宽），怪比例限高完整显示。窄版式以前是标题右侧 126×118 的缩略图，手机上视频片段
  /// 小得看不清、播放 / 放大 / 重播三个角标挤在一起。
  Widget? _picture(_SrsCardStyle s) {
    if (!srsFushiBlockVisible(
      FushiCardBlock.picture,
      widget.fields,
      s.appearance,
    )) {
      return null;
    }
    final String picture = widget.fields['Media']!;
    final SrsPictureLimits limits = srsPictureLimits(
      ref.watch(srsReviewImageSizeProvider),
      viewport: _viewport,
    );
    final double maxHeight = limits.maxHeight;
    // 视频片段（WebM `<video>` / MP4 `[sound:]`）：在卡面上原生播，复习页的音频序列经
    // 片段通道驱动它（先单词音频、再片段）。
    final String? clip = srsVideoSources(picture).firstOrNull;
    if (clip != null) {
      // 尺寸与图片同一套规则：常见比例铺满栏宽、超过高度上限等比缩小。
      return SrsCardVideoClip(
        key: const ValueKey<String>('srs-fushi-picture'),
        name: clip,
        maxHeight: maxHeight,
        fillWidth: limits.fillWidth,
        maxFillHeight: limits.maxFillHeight,
        radius: s.tokens.radiusSmall,
      );
    }
    final String? name = srsImageSources(picture).firstOrNull;
    if (name == null) return null;
    return _MediaImage(
      key: const ValueKey<String>('srs-fushi-picture'),
      name: name,
      // 常见比例（视频截图 16:9、4:3 等）铺满栏宽、与例句卡等宽；竖长 / 超宽的怪比例
      // 限高完整显示。铺满的图有高度上限，再高就整张等比缩小（不裁切），不把例句挤出
      // 首屏。各上限随「卡面图片大小」设置，见 [srsPictureLimits]。
      maxHeight: maxHeight,
      fillWidth: limits.fillWidth,
      maxFillHeight: limits.maxFillHeight,
      radius: s.tokens.radiusSmall,
    );
  }

  Widget? _sentence(_SrsCardStyle s) {
    final Map<String, String> f = widget.fields;
    if (!srsFushiBlockVisible(FushiCardBlock.sentence, f, s.appearance)) {
      return null;
    }
    final bool showRuby = _sentenceRuby;
    final String raw = f['Sentence']!;
    // 目标词强调（#9）：显示的那份没带 `<b>` 时按字段标记 / 词条写法重新定位。
    final List<SrsInline> segs = srsEmphasizeSentenceTarget(
      srsParseInline(srsClozeToBold(raw)),
      marked: srsMarkedTargets(raw),
      terms: <String>[
        srsPlainText(f['Term'] ?? ''),
        if (srsFieldFilled(f['TermFurigana']))
          srsKanaOf(srsParseInline(f['TermFurigana']!)),
        srsPlainText(f['TermReading'] ?? ''),
      ],
    );
    final bool hasRuby = segs.any((SrsInline x) => x.ruby != null);
    // 例句发音键：片段自带例句声音时它控制片段（画面上从头播、有声），否则播例句音频
    // （画面上的动图 / 静音片段从头陪播），两者不再各出一路声音（#7 / #10）。
    final List<String> audio = _media.sentenceUnit;
    // 注音收起时第一下点按是「显示注音」（原有操作），不取词；注音显示后点在字上 =
    // 查词，点在字外 = 收起注音。
    final bool rubyToggle = hasRuby;
    final TextStyle style = s.text(
      s.tokens.emphasisLine,
      scale: s.appearance.textScale,
      height: 1.9 * s.appearance.lineSpacing,
    );
    final bool centered = s.appearance.sentenceAlign == SrsCardTextAlign.center;
    final Widget ruby = SrsRubyText(
      key: const ValueKey<String>('srs-fushi-sentence'),
      segments: showRuby
          ? segs
          : <SrsInline>[for (final SrsInline x in segs) x.withoutRuby()],
      style: style,
      rubyStyle: s.text(
        s.tokens.ruby,
        scale: s.appearance.textScale,
        color: s.muted,
      ),
      emphasis: s.scheme.primary,
      textAlign: centered ? TextAlign.center : TextAlign.start,
      indent: s.indentOf(style, s.appearance.sentenceIndent),
      lookup: !rubyToggle || _sentenceRuby,
    );
    // 居中要占满栏宽（否则短句按自身宽度靠左）。
    final Widget text = centered
        ? SizedBox(width: double.infinity, child: ruby)
        : ruby;
    return FushiCard(
      key: const ValueKey<String>('srs-fushi-sentence-block'),
      padding: EdgeInsets.all(s.pad),
      pressScale: false,
      color: s.tokens.surface1(s.scheme),
      // 发音按钮在句首、与整段垂直居中：贴着它播放的那句话，不再孤零零停在卡片右上角。
      child: Row(
        children: <Widget>[
          if (audio.isNotEmpty) ...<Widget>[
            _AudioButton(
              key: const ValueKey<String>('srs-fushi-sentence-audio'),
              name: audio.first,
              style: s,
              onPlay: (String _) => _playNames(audio),
            ),
            SizedBox(width: s.gap),
          ],
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
                    child: _translation(
                      s,
                      srsPlainText(f['SentenceTranslation']!),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 例句翻译。「模糊到点按」开着（[SrsCardAppearance.blurTranslation]）时默认模糊且不可取词，
  /// 点一下显示；显示后点在字上 = 查词，点在字外（行内空白）= 再次模糊（与注音同一套规则）。
  Widget _translation(_SrsCardStyle s, String text) {
    // 翻译跟随例句对齐（同一个例句区块）；首行缩进只作用于例句本身。
    final bool centered = s.appearance.sentenceAlign == SrsCardTextAlign.center;
    final Widget line = Text(
      text,
      key: const ValueKey<String>('srs-fushi-translation'),
      textAlign: centered ? TextAlign.center : TextAlign.start,
      style: s.text(
        s.tokens.bodySecondary,
        scale: s.appearance.textScale,
        height: 1.55,
        color: s.muted,
        ui: true,
      ),
    );
    final Widget body = centered
        ? SizedBox(width: double.infinity, child: line)
        : line;
    if (!s.appearance.blurTranslation) {
      return srsLookupText(text: text, child: body);
    }
    final bool blurred = !_translationRevealed;
    return Semantics(
      container: true,
      onTap: blurred ? () => setState(() => _translationRevealed = true) : null,
      child: FocusableActionDetector(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) =>
                setState(() => _translationRevealed = !_translationRevealed),
          ),
        },
        mouseCursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey<String>('srs-fushi-translation-toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!blurred && _tapTookLookup) return;
            setState(() => _translationRevealed = !_translationRevealed);
          },
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: blurred ? 6 : 0),
              duration: fushiMotionDuration(context, FushiMotion.short),
              builder: (BuildContext _, double sigma, Widget? child) =>
                  sigma < 0.05
                  ? child!
                  : ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: sigma,
                        sigmaY: sigma,
                        tileMode: TileMode.decal,
                      ),
                      child: child,
                    ),
              // 模糊期间不标成可取词：第一下点按只负责显示。
              child: blurred ? body : srsLookupText(text: text, child: body),
            ),
          ),
        ),
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
          // 明细按词典合并（同一词典的多个值合成一项，与查词弹窗分组一致）。
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String item in srsFrequencyGroups(f['Frequency']!))
                _Chip(text: item, style: s),
            ],
          ),
        ),
      if (srsFushiBlockVisible(FushiCardBlock.source, f, s.appearance))
        _MetaRow(
          key: const ValueKey<String>('srs-fushi-source'),
          label: labels.source,
          style: s,
          child: _sourceText(s, f['Source']!),
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
        // 出处 = 种类图标 + 标题（链接锚文本：书名 / 番名 / 歌名 / 游戏名）+ 定位
        // （第几集 · 时间 / 第几页，[CardSourceLocatorText]）。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              cardSourceKindIcon(link.kind),
              size: 14,
              color: s.scheme.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                style: s
                    .text(s.tokens.caption, color: s.scheme.primary, ui: true)
                    .copyWith(decoration: TextDecoration.underline),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: CardSourceLocatorText(
                database: ref.read(appProvider).database,
                link: link,
                style: s.text(s.tokens.caption, color: s.muted, ui: true),
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
    // 宽版式还要 `align-items:stretch`：模板双栏网格的 `align-items:start` 在这里切成 flex
    // 纵向后照样生效，释义块会按内容收缩成窄条（实测栏宽 785px、释义只有 325px）。
    hostCss:
        '.fc.fc-back.fc-defs-only{flex-direction:column;align-items:stretch;'
        'max-width:none;margin:0;}'
        '${wide ? '' : ':root{--fushi-srs-clamp:${(_viewport * 0.52).round()}px;}'}'
        // 宽版式释义栏铺到底栏背后、页内自己滚：末尾留出底栏高度，最后一条能滚到底栏以上。
        '${wide && _bottomInset > 0 ? 'html{padding-bottom:${_bottomInset.round()}px;}' : ''}'
        // 主词典通栏 + 其他词典分列，展开规则跟查词设置（srs_card_defs_layout.dart）。
        '${ref.watch(srsDefsLayoutCssProvider)}'
        // 卡面外观：释义显示前几本词典、释义对齐 / 首行缩进（只改显示，字段不动）。
        '${srsDefsAppearanceCss(ref.watch(srsCardAppearanceProvider))}',
    hostScript: kSrsDefsLayoutScript,
    onWheel: wide ? null : _onDefsWheel,
    onSourceLink: widget.face.onSourceLink,
    autoplayMedia: widget.face.autoplayMedia,
    // 释义里的发音按钮同样交给复习页的序列（同一时刻只出一路声音）。
    onPlayAudio: widget.face.onPlayAudio,
    // 释义区的卡面手势由页内指针脚本回报（原生区那一层见 [SrsCardGestureRegion]）。
    onCardGesture: widget.face.onCardGesture,
    gestureArming: widget.face.gestureArming,
    // 释义页整页就是释义字段：选区序号对得上字段里的序号，且只在释义字段里找。
    onEditSelection: widget.face.onEditSelection == null
        ? null
        : (SrsCardSelection sel) => widget.face.onEditSelection!(
            SrsCardSelection(
              sel.text,
              occurrence: sel.occurrence,
              definitionsOnly: true,
            ),
          ),
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
        // 释义 WebView 上的手势归页内脚本判定，原生区的识别跳过这块。
        child: SrsCardGestureRegion.excluded(
          child: builder(context, _defsFace(wide: wide)),
        ),
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
    final Widget? picture = _picture(s);
    final Widget? sentence = _sentence(s);
    final Widget? defs = _definitions(context, wide: false);
    final double viewport = c.maxHeight.isFinite ? _viewport : 800;
    final double reported = _defsHeight ?? viewport * 0.6;
    final double defsHeight = reported > kSrsDefsMaxInlineHeight
        ? viewport
        : reported;
    // 自上而下与宽版式左栏同序：词条 → 图片 / 视频（通栏）→ 例句 → 释义 → 元信息。
    final List<Widget> blocks = <Widget>[
      Padding(
        padding: EdgeInsets.fromLTRB(s.pad, s.pad, s.pad, 0),
        child: _header(s, c),
      ),
      if (picture != null)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: s.pad),
          // 放松外层 stretch 的紧约束：铺满时按栏宽定高，怪比例靠左按原比例显示。
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: picture,
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
      padding: EdgeInsets.only(
        top: widget.topInset,
        bottom: s.pad + _bottomInset,
      ),
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
    final Widget? picture = _picture(s);
    final Widget? sentence = _sentence(s);
    final Widget? defs = _definitions(context, wide: true);
    final List<Widget> left = <Widget>[
      _header(s, c),
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
            padding: EdgeInsets.all(s.pad).copyWith(
              top: s.pad + widget.topInset,
              bottom: s.pad + _bottomInset,
            ),
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
            // 释义栏是 WebView，滚不到页头底下：整栏让位。
            child: Padding(
              padding: EdgeInsets.only(top: widget.topInset),
              child: FushiStaggeredEntrance(index: left.length, child: defs),
            ),
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

  /// 首行缩进 [chars] 个字（按 [style] 的字号，1 字 = 1em）的逻辑像素宽度。
  double indentOf(TextStyle style, int chars) =>
      chars <= 0 ? 0 : chars * (style.fontSize ?? 16);

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
    this.indent = 0,
  });

  final List<SrsInline> segments;
  final TextStyle style;
  final TextStyle rubyStyle;
  final TextAlign textAlign;

  /// 首行缩进（逻辑像素，0 = 不缩进）：段首放一个等宽的空白占位。占位在外层段落里占一个
  /// 占位符，取词偏移换算（[_lookupData]）把它算成不可取词的一段，取词范围不受影响。
  final double indent;

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
    // 高亮底色半透明叠在卡面上：深色卡面上也看得清字。
    backgroundColor: s.highlight == null
        ? null
        : Color(s.highlight!).withValues(alpha: 0.45),
  );

  /// 取词标记：各段在外层段落纯文本（注音段只占一个占位符）与整段纯文本里的偏移。
  SrsLookupTextData _lookupData() {
    final StringBuffer full = StringBuffer();
    final List<SrsLookupTextSegment> map = <SrsLookupTextSegment>[];
    final List<FushiRubySpan> rubySpans = <FushiRubySpan>[];
    int outer = 0;
    if (indent > 0) {
      map.add(
        const SrsLookupTextSegment(
          outerStart: 0,
          outerLength: 1,
          fullStart: 0,
          placeholder: true,
        ),
      );
      outer = 1;
    }
    for (final SrsInline s in segments) {
      final bool placeholder = s.ruby != null;
      final String reading = (s.ruby ?? '').trim();
      if (reading.isNotEmpty && s.text.isNotEmpty) {
        rubySpans.add(
          FushiRubySpan(
            start: full.length,
            end: full.length + s.text.length,
            reading: reading,
          ),
        );
      }
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
    return SrsLookupTextData(
      full.toString(),
      segments: map,
      rubySpans: rubySpans,
    );
  }

  @override
  Widget build(BuildContext context) {
    int fullStart = 0;
    final List<InlineSpan> spans = <InlineSpan>[
      if (indent > 0)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(width: indent),
        ),
    ];
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

/// 音调图：读音逐拍，高拍画上划线、降调处画一小段降调符、低拍不画（与模板脚本同一套规则，
/// 见 [srsPitchMoraMarks]）。
class SrsPitchGraph extends StatelessWidget {
  const SrsPitchGraph({
    super.key,
    required this.kana,
    required this.position,
    required this.categories,
    required this.style,
    required this.dark,
    required this.fallbackColor,
    this.showPosition = false,
  });

  final String kana;
  final int? position;
  final String categories;
  final TextStyle style;
  final bool dark;
  final Color fallbackColor;

  /// 在图的右上角画声调核序号角标（取自字段 PitchPosition，不推断）。
  final bool showPosition;

  @override
  Widget build(BuildContext context) {
    final List<String> morae = srsMorae(kana);
    final int? p = position;
    if (p == null) return Text(kana, style: style);
    final Color color = srsPitchColor(
      srsPitchType(p, morae.length, categories),
      dark: dark,
    );
    final List<SrsPitchMoraMark> marks = srsPitchMoraMarks(p, morae.length);
    Widget mora(String text, SrsPitchMoraMark mark) => CustomPaint(
      foregroundPainter: _SrsPitchMoraPainter(mark: mark, color: color),
      child: Padding(
        padding: const EdgeInsets.only(left: 1, right: 1, top: 4),
        child: Text(text, style: style),
      ),
    );
    final Widget graph = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < marks.length; i++)
          mora(i < morae.length ? morae[i] : ' ', marks[i]),
      ],
    );
    return Semantics(
      label: '$kana [$p]',
      child: showPosition
          // 声调核序号：假名右上角的小号带圈数字（顶端对齐），颜色同这张图。
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                graph,
                const SizedBox(width: 2),
                ExcludeSemantics(child: _pitchBadge(p, color)),
              ],
            )
          : graph,
    );
  }

  Widget _pitchBadge(int p, Color color) {
    final double base = style.fontSize ?? 16;
    final double size = math.max(14, base * 0.62);
    return Container(
      key: const ValueKey<String>('srs-fushi-pitch-position'),
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Text(
        '$p',
        style: style.copyWith(
          fontSize: math.max(9, base * 0.42),
          height: 1,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 声调图里一拍的画法（与 Fushi 卡片模板脚本 `drawPitch` + styling.css `.fc-mora*`、
/// Yomitan 的文字式声调图同一套记法）：高拍画上划线；降调前最后一个高拍在右侧向下画
/// 一小段降调符；低拍**什么都不画**（反馈 kP5GJ0pahv：原生卡面给低拍画下划线，和导出到
/// Anki 的模板卡面不是一套图，平板型 / 中高型看起来像「上下框」完全读错）。尾高型在
/// 最后多一个 [tail] 拍，画一段虚线表示后接助词变低。
@immutable
class SrsPitchMoraMark {
  const SrsPitchMoraMark({
    required this.high,
    required this.drop,
    this.tail = false,
  });

  final bool high;
  final bool drop;
  final bool tail;

  @override
  bool operator ==(Object other) =>
      other is SrsPitchMoraMark &&
      other.high == high &&
      other.drop == drop &&
      other.tail == tail;

  @override
  int get hashCode => Object.hash(high, drop, tail);

  @override
  String toString() =>
      'SrsPitchMoraMark(high: $high, drop: $drop, tail: $tail)';
}

/// 声调号 [position]（0 = 平板，n = 第 n 拍后降）在 [moraCount] 拍读音上的逐拍画法；
/// 尾高型（position ≥ 拍数）多出一个尾拍。
List<SrsPitchMoraMark> srsPitchMoraMarks(int position, int moraCount) {
  final int p = position;
  return <SrsPitchMoraMark>[
    for (int i = 0; i < moraCount; i++)
      SrsPitchMoraMark(
        high: p == 0
            ? i > 0
            : p == 1
            ? i == 0
            : i > 0 && i < p,
        drop: p > 0 && i == p - 1,
      ),
    if (p > 0 && p >= moraCount)
      const SrsPitchMoraMark(high: false, drop: false, tail: true),
  ];
}

class _SrsPitchMoraPainter extends CustomPainter {
  const _SrsPitchMoraPainter({required this.mark, required this.color});

  final SrsPitchMoraMark mark;
  final Color color;

  static const double _stroke = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = _stroke
      ..style = PaintingStyle.stroke;
    const double y = _stroke / 2;
    if (mark.high) {
      canvas.drawLine(const Offset(0, y), Offset(size.width, y), paint);
    }
    if (mark.drop) {
      final double x = size.width - _stroke / 2;
      canvas.drawLine(Offset(x, y), Offset(x, size.height * 0.45), paint);
    }
    if (mark.tail) {
      final double ty = size.height * 0.62;
      for (double x = 0; x < size.width; x += 4) {
        canvas.drawLine(
          Offset(x, ty),
          Offset(math.min(x + 2, size.width), ty),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SrsPitchMoraPainter old) =>
      old.mark != mark || old.color != color;
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.text, required this.style});

  final String text;
  final _SrsCardStyle style;

  /// 设计系统标签（词频）：MD3 = M3E 小标签（圆角小件、淡底）；Apple = 空心胶囊
  /// （[FushiTag]）。声调核序号不用它，见 [SrsPitchGraph.showPosition]。
  @override
  Widget build(BuildContext context) => FushiTag(
    text: text,
    dense: true,
    backgroundColor: style.scheme.secondaryContainer,
    foregroundColor: style.scheme.onSecondaryContainer,
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

  /// 与词条区同缩进（一个卡片内边距）：左栏的文字都落在卡片内容那条竖线上。
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: style.pad),
    child: Column(
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
    ),
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

// 铺满栏宽的比例范围 [kSrsPictureFillMinAspect] / [kSrsPictureFillMaxAspect] 与尺寸规则
// [srsCardMediaBoxSize] 在 srs_card_video_clip.dart（图片与视频片段共用）。

/// 铺满的图片最高占卡面视口高度的比例。
const double kSrsPictureFillMaxViewportFraction = 0.4;

/// 会动的图片格式（例句音频开播时从头重播，见 [SrsCardSentenceCompanion]）。
const Set<String> _kAnimatedImageExtensions = <String>{
  'gif',
  'webp',
  'avif',
  'apng',
};

/// [name] 可能是动图（按扩展名）。
@visibleForTesting
bool srsIsAnimatedImageName(String name) {
  final int dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _kAnimatedImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 媒体库里的图片：点按全屏查看。动图是例句音频的陪播画面（#7）：例句开播时从第一帧重播，
/// 画面与句子同步（视频制卡的动图封面与例句音频切自同一段字幕时间）。

/// 原生卡面图片的尺寸上限（[srsPictureLimits] 按「卡面图片大小」设置给出）。
typedef SrsPictureLimits = ({
  double maxHeight,
  bool fillWidth,
  double maxFillHeight,
});

/// Fushi 卡片图片（含视频片段）的尺寸上限，与 WebView 卡面的 [srsReviewImageSizeCss]
/// 读同一个设置。宽版式左栏与窄版式（手机）通栏同一套规则，栏宽由父级给。
///
/// - 原样：常见比例铺满栏宽（视口高于 520 时），怪比例 / 视频片段最高 220（矮视口
///   120）；铺满的图最高占视口的 [kSrsPictureFillMaxViewportFraction]。
/// - 适应宽度：任何视口都铺满栏宽，限高放宽到 360（矮视口 180）/ 视口的 55%。
/// - 放大：铺满栏宽，限高到视口的 [kSrsReviewLargeImageMaxVh]%。
@visibleForTesting
SrsPictureLimits srsPictureLimits(
  SrsReviewImageSize size, {
  required double viewport,
}) {
  final bool short = viewport <= 520;
  final double largeCap = viewport * kSrsReviewLargeImageMaxVh / 100;
  return (
    maxHeight: switch (size) {
      SrsReviewImageSize.original => short ? 120 : 220,
      SrsReviewImageSize.fitWidth => short ? 180 : 360,
      SrsReviewImageSize.large => largeCap,
    },
    fillWidth: size != SrsReviewImageSize.original || !short,
    maxFillHeight: switch (size) {
      SrsReviewImageSize.original =>
        viewport * kSrsPictureFillMaxViewportFraction,
      SrsReviewImageSize.fitWidth => viewport * 0.55,
      SrsReviewImageSize.large => largeCap,
    },
  );
}

/// 全屏查看一张卡面图片（原生卡点图、WebView 卡经 [SrsCardFace.onImageTap] 点图共用）：
/// 可双指 / 滚轮缩放拖动，点一下关闭。
Future<void> showSrsCardImageViewer(BuildContext context, Widget picture) =>
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(child: picture),
      ),
    );

/// 卡面图片控件：AVIF（制卡默认的动图格式）走 Rust 逐帧解码播放，其余按
/// [srsCardImageProvider]。来源无法显示时 null。
Widget? srsCardImageWidget(String src, SrsMediaStore? store, {BoxFit? fit}) {
  final File? avif = !src.startsWith('data:') && isAvifPath(src)
      ? store?.resolve(src)
      : null;
  if (avif != null) {
    return FushiAnimatedAvifImage(
      file: avif,
      fit: fit,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
  final ImageProvider<Object>? provider = srsCardImageProvider(src, store);
  if (provider == null) return null;
  return Image(
    image: provider,
    fit: fit,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
}

/// 媒体库里的图片：点按全屏查看。
class _MediaImage extends ConsumerStatefulWidget {
  const _MediaImage({
    super.key,
    required this.name,
    required this.radius,
    this.maxHeight,
    this.fillWidth = false,
    this.maxFillHeight,
  });

  final String name;
  final double radius;
  final double? maxHeight;

  /// 常见比例时铺满父级宽度（按原比例定高）；怪比例退回 [maxHeight] 限高。
  final bool fillWidth;

  /// 铺满时的高度上限；按原比例超过它就封顶并居中裁切。null = 不封顶。
  final double? maxFillHeight;

  @override
  ConsumerState<_MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends ConsumerState<_MediaImage>
    implements SrsCardSentenceCompanion {
  ImageProvider<Object>? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 解码出的宽 / 高；未知（还没解码 / 失败）时 null。
  double? _aspect;

  /// 图片加载失败（本机没有这个文件——媒体还没同步过来——或解码失败）：画同尺寸的
  /// 「图片未同步」占位，而不是零尺寸空盒（那样与「卡本来没图」分不出来）。
  bool _failed = false;

  late final SrsCardVideoChannel _channel = ref.read(
    srsCardVideoChannelProvider,
  );

  /// 每次例句开播 +1：动图子树换 key 重建，从第一帧播起。
  int _restart = 0;

  /// 重播期间仍垫在底下的旧动图（key）：新实例解出首帧之前先留着旧画面，否则替换瞬间
  /// 整块变空、动图「闪一下」。新实例出帧后（[_layerReady]）撤掉。
  int? _prevRestart;

  @override
  void initState() {
    super.initState();
    _channel.attachCompanion(this);
  }

  @override
  void dispose() {
    _channel.detachCompanion(this);
    _unlisten();
    super.dispose();
  }

  /// 例句音频开播：动图回到第一帧。普通图片引擎的多帧解码器挂在图片缓存里，换 key 重建
  /// 拿到的仍是同一个（接着当前帧播），先把它逐出缓存；AVIF 由原生解码器按 key 重开。
  @override
  void sentenceStarted(String name) {
    if (!mounted || !srsIsAnimatedImageName(widget.name)) return;
    final ImageProvider<Object>? provider = _provider;
    if (provider != null && !isAvifPath(widget.name)) {
      unawaited(provider.evict());
    }
    setState(() {
      _prevRestart ??= _restart;
      _restart++;
    });
  }

  /// 第 [restart] 层已出首帧：是当前层就撤掉垫底的旧层。
  void _layerReady(int restart) {
    if (restart != _restart || _prevRestart == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && restart == _restart && _prevRestart != null) {
        setState(() => _prevRestart = null);
      }
    });
  }

  void _unlisten() {
    final ImageStreamListener? l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  String? _providerName;
  SrsMediaStore? _providerStore;

  /// 同一张图（名字 + 媒体库不变）只建一次 provider：`MemoryImage` 按字节数组身份判等，
  /// 每次 build 新建会让 Image 反复重载、尺寸监听反复重来。
  ImageProvider<Object>? _providerFor(SrsMediaStore? store) {
    if (_providerName != widget.name || !identical(_providerStore, store)) {
      _providerName = widget.name;
      _providerStore = store;
      _unlisten();
      _provider = srsCardImageProvider(widget.name, store);
      _aspect = null;
      _failed = false;
    }
    return _provider;
  }

  /// 解析图片：拿尺寸（铺满模式据此决定铺不铺满）、发现加载失败；同一 provider 只解析
  /// 一次（与 [Image] 共用图片缓存里的同一条流，不额外解码）。
  void _resolve(BuildContext context, ImageProvider<Object> provider) {
    if (_stream != null) return;
    final ImageStream stream = provider.resolve(
      createLocalImageConfiguration(context),
    );
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        final double w = info.image.width.toDouble();
        final double h = info.image.height.toDouble();
        info.dispose();
        if (!mounted || h <= 0) return;
        // 动图每帧都会回调：比例没变就不重建。
        final double aspect = w / h;
        if (aspect == _aspect && !_failed) return;
        setState(() {
          _aspect = aspect;
          _failed = false;
        });
      },
      onError: (Object _, StackTrace? _) {
        if (mounted && !_failed) setState(() => _failed = true);
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  Widget build(BuildContext context) {
    final double radius = widget.radius;
    final ImageProvider<Object>? provider = _providerFor(
      ref.watch(srsMediaStoreProvider).valueOrNull,
    );
    if (provider != null) _resolve(context, provider);
    if (provider != null && _failed) {
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) =>
            SrsCardMediaMissing(
              key: const ValueKey<String>('srs-fushi-picture-missing'),
              kind: SrsCardMediaKind.image,
              size: srsCardMediaBoxSize(
                aspect: kSrsCardMediaFallbackAspect,
                maxWidth: c.maxWidth,
                maxHeight: widget.maxHeight ?? 220,
                fillWidth: widget.fillWidth,
                maxFillHeight: widget.maxFillHeight,
              ),
              radius: radius,
            ),
      );
    }
    final double? aspect = _aspect;
    final bool fill =
        widget.fillWidth &&
        aspect != null &&
        aspect >= kSrsPictureFillMinAspect &&
        aspect <= kSrsPictureFillMaxAspect;
    // AVIF（制卡默认的动图格式）：Rust 逐帧解码播放；静图同一个控件出首帧。尺寸仍由
    // [provider]（AVIF 时是原生首帧解码的 AvifFileImage）解析。
    final File? avif =
        !widget.name.startsWith('data:') && isAvifPath(widget.name)
        ? _providerStore?.resolve(widget.name)
        : null;
    Widget layer(int restart, BoxFit? fit, {required bool signal}) =>
        KeyedSubtree(
          key: ValueKey<int>(restart),
          child: avif != null
              ? FushiAnimatedAvifImage(
                  file: avif,
                  fit: fit,
                  onFirstFrame: signal ? () => _layerReady(restart) : null,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              : Image(
                  image: provider!,
                  fit: fit,
                  gaplessPlayback: true,
                  frameBuilder: signal
                      ? (BuildContext _, Widget child, int? frame, bool _) {
                          if (frame != null) _layerReady(restart);
                          return child;
                        }
                      : null,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
        );
    // 无论有没有垫底层都是同一个 Stack：各层以 key 在兄弟间对位，旧层从「独占」变成
    // 「垫底」、新层从「叠在上面」变成「独占」时元素与已解出的画面原样保留。若单层时直接
    // 返回 KeyedSubtree、双层时才包 Stack，父节点类型一变旧层就被卸载重建，垫底的只是又
    // 一个从零解码的新实例，闪空照旧。
    Widget picture({BoxFit? fit}) {
      final int? prev = _prevRestart;
      return Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          if (prev != null) layer(prev, fit, signal: false),
          layer(_restart, fit, signal: prev != null),
        ],
      );
    }

    final Widget image = provider == null
        ? const SizedBox.shrink()
        // 框与原图同比例；contain 保证取整误差下也不裁掉边。
        : picture(fit: fill ? BoxFit.contain : null);
    // 铺满与否同一棵树（只换约束）：比例解出来那一刻从「限高」切到「铺满」时不换父节点，
    // 画面层不被卸载重建（否则首帧要重新解码一次，动图从头再播）。
    final Widget box = ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => ConstrainedBox(
          constraints: fill
              // 铺满：按原比例定高；超过 [maxFillHeight] 就整张等比缩小到这个高度
              // （不裁切），靠左对齐卡片边缘。
              ? BoxConstraints.tight(
                  srsCardMediaBoxSize(
                    aspect: aspect,
                    maxWidth: c.maxWidth,
                    maxHeight: widget.maxHeight ?? 220,
                    fillWidth: true,
                    maxFillHeight: widget.maxFillHeight,
                  ),
                )
              : BoxConstraints(maxHeight: widget.maxHeight ?? 220),
          child: image,
        ),
      ),
    );
    if (provider == null) return box;
    return FushiPressScale(
      child: GestureDetector(
        onTap: () => unawaited(
          showSrsCardImageViewer(context, picture(fit: BoxFit.contain)),
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
  if (file == null) return null;
  // AVIF 统一走原生内核（同 resizedFileImage / BUG-3643）：不依赖各平台引擎 codec 是否带
  // AVIF；动图在这里只取首帧（全屏查看用），卡面上的动图播放见 FushiAnimatedAvifImage。
  return isAvifPath(file.path) ? AvifFileImage(file) : FileImage(file);
}
