/// 非 Fushi 卡片（Anki 导入牌组、用户自建类型）的**原生**卡面：把 [SrsHtmlBlock] 盒子树
/// （srs_html_card.dart 按卡片 HTML / CSS 层叠出来的）用 Flutter 画出来，取代整面 WebView。
///
/// 只有 [srsHtmlCardOf] 判定两面都画得全的卡才走这里，其余照旧整面 WebView。与 WebView 卡面
/// 共用同一套宿主行为：
/// - 手势（点空白 / 双击 / 长按 / 滑动）经 [SrsCardGestureRegion]，取词经 [SrsNativeLookupRegion]
///   （注音段按 `<rt>` 读音取词，不推断读音），文字可拖选（复习时编辑上报选区）；
/// - `[sound:]` 按钮交给复习页的播放序列（与底栏重播 / 自动播放同一路）；
/// - 图片点按全屏查看；`fushi://` 来源链接跳回原处，http(s) 外链系统浏览器打开；
/// - 「跟随设计系统」样式覆盖（[SrsCardAppearance.designSkin]）按 srs_card_design_skin.dart 的
///   同一判定在原生侧做：中性色换成设计系统色、有彩色保留，深色下调亮深色字 / 调暗亮色块。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart' show CardSourceLink;
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart'
    show SrsNoBaseline, showSrsCardImageViewer, srsCardImageWidget;
import 'package:fushi/src/srs/srs_card_appearance.dart'
    show SrsCardAppearance, kSrsCardDefaultFontZh;
import 'package:fushi/src/srs/srs_card_design_skin.dart'
    show srsCardDesignSkinFont;
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_html_card.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart'
    show srsCardAppearanceProvider, srsMediaStoreProvider, srsRunLogged;
import 'package:fushi/src/srs/srs_review_edit.dart' show SrsCardSelection;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/dictionary_external_link.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 原生画一面非 Fushi 卡片。
class SrsHtmlCardView extends ConsumerStatefulWidget {
  const SrsHtmlCardView({
    super.key,
    required this.face,
    required this.source,
    this.topInset = 0,
    this.bottomInset,
    this.zoom = 1,
  });

  /// 这面卡（cardId / 正反面 / 宿主回调；[SrsCardFace.hostCss] 是卡面图片大小样式）。
  final SrsCardFace face;

  /// 这面卡解析好的 DOM 与样式表（[SrsHtmlCard.face]）。
  final SrsHtmlCardFace source;

  /// 卡面顶端被浮动页头盖住的高度：只作滚动内边距（与原生 Fushi 卡面同一口径）。
  final double topInset;

  /// 卡面底端被浮动底栏盖住的高度：只作滚动内边距。null = 0。
  final ValueListenable<double>? bottomInset;

  /// 卡面缩放（复习页 Ctrl + 滚轮 / 捏合）：所有长度与字号一起乘，与 WebView 页面缩放同效。
  final double zoom;

  @override
  ConsumerState<SrsHtmlCardView> createState() => _SrsHtmlCardViewState();
}

