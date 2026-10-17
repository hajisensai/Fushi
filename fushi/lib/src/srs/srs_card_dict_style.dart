/// 卡面释义区的词典样式处理（宿主脚本，随外壳加载一次）：
///
/// - **统一词典样式（M3E）开**（`.card.fushi-srs-dict-unified`）：移植查词弹窗的
///   `__fushiUnifyDictStyles`（fushi/assets/popup/popup.js「词典样式统一」一节）。导入词典
///   的 styles.css / 结构化内容 inline style 各自写死颜色，这里在渲染后**量一次**每个元素的
///   计算样式（量的时候统一层不生效，量到的是词典原色），按语义写成 `data-fushi-dt*` 属性
///   （chip / block / panel / chip-outline / accent / muted / plain / flat），给作用域挂
///   `fc-dt-ready`；配色全在模板 styling.css 里按卡面令牌取。之后换明暗 / 换强调色只是 CSS
///   变量变化，开关切换只是宿主类名变化，都不必重新分类。
/// - **关**：词典原样式原样显示；深色下把为白纸设计的浅底块调暗、其上的深色字调亮
///   （移植 popup.js `__fushiToneDictColors`），另把近黑的正文色调亮（深色卡面上读不出来）。
///   切回浅色 / 打开统一时先把写过的内联色全部还原。
///
/// 作用域只认 Fushi 卡片模板的释义（`.fc-gloss li[data-dictionary]`），别的模板不受影响。
/// 分类判据与常量逐字取自 popup.js，不按词典名写特例；改判据时两边同步（守卫测试比对常量）。
/// 量与写分相（先读完全部计算样式再统一写），整批只重算两次样式。
library;

/// 「短」标签的字数上限（与 popup.js FUSHI_DICT_UNIFIED_CHIP_MAX_CHARS 同值）。
const int kSrsDictUnifiedChipMaxChars = 16;

/// 不参与分类的节点（与 popup.js FUSHI_DICT_UNIFIED_SKIP 同值）。
const String kSrsDictUnifiedSkip =
    'img, svg, svg *, canvas, video, audio, picture, '
    '.gloss-image-background, .gloss-image-sizer, .ruby-reserve, .deinflection-tag';

