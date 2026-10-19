/// 卡面「跟随设计系统」样式覆盖（[SrsCardAppearance.designSkin]）：给内置「Fushi 卡片」以外的
/// 卡（Anki 导入牌组、Lapis、用户自建类型）套上当前设计系统的外观层。
///
/// 只换**外观类**样式，不碰布局与内容语义：
/// - 卡面底（body / `.card`）、正文色、字体 → 设计系统的表面色 / onSurface / 界面字体链；
/// - 模板画的中性色块（米色纸底、灰底框）→ 与卡面同色的透明 / 表面容器色，圆角换成设计系统
///   形状令牌，去掉阴影；中性色描边（细灰框、`<hr>`）→ outlineVariant；
/// - 中性色文字 → onSurface / onSurfaceVariant；链接 → primary；
/// - **有彩色**（高亮、音调配色、词性标签等承载语义的颜色）原样保留；深色下只把为白纸设计的
///   深色字调亮、亮色块调暗（同释义区的深色调色，见 srs_card_dict_style.dart）。
///
/// 判定在页内做（[kSrsCardDesignSkinScript]）：换卡 / 换主题后先关掉覆盖层量一次计算样式，
/// 按上面的语义写 `data-fushi-ds` 属性，配色全在 [srsCardDesignSkinCss] 的变量里，切明暗 / 换
/// 强调色只是变量变化。
///
/// 关闭时**零注入**：主题样式里没有任何覆盖规则、`.card` 上没有宿主类名、外壳里也不下发判定
/// 脚本，模板按自身 HTML/CSS 原样渲染（与 Anki 一致）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_card_appearance.dart'
    show
        kSrsCardDefaultFontJa,
        kSrsCardDefaultFontUi,
        kSrsCardDefaultFontZh,
        srsCardCssColor;
import 'package:fushi/src/srs/srs_card_tokens.dart';

/// 覆盖开着时挂在 body / 卡面根节点上的宿主类名。
const String kSrsDesignSkinClass = 'fushi-srs-ds';

/// 判定期间挂在 `<html>` 上的类名：覆盖层整体失效，量到的是模板原样。
const String kSrsDesignSkinMeasuringClass = 'fushi-ds-measuring';

/// 覆盖层的字体链：Apple = 系统字体（SF）在前；MD3 = 界面字体链（与 Fushi 卡片模板默认的
/// `--fc-font-ui` 同一份）。日文 / 中文按卡面 `lang` 换对应字形的回落链。
@visibleForTesting
String srsCardDesignSkinFont({required bool apple}) => apple
    ? '-apple-system, "SF Pro Text", system-ui, "Segoe UI", $kSrsCardDefaultFontJa'
    : kSrsCardDefaultFontUi;

