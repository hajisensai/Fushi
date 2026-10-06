import 'dart:convert';
import 'dart:ui' show Color;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_text.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

class LyricsModeHtml {
  LyricsModeHtml._();

  /// 歌词主题 → CSS 变量表 + body 开关 class（初始内联与运行期热更共用一份）。
  ///
  /// 覆盖层架构下歌词 WebView 是透明底、盖在设计系统画的背景上，配色 / 对齐 /
  /// 逐行透明度阶梯全由 [LyricsHtmlTheme] 决定（Apple = Apple Music 白字左对齐；
  /// MD3 = primary 当前行）。[textColorOverride] 是用户自定义歌词文字色（设置项
  /// `lyrics_text_color`，非 0 才传），覆盖非当前行颜色——不丢旧功能。
  /// [currentColorOverride] 是用户自定义歌词当前行高亮色（`lyrics_highlight_color`，
  /// 非 0 才传）：覆盖当前行色及其派生（逐字扫过的未读色、回到当前行胶囊）。
  /// 覆盖层主题下 `.cue.current` 只认 `--ly-current`，不经这里就没有任何用户
  /// 可控的高亮色通路（歌词模式高亮颜色无法修改的根因）。查词选区 `--ly-hl` 不变。
  static ({Map<String, String> vars, List<String> bodyClasses}) themeVars(
    LyricsHtmlTheme theme, {
    Color? textColorOverride,
    Color? currentColorOverride,
  }) {
    final Color text = textColorOverride ?? theme.textColor;
    final Color current = currentColorOverride ?? theme.currentColor;
    final List<double> ops = <double>[
      for (int i = 0; i < 4; i++)
        i < theme.contextOpacities.length
            ? theme.contextOpacities[i]
            : (theme.contextOpacities.isEmpty
                ? 1.0
                : theme.contextOpacities.last),
    ];
    final double scale = theme.deselectedScale <= 0
        ? 1.0
        : 1.0 / theme.deselectedScale;
    final double anchor = theme.anchorY.clamp(0.1, 0.9);
    final Map<String, String> vars = <String, String>{
      '--ly-text': _css(text),
      '--ly-current': _css(current),
      // 逐字扫过（Niratan 的 line progress sweep）：当前行未读部分 = 当前色 × 0.4。
      '--ly-upcoming': _css(
        current.withValues(alpha: current.a * 0.4),
      ),
      '--ly-hl': _css(theme.accentColor),
      '--ly-hl-text': _css(theme.selectionTextColor),
      '--ly-op1': ops[0].toStringAsFixed(3),
      '--ly-op2': ops[1].toStringAsFixed(3),
      '--ly-op3': ops[2].toStringAsFixed(3),
      '--ly-op4': ops[3].toStringAsFixed(3),
      '--ly-op-browse': theme.browsingOpacity.toStringAsFixed(3),
      '--ly-near1-scale': '1',
      '--cue-scale': scale.toStringAsFixed(4),
      '--ly-anchor': anchor.toStringAsFixed(3),
      '--ly-pad-top': '${(anchor * 100).toStringAsFixed(1)}vh',
      '--ly-pad-bottom': '${((1 - anchor) * 100).toStringAsFixed(1)}vh',
      '--ly-fade': '${(theme.edgeFade * 100).toStringAsFixed(1)}%',
      '--ly-align': theme.alignStart ? 'start' : 'center',
      '--ly-origin': theme.alignStart ? 'left center' : 'center',
      // 竖排（vertical-rl）的「行首」在上：靠首对齐时当前句从顶端放大，不往上溢出。
      '--ly-origin-v': theme.alignStart ? 'center top' : 'center',
      '--ly-self': theme.alignStart ? 'stretch' : 'auto',
      '--ly-ctx-blur': '${theme.contextBlurPx.toStringAsFixed(1)}px',
      '--ly-radius': '${theme.rowRadius.toStringAsFixed(1)}px',
      '--ly-hover': _css(theme.hoverFill),
      '--ly-pill-bg': _css(
        current.withValues(alpha: 0.16),
      ),
      '--ly-pill-fg': _css(current),
      '--ly-past-k': theme.pastOpacityFactor.clamp(0.0, 1.0).toStringAsFixed(3),
    };
    return (
      vars: vars,
      bodyClasses: <String>[
        'ly-themed',
        'ly-sweep',
        if (theme.edgeFade > 0) 'ly-fade',
        if (theme.contextBlurPx > 0) 'ly-ctxblur',
        if (theme.pastOpacityFactor < 1) 'ly-past-dim',
      ],
    );
  }

  /// 运行期热更主题（不重建整页）：写 CSS 变量 + 换 body 开关 class。
  static String applyThemeInvocation(
    LyricsHtmlTheme theme, {
    Color? textColorOverride,
    Color? currentColorOverride,
  }) {
    final ({Map<String, String> vars, List<String> bodyClasses}) t = themeVars(
      theme,
      textColorOverride: textColorOverride,
      currentColorOverride: currentColorOverride,
    );
    return 'window.__lyricsApplyTheme && window.__lyricsApplyTheme('
        '${jsonEncode(t.vars)}, ${jsonEncode(t.bodyClasses)});';
  }

  static String _css(Color c) {
    final int r = (c.r * 255.0).round().clamp(0, 255);
    final int g = (c.g * 255.0).round().clamp(0, 255);
    final int b = (c.b * 255.0).round().clamp(0, 255);
    return 'rgba($r,$g,$b,${c.a.toStringAsFixed(2)})';
  }