class _SrsHtmlCardViewState extends ConsumerState<SrsHtmlCardView> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _selectionFocus = FocusNode(
    debugLabel: 'srs-html-selection',
    skipTraversal: true,
  );
  final GlobalKey<SrsNativeLookupRegionState> _lookupRegion =
      GlobalKey<SrsNativeLookupRegionState>(debugLabel: 'srs-html-lookup');

  bool get _tapTookLookup => _lookupRegion.currentState?.tookTap ?? false;

  double get _bottomInset => widget.bottomInset?.value ?? 0;

  void _onBottomInset() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.bottomInset?.addListener(_onBottomInset);
  }

  @override
  void didUpdateWidget(SrsHtmlCardView old) {
    super.didUpdateWidget(old);
    if (old.bottomInset != widget.bottomInset) {
      old.bottomInset?.removeListener(_onBottomInset);
      widget.bottomInset?.addListener(_onBottomInset);
    }
    if (old.face.cardId != widget.face.cardId ||
        old.face.showingAnswer != widget.face.showingAnswer) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    widget.bottomInset?.removeListener(_onBottomInset);
    _scroll.dispose();
    _selectionFocus.dispose();
    super.dispose();
  }

  Future<void> _play(String name) async {
    final void Function(List<String>)? host = widget.face.onPlayAudio;
    if (host != null) {
      host(<String>[name]);
      return;
    }
    SrsMediaStore? store;
    try {
      store = await ref.read(srsMediaStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsHtmlCardView.mediaStore', e, stack);
    }
    final File? file = store?.resolve(name);
    if (file == null || !await file.exists()) {
      FushiToast.show(msg: t.srs_media_missing(name: name));
      return;
    }
    await ref.read(srsSoundPlayerProvider)(file.path);
  }

  void _openLink(String href) {
    final String h = href.trim();
    if (h.toLowerCase().startsWith('fushi:')) {
      final CardSourceLink? link = CardSourceLink.tryParse(h);
      if (link != null) widget.face.onSourceLink?.call(link);
      return;
    }
    final String scheme = Uri.tryParse(h)?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      unawaited(openDictionaryExternalLink(h));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final SrsCardAppearance appearance = ref.watch(srsCardAppearanceProvider);
    final SrsMediaStore? store = ref.watch(srsMediaStoreProvider).valueOrNull;
    final SrsHtmlBlock root = widget.source.layout(
      dark: dark,
      foreground: scheme.onSurface.toARGB32(),
      hostCss: widget.face.hostCss,
    );
    final SrsCardTokens tokens = SrsCardTokens.of(context);
    final String? lang = widget.source.languageCode ?? widget.face.languageCode;
    final _Skin skin = _Skin(
      on: appearance.designSkin,
      dark: dark,
      scheme: scheme,
      tokens: tokens,
      body: root.style,
      languageCode: lang,
    );
    final int pageBg = skin.on
        ? scheme.surface.toARGB32()
        : root.style.background;
    return SrsCardGestureRegion(
      onGesture: widget.face.onCardGesture,
      arming: widget.face.gestureArming,
      tapTookLookup: () => _tapTookLookup,
      scrollController: _scroll,
      child: SrsNativeLookupRegion(
        key: _lookupRegion,
        child: LayoutBuilder(
          // 卡片 CSS 给 body 的底色铺满整个卡面（浏览器把 body 底色传给画布），不只内容高度。
          builder: (BuildContext context, BoxConstraints c) => SizedBox(
            width: c.maxWidth.isFinite ? c.maxWidth : null,
            height: c.maxHeight.isFinite ? c.maxHeight : null,
            child: ColoredBox(
              color: Color(pageBg),
              child: _content(root, store, skin, lang, c),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    SrsHtmlBlock root,
    SrsMediaStore? store,
    _Skin skin,
    String? lang,
    BoxConstraints c,
  ) {
    final double viewportH = c.maxHeight.isFinite
        ? math.max(0, c.maxHeight - widget.topInset - _bottomInset)
        : 800;
    final _Painter painter = _Painter(
      zoom: widget.zoom,
      viewportW: c.maxWidth,
      viewportH: viewportH,
      skin: skin,
      store: store,
      families: contentFontFamilies(
        languageTag: lang,
        platform: defaultTargetPlatform,
        fallbackWhenUnknown: true,
      ),
      locale: lang == null || lang.isEmpty ? null : Locale(lang),
      onPlay: (String name) =>
          srsRunLogged('SrsHtmlCardView.play', () => _play(name)),
      onLink: _openLink,
      cardKey: '${widget.face.cardId}-${widget.face.showingAnswer}',
    );
    return FushiEntranceScope(
      replayKey: painter.cardKey,
      child: SingleChildScrollView(
        key: const ValueKey<String>('srs-html-card-scroll'),
        controller: _scroll,
        padding: EdgeInsets.only(top: widget.topInset, bottom: _bottomInset),
        child: _selectable(painter.block(root, c.maxWidth, root: true)),
      ),
    );
  }

  Widget _selectable(Widget child) => SelectionArea(
    focusNode: _selectionFocus,
    onSelectionChanged: widget.face.onEditSelection == null
        ? null
        : (SelectedContent? content) {
            final String text = content?.plainText ?? '';
            if (text.trim().isEmpty) return;
            widget.face.onEditSelection!(SrsCardSelection(text));
          },
    child: child,
  );
}

// ---------------------------------------------------------------- 设计系统覆盖

/// 「跟随设计系统」样式覆盖的原生版（判定与 srs_card_design_skin.dart 的页内脚本同一套）。
class _Skin {
  _Skin({
    required this.on,
    required this.dark,
    required this.scheme,
    required this.tokens,
    required SrsHtmlStyle body,
    required String? languageCode,
  }) : _cardBg = body.background,
       _cardFg = body.color,
       _cardFonts = body.fontFamilies,
       _font = srsCssFontFamilies(
         (languageCode ?? '').toLowerCase().startsWith('zh')
             ? 'system-ui, $kSrsCardDefaultFontZh'
             : srsCardDesignSkinFont(apple: tokens.apple),
       );

  final bool on;
  final bool dark;
  final ColorScheme scheme;
  final SrsCardTokens tokens;
  final int _cardBg;
  final int _cardFg;
  final List<String> _cardFonts;
  final List<String> _font;

  static int _r(int c) => (c >> 16) & 0xFF;
  static int _g(int c) => (c >> 8) & 0xFF;
  static int _b(int c) => c & 0xFF;
  static double _a(int c) => ((c >> 24) & 0xFF) / 255;

  static bool _neutral(int c) =>
      (math.max(_r(c), math.max(_g(c), _b(c))) -
              math.min(_r(c), math.min(_g(c), _b(c)))) /
          255 <
      0.12;

  static double _light(int c) =>
      (math.max(_r(c), math.max(_g(c), _b(c))) +
          math.min(_r(c), math.min(_g(c), _b(c)))) /
      510;

  static double _lum(int c) {
    double ch(int v) {
      final double x = v / 255;
      return x <= 0.03928
          ? x / 12.92
          : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * ch(_r(c)) + 0.7152 * ch(_g(c)) + 0.0722 * ch(_b(c));
  }

  static bool _same(int a, int b) =>
      (_r(a) - _r(b)).abs() + (_g(a) - _g(b)).abs() + (_b(a) - _b(b)).abs() <=
      12;

  /// 调到给定亮度（保留色相，饱和度封顶 0.7），透明度不变。
  static int _tone(int c, double lightness) {
    final HSLColor hsl = HSLColor.fromColor(Color(c));
    return HSLColor.fromAHSL(
      _a(c),
      hsl.hue,
      math.min(hsl.saturation, 0.7),
      lightness,
    ).toColor().toARGB32();
  }

  /// 文字颜色。[link] = 在 `<a href>` 里。
  int text(SrsHtmlStyle s, {bool link = false}) {
    if (!on) return s.color;
    if (link) return scheme.primary.toARGB32();
    final int c = s.color;
    if (_a(c) < 0.3) return c;
    if (_neutral(c)) {
      // 判定时覆盖层失效：body 的颜色是主题前景色（与页内脚本量到的一致）。
      final double lc = _light(c);
      final double lf = _light(_cardFg);
      final double lb = _light(_cardBg);
      final bool between = (lc - lf) * (lc - lb) < 0 && (lc - lf).abs() > 0.2;
      return (between ? scheme.onSurfaceVariant : scheme.onSurface).toARGB32();
    }
    if (dark && _lum(c) < 0.18) return _tone(c, 0.78);
    return c;
  }

  /// 块 / 行内盒子的底色（0 = 不画）。
  int background(int bg) {
    if (!on || bg == 0 || _a(bg) < 0.35) return bg;
    if (_same(bg, _cardBg) && _a(_cardBg) >= 0.35) return 0;
    if (_neutral(bg)) return tokens.surface1(scheme).toARGB32();
    if (dark && _lum(bg) > 0.45) return _tone(bg, 0.24);
    return bg;
  }

  /// 底色是中性面板（换设计系统圆角）。
  bool panel(int bg) =>
      on &&
      bg != 0 &&
      _a(bg) >= 0.35 &&
      !(_same(bg, _cardBg) && _a(_cardBg) >= 0.35) &&
      _neutral(bg);

  /// 有几条可见描边（有彩色描边 = -1，整体不换）。
  int _borderSides(SrsHtmlStyle s) {
    int n = 0;
    for (final SrsHtmlBorder b in s.border) {
      if (b.width <= 0 || _a(b.color) < 0.2) continue;
      if (!_neutral(b.color)) return -1;
      n++;
    }
    return n;
  }

  /// 描边颜色（中性描边换 outlineVariant）。
  int border(SrsHtmlStyle s, SrsHtmlBorder b, {bool hr = false}) {
    if (!on) return b.color;
    if (hr || _borderSides(s) > 0) return scheme.outlineVariant.toARGB32();
    return b.color;
  }

  /// 是否当成「块」（中性面板或四边中性描边）：圆角换设计系统形状、去阴影。
  bool boxLike(SrsHtmlStyle s) =>
      on && (panel(s.background) || _borderSides(s) == 4);

  /// 字族：与卡面同字族（模板没单独设）的换设计系统字体链。
  List<String> fonts(SrsHtmlStyle s) {
    if (!on) return s.fontFamilies;
    if (identical(s.fontFamilies, _cardFonts) ||
        _listEquals(s.fontFamilies, _cardFonts)) {
      return _font;
    }
    return s.fontFamilies;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------- 绘制

/// 一次 build 的绘制上下文：把盒子树转成 widget。
class _Painter {
  _Painter({
    required this.zoom,
    required this.viewportW,
    required this.viewportH,
    required this.skin,
    required this.store,
    required this.families,
    required this.locale,
    required this.onPlay,
    required this.onLink,
    required this.cardKey,
  });

  final double zoom;
  final double viewportW;
  final double viewportH;
  final _Skin skin;
  final SrsMediaStore? store;

  /// 内容语言的受控字体回落链（接在模板字族之后）。
  final List<String> families;
  final Locale? locale;
  final void Function(String name) onPlay;
  final void Function(String href) onLink;

  /// 这一面卡的标识：`<details>` 的展开状态按它复位。
  final String cardKey;

  int _detailsIndex = 0;

  double _len(SrsCssLength? l, double container) {
    if (l == null) return 0;
    final double v = l.resolve(
      container: container,
      viewportW: viewportW,
      viewportH: viewportH,
    );
    return l.unit == SrsCssUnit.px ? v * zoom : v;
  }

  EdgeInsets _edges(List<SrsCssLength> e, double cw) => EdgeInsets.fromLTRB(
    _len(e[3], cw),
    _len(e[0], cw),
    _len(e[1], cw),
    _len(e[2], cw),
  );

  /// 子节点的竖直外边距（块级子节点之间按相邻外边距折叠取大）。
  (double, double) _vMargins(SrsHtmlNode n, double cw) => switch (n) {
    SrsHtmlBlock(:final SrsHtmlStyle style) => (
      _len(style.margin[0], cw),
      _len(style.margin[2], cw),
    ),
    SrsHtmlFlow() => (0, 0),
  };

  TextStyle textStyle(SrsHtmlStyle s, {int background = 0, bool link = false}) {
    final List<String> own = skin.fonts(s);
    final List<String> chain = <String>[
      ...own,
      for (final String f in families)
        if (!own.contains(f)) f,
    ];
    final int color = skin.text(s, link: link);
    final int bg = skin.background(background);
    final List<TextDecoration> deco = <TextDecoration>[
      if (s.underline) TextDecoration.underline,
      if (s.lineThrough) TextDecoration.lineThrough,
      if (s.overline) TextDecoration.overline,
    ];
    return TextStyle(
      color: Color(color),
      fontSize: s.fontSize * zoom,
      fontWeight:
          FontWeight.values[((s.fontWeight / 100).round().clamp(1, 9)) - 1],
      fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
      fontFamily: chain.firstOrNull,
      fontFamilyFallback: chain.length > 1 ? chain.sublist(1) : null,
      height: s.lineHeight,
      letterSpacing: s.letterSpacing == 0 ? null : s.letterSpacing * zoom,
      decoration: deco.isEmpty ? null : TextDecoration.combine(deco),
      decorationColor: Color(color),
      backgroundColor: bg == 0 ? null : Color(bg),
      locale: locale,
    );
  }

  TextAlign textAlign(SrsHtmlTextAlign a) => switch (a) {
    SrsHtmlTextAlign.start => TextAlign.start,
    SrsHtmlTextAlign.left => TextAlign.left,
    SrsHtmlTextAlign.right => TextAlign.right,
    SrsHtmlTextAlign.center => TextAlign.center,
    SrsHtmlTextAlign.justify => TextAlign.justify,
  };

  /// 一个块级盒子。[cw] 是容器内容宽；[shrink] = 按内容收缩（flex 项、行内盒子）。
  Widget block(
    SrsHtmlBlock b,
    double cw, {
    bool shrink = false,
    bool root = false,
  }) {
    final SrsHtmlStyle s = b.style;
    final SrsCssLength? ml = s.margin[3];
    final SrsCssLength? mr = s.margin[1];
    final double marginL = _len(ml, cw);
    final double marginR = _len(mr, cw);
    final EdgeInsets pad = _edges(s.padding, cw);
    final bool hr = b.tag == 'hr';
    final List<double> bw = <double>[
      for (final SrsHtmlBorder x in s.border) x.width * zoom,
    ];
    final double avail = math.max(0, cw - marginL - marginR);
    final double? maxW = s.maxWidth == null ? null : _len(s.maxWidth, cw);
    double? width = s.width == null ? null : _len(s.width, cw);
    if (width != null && maxW != null) width = math.min(width, maxW);
    final double outer = width ?? math.min(avail, maxW ?? double.infinity);
    final double inner = math.max(0, outer - pad.horizontal - bw[1] - bw[3]);
    final bool fit = s.fitContent || shrink;

    Widget content;
    if (b.isDetails) {
      content = _DetailsView(
        key: ValueKey<String>('$cardKey-details-${_detailsIndex++}'),
        initiallyOpen: b.detailsOpen,
        summary: _column(b.summary!.children, inner, b.summary!.style, fit),
        summaryStyle: textStyle(b.summary!.style),
        summaryAlign: switch (b.summary!.style.textAlign) {
          SrsHtmlTextAlign.center => Alignment.center,
          SrsHtmlTextAlign.right => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        body: _column(b.children, inner, s, fit),
      );
    } else if (s.display == SrsHtmlDisplay.flex ||
        s.display == SrsHtmlDisplay.inlineFlex) {
      content = _flex(b, inner);
    } else {
      content = _column(b.children, inner, s, fit);
    }
    if (b.marker != null) {
      // 列表标记画在内容左侧（落在列表的左内边距里，同浏览器的 outside 标记）。
      content = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          content,
          Positioned(
            left: -40 * zoom,
            width: 40 * zoom,
            top: 0,
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(right: 6 * zoom),
                child: Text(
                  b.marker!,
                  style: textStyle(s),
                  textScaler: TextScaler.noScaling,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 盒子本身：底色 / 描边 / 圆角（body 的底色由页面铺满，不在这里画）。
    final int bg = root ? 0 : skin.background(s.background);
    final bool boxLike = !root && skin.boxLike(s);
    final double radius = boxLike
        ? (fit || width != null || (maxW != null && maxW < viewportW * 0.6)
              ? skin.tokens.radiusSmall
              : skin.tokens.radius)
        : s.radius * zoom;
    BorderSide side(int i) {
      final SrsHtmlBorder x = s.border[i];
      if (x.width <= 0) return BorderSide.none;
      return BorderSide(
        width: x.width * zoom,
        color: Color(skin.border(s, x, hr: hr)),
      );
    }

    final bool hasBorder = s.hasBorder;
    final bool uniform =
        hasBorder &&
        s.border.every(
          (SrsHtmlBorder x) =>
              x.width == s.border[0].width && x.color == s.border[0].color,
        );
    Widget box = Container(
      padding: pad,
      decoration: bg == 0 && !hasBorder
          ? null
          : BoxDecoration(
              color: bg == 0 ? null : Color(bg),
              border: hasBorder
                  ? Border(
                      top: side(0),
                      right: side(1),
                      bottom: side(2),
                      left: side(3),
                    )
                  : null,
              // 不同色 / 不同宽的边框不能带圆角（Flutter 限制）：只有统一边框或无边框时给。
              borderRadius: radius > 0 && (!hasBorder || uniform)
                  ? BorderRadius.circular(radius)
                  : null,
            ),
      child: content,
    );
    if (s.minHeight != null) {
      box = ConstrainedBox(
        constraints: BoxConstraints(minHeight: _len(s.minHeight, cw)),
        child: box,
      );
    }
    if (fit) box = IntrinsicWidth(child: box);
    if (width != null) {
      box = SizedBox(width: width, child: box);
    } else if (maxW != null) {
      box = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: box,
      );
    }
    if (!shrink && (fit || width != null || maxW != null)) {
      // 窄于容器的块按 margin auto 定位（两边 auto = 居中）。
      final Alignment a = ml == null && mr == null
          ? Alignment.topCenter
          : ml == null
          ? Alignment.topRight
          : Alignment.topLeft;
      box = Align(alignment: a, child: box);
    }
    if (marginL > 0 || marginR > 0) {
      box = Padding(
        padding: EdgeInsets.only(left: marginL, right: marginR),
        child: box,
      );
    }
    if (s.hidden) {
      box = Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: box,
      );
    } else if (s.opacity < 1) {
      box = Opacity(opacity: s.opacity, child: box);
    }
    return box;
  }

  /// 普通块的子节点：纵向排列，相邻块的竖直外边距折叠取大。
  Widget _column(
    List<SrsHtmlNode> children,
    double cw,
    SrsHtmlStyle s,
    bool shrink,
  ) {
    if (children.isEmpty) return const SizedBox.shrink();
    final List<Widget> out = <Widget>[];
    double prevBottom = 0;
    for (int i = 0; i < children.length; i++) {
      final SrsHtmlNode n = children[i];
      final (double top, double bottom) = _vMargins(n, cw);
      final double gap = i == 0 ? top : math.max(prevBottom, top);
      if (gap > 0) out.add(SizedBox(height: gap));
      final Widget w = _node(n, cw);
      out.add(i < 12 ? FushiStaggeredEntrance(index: i, child: w) : w);
      prevBottom = bottom;
    }
    if (prevBottom > 0) out.add(SizedBox(height: prevBottom));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
    );
  }

  Widget _node(SrsHtmlNode n, double cw, {bool shrink = false}) => switch (n) {
    SrsHtmlBlock() => block(n, cw, shrink: shrink),
    SrsHtmlFlow() => _FlowView(painter: this, flow: n, width: cw),
  };

  Widget _flex(SrsHtmlBlock b, double cw) {
    final SrsHtmlStyle s = b.style;
    final double rowGap = s.rowGap * zoom;
    final double colGap = s.columnGap * zoom;
    final List<SrsHtmlNode> items = b.children;
    MainAxisAlignment main() => switch (s.justify) {
      'center' => MainAxisAlignment.center,
      'flex-end' || 'end' || 'right' => MainAxisAlignment.end,
      'space-between' => MainAxisAlignment.spaceBetween,
      'space-around' => MainAxisAlignment.spaceAround,
      'space-evenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    };
    CrossAxisAlignment cross({required bool column}) => switch (s.alignItems) {
      'center' => CrossAxisAlignment.center,
      'flex-end' || 'end' => CrossAxisAlignment.end,
      'baseline' when !column => CrossAxisAlignment.baseline,
      'normal' || 'stretch' when column => CrossAxisAlignment.stretch,
      _ => CrossAxisAlignment.start,
    };
    if (s.flexColumn) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: main(),
        crossAxisAlignment: cross(column: true),
        children: <Widget>[
          for (int i = 0; i < items.length; i++) ...<Widget>[
            if (i > 0 && rowGap > 0) SizedBox(height: rowGap),
            _node(
              items[i],
              cw,
              shrink: s.alignItems != 'stretch' && s.alignItems != 'normal',
            ),
          ],
        ],
      );
    }
    if (s.flexWrap) {
      return Wrap(
        spacing: colGap,
        runSpacing: rowGap,
        alignment: switch (s.justify) {
          'center' => WrapAlignment.center,
          'flex-end' || 'end' || 'right' => WrapAlignment.end,
          'space-between' => WrapAlignment.spaceBetween,
          'space-around' => WrapAlignment.spaceAround,
          'space-evenly' => WrapAlignment.spaceEvenly,
          _ => WrapAlignment.start,
        },
        crossAxisAlignment: switch (s.alignItems) {
          'center' => WrapCrossAlignment.center,
          'flex-end' || 'end' => WrapCrossAlignment.end,
          _ => WrapCrossAlignment.start,
        },
        children: <Widget>[
          for (final SrsHtmlNode n in items) _node(n, cw, shrink: true),
        ],
      );
    }
    double grow(SrsHtmlNode n) => n is SrsHtmlBlock ? n.style.flexGrow : 0;
    // 有伸展项时，不伸展的项按内容宽占位（CSS 的 flex 项不会被压到比内容还窄，伸展项吃掉
    // 剩余空间）；没有伸展项时各项可收缩（长文字换行）。
    final bool anyGrow = items.any((SrsHtmlNode n) => grow(n) > 0);
    return Row(
      mainAxisAlignment: main(),
      crossAxisAlignment: cross(column: false),
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        for (int i = 0; i < items.length; i++) ...<Widget>[
          if (i > 0 && colGap > 0) SizedBox(width: colGap),
          if (grow(items[i]) > 0)
            Expanded(
              flex: math.max(1, (grow(items[i]) * 100).round()),
              child: _node(items[i], cw),
            )
          else if (anyGrow)
            _node(items[i], cw, shrink: true)
          else
            Flexible(child: _node(items[i], cw, shrink: true)),
        ],
      ],
    );
  }

  Widget image(SrsHtmlImageRun r, double cw, BuildContext context) {
    final SrsHtmlStyle s = r.style;
    final Widget? picture = srsCardImageWidget(
      r.src,
      store,
      fit: BoxFit.contain,
    );
    if (picture == null) return const SizedBox.shrink();
    final double? width = s.width == null ? null : _len(s.width, cw);
    final double? height = s.height == null ? null : _len(s.height, cw);
    final double maxW = math.min(
      cw,
      s.maxWidth == null ? double.infinity : _len(s.maxWidth, cw),
    );
    final double maxH = s.maxHeight == null
        ? double.infinity
        : _len(s.maxHeight, cw);
    Widget w = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: width != null || height != null
          ? SizedBox(width: width, height: height, child: picture)
          : picture,
    );
    if (s.radius > 0) {
      w = ClipRRect(
        borderRadius: BorderRadius.circular(s.radius * zoom),
        child: w,
      );
    }
    if (r.href != null) {
      return GestureDetector(onTap: () => onLink(r.href!), child: w);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: () {
          final Widget? full = srsCardImageWidget(r.src, store);
          if (full != null) unawaited(showSrsCardImageViewer(context, full));
        },
        child: w,
      ),
    );
  }

  /// `[sound:]` 播放键：与 WebView 卡面的 `.fushi-srs-sound` 同尺寸（32px 圆、左右 4px），
  /// 强调色底。
  Widget sound(SrsHtmlSoundRun r, ColorScheme scheme) => Padding(
    padding: EdgeInsets.symmetric(horizontal: 4 * zoom),
    child: Tooltip(
      message: t.play,
      child: Semantics(
        button: true,
        label: t.play,
        child: FushiPressScale(
          child: Material(
            key: ValueKey<String>('srs-html-sound-${r.name}'),
            color: scheme.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onPlay(r.name),
              child: SizedBox.square(
                dimension: 32 * zoom,
                child: Center(
                  child: FushiIcon(
                    FushiIcons.volumeUp,
                    size: 18 * zoom,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 一段行内内容：文字 / 注音 / 图片 / 发音键 / 行内盒子拼成一个段落，标成可取词。
class _FlowView extends StatefulWidget {
  const _FlowView({
    required this.painter,
    required this.flow,
    required this.width,
  });

  final _Painter painter;
  final SrsHtmlFlow flow;
  final double width;

  @override
  State<_FlowView> createState() => _FlowViewState();
}

class _FlowViewState extends State<_FlowView> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  void _clearRecognizers() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  TapGestureRecognizer? _link(String? href) {
    if (href == null || href.isEmpty) return null;
    final TapGestureRecognizer r = TapGestureRecognizer()
      ..onTap = () => widget.painter.onLink(href);
    _recognizers.add(r);
    return r;
  }

  PlaceholderAlignment _align(SrsHtmlVerticalAlign a) => switch (a) {
    SrsHtmlVerticalAlign.middle => PlaceholderAlignment.middle,
    SrsHtmlVerticalAlign.top => PlaceholderAlignment.top,
    SrsHtmlVerticalAlign.bottom => PlaceholderAlignment.bottom,
    _ => PlaceholderAlignment.aboveBaseline,
  };

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final _Painter p = widget.painter;
    final SrsHtmlFlow flow = widget.flow;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 只有一个 <br> 的段：一行空行（浏览器同样只占一行）。
    if (flow.inlines.length == 1 && flow.inlines.single is SrsHtmlBreakRun) {
      final TextStyle ts = p.textStyle(flow.style);
      return SizedBox(
        height: (ts.fontSize ?? 16) * (flow.style.lineHeight ?? 1.2),
      );
    }
    final List<InlineSpan> spans = <InlineSpan>[];
    final StringBuffer full = StringBuffer();
    final List<SrsLookupTextSegment> segments = <SrsLookupTextSegment>[];
    final List<FushiRubySpan> rubySpans = <FushiRubySpan>[];
    int outer = 0;
    void placeholder() {
      segments.add(
        SrsLookupTextSegment(
          outerStart: outer,
          outerLength: 1,
          fullStart: full.length,
          placeholder: true,
        ),
      );
      outer += 1;
    }

    void text(String s) {
      segments.add(
        SrsLookupTextSegment(
          outerStart: outer,
          outerLength: s.length,
          fullStart: full.length,
          placeholder: false,
        ),
      );
      outer += s.length;
      full.write(s);
    }

    for (final SrsHtmlInline r in flow.inlines) {
      switch (r) {
        case SrsHtmlTextRun():
          final TextStyle ts = p.textStyle(
            r.style,
            background: r.background,
            link: r.href != null,
          );
          final SrsHtmlVerticalAlign va = r.style.verticalAlign;
          if (va == SrsHtmlVerticalAlign.sub ||
              va == SrsHtmlVerticalAlign.sup) {
            final double shift =
                (ts.fontSize ?? 16) *
                (va == SrsHtmlVerticalAlign.sub ? 0.3 : -0.45);
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Transform.translate(
                  offset: Offset(0, shift),
                  child: Text(
                    r.text,
                    style: ts,
                    textScaler: TextScaler.noScaling,
                  ),
                ),
              ),
            );
            placeholder();
            continue;
          }
          spans.add(
            TextSpan(
              text: r.text,
              style: ts,
              recognizer: _link(r.href),
              mouseCursor: r.href == null ? null : SystemMouseCursors.click,
            ),
          );
          text(r.text);
        case SrsHtmlRubyRun():
          final TextStyle base = p.textStyle(r.style, link: r.href != null);
          final TextStyle ruby = p.textStyle(r.rubyStyle, link: r.href != null);
          final int fullStart = full.length;
          if (r.reading.isNotEmpty) {
            rubySpans.add(
              FushiRubySpan(
                start: fullStart,
                end: fullStart + r.base.length,
                reading: r.reading,
              ),
            );
          }
          Widget tag(Widget child, {required bool isRuby}) => MetaData(
            metaData: SrsLookupRubySegment(
              fullStart: fullStart,
              isRuby: isRuby,
            ),
            child: child,
          );
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SrsNoBaseline(
                    child: tag(
                      Text(
                        r.reading,
                        style: ruby.copyWith(height: 1.1),
                        maxLines: 1,
                        softWrap: false,
                        textScaler: TextScaler.noScaling,
                      ),
                      isRuby: true,
                    ),
                  ),
                  tag(
                    Text(
                      r.base,
                      style: base,
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
          segments.add(
            SrsLookupTextSegment(
              outerStart: outer,
              outerLength: 1,
              fullStart: fullStart,
              placeholder: true,
            ),
          );
          outer += 1;
          full.write(r.base);
        case SrsHtmlImageRun():
          spans.add(
            WidgetSpan(
              alignment: _align(r.style.verticalAlign),
              baseline: TextBaseline.alphabetic,
              child: p.image(r, widget.width, context),
            ),
          );
          placeholder();
        case SrsHtmlSoundRun():
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: p.sound(r, scheme),
            ),
          );
          placeholder();
        case SrsHtmlBreakRun():
          spans.add(const TextSpan(text: '\n'));
          text('\n');
        case SrsHtmlBoxRun():
          spans.add(
            WidgetSpan(
              alignment:
                  r.box.style.verticalAlign == SrsHtmlVerticalAlign.baseline
                  ? PlaceholderAlignment.middle
                  : _align(r.box.style.verticalAlign),
              child: p.block(r.box, widget.width, shrink: true),
            ),
          );
          placeholder();
      }
    }
    final SrsHtmlStyle s = flow.style;
    final Widget paragraph = Text.rich(
      TextSpan(children: spans),
      textAlign: p.textAlign(s.textAlign),
      style: p.textStyle(s),
      softWrap:
          s.whiteSpace != SrsHtmlWhiteSpace.nowrap &&
          s.whiteSpace != SrsHtmlWhiteSpace.pre,
      textScaler: TextScaler.noScaling,
      locale: p.locale,
    );
    return MetaData(
      metaData: SrsLookupTextData(
        full.toString(),
        segments: segments,
        rubySpans: rubySpans,
      ),
      child: paragraph,
    );
  }
}

/// `<details>`：点标题展开 / 收起（换卡复位，key 带卡面标识）。
class _DetailsView extends StatefulWidget {
  const _DetailsView({
    super.key,
    required this.initiallyOpen,
    required this.summary,
    required this.summaryStyle,
    required this.summaryAlign,
    required this.body,
  });

  final bool initiallyOpen;
  final Widget summary;
  final TextStyle summaryStyle;

  /// 标题行（展开标记 + 标题）按标题的 text-align 摆放：浏览器里标记是标题行内的第一个字符，
  /// 跟着标题一起居中。
  final Alignment summaryAlign;
  final Widget body;

  @override
  State<_DetailsView> createState() => _DetailsViewState();
}

class _DetailsViewState extends State<_DetailsView> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _open,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Align(
                alignment: widget.summaryAlign,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: d,
                      child: Text(
                        '▶',
                        style: widget.summaryStyle.copyWith(
                          fontSize: (widget.summaryStyle.fontSize ?? 16) * 0.7,
                        ),
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(child: IntrinsicWidth(child: widget.summary)),
                  ],
                ),
              ),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: d,
            alignment: Alignment.topCenter,
            child: _open ? widget.body : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