/// 覆盖层样式（追加在主题样式里）：变量 + 按 `data-fushi-ds` 语义取色的规则。
///
/// 选择器带 `html:not(.fushi-ds-measuring) body.card.fushi-srs-ds` 前缀：特异度高于模板常见的
/// `.card` / `.nightMode .card` 规则，且判定脚本量样式时整层失效。
String srsCardDesignSkinCss({
  required ColorScheme scheme,
  required SrsCardTokens tokens,
}) {
  const String s =
      'html:not(.$kSrsDesignSkinMeasuringClass) body.card.$kSrsDesignSkinClass';
  const String r = '$s #fushi-card-root';
  final String font = srsCardDesignSkinFont(apple: tokens.apple);
  String px(double v) => '${v.toStringAsFixed(1).replaceFirst('.0', '')}px';
  return ':root{'
      '--fushi-ds-bg:${srsCardCssColor(scheme.surface)};'
      '--fushi-ds-fg:${srsCardCssColor(scheme.onSurface)};'
      '--fushi-ds-fg-muted:${srsCardCssColor(scheme.onSurfaceVariant)};'
      '--fushi-ds-surface:${srsCardCssColor(tokens.surface1(scheme))};'
      '--fushi-ds-outline:${srsCardCssColor(scheme.outlineVariant)};'
      '--fushi-ds-link:${srsCardCssColor(scheme.primary)};'
      '--fushi-ds-radius:${px(tokens.radius)};'
      '--fushi-ds-radius-small:${px(tokens.radiusSmall)};'
      '--fushi-ds-font:$font;}'
      '$s,$r.card{background:var(--fushi-ds-bg)!important;'
      'color:var(--fushi-ds-fg)!important;'
      'font-family:var(--fushi-ds-font)!important;}'
      '$s [lang|="zh"]{--fushi-ds-font:system-ui, $kSrsCardDefaultFontZh;'
      'font-family:var(--fushi-ds-font)!important;}'
      '$s [lang|="ja"]{--fushi-ds-font:$font;}'
      '$r [data-fushi-ds~="page"]{background-color:transparent!important;'
      'background-image:none!important;}'
      '$r [data-fushi-ds~="panel"]{background-color:var(--fushi-ds-surface)!important;'
      'background-image:none!important;}'
      '$r [data-fushi-ds~="border"]{border-color:var(--fushi-ds-outline)!important;}'
      '$r [data-fushi-ds~="box"]{border-radius:var(--fushi-ds-radius-small)!important;'
      'box-shadow:none!important;}'
      '$r [data-fushi-ds~="frame"]{border-radius:var(--fushi-ds-radius)!important;'
      'box-shadow:none!important;}'
      '$r [data-fushi-ds~="text"]{color:var(--fushi-ds-fg)!important;}'
      '$r [data-fushi-ds~="muted"]{color:var(--fushi-ds-fg-muted)!important;}'
      '$r [data-fushi-ds~="font"]{font-family:var(--fushi-ds-font)!important;}'
      '$r a[href],$r a[href] *{color:var(--fushi-ds-link)!important;}'
      '$r hr{border-color:var(--fushi-ds-outline)!important;}';
}