  static String generate({
    required List<AudioCue> cues,
    required int currentIndex,
    EpubBook? book,
    int loadGeneration = 0,
    required String backgroundColor,
    required String textColor,
    required String accentColor,
    required double fontSize,
    double marginTop = 0,
    double marginBottom = 0,
    double marginLeft = 0,
    double marginRight = 0,
    bool vertical = false,
    bool blur = false,
    String fontFamilyCss = '',
    String fontFaceCss = '',
    LyricsHtmlTheme? theme,
    Color? textColorOverride,
    Color? currentColorOverride,
    String followLabel = '',
  }) {
    // 覆盖层主题：内联进 :root 与 body class，首帧即是最终观感（不等热更）。
    // 无主题（旧调用 / 单测）时变量全部缺省，CSS 的 var() 回落值与改动前逐值相同。
    final ({Map<String, String> vars, List<String> bodyClasses})? themed =
        theme == null
            ? null
            : themeVars(
                theme,
                textColorOverride: textColorOverride,
                currentColorOverride: currentColorOverride,
              );
    final String themeVarsCss = themed == null
        ? ''
        : themed.vars.entries
            .map((MapEntry<String, String> e) => '${e.key}: ${e.value};')
            .join(' ');
    final StringBuffer cueHtml = StringBuffer();
    final LyricsCueTextResolver? textResolver = book == null
        ? null
        : LyricsCueTextResolver(book);
    for (int i = 0; i < cues.length; i++) {
      final LyricsCueText cueText =
          textResolver?.resolveForCue(cues[i]) ??
          LyricsCueText.plain(cues[i].text);
      final String escaped = _cueInnerHtml(cueText);
      // 无读音的纯文本：收藏标记按它比对（textContent 会把 <rt> 读音混进来）。
      final String plainText = _escapeAttr(cueText.text);
      final String fragId = _escapeAttr(cues[i].textFragmentId);
      final int dist = (i - currentIndex).abs();
      final String cls = dist == 0
          ? 'cue current'
          : dist <= 3
          ? 'cue near-$dist'
          : 'cue';
      // `.tx` 是行内包装：逐字扫过的渐变按 box-decoration-break: slice 把多行
      // 当成一条长行来铺，扫过方向因此与阅读顺序一致（换行处接续）。
      cueHtml.write(
        '<div class="$cls" data-cue-index="$i" '
        'data-text-fragment-id="$fragId" data-text="$plainText">'
        '<span class="tx">$escaped</span></div>\n',
      );
    }

    final String selectionJs = ReaderSelectionScripts.source();

    // ── TODO-907: 轴依赖样式（横排=纵滚，竖排 vertical-rl=横滚） ──
    // 把横/竖排差异收敛成三段 CSS 片段，模板里只插一次，正文逻辑不再撒分支。
    // 竖排 vertical-rl 是右起左推：主轴为列、横向滚动、纵向溢出隐藏。
    final String htmlBodyAxisCss = vertical
        ? 'writing-mode: vertical-rl; overflow-x: auto; overflow-y: hidden;'
        : 'overflow-x: hidden;';
    // flex 主轴跟随 writing-mode：vertical-rl 下 column = 块方向 = 从右往左，句子
    // 一列一句右起排开；row 是行内方向（自上而下），会把所有句子塞进一屏高里竖着
    // 叠成一摞、每句被压成几行碎块（TODO-907 初版就是这样，竖排从来没正常显示过）。
    final String containerAxisCss = vertical
        ? 'flex-direction: column; justify-content: flex-start; align-items: center;'
        : 'flex-direction: column; align-items: center;';
    // 主轴方向的「45vh/45vw 居中余量 + 用户边距」。横排=上下(vh)，竖排=左右(vw)。
    // 注意竖排 vertical-rl 视觉「先读」在右，但 padding 仍按物理 left/right 写，
    // 由 writing-mode 决定读序，无需翻 padding 值。
    final double padTop = vertical ? marginTop : 45 + marginTop;
    final double padBottom = vertical ? marginBottom : 45 + marginBottom;
    final double padLeft = vertical
        ? 45 + marginLeft
        : (marginLeft > 0 ? marginLeft : 2.5);
    final double padRight = vertical
        ? 45 + marginRight
        : (marginRight > 0 ? marginRight : 2.5);
    final String containerPaddingCss = vertical
        ? 'padding: ${padTop}vh ${padRight}vw ${padBottom}vh ${padLeft}vw;'
        // 主题的锚点（当前行落在视口 anchorY 处）决定上下余量：上 anchorY·100vh、
        // 下 (1-anchorY)·100vh；无主题时 var 回落 45vh（旧的居中余量）。
        : 'padding: calc(var(--ly-pad-top, 45vh) + ${marginTop}vh) ${marginLeft > 0 ? marginLeft : 2.5}vw '
              'calc(var(--ly-pad-bottom, 45vh) + ${marginBottom}vh) ${marginRight > 0 ? marginRight : 2.5}vw;';
    // 竖排专属的 .cue 几何，只在竖排时输出（横排文档逐字节不变）。选择器刻意不写成
    // 裸 `.cue`：__lyricsUpdateStyle 按 selectorText 逐条改写规则，裸 `.cue` 会被
    // 当成基础规则再写一遍。
    // - 宽度上限换成行内方向（竖排=高度）：长句折成多列，而不是撑出屏幕被裁掉；
    // - 句内留白 / 句间距按物理方向对调（列与列之间是左右）；
    // - 放大原点用 --ly-origin-v（靠首对齐 = 顶端），收藏星标挪到列尾（下端）。
    final String verticalCueCss = vertical
        ? '''
/* 竖排（vertical-rl）：句子是右起左排的列。 */
.lyrics-container > .cue {
  max-width: none;
  max-inline-size: calc(100% / var(--cue-scale) - 1%);
  padding: 8px 12px;
  transform-origin: var(--ly-origin-v, center);
}
body.ly-themed .lyrics-container > .cue {
  padding: 14px 10px;
  margin: 0 2px;
}
.lyrics-container > .cue.favorited::before {
  right: auto;
  top: auto;
  bottom: -2px;
  left: 50%;
  transform: translateX(-50%);
}
'''
        : '';
    // JS 端轴标记：true=竖排横滚（用 scrollBy 增量绕开 vertical-rl 负向 scrollX）。
    final String verticalJs = vertical ? 'true' : 'false';
    // TODO-908 / BUG-852：听力沉浸模糊。blur=true 时给 body 挂 `lyrics-blur` class，CSS
    // 对**所有**句（.cue）盖 8px 高斯模糊；单独 hover 或点击（.revealed）才显形。模糊
    // 维度与 writing-mode 正交——blur CSS 只作用在 cue 元素上，与轴/竖排无关。
    final List<String> bodyClasses = <String>[
      if (blur) 'lyrics-blur',
      ...?themed?.bodyClasses,
      // 竖排标记只服务主题态的扫过 / 渐隐方向；旧观感不加 class（输出与改动前一致）。
      if (vertical && themed != null) 'ly-vertical',
    ];
    final String blurBodyClass =
        bodyClasses.isEmpty ? '' : ' class="${bodyClasses.join(' ')}"';
    final String followLabelHtml = _escapeHtml(followLabel);
    // 歌词模式此前硬编码 "Noto Serif JP", "Noto Sans JP", serif：同一本书在正文视图
    // 用用户设的阅读字体、切到歌词就变回 Noto。这里接上 FontTarget.body 的
    // @font-face + family（调用方传 ReaderSettings.buildCustomFontCss()）。
    // 用户没设字体时 fontFamilyCss 为空，整条链与改动前逐字节相同。
    // 覆盖层主题（Apple Music / MD3 播放页）的歌词是粗体无衬线（Apple Music 用 SF
    // 粗体）；旧歌词页保留 Noto 衬线链。用户设了正文字体时两者都优先用户字体。
    final String lyricsFallbackFonts = theme == null
        ? '"Noto Serif JP", "Noto Sans JP", serif'
        : 'system-ui, -apple-system, "Hiragino Sans", "Yu Gothic UI", '
            '"Noto Sans JP", "Noto Sans CJK JP", sans-serif';
    final String bodyFontFamily = fontFamilyCss.isEmpty
        ? lyricsFallbackFonts
        : '$fontFamilyCss, $lyricsFallbackFonts';

    return '''
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
:root { --cue-scale: 1.15; --cue-font-size: ${fontSize}px; $themeVarsCss }
/* 逐字扫过的进度（0%–100%）。注册成 <percentage> 才能被 transition 插值；不支持
   @property 的旧内核上它不动画、直接落到 100%（整行点亮），只是少了扫过效果。 */
@property --ly-p { syntax: '<percentage>'; inherits: true; initial-value: 100%; }
html, body {
  width: 100%;
  height: 100%;
  background: $backgroundColor;
  $htmlBodyAxisCss
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: none;
  /* Themed scrollbar: transparent track shows the lyrics background, thumb
     takes the cue text colour so it matches the theme instead of the default
     grey bar. ::-webkit-scrollbar covers the classic scrollbar; the standard
     props cover overlay scrollbars on newer engines. */
  scrollbar-width: thin;
  scrollbar-color: $textColor transparent;
}
$fontFaceCss
body { font-family: $bodyFontFamily; }
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: transparent;
}
::-webkit-scrollbar-thumb {
  background-color: $textColor;
  background-clip: padding-box;
  border: 2px solid transparent;
  border-radius: 8px;
}
.lyrics-container {
  display: flex;
  $containerAxisCss
  $containerPaddingCss
  gap: 0;
}
/* 振假名：只有正文自带 ruby 的 cue 才有。选区脚本自己跳过 rt/rp（查词拿基底），
   这里不动 user-select——页面级守卫要求原生选区始终可用。 */
.cue ruby {
  /* 读音比基底宽时（艦長/かんちょう）默认 space-around 会把基底两个字撑散成
     「艦 長」；居中让基底保持紧凑、读音悬在上方。 */
  ruby-align: center;
}
.cue rt {
  font-size: 0.5em;
  line-height: 1;
}
.cue {
  position: relative;
  text-align: var(--ly-align, center);
  color: var(--ly-text, $textColor);
  align-self: var(--ly-self, auto);
  transform-origin: var(--ly-origin, center);
  border-radius: var(--ly-radius, 0);
  /* TODO-1080: per-cue font-size flows from --cue-font-size so JS can shrink one
     over-long cue via inline font-size (see __lyricsFitCues) without touching the
     shared base every other cue uses. */
  font-size: var(--cue-font-size);
  line-height: 1.7;
  padding: 12px 8px;
  max-width: calc(100% / var(--cue-scale) - 1%);
  overflow-wrap: break-word;
  word-break: break-word;
  opacity: var(--ly-op4, 0.15);
  transform: scale(1);
  transition: opacity 0.35s ease-out, transform 0.3s ease-out, color 0.3s ease-out;
  will-change: transform, opacity;
  cursor: pointer;
}
.cue.current {
  opacity: 1.0;
  transform: scale(var(--cue-scale));
  font-weight: 700;
  color: var(--ly-current, $accentColor);
}
.cue.near-1 { opacity: var(--ly-op1, 0.55); transform: scale(var(--ly-near1-scale, 1.05)); }
.cue.near-2 { opacity: var(--ly-op2, 0.35); }
.cue.near-3 { opacity: var(--ly-op3, 0.25); }
/* ── 覆盖层主题（Apple Music / MD3）──────────────────────────────────────
   整行粗体、行级圆角悬停底块；当前行弹簧放大（Niratan highlightAnimation：
   stiffness 322 / damping 24 → 轻微过冲），离开当前行用阻尼更大的收回。 */
body.ly-themed .cue {
  font-weight: 700;
  padding: 10px 14px;
  margin: 2px 0;
  transition: opacity 0.45s ease-out, transform 0.55s cubic-bezier(0.22, 1, 0.36, 1),
      color 0.3s ease-out, background-color 0.18s ease-out, filter 0.3s ease-out;
}
body.ly-themed .cue.current {
  transition: opacity 0.3s ease-out, transform 0.42s cubic-bezier(0.34, 1.36, 0.64, 1),
      color 0.3s ease-out, background-color 0.18s ease-out, filter 0.3s ease-out;
}
/* Apple Music / Niratan 不显示滚动条（scrollIndicators(.never)）。 */
body.ly-themed { scrollbar-width: none; }
body.ly-themed::-webkit-scrollbar { width: 0; height: 0; }
body.ly-browsing .cue:not(.current) { opacity: var(--ly-op-browse, 0.6); }
/* 已读句淡化（M3E）：当前句之前的行在对称阶梯上再乘 --ly-past-k，读过的退到背景、
   要读的更清楚。只认「不是当前句、也不在当前句之后」的兄弟（:not 复杂选择器，
   WebView2 / Android WebView / WKWebView 均支持）；手动浏览态让位给统一透明度。 */
body.ly-past-dim:not(.ly-browsing) .cue:not(.current):not(.current ~ .cue) {
  opacity: calc(var(--ly-op4, 0.15) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .cue.near-1:not(.current ~ .cue) {
  opacity: calc(var(--ly-op1, 0.55) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .cue.near-2:not(.current ~ .cue) {
  opacity: calc(var(--ly-op2, 0.35) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .cue.near-3:not(.current ~ .cue) {
  opacity: calc(var(--ly-op3, 0.25) * var(--ly-past-k, 1));
}
/* 系统「减弱动态效果」/ 墨水屏：行切换的放大 / 淡入淡出直接落值（滚动已由
   __lyricsReduceMotion 改为直接落位）。 */
body.ly-reduce .cue,
body.ly-reduce #ly-follow { transition: none !important; }
body.ly-ctxblur .cue:not(.current) { filter: blur(var(--ly-ctx-blur, 0px)); }
@media (hover: hover) {
  body.ly-themed .cue:hover { background-color: var(--ly-hover, transparent); }
  body.ly-themed .cue:not(.current):hover { opacity: 0.84; }
}
/* 逐字扫过：当前行按播放进度从左到右点亮（未读部分 = 当前色 × 0.4）。.tx 是行内
   元素，slice 让多行渐变按阅读顺序接续。暂停 / 查词时整行直接点亮。 */
body.ly-sweep:not(.ly-paused) .cue.current:not(.ly-nosweep) .tx {
  background-image: linear-gradient(to right, var(--ly-current) calc(var(--ly-p) - 4%),
      var(--ly-upcoming) calc(var(--ly-p) + 4%));
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  -webkit-box-decoration-break: slice;
  box-decoration-break: slice;
}
body.ly-sweep:not(.ly-paused) .cue.current:not(.ly-nosweep) .tx rt {
  -webkit-text-fill-color: var(--ly-current);
}
body.ly-sweep.ly-vertical .cue.current .tx {
  background-image: linear-gradient(to bottom, var(--ly-current) calc(var(--ly-p) - 4%),
      var(--ly-upcoming) calc(var(--ly-p) + 4%));
}
/* 上下边缘渐隐（Niratan listEdgeFadeFraction）。body 是真正的滚动元素（BUG-784），
   遮罩挂在它的盒上、不随内容滚动。 */
body.ly-fade {
  -webkit-mask-image: linear-gradient(to bottom, transparent 0, #000 var(--ly-fade),
      #000 calc(100% - var(--ly-fade)), transparent 100%);
  mask-image: linear-gradient(to bottom, transparent 0, #000 var(--ly-fade),
      #000 calc(100% - var(--ly-fade)), transparent 100%);
}
body.ly-fade.ly-vertical {
  -webkit-mask-image: linear-gradient(to left, transparent 0, #000 var(--ly-fade),
      #000 calc(100% - var(--ly-fade)), transparent 100%);
  mask-image: linear-gradient(to left, transparent 0, #000 var(--ly-fade),
      #000 calc(100% - var(--ly-fade)), transparent 100%);
}
/* 手动滚动脱离跟随后的「回到当前行」胶囊（Niratan followPlaybackButton）。 */
#ly-follow {
  position: fixed;
  left: 50%;
  bottom: 22px;
  writing-mode: horizontal-tb;
  transform: translate(-50%, 14px);
  opacity: 0;
  pointer-events: none;
  border: none;
  border-radius: 999px;
  padding: 9px 16px;
  font: 600 14px system-ui, -apple-system, "Segoe UI", sans-serif;
  color: var(--ly-pill-fg, $textColor);
  background: var(--ly-pill-bg, rgba(127,127,127,0.2));
  -webkit-backdrop-filter: blur(20px) saturate(1.6);
  backdrop-filter: blur(20px) saturate(1.6);
  transition: opacity 0.24s ease-out, transform 0.3s cubic-bezier(0.22, 1, 0.36, 1);
  cursor: pointer;
  z-index: 10;
}
body.ly-browsing #ly-follow {
  opacity: 1;
  transform: translate(-50%, 0);
  pointer-events: auto;
}
/* TODO-908 / BUG-852: 听力沉浸模糊 —— body.lyrics-blur 时对**所有**句（.cue，含
   当前句与前后文 near-*）盖 8px 高斯模糊；单独 hover 或点击（.revealed）才显形。
   之前只盖 .cue.current，前后文照样能读、可预读，沉浸失效——听力模糊的语义是整篇
   不可预读，必须盖全部 cue。与视频字幕的 ImageFilter.blur(sigma:8) 等价。仅作用
   .cue（与 writing-mode 正交，不碰 TODO-907 轴 CSS）。 */
body.lyrics-blur .cue {
  filter: blur(8px);
  transition: filter 0.2s ease-out, opacity 0.35s ease-out,
      transform 0.3s ease-out, color 0.3s ease-out;
}
body.lyrics-blur .cue:hover,
body.lyrics-blur .cue.revealed {
  filter: blur(0);
}
::highlight(fushi-selection) {
  background-color: var(--ly-hl, $accentColor);
  color: var(--ly-hl-text, $backgroundColor);
}
.fushi-dict-highlight {
  background-color: var(--ly-hl, $accentColor) !important;
  color: inherit;
  border-radius: 2px;
}
.cue.current .fushi-dict-highlight {
  color: var(--ly-hl-text, $backgroundColor);
}
.cue.favorited::before {
  content: '\\2605';
  position: absolute;
  right: -2px;
  top: 50%;
  transform: translateY(-50%);
  font-size: 0.5em;
  opacity: 0.6;
}
$verticalCueCss</style>
</head>
<body$blurBodyClass>
<div class="lyrics-container" id="lc">
$cueHtml
</div>
<button id="ly-follow" type="button" tabindex="-1">&#8634;&nbsp;$followLabelHtml</button>
<script>
$selectionJs

// ── 滚动动画 ──
// TODO-907: 横/竖排统一走「getBoundingClientRect 相对视口中线的 delta + 增量
// scrollBy」。delta 是轴无关的相对量，竖排 vertical-rl 的 scrollX 是负向坐标，
// 用相对 delta 增量滚动绕开 RTL 绝对坐标符号坑（参考正文横排亚像素累积教训）。
var __lyricsVertical = $verticalJs;
var _animId = 0;
// 返回元素中心相对视口中线的偏移（沿当前滚动轴）：>0 表示需正向 scrollBy。
// 当前行对齐到视口的哪个比例处：主题的 --ly-anchor（Apple 0.46 / MD3 0.42），无主题 0.5。
// 对齐口径同 SwiftUI scrollTo(anchor:)：元素自身 a 处对齐视口 a 处。
var _lyAnchor = 0.5;
function _lyReadAnchor() {
  var v = parseFloat(getComputedStyle(document.documentElement)
      .getPropertyValue('--ly-anchor'));
  _lyAnchor = (isFinite(v) && v > 0 && v < 1) ? v : 0.5;
}
_lyReadAnchor();
// 纯函数（无 DOM / 无全局读）：给定元素的视口矩形，求沿滚动轴还需滚多少才让它落到
// 锚点。结果只用作「scrollLeft/scrollTop += delta」的增量，从不换算成绝对坐标：
// vertical-rl 的 scrollLeft 在 WebView2 / Android WebView（Chromium 85+）与
// WKWebView 上都是「起点 0、往左为负」，老 Chromium WebView（<85）是「起点 max、
// 往左变小」；两种约定下 scrollLeft 变大都等于视口右移，所以增量写法不分平台、
// 不必探测约定（与正文竖排 scrollBy({left}) 同一口径）。
function __lyricsCenterDeltaFor(rect, viewW, viewH, vertical, anchor) {
  if (vertical) return (rect.left + rect.width / 2) - viewW / 2;
  return (rect.top + rect.height * anchor) - viewH * anchor;
}
function _lyricsCenterDelta(el) {
  return __lyricsCenterDeltaFor(el.getBoundingClientRect(), window.innerWidth,
      window.innerHeight, __lyricsVertical, _lyAnchor);
}
// BUG-784: `html, body { height:100%; overflow-x:hidden }` —— 按 CSS 规范，overflow-x
// 非 visible 会把 overflow-y 从 visible **计算成 auto**，于是 body 恰好填满 html、真正
// 溢出滚动的是 **body**，而 `window.scrollBy` 作用于 `document.scrollingElement`(=html，
// body 等高无溢出) → **空转 no-op**：当前句高亮会更新，但页面永不跟随滚动、初始也不居中
// （用户手动滚滚的正是 body 故有效）——即「歌词高亮变但不跟随滚动」。这里改成动态选真正
// 有溢出的滚动元素再滚，横竖排一致；`_lyricsCenterDelta` 用 getBoundingClientRect（视口相对）
// 不受影响。
function _lyricsScrollTarget() {
  var b = document.body, h = document.documentElement;
  if (__lyricsVertical) {
    if (b && b.scrollWidth > b.clientWidth + 1) return b;
    if (h && h.scrollWidth > h.clientWidth + 1) return h;
  } else {
    if (b && b.scrollHeight > b.clientHeight + 1) return b;
    if (h && h.scrollHeight > h.clientHeight + 1) return h;
  }
  return b || h;
}
// 程序化滚动的「免判」窗口：滚动事件晚于 scrollTop 赋值异步到达，窗口内的 scroll
// 不算用户手动滚（否则自动跟随会把自己判成「用户滚走了」）。
var _lyProgUntil = 0;
function _lyricsScrollByAxis(d) {
  var s = _lyricsScrollTarget();
  _lyProgUntil = performance.now() + 150;
  if (__lyricsVertical) s.scrollLeft += d;
  else s.scrollTop += d;
}
// 行切换滚动：弹簧（Niratan lineChangeAnimation：mass 1 / stiffness 100 / damping 18，
// ζ≈0.9 轻微欠阻尼），按帧半隐式积分，跨帧时长被钳住防卡顿后一步飞过头。相距很远
// （>3 屏，例如拖进度 / 跳章）直接落位，不做长距离动画。
// force=true（显式回中：跟随开关 snap / 焦点 caret / 点「回到当前行」）无视手动浏览态。
function scrollToCenter(el, duration, force) {
  if (!el) return;
  if (_lyBrowsing && !force) return;
  _animId++;
  var myId = _animId;
  var diff = _lyricsCenterDelta(el);
  if (Math.abs(diff) < 1) return;
  var extent = __lyricsVertical ? window.innerWidth : window.innerHeight;
  if (Math.abs(diff) > extent * 3 || window.__lyricsReduceMotion) {
    _lyricsScrollByAxis(diff);
    return;
  }
  var x = 0, v = 0, last = performance.now();
  var K = 100, C = 18;
  function step(now) {
    if (myId !== _animId) return;
    var dt = Math.min(0.034, Math.max(0.001, (now - last) / 1000));
    last = now;
    // 两个子步，60Hz 下也足够稳定。
    for (var i = 0; i < 2; i++) {
      var h = dt / 2;
      v += (-K * (x - diff) - C * v) * h;
      x += v * h;
    }
    var applied = x;
    if (Math.abs(diff - x) < 0.5 && Math.abs(v) < 4) applied = diff;
    _lyricsScrollByAxis(applied - (step.done || 0));
    step.done = applied;
    if (applied !== diff) requestAnimationFrame(step);
  }
  step.done = 0;
  requestAnimationFrame(step);
}

// ── 手动滚动脱离跟随（Niratan isFollowingPlayback）──
// 用户滚动 / 拖动歌词时停止自动跟随，统一降透明度并露出「回到当前行」；播放中静置
// 4 秒自动回到当前行（manualScrollFollowResumeDelay），暂停时一直停在用户位置。
// 只在覆盖层主题下启用；旧观感无此状态。
var _lyBrowsing = false, _lyResumeTimer = 0, _lyPlaying = false;
function _lyThemed() { return document.body.classList.contains('ly-themed'); }
function _lyScheduleResume() {
  clearTimeout(_lyResumeTimer);
  if (!_lyPlaying || !_lyBrowsing) return;
  _lyResumeTimer = setTimeout(_lyResume, 4000);
}
function _lyEnterBrowse() {
  if (!_lyThemed() || window.__lyricsCaretActive) return;
  _animId++;
  if (!_lyBrowsing) {
    _lyBrowsing = true;
    document.body.classList.add('ly-browsing');
  }
  _lyScheduleResume();
}
function _lyResume() {
  clearTimeout(_lyResumeTimer);
  if (!_lyBrowsing) return;
  _lyBrowsing = false;
  document.body.classList.remove('ly-browsing');
  if (_currentIdx >= 0 && _currentIdx < _cues.length) {
    scrollToCenter(_cues[_currentIdx], 0, true);
  }
}
window.addEventListener('wheel', function() { _lyEnterBrowse(); }, {passive: true});
// 竖排只能横向滚：鼠标滚轮只给 deltaY，Chromium / WebKit 不会把它转成横滚，桌面上
// 滚轮就滚不动歌词。主方向是纵向的滚轮投影成横滚，往下滚 = 往后读 = 视口左移
// （scrollLeft 变小，两种 RTL 约定同向）。触控板的横向手势（|dx| ≥ |dy|）照原生走。
if (__lyricsVertical) {
  window.addEventListener('wheel', function(e) {
    if (e.ctrlKey || Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    var px = e.deltaMode === 1 ? e.deltaY * 40
        : e.deltaMode === 2 ? e.deltaY * window.innerWidth : e.deltaY;
    e.preventDefault();
    _lyricsScrollTarget().scrollLeft -= px;
  }, {passive: false});
}
document.addEventListener('scroll', function() {
  if (performance.now() > _lyProgUntil) _lyEnterBrowse();
}, {passive: true, capture: true});

// ── cue 切换 ──
var _currentIdx = -1;
var _cues = document.querySelectorAll('.cue');

// ── TODO-1080: over-long cue auto-shrink ──────────────────────────────────
// A single sentence can be longer than the screen fits. In vertical-rl the cue
// column runs top-to-bottom and the body clips overflow-y, so a too-tall column
// is silently cut off; in horizontal the cue wraps and grows vertically but a
// single unbreakable run can still spill past the content-box width. Instead of
// letting either clip, measure each cue against the constraining cross-axis and,
// only when it truly overflows, override THAT cue's inline font-size down by the
// overflow ratio (clamped to a readable floor). Cues that already fit keep the
// user's base font-size untouched (never-break: no change for the common case).
//
// The base size lives in --cue-font-size; the .current cue is transform:scaled
// by --cue-scale, so we discount the available extent by that factor to leave
// headroom (a cue that fits un-scaled but overflows once enlarged still fits).
var __LYRICS_MIN_FONT_PX = 12;
function _lyricsCueScale() {
  var raw = getComputedStyle(document.documentElement)
      .getPropertyValue('--cue-scale');
  var v = parseFloat(raw);
  return (isFinite(v) && v > 0) ? v : 1;
}
function _lyricsBaseFontPx() {
  var raw = getComputedStyle(document.documentElement)
      .getPropertyValue('--cue-font-size');
  var v = parseFloat(raw);
  return (isFinite(v) && v > 0) ? v : 24;
}
// Available cross-axis extent (px) a cue may occupy without clipping, already
// discounted for the enlarged .current scale. Vertical clips on height, so the
// limit is the viewport height minus the container's top+bottom padding; the
// horizontal path scrolls vertically so its only hard limit is width.
function _lyricsAvailExtent(container) {
  var cs = getComputedStyle(container);
  var scale = _lyricsCueScale();
  if (__lyricsVertical) {
    var padV = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    return Math.max(1, (window.innerHeight - padV) / scale);
  }
  var padH = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight);
  return Math.max(1, (window.innerWidth - padH) / scale);
}
// Fit one cue: clear any prior override, measure at base size, and if it still
// overflows the available extent, set an inline font-size scaled by the overflow
// ratio down to the floor. Returns nothing; idempotent.
function _lyricsFitCue(el, avail, base) {
  el.style.fontSize = '';
  // offsetHeight/offsetWidth are the layout-box extents and (unlike
  // getBoundingClientRect) exclude the .current scale transform, so the
  // measurement is scale-independent and the shared avail (already discounted
  // by --cue-scale) applies uniformly to current and non-current cues alike.
  var measured = __lyricsVertical ? el.offsetHeight : el.offsetWidth;
  if (measured <= avail) return;
  var shrunk = Math.max(__LYRICS_MIN_FONT_PX, base * (avail / measured));
  if (shrunk < base) el.style.fontSize = shrunk + 'px';
}
function __lyricsFitCues() {
  var container = document.getElementById('lc');
  if (!container) return;
  var base = _lyricsBaseFontPx();
  var avail = _lyricsAvailExtent(container);
  for (var i = 0; i < _cues.length; i++) _lyricsFitCue(_cues[i], avail, base);
}
window.__lyricsFitCues = __lyricsFitCues;
// Re-fit on viewport changes (rotation / window resize) so a cue that fit at the
// old size is re-measured; debounced via rAF to coalesce burst resize events.
var _lyricsFitPending = false;
window.addEventListener('resize', function() {
  if (_lyricsFitPending) return;
  _lyricsFitPending = true;
  requestAnimationFrame(function() { _lyricsFitPending = false; __lyricsFitCues(); });
});

// scroll === false (audio-follow OFF) updates the current/near highlight but
// does NOT auto-scroll, so the user can freely scroll the lyrics while playback
// continues — mirrors the non-lyrics path where `followAudio` gates reveal.
function setCue(index, scroll) {
  if (index === _currentIdx) return;
  var old = _currentIdx;
  _currentIdx = index;
  var len = _cues.length;
  if (old >= 0) {
    for (var i = Math.max(0, old - 3), e = Math.min(len - 1, old + 3); i <= e; i++)
      _cues[i].classList.remove('current', 'near-1', 'near-2', 'near-3', 'revealed', 'ly-nosweep');
    _lySweepReset(_cues[old]);
  }
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  // 焦点 caret 激活时，播放推进只换高亮，不把屏幕从用户正读的行拽走；跟随关闭(scroll===false)时也不滚。
  if (scroll !== false && !window.__lyricsCaretActive) scrollToCenter(_cues[index]);
}

// ── Dart bridge ──
window.__fushiLyricsLoadGeneration = $loadGeneration;
window.__lyricsSetCue = function(index, scroll) { setCue(index, scroll); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };
// 供 fushiLyricsCaret 行间移动时把目标 cue 居中（复用同一滚动动画）。
window.__lyricsScrollToCue = function(index) {
  if (index < 0 || index >= _cues.length) return;
  // 显式回中（跟随 snap / 焦点 caret）同时结束手动浏览态。
  if (_lyBrowsing) {
    _lyBrowsing = false;
    clearTimeout(_lyResumeTimer);
    document.body.classList.remove('ly-browsing');
  }
  scrollToCenter(_cues[index], 0, true);
};


// BUG-1809: iOS WKWebView can complete loadData() without delivering
// onLoadStop, so the page tells Dart it is ready by itself. Register the
// notifier immediately after the sentinel API exists, before optional
// interaction wiring can throw.
//
// The ready primitive is the bridge object, not a timer and not an event:
// `window.flutter_inappwebview` is installed by the plugin's own user script at
// AT_DOCUMENT_START (iOS InAppWebView.swift:557 + JavaScriptBridgeJS.swift:16,
// Android InAppWebView.java:564 + JavaScriptBridgeJS.java:12), which by spec
// runs before any inline script in this document. So the bridge is already
// there when this line executes — call it synchronously.
//
// `flutterInAppWebViewPlatformReady` must NOT be the primary signal: every
// platform dispatches it from the very native callback that also emits
// onLoadStop (iOS InAppWebView.swift:1925 vs :1934, Android
// InAppWebViewClient.java:240 vs :249, Windows in_app_webview.cpp:647), i.e.
// exactly the callback BUG-1809 is about. On iOS/macOS it does not even set a
// `_platformReady` latch. It is armed only as a belt for a late bridge.
//
// No requestAnimationFrame either: an offscreen / backgrounded WebView
// throttles or never runs rAF, which is the same class of state that eats
// onLoadStop — that would be tunnelling one unreliable callback through
// another.
(function() {
  var fired = false;
  function notifyLyricsReady() {
    if (fired) return;
    var bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') return;
    fired = true;
    try {
      bridge.callHandler('onLyricsReady', $loadGeneration);
    } catch (err) {
      // Do not let a bridge failure kill the interaction wiring below; keep the
      // event belt armed and leave the reason readable for a device probe.
      fired = false;
      window.__fushiLyricsReadyError = String(err);
    }
  }
  notifyLyricsReady();
  if (!fired) {
    window.addEventListener('flutterInAppWebViewPlatformReady', notifyLyricsReady, {once: true});
  }
})();

// ── 逐字扫过（Niratan line progress）──
// Dart 在 cue 推进 / 播放态翻转 / seek 时下发「当前行已播比例 + 每秒推进量」，
// JS 只用一次 CSS transition 把 --ly-p 从该比例线性推到 100%，不逐帧回传。
function _lyTx(el) { return el ? el.querySelector('.tx') : null; }
function _lySweepReset(el) {
  var tx = _lyTx(el);
  if (!tx) return;
  tx.style.transition = 'none';
  tx.style.removeProperty('--ly-p');
}
window.__lyricsSetProgress = function(index, fraction, ratePerSec) {
  if (index !== _currentIdx || !_lyPlaying) return;
  var tx = _lyTx(_cues[index]);
  if (!tx) return;
  var f = Math.max(0, Math.min(1, fraction || 0));
  tx.style.transition = 'none';
  tx.style.setProperty('--ly-p', (f * 100).toFixed(2) + '%');
  void tx.offsetWidth;
  if (ratePerSec > 0 && f < 1) {
    var ms = Math.max(0, (1 - f) / ratePerSec * 1000);
    tx.style.transition = '--ly-p ' + ms.toFixed(0) + 'ms linear';
    tx.style.setProperty('--ly-p', '100%');
  }
};
// 播放态：暂停时当前行整行点亮（不扫）、并停掉自动回到当前行的计时；继续播放时
// 若用户正停在别处浏览，重新起 4 秒回中计时。
window.__lyricsSetPlaying = function(playing) {
  _lyPlaying = !!playing;
  document.body.classList.toggle('ly-paused', !_lyPlaying);
  if (_lyPlaying) _lyScheduleResume();
  else clearTimeout(_lyResumeTimer);
};
// 覆盖层主题热更（设计系统切换 / 封面取色到达 / 明暗切换），不重建整页。
var _lyThemeClasses = [];
window.__lyricsApplyTheme = function(vars, classes) {
  var root = document.documentElement;
  for (var k in vars) root.style.setProperty(k, vars[k]);
  var keep = (classes || []).slice();
  for (var i = 0; i < _lyThemeClasses.length; i++) {
    if (keep.indexOf(_lyThemeClasses[i]) < 0) document.body.classList.remove(_lyThemeClasses[i]);
  }
  for (var j = 0; j < keep.length; j++) document.body.classList.add(keep[j]);
  _lyThemeClasses = keep;
  _lyReadAnchor();
  __lyricsFitCues();
  if (_currentIdx >= 0 && _currentIdx < _cues.length && !_lyBrowsing) {
    _lyricsScrollByAxis(_lyricsCenterDelta(_cues[_currentIdx]));
  }
};
// 「回到当前行」胶囊。用原始 pointerup / touchend（与歌词点按同一机制，不依赖合成
// click——查词弹窗的 Flutter 屏障在场时合成 click 会被吞，见 BUG-280）。
(function() {
  var pill = document.getElementById('ly-follow');
  if (!pill) return;
  function resume(e) { if (e) e.preventDefault(); _lyResume(); }
  pill.addEventListener('pointerup', function(e) {
    if (e.pointerType === 'touch') return;
    resume(e);
  }, {passive: false});
  pill.addEventListener('touchend', resume, {passive: false});
})();

// ── 点击：所有句子→查词 ──
// BUG-280: 原来用 DOM 'click' 事件触发查词。click 只在「pointerdown→pointerup 全程
// 未被宿主层认领」时由浏览器合成；当 Flutter 端弹窗可见时，整屏有一层 translucent
// 手势屏障（base_source_page 的 Positioned.fill GestureDetector，onTap=关闭弹窗）会在
// 手势竞技场里认领这次点按 → WebView 收不到合成 click → 查完一个词后再点下一句只关掉
// 弹窗、不发新查词（无法连续查）。阅读器正文连续查词靠的是自绘的 touchend / pointerup
// （passive:false）原始指针监听，绕过合成 click；这里对齐同一机制：用原始 pointerup /
// touchend + 小位移门控（拖动滚动不误触发），使弹窗屏障在场时 WebView 仍能拿到点按并
// 发起下一次查词。
var _lyTapX = 0, _lyTapY = 0, _lyTapMoved = false, _lyHasTap = false;
function _lyTapStart(x, y) {
  _lyTapX = x; _lyTapY = y; _lyTapMoved = false; _lyHasTap = true;
}
function _lyTapMove(x, y) {
  if (!_lyHasTap) return;
  if (Math.abs(x - _lyTapX) > 12 || Math.abs(y - _lyTapY) > 12) _lyTapMoved = true;
}
function _lyTapEnd(x, y) {
  if (!_lyHasTap) return;
  _lyHasTap = false;
  if (_lyTapMoved) return;
  var el = document.elementFromPoint(x, y);
  var cueEl = el ? el.closest('.cue') : null;
  if (!cueEl) {
    // BUG-756: 歌词是独立文档，没有正文的 fushiReader tap 桥（onTap/onTapEmpty）。
    // 命中空白必须显式回 Dart：① 唤出/收起隐藏的底栏（正文靠 onTapEmpty，歌词此前
    // 完全无此通道 → 底栏一旦隐藏就再也叫不出来）；② 让 Dart reclaim 阅读焦点——桌面
    // WebView2 在本次 pointer 手势里抢走了 OS 焦点，不夺回 Flutter _focusNode 就永远
    // 收不到 ESC，全局「Esc 退出整页」处理器再不触发（正文每个手势 handler 都 reclaim，
    // 歌词 tap 路径此前一处都没有 → esc 退不出）。与正文 onTapEmpty 同款语义。
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onLyricsTapEmpty');
    }
    return;
  }
  // TODO-908: 模糊态下点句显形（同视频「点击显形」语义）；非模糊态无影响。
  if (document.body.classList.contains('lyrics-blur')) cueEl.classList.add('revealed');
  // 覆盖层主题（Apple Music 形态）：点在行的**字形之外**（行尾空白 / 行内边距）=
  // 跳到这一句播放并回到跟随（Niratan contextLyricsLineTapTarget）；点在字上照旧查词，
  // 查词能力不变。模糊态下第一下只显形不跳（上面已 revealed）。
  if (_lyThemed() && window.fushiSelection &&
      window.fushiSelection.getCharacterAtPoint &&
      !window.fushiSelection.getCharacterAtPoint(x, y)) {
    var seekIdx = parseInt(cueEl.getAttribute('data-cue-index'), 10);
    if (!isNaN(seekIdx) && window.flutter_inappwebview) {
      if (_lyBrowsing) {
        _lyBrowsing = false;
        clearTimeout(_lyResumeTimer);
        document.body.classList.remove('ly-browsing');
      }
      window.flutter_inappwebview.callHandler('onLyricsCueTap', seekIdx);
    }
    return;
  }
  if (window.fushiSelection) {
    window.fushiSelection.selectText(x, y, 400);
  }
}
var _lc = document.getElementById('lc');
_lc.addEventListener('touchstart', function(e) {
  var t = e.touches[0]; _lyTapStart(t.clientX, t.clientY);
}, {passive: true});
_lc.addEventListener('touchmove', function(e) {
  var t = e.touches[0]; _lyTapMove(t.clientX, t.clientY);
}, {passive: true});
_lc.addEventListener('touchend', function(e) {
  var t = e.changedTouches[0]; _lyTapEnd(t.clientX, t.clientY);
}, {passive: false});
_lc.addEventListener('pointerdown', function(e) {
  if (e.pointerType === 'touch' || e.button !== 0) return;
  _lyTapStart(e.clientX, e.clientY);
}, {passive: true});
_lc.addEventListener('pointermove', function(e) {
  if (e.pointerType === 'touch') return;
  _lyTapMove(e.clientX, e.clientY);
}, {passive: true});
_lc.addEventListener('pointerup', function(e) {
  if (e.pointerType === 'touch' || e.button !== 0) return;
  _lyTapEnd(e.clientX, e.clientY);
}, {passive: false});

// ── BUG-844: 桌面 Shift-悬停 / 纯悬停查词 ──
// 歌词是独立文档，正文 setup 脚本（含 mousemove→onShiftHover 与 window.__hoverAutoLookup）
// 不注入到这里，导致歌词模式此前完全不支持悬停查词（只有点击查词）。这里镜像正文
// webview.part.dart 的 mousemove 监听：Shift 按住或开了「悬停即查词」开关时，鼠标越过
// 8px 门限即回 Dart onShiftHover（→ _selectTextAt(fromHover:true)，命中被重写的
// selectText 写入 cue 元数据、同源查词管线）。命中空白/同词由 selectText 的 fromHover
// 短路处理，不闪不叠层。__hoverAutoLookup 初值由 Dart 在歌词页就绪时下发。
var _shiftHoverLastX = -1, _shiftHoverLastY = -1;
document.addEventListener('mousemove', function(e) {
  // BUG-2508：宿主（Flutter）侧接管悬停查词的平台上本腿让路（开关由 Dart 与
  // __hoverAutoLookup 一起在歌词页就绪时下发）。
  if (window.__fushiHostHoverLookup) return;
  if (!e.shiftKey && !window.__hoverAutoLookup) { _shiftHoverLastX = -1; _shiftHoverLastY = -1; return; }
  var dx = e.clientX - _shiftHoverLastX, dy = e.clientY - _shiftHoverLastY;
  if (dx * dx + dy * dy < 64) return;
  _shiftHoverLastX = e.clientX; _shiftHoverLastY = e.clientY;
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('onShiftHover', e.clientX, e.clientY);
  }
}, {passive: true});

// ── 中键点句 → seek 到该 cue 并播放（标准 click 不触发中键，单列 mousedown）──
_lc.addEventListener('mousedown', function(e) {
  if (e.button === 0) return;
  var el = e.target.closest('.cue');
  if (!el) return;
  e.preventDefault();
  var idx = parseInt(el.getAttribute('data-cue-index'), 10);
  if (isNaN(idx)) return;
  window.flutter_inappwebview.callHandler('onLyricsPointerSeek', e.button, idx);
});

// ── 歌词模式：覆写 selection 回调，附加 cue 元数据 ──
(function() {
  var origSelectText = window.fushiSelection.selectText;
  // BUG-844: 必须透传全部实参（含第 4 个 fromHover）。旧重写只声明 (x,y,maxLen)、
  // 只转发 3 参，把 Shift-悬停/纯悬停查词路径（selectInvocation 传 fromHover=true）
  // 的 fromHover 吞成 undefined → origSelectText 当成真点击：命中空白误 fire
  // onTapEmpty（关弹窗/唤底栏闪烁）、同词再悬停被 toggle 掉选区。用 apply 原样转发
  // 整个 arguments，语义与正文选区完全一致。
  window.fushiSelection.selectText = function(x, y, maxLen, fromHover) {
    var hitEl = document.elementFromPoint(x, y);
    var cueEl = hitEl ? hitEl.closest('.cue') : null;
    if (cueEl) {
      // 查词高亮落在这一行：停掉逐字扫过（扫过用透明字 + 背景裁切，会把查词底块
      // 里的字一起「挖空」），换行后自动恢复。
      cueEl.classList.add('ly-nosweep');
      window.__lyricsCueContext = {
        textFragmentId: cueEl.getAttribute('data-text-fragment-id'),
        cueIndex: parseInt(cueEl.getAttribute('data-cue-index'), 10),
      };
    } else {
      window.__lyricsCueContext = null;
    }
    return origSelectText.apply(window.fushiSelection, arguments);
  };
})();

// ── 收藏标记 ──
window.__lyricsMarkFavorites = function(texts) {
  var set = new Set(texts || []);
  var cues = document.querySelectorAll('.cue');
  for (var i = 0; i < cues.length; i++) {
    // data-text 是无读音的纯文本；textContent 会把 <rt> 振假名拼进来，永不相等。
    var t = (cues[i].dataset.text || cues[i].textContent).trim();
    if (set.has(t)) cues[i].classList.add('favorited');
    else cues[i].classList.remove('favorited');
  }
};

// ── 实时样式更新（避免整页重载） ──
function __lyricsApplyContainerPadding(r, mt, mb, ml, mr) {
  if (__lyricsVertical) {
    // 竖排 vertical-rl：居中余量在左右(45vw)，上下吃用户 vh 边距。
    r.style.padding = (mt||0) + 'vh calc(45vw + ' + (mr||0) + 'vw) ' + (mb||0) + 'vh calc(45vw + ' + (ml||0) + 'vw)';
  } else {
    var lv = (ml != null && ml > 0) ? ml : 2.5;
    var rv = (mr != null && mr > 0) ? mr : 2.5;
    r.style.padding = 'calc(var(--ly-pad-top, 45vh) + ' + (mt||0) + 'vh) ' + lv + 'vw calc(var(--ly-pad-bottom, 45vh) + ' + (mb||0) + 'vh) ' + rv + 'vw';
  }
}
window.__lyricsUpdateStyle = function(bgColor, textColor, accentColor, fontSize, mt, mb, ml, mr) {
  var root = document.documentElement;
  document.body.style.background = bgColor;
  root.style.background = bgColor;
  // 覆盖层主题下，文字 / 当前行 / 高亮配色归 __lyricsApplyTheme 的 CSS 变量管
  // （规则里是 var(--ly-*)），这里只更新字号与边距，不能用字面色把变量盖掉。
  var themed = _lyThemed();

  var sheet = document.styleSheets[0];
  var rules = sheet.cssRules || sheet.rules;
  for (var i = 0; i < rules.length; i++) {
    var r = rules[i];
    if (r.selectorText === '.cue') {
      if (!themed) r.style.color = textColor;
      // TODO-1080: the base size is now the --cue-font-size custom prop that .cue
      // reads via var(); update the prop (not a fixed .cue font-size) so the refit
      // below re-measures against the new base and clears/re-applies per-cue
      // shrink overrides. Setting .cue's own font-size would beat the var and
      // strand overflowing cues at the un-shrunk size.
      root.style.setProperty('--cue-font-size', fontSize + 'px');
    } else if (r.selectorText === 'html, body') {
      r.style.setProperty('scrollbar-color', textColor + ' transparent');
    } else if (r.selectorText === '::-webkit-scrollbar-thumb') {
      r.style.backgroundColor = textColor;
    } else if (r.selectorText === '.lyrics-container') {
      __lyricsApplyContainerPadding(r, mt, mb, ml, mr);
    } else if (themed) {
      // 主题配色由 CSS 变量承担，跳过下面的字面色改写。
    } else if (r.selectorText === '.cue.current') {
      r.style.color = accentColor;
    } else if (r.type === CSSRule.STYLE_RULE && r.selectorText === '.cue.current .fushi-dict-highlight') {
      r.style.color = bgColor;
    } else if (r.selectorText === '.fushi-dict-highlight') {
      r.style.setProperty('background-color', accentColor, 'important');
    } else if (r.selectorText === '::highlight(fushi-selection)') {
      r.style.setProperty('background-color', accentColor);
      r.style.color = bgColor;
    }
  }
  // Base font-size / margins just changed, so cues re-flow; re-measure overflow
  // and re-apply (or clear) the per-cue shrink so a now-fitting cue reverts to
  // the base and a now-overflowing cue shrinks — without a full page reload.
  __lyricsFitCues();
};

// ── 实时模糊开关（TODO-908 / BUG-852，仿 __lyricsUpdateStyle，不重建整页） ──
// on=true 给 body 挂 lyrics-blur（CSS 模糊所有句，逐句 hover/点击显形）；off 摘掉并
// 清掉所有遗留的 .revealed，回到无模糊态。
window.__lyricsSetBlur = function(on) {
  if (on) {
    document.body.classList.add('lyrics-blur');
  } else {
    document.body.classList.remove('lyrics-blur');
    var revealed = document.querySelectorAll('.cue.revealed');
    for (var i = 0; i < revealed.length; i++) revealed[i].classList.remove('revealed');
  }
};

// TODO-1080: shrink any over-long cue before positioning so the initial-scroll
// geometry (and the caret ring) is measured against the final, fitted sizes.
__lyricsFitCues();

// ── 初始定位（即时跳转，不用动画，避免与 Dart 端 setCue 竞争） ──
// TODO-907: 同样走 delta 增量滚动，横竖排一致；竖排 vertical-rl 的负向 scrollX
// 用 scrollBy 增量打到位，不硬算绝对坐标。
_currentIdx = $currentIndex;
if ($currentIndex >= 0 && $currentIndex < _cues.length) {
  var _initEl = _cues[$currentIndex];
  if (_initEl) _lyricsScrollByAxis(_lyricsCenterDelta(_initEl));
}
</script>
</body>
</html>
''';
  }

  /// cue 正文 → HTML：正文里的 ruby 画回 `<ruby>基底<rt>读音</rt></ruby>`
  /// （振假名）。区间已相对 [LyricsCueText.text]、互不重叠、按序。
  static String _cueInnerHtml(LyricsCueText cue) {
    if (cue.rubies.isEmpty) return _escapeHtml(cue.text);
    final StringBuffer sb = StringBuffer();
    int cursor = 0;
    for (final EpubRubyAnnotation r in cue.rubies) {
      sb
        ..write(_escapeHtml(cue.text.substring(cursor, r.start)))
        ..write('<ruby>')
        ..write(_escapeHtml(cue.text.substring(r.start, r.end)))
        ..write('<rt>')
        ..write(_escapeHtml(r.reading))
        ..write('</rt></ruby>');
      cursor = r.end;
    }
    sb.write(_escapeHtml(cue.text.substring(cursor)));
    return sb.toString();
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _escapeAttr(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}