/// 宿主脚本：定义 `window.__fushiSrsDictStyle()`（换卡 / 换主题后由外壳调用）。
const String kSrsCardDictStyleScript =
    '''
(function(){
  if (window.__fushiSrsDictStyle) return;
  var CHIP_MAX = $kSrsDictUnifiedChipMaxChars;
  // 外加卡面自己画的义项标签（它们已经吃卡面令牌）。
  var SKIP = '$kSrsDictUnifiedSkip, .fc-tags, .fc-tags *';
  var ATTRS = ['data-fushi-dt', 'data-fushi-dt-pad', 'data-fushi-dt-before', 'data-fushi-dt-after'];
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
  function hslCss(h, s, l, a){
    var hh = Math.round(h), ss = Math.round(s * 100), ll = Math.round(l * 100);
    return a < 1 ? 'hsla(' + hh + ',' + ss + '%,' + ll + '%,' + (Math.round(a * 100) / 100) + ')'
      : 'hsl(' + hh + ',' + ss + '%,' + ll + '%)';
  }
  function solidBg(bg){
    if (!bg || bg.a < 0.12) return false;
    var x = hsl(bg);
    return !(x.s < 0.12 && x.l > 0.92);
  }
  function sameColor(a, b){
    if (!a || !b) return false;
    return Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b) <= 12 && Math.abs(a.a - b.a) < 0.1;
  }
  function textTone(c){
    if (!c || c.a < 0.3) return null;
    var x = hsl(c);
    if (x.s >= 0.25 && x.l >= 0.12 && x.l <= 0.88) return 'accent';
    if (x.l > 0.88) return null;
    if (x.l >= 0.3) return 'muted';
    return 'plain';
  }
  function fullBorder(cs){
    var sides = ['Top', 'Right', 'Bottom', 'Left'];
    for (var i = 0; i < sides.length; i++) {
      if (!(parseFloat(cs['border' + sides[i] + 'Width']) > 0)) return false;
      var st = cs['border' + sides[i] + 'Style'];
      if (!st || st === 'none' || st === 'hidden') return false;
    }
    var c = parseRgb(cs.borderTopColor);
    return !!(c && c.a > 0.2);
  }

  /* 读相：同 popup.js __fushiDictUnifiedClassify（px = 量到的计算字号，只用于分类，不写回）。 */
  function classify(scope, writes){
    var scs = getComputedStyle(scope);
    var info = new Map();
    info.set(scope, { color: parseRgb(scs.color), px: parseFloat(scs.fontSize) || 0, ctx: null });
    var nodes = scope.querySelectorAll('*');
    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n];
      var pi = info.get(node.parentElement) || info.get(scope);
      for (var k = 0; k < ATTRS.length; k++) {
        if (node.hasAttribute(ATTRS[k])) writes.push([node, ATTRS[k], null]);
      }
      if (node.matches(SKIP)) { info.set(node, pi); continue; }
      var cs = getComputedStyle(node);
      var color = parseRgb(cs.color);
      var px = parseFloat(cs.fontSize) || pi.px;
      var bg = parseRgb(cs.backgroundColor);
      var gradient = /gradient\\(/i.test(cs.backgroundImage || '');
      var hasBg = gradient || solidBg(bg);
      var inline = /^(inline|ruby)/.test(cs.display || '');
      var textLen = (node.textContent || '').trim().length;
      var tag = null;
      if (hasBg && pi.ctx !== 'chip') {
        var big = pi.px > 0 && px >= pi.px * 1.4;
        if (inline && !big && textLen <= CHIP_MAX) {
          tag = 'chip';
        } else {
          var x = bg ? hsl(bg) : { s: 1, l: 0.5 };
          tag = (!gradient && x.l > 0.8) ? 'panel' : 'block';
        }
        if (tag === 'chip' && !(parseFloat(cs.paddingLeft) >= 1)) writes.push([node, 'data-fushi-dt-pad', '']);
      } else if (!hasBg && pi.ctx === null && inline && textLen > 0 && textLen <= CHIP_MAX && fullBorder(cs)) {
        tag = 'chip-outline';
      } else if (gradient) {
        tag = 'flat';
      }
      if (tag === null && pi.ctx !== 'chip' && !sameColor(color, pi.color)) {
        var tone = textTone(color);
        if (tone === 'accent' || (tone && pi.ctx === null)) tag = tone;
      }
      if (tag) writes.push([node, 'data-fushi-dt', tag]);
      ['before', 'after'].forEach(function(pseudo){
        var ps = getComputedStyle(node, '::' + pseudo);
        var content = ps && ps.content;
        if (!content || content === 'none' || content === 'normal') return;
        var pbg = parseRgb(ps.backgroundColor), ptag = null;
        if (/gradient\\(/i.test(ps.backgroundImage || '') || solidBg(pbg)) ptag = 'chip';
        else if (!sameColor(parseRgb(ps.color), color) && textTone(parseRgb(ps.color)) === 'accent') ptag = 'accent';
        if (ptag) writes.push([node, 'data-fushi-dt-' + pseudo, ptag]);
      });
      var ctx = (tag === 'chip' || tag === 'block' || tag === 'panel' || tag === 'chip-outline')
        ? (tag === 'chip-outline' ? 'chip' : tag) : pi.ctx;
      info.set(node, { color: ctx !== pi.ctx ? null : color, px: px, ctx: ctx });
    }
  }

  function unify(scopes){
    var todo = scopes.filter(function(s){ return !s.__fushiDtDone; });
    if (!todo.length) return;
    todo.forEach(function(s){ s.classList.remove('fc-dt-ready'); s.classList.add('fc-dt-measuring'); });
    var writes = [];
    try {
      todo.forEach(function(s){ classify(s, writes); });
    } finally {
      todo.forEach(function(s){ s.classList.remove('fc-dt-measuring'); });
    }
    writes.forEach(function(w){
      if (w[2] === null) w[0].removeAttribute(w[1]); else w[0].setAttribute(w[1], w[2]);
    });
    todo.forEach(function(s){ s.__fushiDtDone = true; s.classList.add('fc-dt-ready'); });
  }

  function remember(node, prop){
    var key = prop === 'color' ? '__fcOrigColor' : '__fcOrigBg';
    if (node[key]) return;
    node[key] = { value: node.style.getPropertyValue(prop), priority: node.style.getPropertyPriority(prop) };
    toned.push(node);
  }
  function restoreTone(){
    toned.forEach(function(node){
      [['__fcOrigBg', 'background-color'], ['__fcOrigColor', 'color']].forEach(function(kp){
        var o = node[kp[0]];
        if (!o) return;
        if (o.value) node.style.setProperty(kp[1], o.value, o.priority);
        else node.style.removeProperty(kp[1]);
        node[kp[0]] = null;
      });
      node.__fcToned = false;
    });
    toned = [];
  }

  /* 深色 + 不统一：浅底块调暗、其上深字调亮（popup.js __fushiToneDictColors），近黑正文调亮。 */
  function tone(scopes){
    var nodes = [];
    scopes.forEach(function(s){
      nodes.push(s);
      s.querySelectorAll('*').forEach(function(n){ nodes.push(n); });
    });
    var bgs = [], texts = [];
    nodes.forEach(function(node){
      if (node.__fcToned || node.tagName === 'IMG' || node.tagName === 'svg' || node.matches(SKIP)) return;
      node.__fcToned = true;
      var cs = getComputedStyle(node);
      var bg = parseRgb(cs.backgroundColor);
      if (bg && bg.a >= 0.25 && lum(bg) > 0.35) bgs.push({ node: node, bg: bg });
      var fg = parseRgb(cs.color);
      if (fg && lum(fg) < 0.06) texts.push({ node: node, fg: fg });
    });
    bgs.forEach(function(it){
      it.node.querySelectorAll('*').forEach(function(n){
        var fg = parseRgb(getComputedStyle(n).color);
        if (fg && lum(fg) < 0.3) texts.push({ node: n, fg: fg });
      });
    });
    bgs.forEach(function(it){
      var x = hsl(it.bg);
      remember(it.node, 'background-color');
      it.node.style.setProperty('background-color', hslCss(x.h, Math.min(x.s, 0.5), 0.22, it.bg.a), 'important');
    });
    texts.forEach(function(it){
      var x = hsl(it.fg);
      remember(it.node, 'color');
      it.node.style.setProperty('color', hslCss(x.h, Math.min(x.s, 0.6), 0.82, it.fg.a), 'important');
    });
  }

  window.__fushiSrsDictStyle = function(){
    var root = document.getElementById('fushi-card-root');
    if (!root || typeof getComputedStyle !== 'function') return;
    var scopes = Array.prototype.slice.call(root.querySelectorAll('.fc-gloss li[data-dictionary]'));
    if (!scopes.length) { toned = []; return; }
    var cls = document.body.classList;
    restoreTone();
    if (cls.contains('fushi-srs-dict-unified')) {
      unify(scopes);
      return;
    }
    if (cls.contains('nightMode')) tone(scopes);
  };
})();
''';