/// 页内判定脚本：定义 `window.__fushiSrsDesignSkin()`（外壳在换卡的卡片脚本 / 钩子跑完后、
/// 换主题后调用；见 srs_card_face.dart 的外壳脚本）。只在覆盖开着时随主题调用下发，幂等。
///
/// 每次调用先清掉上一轮写的属性与内联调色，再看 body 是否挂着 [kSrsDesignSkinClass]：没挂
/// （刚关掉覆盖）就到此为止——模板恢复原样。读写分相：先在覆盖层失效的状态下读完全部计算
/// 样式，再统一写属性。
const String kSrsCardDesignSkinScript =
    '''
(function(){
  if (window.__fushiSrsDesignSkin) return;
  var SKIN = '$kSrsDesignSkinClass', MEASURING = '$kSrsDesignSkinMeasuringClass';
  var SKIP = 'img, svg, svg *, canvas, video, audio, picture, iframe, object, embed, script, style, br, source, track';
  var MAX_NODES = 4000;
  var toned = [];

  function parseRgb(v){
    var m = /^rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+)(%?))?\\s*\\)\$/.exec(String(v || '').trim());
    if (!m) return null;
    var a = m[4] === undefined ? 1 : parseFloat(m[4]);
    if (m[5] === '%') a /= 100;
    return { r: +m[1], g: +m[2], b: +m[3], a: a };
  }
  function lum(c){
    function ch(v){ v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }
  function light(c){ return (Math.max(c.r, c.g, c.b) + Math.min(c.r, c.g, c.b)) / 510; }
  /* 中性色：色度（max − min）小。米色纸底 #fdf8ec 的 HSL 饱和度很高但色度只有 0.07。 */
  function neutral(c){ return (Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b)) / 255 < 0.12; }
  function sameColor(a, b){
    if (!a || !b) return false;
    return Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b) <= 12;
  }
  function hsl(c){
    var r = c.r / 255, g = c.g / 255, b = c.b / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
    if (max === min) return { h: 0, s: 0, l: l };
    var d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min), h;
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    return { h: h * 60, s: s, l: l };
  }
  function hslCss(c, l){
    var x = hsl(c);
    return 'hsla(' + Math.round(x.h) + ',' + Math.round(Math.min(x.s, 0.7) * 100) + '%,'
      + Math.round(l * 100) + '%,' + (Math.round(c.a * 100) / 100) + ')';
  }
  function borderSides(cs){
    var sides = ['Top', 'Right', 'Bottom', 'Left'], n = 0, colored = false;
    for (var i = 0; i < 4; i++) {
      var st = cs['border' + sides[i] + 'Style'];
      if (!(parseFloat(cs['border' + sides[i] + 'Width']) > 0) || !st || st === 'none' || st === 'hidden') continue;
      var c = parseRgb(cs['border' + sides[i] + 'Color']);
      if (!c || c.a < 0.2) continue;
      if (!neutral(c)) colored = true;
      n++;
    }
    return colored ? -1 : n;
  }

  function restore(root){
    var marked = root.querySelectorAll('[data-fushi-ds]');
    for (var i = 0; i < marked.length; i++) marked[i].removeAttribute('data-fushi-ds');
    if (root.hasAttribute('data-fushi-ds')) root.removeAttribute('data-fushi-ds');
    toned.forEach(function(t){
      if (t.value) t.node.style.setProperty(t.prop, t.value, t.priority);
      else t.node.style.removeProperty(t.prop);
    });
    toned = [];
  }

  function classify(root, dark, writes, tones){
    var bcs = getComputedStyle(document.body);
    var rcs = getComputedStyle(root);
    var cardBg = parseRgb(rcs.backgroundColor);
    if (!cardBg || cardBg.a < 0.35) cardBg = parseRgb(bcs.backgroundColor);
    var cardFg = parseRgb(rcs.color);
    var cardFont = rcs.fontFamily;
    var rootW = root.getBoundingClientRect().width || window.innerWidth;
    var all = root.querySelectorAll('*');
    var n = Math.min(all.length, MAX_NODES);
    for (var i = -1; i < n; i++) {
      var node = i < 0 ? root : all[i];
      if (i >= 0 && node.matches(SKIP)) continue;
      var cs = i < 0 ? rcs : getComputedStyle(node);
      var tags = [];
      var bg = parseRgb(cs.backgroundColor);
      var gradient = /gradient\\(/i.test(cs.backgroundImage || '');
      var block = false;
      if (bg && bg.a >= 0.35 && !gradient) {
        if (i < 0 || sameColor(bg, cardBg)) tags.push('page');
        else if (neutral(bg)) { tags.push('panel'); block = true; }
        else if (dark && lum(bg) > 0.45) tones.push({ node: node, prop: 'background-color', value: hslCss(bg, 0.24) });
      }
      var sides = borderSides(cs);
      if (sides > 0) {
        tags.push('border');
        if (sides === 4) block = true;
      }
      if (block && i >= 0) {
        tags.push(node.getBoundingClientRect().width >= rootW * 0.6 ? 'frame' : 'box');
      }
      var c = parseRgb(cs.color);
      if (c && c.a >= 0.3) {
        if (neutral(c)) {
          var lc = light(c), lf = cardFg ? light(cardFg) : lc, lb = cardBg ? light(cardBg) : 1 - lf;
          var between = (lc - lf) * (lc - lb) < 0 && Math.abs(lc - lf) > 0.2;
          if (i >= 0) tags.push(between ? 'muted' : 'text');
        } else if (dark && lum(c) < 0.18) {
          tones.push({ node: node, prop: 'color', value: hslCss(c, 0.78) });
        }
      }
      if (i >= 0 && cs.fontFamily === cardFont) tags.push('font');
      if (tags.length) writes.push([node, tags.join(' ')]);
    }
  }

  window.__fushiSrsDesignSkin = function(){
    var root = document.getElementById('fushi-card-root');
    if (!root || typeof getComputedStyle !== 'function') return;
    restore(root);
    if (!document.body.classList.contains(SKIN)) return;
    var dark = document.body.classList.contains('nightMode');
    var html = document.documentElement;
    var writes = [], tones = [];
    html.classList.add(MEASURING);
    try {
      classify(root, dark, writes, tones);
    } finally {
      html.classList.remove(MEASURING);
    }
    for (var i = 0; i < writes.length; i++) writes[i][0].setAttribute('data-fushi-ds', writes[i][1]);
    tones.forEach(function(t){
      toned.push({ node: t.node, prop: t.prop,
        value: t.node.style.getPropertyValue(t.prop), priority: t.node.style.getPropertyPriority(t.prop) });
      t.node.style.setProperty(t.prop, t.value, 'important');
    });
  };
})();
''';
