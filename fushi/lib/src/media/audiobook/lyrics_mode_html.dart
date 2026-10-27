import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_text.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/models/cjk_font_families.dart' show CjkFontStyle;
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_vertical_punctuation_font.dart';

/// 歌词层「手动滚动脱离跟随」诊断（JS `onLyricsBrowseDiag`，反馈 0rvPl6s6tR）的一行文字。[args] =
/// `[kind, 距上次程序化滚动 ms, 距上次用户输入 ms, 已在浏览态, 在播放]`；同时记下此刻常规同步 / 复习同步
/// 是否在跑，用来判断跟随中断与后台同步有没有关系。参数不全或类型不对时照原样记下，不丢这条线索。
String lyricsBrowseDiagLine(
  List<dynamic> args, {
  required bool regularSyncRunning,
  required bool srsSyncRunning,
}) {
  String at(int i) => i < args.length ? '${args[i]}' : '?';
  return '${at(0)} sinceProgMs=${at(1)} sinceInputMs=${at(2)} '
      'browsing=${at(3)} playing=${at(4)} '
      'sync=$regularSyncRunning srsSync=$srsSyncRunning';
}

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
    bool sweep = true,
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
      '--ly-upcoming': _css(current.withValues(alpha: current.a * 0.4)),
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
      '--ly-pill-bg': _css(current.withValues(alpha: 0.16)),
      '--ly-pill-fg': _css(current),
      '--ly-past-k': theme.pastOpacityFactor.clamp(0.0, 1.0).toStringAsFixed(3),
    };
    return (
      vars: vars,
      bodyClasses: <String>[
        'ly-themed',
        // 逐字跟读渐变（`lyrics_sweep`）。关掉时当前行整行用纯色，不扫过。
        if (sweep) 'ly-sweep',
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
    bool sweep = true,
  }) {
    final ({Map<String, String> vars, List<String> bodyClasses}) t = themeVars(
      theme,
      textColorOverride: textColorOverride,
      currentColorOverride: currentColorOverride,
      sweep: sweep,
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
    bool sweep = true,
    String followLabel = '',
    String? contentLanguage,
    String verticalTextOrientation = 'mixed',
    TargetPlatform? platform,
    bool showSkippedText = true,
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
            sweep: sweep,
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
      // 跳读灰显：上一条与这一条之间没被任何 cue 认领的正文，作为一行灰色小字
      // 夹在两行之间。它不是 `.cue`——不进当前句高亮 / 逐字扫过、不计时、点按不
      // 跳播放、不进收藏 / 焦点 caret / 字号适配（JS 全部按 `.cue` 取行）。
      // 透明度跟着相邻两行里离当前句近的那行走（`near-N`，setCue 同步改）。
      final LyricsCueText? skipped = i == 0 || textResolver == null
          ? null
          : textResolver.skippedTextBetween(cues[i - 1], cues[i]);
      if (skipped != null) {
        final int gapDist = i - 1 >= currentIndex
            ? i - 1 - currentIndex + 1
            : currentIndex - i + 1;
        final String gapCls = gapDist <= 3 ? 'ly-gap near-$gapDist' : 'ly-gap';
        cueHtml.write(
          '<div class="$gapCls" data-after="${i - 1}">'
          '<span class="ly-gap-tx">${_cueInnerHtml(skipped)}</span></div>\n',
        );
      }
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
    // 竖排字形朝向跟正文同一设置（`vert_text_orient`，正文 reader_content_styles
    // 的 textOrientCss）：同一本书切到歌词，标点 / 拉丁字母的朝向不该变（BUG-3281）。
    final String htmlBodyAxisCss = vertical
        ? 'writing-mode: vertical-rl; overflow-x: auto; overflow-y: hidden; '
              'text-orientation: ${_cssIdent(verticalTextOrientation)};'
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
.lyrics-container > .ly-gap {
  max-width: none;
  max-inline-size: calc(100% / var(--cue-scale) - 1%);
  padding: 8px 2px;
}
/* 盖过横排的 body.ly-themed .ly-gap（0 14px）：竖排的行首在上，与歌词列同一行首缩进。 */
body.ly-themed .lyrics-container > .ly-gap {
  padding: 14px 2px;
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
      if (!showSkippedText) 'ly-hide-skipped',
      ...?themed?.bodyClasses,
      // 竖排标记只服务主题态的扫过 / 渐隐方向；旧观感不加 class（输出与改动前一致）。
      if (vertical && themed != null) 'ly-vertical',
    ];
    final String blurBodyClass = bodyClasses.isEmpty
        ? ''
        : ' class="${bodyClasses.join(' ')}"';
    final String followLabelHtml = _escapeHtml(followLabel);
    // 歌词模式此前硬编码 "Noto Serif JP", "Noto Sans JP", serif：同一本书在正文视图
    // 用用户设的阅读字体、切到歌词就变回 Noto。这里接上 FontTarget.body 的
    // @font-face + family（调用方传 ReaderSettings.buildCustomFontCss()）。
    // 用户没设字体时 fontFamilyCss 为空，整条链与改动前逐字节相同。
    // 覆盖层主题（Apple Music / MD3 播放页）的歌词是粗体无衬线（Apple Music 用 SF
    // 粗体）；旧歌词页保留 Noto 衬线链。用户设了正文字体时两者都优先用户字体。
    //
    // BUG-3281：回退链与正文同源——[contentFontFamilyCss] 按**书的内容语言**给
    // CJK 字体链。旧覆盖层链以 `system-ui, -apple-system` 打头：那是拉丁系统字体
    // （Segoe UI / Roboto / SF），它们自带 “ ” ‘ ’ … — 等歧义宽度标点，于是这些
    // 标点从拉丁字体取半角字形（竖排时只能被整体侧转），而汉字假名与 。、「」 落到
    // 日文字体——与正文（链首就是 CJK 字体）的标点字形、竖排方向都对不上。
    //
    // 与正文 `_bodyFontFamily` 同口径：**不**开 fallbackWhenUnknown。没有全局学习
    // 语言——英文 / 西语有声书（或语言未知的书）不能被塞进日文 CJK 链；只有内容
    // 语言确为 CJK 时才给 CJK 链，否则落回通用族（无主题 serif，与正文同；覆盖层
    // 主题保持无衬线的系统字体观感）。
    final String lyricsFallbackFonts = _lyricsFallbackFonts(
      contentLanguage: contentLanguage,
      platform: platform ?? defaultTargetPlatform,
      themed: theme != null,
    );
    final String chainFontFamily = fontFamilyCss.isEmpty
        ? lyricsFallbackFonts
        : '$fontFamilyCss, $lyricsFallbackFonts';
    // BUG-3606：竖排与正文同一套标点子集与同一判据（链首 + unicode-range）。
    final bool verticalPunctuation = ReaderVerticalPunctuationFont.appliesTo(
      vertical: vertical,
      contentLanguage: contentLanguage,
    );
    final String bodyFontFamily = verticalPunctuation
        ? ReaderVerticalPunctuationFont.prependTo(chainFontFamily)
        : chainFontFamily;
    final String bodyFontFaceCss = verticalPunctuation
        ? '${ReaderVerticalPunctuationFont.fontFace()}\n$fontFaceCss'
        : fontFaceCss;

    return '''
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
:root { --cue-scale: 1.15; --cue-font-size: ${fontSize}px; $themeVarsCss }
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
$bodyFontFaceCss
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
  cursor: pointer;
}
/* BUG-3282：合成层只给会动的那几行（当前行 ±3，setCue 只改这个窗口的 class）。
   以前挂在裸 .cue 上，整页最多 600 行每行一个合成层，滚动 / 换行时合成器要搬
   几百张图层，WebView2 / Android WebView 上掉帧明显。 */
.cue.current, .cue.near-1, .cue.near-2, .cue.near-3 {
  will-change: transform, opacity;
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
/* 跳读灰显：两行之间没被任何 cue 认领的正文（朗读者跳过 / 转录没对上）。次要文本
   色（--ly-text，覆盖层主题下即非当前行色）+ 小字号 + 比相邻行再淡一档；透明度
   阶梯跟着 near-N 走，与相邻行同进退。不可点、不参与高亮 / 扫过。 */
.ly-gap {
  position: relative;
  text-align: var(--ly-align, center);
  color: var(--ly-text, $textColor);
  align-self: var(--ly-self, auto);
  font-size: calc(var(--cue-font-size) * 0.62);
  font-weight: 400;
  line-height: 1.6;
  padding: 2px 8px;
  max-width: calc(100% / var(--cue-scale) - 1%);
  overflow-wrap: break-word;
  word-break: break-word;
  opacity: calc(var(--ly-op4, 0.15) * var(--ly-gap-k, 0.8));
  transition: opacity 0.35s ease-out, filter 0.3s ease-out;
  cursor: default;
}
.ly-gap.near-1 { opacity: calc(var(--ly-op1, 0.55) * var(--ly-gap-k, 0.8)); }
.ly-gap.near-2 { opacity: calc(var(--ly-op2, 0.35) * var(--ly-gap-k, 0.8)); }
.ly-gap.near-3 { opacity: calc(var(--ly-op3, 0.25) * var(--ly-gap-k, 0.8)); }
body.ly-themed .ly-gap { padding: 0 14px; }
body.ly-browsing .ly-gap { opacity: calc(var(--ly-op-browse, 0.6) * var(--ly-gap-k, 0.8)); }
body.ly-past-dim:not(.ly-browsing) .ly-gap:not(.current ~ .ly-gap) {
  opacity: calc(var(--ly-op4, 0.15) * var(--ly-gap-k, 0.8) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .ly-gap.near-1:not(.current ~ .ly-gap) {
  opacity: calc(var(--ly-op1, 0.55) * var(--ly-gap-k, 0.8) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .ly-gap.near-2:not(.current ~ .ly-gap) {
  opacity: calc(var(--ly-op2, 0.35) * var(--ly-gap-k, 0.8) * var(--ly-past-k, 1));
}
body.ly-past-dim:not(.ly-browsing) .ly-gap.near-3:not(.current ~ .ly-gap) {
  opacity: calc(var(--ly-op3, 0.25) * var(--ly-gap-k, 0.8) * var(--ly-past-k, 1));
}
body.ly-ctxblur .ly-gap { filter: blur(var(--ly-ctx-blur, 0px)); }
body.ly-hide-skipped .ly-gap { display: none; }
.ly-gap ruby { ruby-align: center; }
.ly-gap rt { font-size: 0.5em; line-height: 1; }
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
/* 帧率：屏外的行不做过渡。进出手动浏览态（body.ly-browsing）一次改全书几百行的
   opacity，每行一条过渡、Chromium 给每条在动画的行临时建合成层，滚轮一动就卡一下。
   屏外的行看不见，直接落值即可；视口附近的行由 IntersectionObserver 标 .ly-vis
   （不支持时全部标上，退回改动前行为）。 */
.cue:not(.ly-vis) { transition: none !important; }
body.ly-ctxblur .cue:not(.current) { filter: blur(var(--ly-ctx-blur, 0px)); }
@media (hover: hover) {
  body.ly-themed .cue:not(.current):hover { opacity: 0.84; }
}
/* 逐字扫过（Niratan line progress）：当前行按播放进度沿阅读方向点亮，未读部分 =
   当前色 × 0.4。只用合成器能独立推进的属性（transform）实现，播放全程不重绘：
   - 底层 = 行内文字本身，扫过期间整行画成未读色（.tx 的 color，静态）；
   - 上层 = .ly-sw 宿主（shadow DOM，不进文本遍历 / 选区 / textContent）里每个视觉行
     （竖排是每列）一个窗口，窗口里是整句的当前色副本，排版与底层逐像素重合；窗口
     沿行方向平移、里面的副本反向平移同样距离（副本相对屏幕不动），窗口前沿的遮罩
     渐变就是扫过的软边。两个平移都是 Web Animations 的 transform 关键帧，Blink 与
     WebKit 都交给合成器线程插值；主线程只在换句 / seek / 起播 / 重排时搭一次。
   以前是注册自定义属性（@property 进度变量）+ transition：自定义属性动画不能上合成器，每帧主线程
   重算样式、重画当前行，WebView 全程 60fps 出帧（WebView2 每帧逼 Flutter 整帧重合成）。
   门与旧规则相同：暂停 / 查词（.ly-nosweep）/ 关掉扫过时整行直接点亮；.ly-sw-on
   由 JS 在上层搭好后挂上，没搭好（不支持 Web Animations / 尚未下发进度）时也整行点亮。 */
.ly-sw {
  display: none;
  position: absolute;
  left: 0;
  top: 0;
  width: 0;
  height: 0;
  overflow: visible;
  pointer-events: none;
}
body.ly-sweep:not(.ly-paused) .cue.current.ly-sw-on:not(.ly-nosweep) > .ly-sw {
  display: block;
}
body.ly-sweep:not(.ly-paused) .cue.current.ly-sw-on:not(.ly-nosweep) .tx {
  color: var(--ly-upcoming);
}
body.ly-sweep:not(.ly-paused) .cue.current.ly-sw-on:not(.ly-nosweep) .tx rt {
  color: var(--ly-current);
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
  /* 悬浮面实色（Apple 2026-10-13 拍板；MD3 悬浮面同为实色）：着色层叠在页面底色上，
     不再半透明 + 背景模糊（也就不受「降低透明度」影响）。 */
  background: linear-gradient(var(--ly-pill-bg, rgba(127,127,127,0.2)),
      var(--ly-pill-bg, rgba(127,127,127,0.2))), $backgroundColor;
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
/* 未朗读的原文同样不可预读，悬停显形。 */
body.lyrics-blur .ly-gap { filter: blur(8px); }
body.lyrics-blur .ly-gap:hover { filter: blur(0); }
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
/* BUG-3368：选区脚本对 <ruby> 里的字不走 ::highlight / 包裹，只给 ruby 元素挂
   fushi-selection-ruby-active（BUG-110，竖排防双绘），背景要页面自己画。歌词页此前
   没有这条规则 → 带注音的词（烏滸がましい）查词时基字永远不高亮，只亮后半截。 */
ruby.fushi-selection-ruby-active {
  background-color: var(--ly-hl, $accentColor) !important;
  border-radius: 2px;
}
.cue.current ruby.fushi-selection-ruby-active {
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
  _lyWheelStop();
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
// 无极滚轮（横竖排同一套）：滚轮由这里接管，不交给浏览器原生的逐格动画。
//  * 竖排只能横向滚：鼠标滚轮只给 deltaY，Chromium / WebKit 不会把它转成横滚。
//    主方向是纵向的滚轮投影成横滚，往下滚 = 往后读 = 视口左移（scrollLeft 变小，
//    两种 RTL 约定同向）。
//  * BUG-3282 / 用户 2026-10-14「支持无极滑动」：一格滚轮 100px，原生平滑滚轮
//    和旧的「每帧逼近 30%」都在约 50ms 内停稳，而相邻两格间隔 60–120ms——每格之间
//    停一下，就是一顿一顿的「有级」滚动。滚轮量累加进目标位置，按**真实帧间隔**
//    指数逼近（时间常数 _LY_WHEEL_TAU_MS，与刷新率无关），连续几格衔接成一段
//    不停顿的滑行；连续滚动只推远目标、不重置动画。
//  * 触控板 / 高精度滚轮（单次增量小）本身就是连续的，直接跟手，不加缓动延迟。
//  * 触控板主方向与滚动轴垂直的手势（竖排时的纯横向两指滑）照原生走。
var _LY_WHEEL_TAU_MS = 90;
var _LY_WHEEL_PRECISE_PX = 40;
var _lyWheelTarget = null, _lyWheelRaf = 0, _lyWheelLast = 0;
function _lyWheelStop() {
  if (_lyWheelRaf) cancelAnimationFrame(_lyWheelRaf);
  _lyWheelRaf = 0;
  _lyWheelTarget = null;
}
function _lyAxisPos(s) { return __lyricsVertical ? s.scrollLeft : s.scrollTop; }
function _lySetAxisPos(s, v) {
  if (__lyricsVertical) s.scrollLeft = v;
  else s.scrollTop = v;
}
// 纯函数：经过 dtMs 之后的位置（时间常数 tauMs 的指数逼近，dt 越长走得越多，
// 与刷新率无关）。剩余量 < 1px 直接落到目标，不拖亚像素尾巴。
function __lyricsWheelStep(cur, target, dtMs, tauMs) {
  var d = target - cur;
  if (Math.abs(d) < 1) return target;
  var k = 1 - Math.exp(-Math.max(0, dtMs) / tauMs);
  var next = cur + d * k;
  return Math.abs(target - next) < 1 ? target : next;
}
function _lyWheelFrame(now) {
  _lyWheelRaf = 0;
  if (_lyWheelTarget === null) return;
  // 跨帧时长钳到 50ms：后台 / 卡顿一帧后不一步飞到底。
  var dt = Math.min(50, Math.max(0, now - _lyWheelLast));
  _lyWheelLast = now;
  var s = _lyricsScrollTarget();
  var before = _lyAxisPos(s);
  var next = __lyricsWheelStep(before, _lyWheelTarget, dt, _LY_WHEEL_TAU_MS);
  _lySetAxisPos(s, next);
  // 顶到滚动边界（位置没动）或已到目标：结束，不让越界的目标空转。
  if (next === _lyWheelTarget || (dt > 0 && _lyAxisPos(s) === before)) {
    _lyWheelTarget = null;
    return;
  }
  _lyWheelRaf = requestAnimationFrame(_lyWheelFrame);
}
window.addEventListener('wheel', function(e) {
  if (e.ctrlKey) return;
  var raw;
  if (__lyricsVertical) {
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    raw = -e.deltaY;
  } else {
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
    raw = e.deltaY;
  }
  var extent = __lyricsVertical ? window.innerWidth : window.innerHeight;
  var px = e.deltaMode === 1 ? raw * 40 : e.deltaMode === 2 ? raw * extent : raw;
  if (px === 0) return;
  e.preventDefault();
  var s = _lyricsScrollTarget();
  if (window.__lyricsReduceMotion ||
      (e.deltaMode === 0 && Math.abs(px) < _LY_WHEEL_PRECISE_PX)) {
    // 跟手：在途的缓动目标一起平移，避免两路互相拉扯。
    if (_lyWheelTarget !== null) _lyWheelTarget += px;
    else _lySetAxisPos(s, _lyAxisPos(s) + px);
    return;
  }
  if (_lyWheelTarget === null) {
    _lyWheelTarget = _lyAxisPos(s);
    _lyWheelLast = performance.now();
  }
  _lyWheelTarget += px;
  if (!_lyWheelRaf) _lyWheelRaf = requestAnimationFrame(_lyWheelFrame);
}, {passive: false});
// 反馈 0rvPl6s6tR：「手动滚动」只认真的用户输入。以前「免判窗口之外的 scroll 都算用户滚」：
// 设备忙（后台同步 / 解码占满 CPU）时，自动跟随那一帧的 scroll 事件晚于 150 ms 才到；视口尺寸
// 变化、重排后的位置钳制 / 滚动锚定也会发 scroll——都被当成用户滚走了，歌词停止跟随、弹出
// 「跟随音频」。现在只有手指按着、或刚有过触摸 / 指针 / 键盘输入（[_LY_USER_INPUT_MS] 内）时的
// scroll 才进入浏览态；滚轮另由上面的 wheel 监听进入。其余 scroll 一律不算，并上报诊断。
var _LY_USER_INPUT_MS = 1000;
var _lyTouching = false, _lyUserInputAt = -1e9;
function _lyNoteUserInput() { _lyUserInputAt = performance.now(); }
document.addEventListener('touchstart', function() {
  _lyTouching = true; _lyNoteUserInput();
}, {passive: true, capture: true});
document.addEventListener('touchmove', _lyNoteUserInput, {passive: true, capture: true});
function _lyTouchDone() { _lyTouching = false; _lyNoteUserInput(); }
document.addEventListener('touchend', _lyTouchDone, {passive: true, capture: true});
document.addEventListener('touchcancel', _lyTouchDone, {passive: true, capture: true});
document.addEventListener('pointerdown', _lyNoteUserInput, {passive: true, capture: true});
document.addEventListener('pointermove', function(e) {
  if (e.buttons) _lyNoteUserInput();
}, {passive: true, capture: true});
document.addEventListener('keydown', _lyNoteUserInput, {passive: true, capture: true});
function __lyricsIsUserScroll(now) {
  if (now <= _lyProgUntil) return false;
  return _lyTouching || now - _lyUserInputAt <= _LY_USER_INPUT_MS;
}
window.__lyricsIsUserScroll = __lyricsIsUserScroll;
// 诊断（随反馈日志上传）：每类每 30 秒最多报一次，带离上次程序化滚动 / 上次用户输入多久。
var _lyDiagAt = {};
function _lyBrowseDiag(kind, now) {
  if (_lyDiagAt[kind] !== undefined && now - _lyDiagAt[kind] < 30000) return;
  _lyDiagAt[kind] = now;
  var bridge = window.flutter_inappwebview;
  if (!bridge || typeof bridge.callHandler !== 'function') return;
  try {
    bridge.callHandler('onLyricsBrowseDiag', kind,
      Math.round(now - _lyProgUntil), Math.round(now - _lyUserInputAt),
      _lyBrowsing, _lyPlaying);
  } catch (e) {}
}
document.addEventListener('scroll', function() {
  var now = performance.now();
  if (now <= _lyProgUntil) return;
  if (__lyricsIsUserScroll(now)) {
    if (!_lyBrowsing) _lyBrowseDiag('user-scroll', now);
    _lyEnterBrowse();
  } else {
    _lyBrowseDiag('ignored-scroll', now);
  }
}, {passive: true, capture: true});

// ── cue 切换 ──
var _currentIdx = -1;
var _cues = document.querySelectorAll('.cue');
// 跳读灰显行（不是 .cue）：按「夹在第几条 cue 之后」索引，setCue 时同步它们的
// near-N（取相邻两行里离当前句近的那行）。
var _lyGapAfter = {};
(function() {
  var gs = document.querySelectorAll('.ly-gap');
  for (var g = 0; g < gs.length; g++) {
    var after = parseInt(gs[g].getAttribute('data-after'), 10);
    if (!isNaN(after)) _lyGapAfter[after] = gs[g];
  }
})();
function _lyMarkGaps(index, add) {
  for (var i = index - 3; i <= index + 2; i++) {
    var gap = _lyGapAfter[i];
    if (!gap) continue;
    gap.classList.remove('near-1', 'near-2', 'near-3');
    var d = (i >= index ? i - index : index - 1 - i) + 1;
    if (add && d <= 3) gap.classList.add('near-' + d);
  }
}

// 视口附近（上下 / 左右各多算一屏）的行标 .ly-vis，只有它们做过渡（见 CSS）。
(function() {
  if (typeof IntersectionObserver !== 'function') {
    for (var i = 0; i < _cues.length; i++) _cues[i].classList.add('ly-vis');
    return;
  }
  var io = new IntersectionObserver(function(entries) {
    for (var i = 0; i < entries.length; i++) {
      entries[i].target.classList.toggle('ly-vis', entries[i].isIntersecting);
    }
  // root 必须是真正的滚动元素（BUG-784：通常是 body）：以视口为 root 时
  // rootMargin 扩不出 body 自己的溢出裁剪，「多算一屏」就成了 0。
  }, {
    root: _lyricsScrollTarget() === document.documentElement
        ? null : _lyricsScrollTarget(),
    rootMargin: '100% 100% 100% 100%',
  });
  for (var j = 0; j < _cues.length; j++) io.observe(_cues[j]);
})();

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
// Fit one cue from its base-size measurement: if it overflows the available
// extent, set an inline font-size scaled by the overflow ratio down to the floor.
function _lyricsFitCue(el, measured, avail, base) {
  if (measured <= avail) return;
  var shrunk = Math.max(__LYRICS_MIN_FONT_PX, base * (avail / measured));
  if (shrunk < base) el.style.fontSize = shrunk + 'px';
}
// WKWebView 在被 Flutter 隐藏（歌词页就绪前 opacity 0）时视口是 0×0。零视口下没有
// 可用的约束尺寸：每一句都「溢出」，竖排更是每字一列。此时一律不量，等 resize 带来
// 真实视口再量（下方 resize 监听）。
function __lyricsHasViewport() {
  return window.innerWidth > 0 && window.innerHeight > 0;
}
function __lyricsFitCues() {
  var container = document.getElementById('lc');
  if (!container) return;
  if (!__lyricsHasViewport()) return;
  var base = _lyricsBaseFontPx();
  var avail = _lyricsAvailExtent(container);
  // 读写分离：先统一清掉旧覆盖、再一次性量完、最后统一写。逐句「写→读」会让每一句
  // 都触发一次整页同步布局（600 句竖排在零视口下实测 11–13 s，期间 WebContent 主线程
  // 全程阻塞：就绪握手、resize、后续 loadData 全部排队）。
  var n = _cues.length, measured = new Array(n), i, el;
  for (i = 0; i < n; i++) { el = _cues[i]; el.style.fontSize = ''; }
  // offsetHeight/offsetWidth are the layout-box extents and (unlike
  // getBoundingClientRect) exclude the .current scale transform, so the
  // measurement is scale-independent and the shared avail (already discounted
  // by --cue-scale) applies uniformly to current and non-current cues alike.
  for (i = 0; i < n; i++) { el = _cues[i]; measured[i] = __lyricsVertical ? el.offsetHeight : el.offsetWidth; }
  for (i = 0; i < n; i++) _lyricsFitCue(_cues[i], measured[i], avail, base);
  // 字号变了行就变了：按此刻进度重搭扫过层。
  _lySweepRelayout();
}
window.__lyricsFitCues = __lyricsFitCues;
// Re-fit on viewport changes (rotation / window resize) so a cue that fit at the
// old size is re-measured; debounced via rAF to coalesce burst resize events.
var _lyricsFitPending = false;
window.addEventListener('resize', function() {
  if (_lyricsFitPending) return;
  _lyricsFitPending = true;
  requestAnimationFrame(function() {
    _lyricsFitPending = false;
    __lyricsFitCues();
    _lyInitialPosition();
  });
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
    _lyMarkGaps(old, false);
  }
  _lyMarkGaps(index, true);
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  // 新句的扫过层等同一次同步里紧跟着的 __lyricsSetProgress 按真实进度搭；只换句
  // 不下发进度时整行点亮（.ly-sw-on 未挂）。
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
// BUG-3777 R2：文档从不可见变回可见（App 回前台 / WebView 重新上屏）时请 Dart 按此刻
// 的播放位置重推一次当前行 / 播放态 / 扫过进度——不可见期间被节流积压或丢掉的同步
// 不能指望下一句才纠正。
document.addEventListener('visibilitychange', function() {
  if (document.visibilityState !== 'visible') return;
  var bridge = window.flutter_inappwebview;
  if (!bridge || typeof bridge.callHandler !== 'function') return;
  try {
    bridge.callHandler('onLyricsVisible');
  } catch (err) {}
});

// ── 逐字扫过（Niratan line progress）──
// Dart 在 cue 推进 / 播放态翻转 / seek / 倍速变化时下发「当前行已播比例 + 每秒推进量」，
// JS 量一次当前句的视觉行（竖排是列），给每行搭一个「当前色副本 + 平移窗口」，用
// Web Animations 的 transform 关键帧把窗口从该比例线性推到 100%，不逐帧回传。transform
// 动画在 Blink 与 WebKit 都由合成器线程插值：播放中当前行不重绘、主线程不出帧。
// 几何只在换句 / 起播 / seek / 重新适配字号 / 字体加载完成时量（_lySweepRelayout）。
function _lyTx(el) { return el ? el.querySelector('.tx') : null; }
// 影子树里的副本吃不到文档样式表，把影响 .tx 排版的规则（全局重置、振假名）照抄一份。
var _LY_SW_CSS = '* { margin: 0; padding: 0; box-sizing: border-box; }' +
    '.w { position: absolute; overflow: visible; }' +
    '.i { position: absolute; }' +
    '.tx { color: var(--ly-current); }' +
    'ruby { ruby-align: center; }' +
    'rt { font-size: 0.5em; line-height: 1; }';
// 当前一次扫过的请求（换句前一直有效，用来在重排时按「此刻进度」重搭）。
var _lySw = null;
function _lySweepClearCue(el) {
  if (!el) return;
  el.classList.remove('ly-sw-on');
  for (var i = el.children.length - 1; i >= 0; i--) {
    var c = el.children[i];
    if (!c.classList.contains('ly-sw')) continue;
    var anims = c._lyAnims || [];
    for (var j = 0; j < anims.length; j++) anims[j].cancel();
    el.removeChild(c);
  }
}
function _lySweepReset(el) {
  _lySweepClearCue(el);
  if (_lySw && _lySw.cue === el) _lySw = null;
}
// 只在扫过真会显示时搭：隐藏着的 transform 动画没有合成层，会退回主线程逐帧跑。
function _lySweepWanted(el) {
  var b = document.body.classList;
  return _lyPlaying && b.contains('ly-sweep') && !b.contains('ly-paused') &&
      el.classList.contains('current') && !el.classList.contains('ly-nosweep');
}
// 纯函数：当前句局部坐标下的字形矩形 {l,r,t,b} → 按阅读顺序排好的视觉行。
// u = 行内方向（横排 x / 竖排 y），v = 交叉方向；b0/b1 = 该行窗口在交叉方向的条带
// （相邻两行取中线分界，首尾各外扩半行，盖住字形墨迹）。
function __lyricsSweepLines(rects, vertical) {
  var lines = [];
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    var c = vertical ? {u0: r.t, u1: r.b, v0: r.l, v1: r.r}
                     : {u0: r.l, u1: r.r, v0: r.t, v1: r.b};
    if (!(c.u1 > c.u0 && c.v1 > c.v0)) continue;
    var hit = null;
    for (var j = 0; j < lines.length; j++) {
      var ov = Math.min(lines[j].v1, c.v1) - Math.max(lines[j].v0, c.v0);
      if (ov > 0.5 * Math.min(lines[j].v1 - lines[j].v0, c.v1 - c.v0)) { hit = lines[j]; break; }
    }
    if (hit) {
      hit.u0 = Math.min(hit.u0, c.u0); hit.u1 = Math.max(hit.u1, c.u1);
      hit.v0 = Math.min(hit.v0, c.v0); hit.v1 = Math.max(hit.v1, c.v1);
    } else {
      lines.push(c);
    }
  }
  // 横排自上而下；竖排 vertical-rl 右边的列先读。
  lines.sort(function(a, b) { return vertical ? b.v1 - a.v1 : a.v0 - b.v0; });
  for (var n = 0; n < lines.length; n++) {
    var ln = lines[n], ext = (ln.v1 - ln.v0) / 2;
    var prev = lines[n - 1], next = lines[n + 1];
    if (vertical) {
      ln.b1 = prev ? (ln.v1 + prev.v0) / 2 : ln.v1 + ext;
      ln.b0 = next ? (ln.v0 + next.v1) / 2 : ln.v0 - ext;
    } else {
      ln.b0 = prev ? (prev.v1 + ln.v0) / 2 : ln.v0 - ext;
      ln.b1 = next ? (ln.v1 + next.v0) / 2 : ln.v1 + ext;
    }
  }
  return lines;
}
// 纯函数：整句进度 p（0–1）下，某行窗口沿行方向的位移（px）。该行占全句累计长度
// [start, end)，长 len px，全句 total px，软边半宽 half px（= 全句 4%，与旧渐变
// calc(p ± 4%) 同宽）。窗口静止位置让软边中心落在行尾；位移 = (p − end)·total，
// 钳在「软边整个落到行首之前」与「软边整个越过行尾」之间——相邻行的软边因此跨行
// 接续，与旧的 slice 渐变一致。
function __lyricsSweepOffset(p, end, len, total, half) {
  return Math.max(-(len + half), Math.min(half, (p - end) * total));
}
// 纯函数：从进度 p0 线性推到 1 的关键帧（offset 0–1 + 位移），拐点在该行软边进入
// 行首与离开行尾的两个进度上。
function __lyricsSweepFrames(p0, start, end, len, total, half) {
  var pts = [p0, start - half / total, end + half / total, 1];
  pts.sort(function(a, b) { return a - b; });
  var out = [];
  for (var i = 0; i < pts.length; i++) {
    var p = pts[i];
    if (p < p0 || p > 1) continue;
    var off = p0 >= 1 ? 1 : (p - p0) / (1 - p0);
    if (out.length && Math.abs(out[out.length - 1].offset - off) < 1e-6) continue;
    out.push({offset: off, shift: __lyricsSweepOffset(p, end, len, total, half)});
  }
  return out;
}
// 当前句此刻的 scale（transform 过渡中途也准）：客户区坐标 ÷ 它 = 布局像素。
// 计算值是 matrix(a, b, c, d, e, f)；只有等比缩放，取 a。
function _lyCueScale(el) {
  var t = getComputedStyle(el).transform || '';
  var open = t.indexOf('(');
  var a = open < 0 ? 1 : parseFloat(t.slice(open + 1));
  return (isFinite(a) && a > 0) ? a : 1;
}
function _lySweepBuild(el, p, rate) {
  _lySweepClearCue(el);
  _lySw = {cue: el, p0: p, rate: rate, t0: performance.now()};
  if (!_lySweepWanted(el) || typeof el.animate !== 'function' || !el.attachShadow) return;
  var tx = _lyTx(el);
  if (!tx) return;
  var box = el.getBoundingClientRect();
  var k = _lyCueScale(el);
  if (!(box.width > 0 && box.height > 0)) return;
  var vertical = __lyricsVertical;
  var rects = [];
  var walker = document.createTreeWalker(tx, NodeFilter.SHOW_TEXT, null);
  var range = document.createRange();
  var node;
  while ((node = walker.nextNode())) {
    // 注音（rt / rp）贴在基字侧边，两层都是当前色，不参与行划分。
    if (node.parentElement && node.parentElement.closest('rt, rp')) continue;
    range.selectNodeContents(node);
    var rs = range.getClientRects();
    for (var i = 0; i < rs.length; i++) {
      rects.push({l: (rs[i].left - box.left) / k, r: (rs[i].right - box.left) / k,
                  t: (rs[i].top - box.top) / k, b: (rs[i].bottom - box.top) / k});
    }
  }
  var lines = __lyricsSweepLines(rects, vertical);
  var total = 0;
  for (var n = 0; n < lines.length; n++) total += lines[n].u1 - lines[n].u0;
  if (!(total > 0)) return;
  var half = total * 0.04, margin = 6;
  var cs = getComputedStyle(el);
  var host = document.createElement('span');
  host.className = 'ly-sw';
  host.setAttribute('aria-hidden', 'true');
  var root = host.attachShadow({mode: 'open'});
  var style = document.createElement('style');
  style.textContent = _LY_SW_CSS;
  root.appendChild(style);
  el.appendChild(host);
  // 副本的排版盒与当前句的盒逐像素一致：同宽高（布局像素，不取整）、同内边距。
  var boxCss = 'width:' + (box.width / k) + 'px;height:' + (box.height / k) + 'px;' +
      'padding:' + cs.paddingTop + ' ' + cs.paddingRight + ' ' + cs.paddingBottom +
      ' ' + cs.paddingLeft + ';';
  var fn = vertical ? 'translateY(' : 'translateX(';
  var dur = (rate > 0 && p < 1) ? (1 - p) / rate * 1000 : 0;
  var anims = [];
  var acc = 0;
  for (var m = 0; m < lines.length; m++) {
    var ln = lines[m], len = ln.u1 - ln.u0;
    var start = acc / total, end = (acc + len) / total;
    acc += len;
    var a0 = ln.u0 - half - margin, a1 = ln.u1 + half;
    var L = vertical ? ln.b0 : a0, T = vertical ? a0 : ln.b0;
    var W = vertical ? ln.b1 - ln.b0 : a1 - a0, H = vertical ? a1 - a0 : ln.b1 - ln.b0;
    var mask = 'linear-gradient(to ' + (vertical ? 'bottom' : 'right') +
        ', #000 calc(100% - ' + (2 * half) + 'px), transparent)';
    var win = document.createElement('div');
    win.className = 'w';
    win.style.cssText = 'left:' + L + 'px;top:' + T + 'px;width:' + W + 'px;height:' + H + 'px;' +
        '-webkit-mask-image:' + mask + ';mask-image:' + mask + ';';
    var inner = document.createElement('div');
    inner.className = 'i';
    inner.style.cssText = 'left:' + (-L) + 'px;top:' + (-T) + 'px;' + boxCss;
    inner.appendChild(tx.cloneNode(true));
    win.appendChild(inner);
    root.appendChild(win);
    var frames = __lyricsSweepFrames(p, start, end, len, total, half);
    if (dur > 0 && frames.length > 1) {
      var fw = [], fi = [];
      for (var f = 0; f < frames.length; f++) {
        fw.push({offset: frames[f].offset, transform: fn + frames[f].shift + 'px)'});
        fi.push({offset: frames[f].offset, transform: fn + (-frames[f].shift) + 'px)'});
      }
      var opts = {duration: dur, fill: 'forwards', easing: 'linear'};
      anims.push(win.animate(fw, opts), inner.animate(fi, opts));
    } else {
      var s0 = __lyricsSweepOffset(p, end, len, total, half);
      win.style.transform = fn + s0 + 'px)';
      inner.style.transform = fn + (-s0) + 'px)';
    }
  }
  host._lyAnims = anims;
  el.classList.add('ly-sw-on');
}
// 排版变了（字号适配 / 主题 / 字体加载完成）：按此刻的进度重搭，进度不跳。
function _lySweepProgressNow(s) {
  if (!_lyPlaying) return s.p0;
  return Math.min(1, s.p0 + Math.max(0, performance.now() - s.t0) / 1000 * s.rate);
}
function _lySweepRelayout() {
  var s = _lySw;
  if (!s || !s.cue) return;
  _lySweepBuild(s.cue, _lySweepProgressNow(s), s.rate);
}
window.__lyricsRelayoutSweep = _lySweepRelayout;
if (document.fonts && document.fonts.addEventListener) {
  document.fonts.addEventListener('loadingdone', function() { _lySweepRelayout(); });
}
// 纯函数：Dart 在 [sentAtMs]（墙钟）按真实播放位置算出 [fraction]；这段脚本可能晚
// 很久才执行（WebView 被节流 / 后台积压），执行时再把这段延迟按播放速率补上，否则
// 扫过会整段落后于声音（BUG-3777 R2）。没带发送时刻（旧调用方）或未在推进时原样返回。
function __lyricsProgressAtArrival(fraction, ratePerSec, sentAtMs, nowMs) {
  var f = Math.max(0, Math.min(1, fraction || 0));
  if (!(ratePerSec > 0) || !(sentAtMs > 0)) return f;
  var lag = nowMs - sentAtMs;
  if (!(lag > 0)) return f;
  return Math.min(1, f + lag / 1000 * ratePerSec);
}
window.__lyricsSetProgress = function(index, fraction, ratePerSec, sentAtMs) {
  if (index !== _currentIdx || !_lyPlaying) return;
  var el = _cues[index];
  if (!el) return;
  var rate = ratePerSec > 0 ? ratePerSec : 0;
  _lySweepBuild(el, __lyricsProgressAtArrival(fraction, rate, sentAtMs, Date.now()), rate);
};
// 播放态：暂停时当前行整行点亮（不扫）、并停掉自动回到当前行的计时；继续播放时
// 若用户正停在别处浏览，重新起 4 秒回中计时。
window.__lyricsSetPlaying = function(playing) {
  var was = _lyPlaying;
  // 暂停：把进度冻在此刻并拆掉扫过层（隐藏着的动画会退回主线程空转）；继续：从冻结
  // 处接着推（随后的 __lyricsSetProgress 会再按真实播放位置校准一次）。
  if (was && !playing && _lySw) _lySw.p0 = _lySweepProgressNow(_lySw);
  _lyPlaying = !!playing;
  document.body.classList.toggle('ly-paused', !_lyPlaying);
  // 播放态没变（Dart 每次同步都会先下发一次）：不动扫过层，进度由紧随的
  // __lyricsSetProgress 校准。
  if (_lySw && was !== _lyPlaying) {
    _lySw.t0 = performance.now();
    if (_lyPlaying) _lySweepRelayout();
    else _lySweepClearCue(_lySw.cue);
  }
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
  if (!e[window.__fushiHoverKey || 'shiftKey'] && !window.__hoverAutoLookup) { _shiftHoverLastX = -1; _shiftHoverLastY = -1; return; }
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
    // 跳读灰显行不查词：它不属于任何 cue，查词 / 制卡会拿当前句的音频与句子
    // 去配一段根本没念过的正文。
    if (hitEl && hitEl.closest('.ly-gap')) {
      window.__lyricsCueContext = null;
      return;
    }
    var cueEl = hitEl ? hitEl.closest('.cue') : null;
    if (cueEl) {
      // 查词高亮落在这一行：停掉逐字扫过（扫过用透明字 + 背景裁切，会把查词底块
      // 里的字一起「挖空」），换行后自动恢复。
      cueEl.classList.add('ly-nosweep');
      _lySweepClearCue(cueEl);
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
    } else if (r.selectorText === '.ly-gap') {
      if (!themed) r.style.color = textColor;
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
    } else if (r.type === CSSRule.STYLE_RULE && r.selectorText === '.cue.current ruby.fushi-selection-ruby-active') {
      r.style.color = bgColor;
    } else if (r.selectorText === '.fushi-dict-highlight' ||
        r.selectorText === 'ruby.fushi-selection-ruby-active') {
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

// 跳读灰显开关热更（`lyrics_show_skipped_text`）：只换 body class。行高变了，
// 跟随态下把当前句重新对准锚点。
window.__lyricsSetShowSkipped = function(on) {
  var hide = !on;
  if (document.body.classList.contains('ly-hide-skipped') === hide) return;
  document.body.classList.toggle('ly-hide-skipped', hide);
  if (_currentIdx >= 0 && _currentIdx < _cues.length && !_lyBrowsing) {
    _lyricsScrollByAxis(_lyricsCenterDelta(_cues[_currentIdx]));
  }
};

// TODO-1080: shrink any over-long cue before positioning so the initial-scroll
// geometry (and the caret ring) is measured against the final, fitted sizes.
__lyricsFitCues();

// ── 初始定位（即时跳转，不用动画，避免与 Dart 端 setCue 竞争） ──
// TODO-907: 同样走 delta 增量滚动，横竖排一致；竖排 vertical-rl 的负向 scrollX
// 用 scrollBy 增量打到位，不硬算绝对坐标。
_currentIdx = $currentIndex;
// 零视口下算出的居中增量没有意义（见 __lyricsHasViewport）：推迟到第一次拿到真实
// 视口的 resize 再定位，只做一次。
var _lyInitPending = true;
function _lyInitialPosition() {
  if (!_lyInitPending || !__lyricsHasViewport()) return;
  _lyInitPending = false;
  var el = (_currentIdx >= 0 && _currentIdx < _cues.length) ? _cues[_currentIdx] : null;
  if (el) _lyricsScrollByAxis(_lyricsCenterDelta(el));
}
_lyInitialPosition();
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

  /// 歌词正文的字体回退链（BUG-3281）。内容语言为 CJK 时与正文同源的 CJK 链；
  /// 否则（非 CJK / 未知）通用族：无主题 `serif`（同正文 `_bodyFontFamily`），
  /// 覆盖层主题 `system-ui, -apple-system, sans-serif`。
  static String _lyricsFallbackFonts({
    required String? contentLanguage,
    required TargetPlatform platform,
    required bool themed,
  }) {
    final String chain = contentFontFamilyCss(
      languageTag: contentLanguage,
      platform: platform,
      style: themed ? CjkFontStyle.sansSerif : CjkFontStyle.serif,
    );
    if (chain.isNotEmpty) return chain;
    return themed ? 'system-ui, -apple-system, sans-serif' : 'serif';
  }

  /// CSS 关键字白名单化：只放行字母与连字符（`mixed` / `upright` / `sideways`），
  /// 其余回落 `mixed`——偏好值来自持久化存储，不直接拼进样式表。
  static String _cssIdent(String value) =>
      RegExp(r'^[a-z-]+$').hasMatch(value) ? value : 'mixed';

  static String _escapeAttr(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}
