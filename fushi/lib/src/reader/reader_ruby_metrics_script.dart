/// BUG-2779：WebKit（iOS / macOS）振假名贴回本行/本列所需的字体度量，运行时量出来。
///
/// WebKit 把注音盒的边框盒底贴在基字的**内容区**顶（竖排是右缘），注音与基字之间
/// 夹着两截空白：① 基字内容区超出其 em 盒的部分（字体 ascent + descent 比 1em 大多少）；
/// ② 注音盒自己的 `line-height: normal` 半行距（WebKit 不理会 rt 上的 line-height）。
/// 两截都只由字体度量决定，CSS 里拿不到——BUG-2724 的固定 `-0.2em` 是按 Hiragino
/// 标定的，Hiragino 的内容区几乎就是 em 盒；换成 Klee One（ascent+descent = 1.45em）
/// 这类字体后注音离本列 6px、贴上一列（iOS 26.5 模拟器实测，22px）。
///
/// 这里在页面里直接量一个真实 `<ruby>`：基字 Range 的块轴尺寸 = 内容区，`<rt>` 盒的块轴
/// 尺寸 = 注音盒；竖排 em 盒在内容区里居中，横排 em 盒位置用 canvas 量汉字墨迹中心推出
/// （WebKit 的 `emHeightAscent` 就是 ascent，不可用）。两截空白之和折成注音字号的倍数写进
/// `--fushi-ruby-pull`，由 `ReaderContentStyles` 的 Apple 注音规则消费
/// （`margin-block-end: calc(-1em * var(--fushi-ruby-pull, 0.1) - 0.1em)`，缺省即旧的
/// `-0.2em`）。改的是注音盒的负块尾边距，注音在流中的高度早被 BUG-2472 的负
/// `margin-block-start` 抵消到 0，所以写入变量不会让行盒 / 分页几何变化。
///
/// 只在 Apple 注音规则打出的 `--fushi-ruby-snap: 1` 标记存在时工作（Blink 注音本就贴
/// 基字）。触发：安装时、字体就绪、`document.fonts` 每次加载完成、`#fushi-reader-style`
/// 内容被实时换掉（改字体 / 字号走这条）。
const String kReaderRubyMetricsJs = r'''
(function() {
  if (window.__fushiRubyMetrics) return;
  var scheduled = false;
  function inkCenterAboveBaseline(font) {
    try {
      var ctx = document.createElement('canvas').getContext('2d');
      ctx.font = font;
      var m = ctx.measureText('永');
      if (!(m.fontBoundingBoxAscent > 0)) return null;
      return {
        ascent: m.fontBoundingBoxAscent,
        descent: m.fontBoundingBoxDescent,
        inkCenter: (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent) / 2
      };
    } catch (e) { return null; }
  }
  function canvasFont(cs) {
    return cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  }
  function probeRuby() {
    var list = document.body ? document.body.getElementsByTagName('ruby') : [];
    for (var i = 0; i < list.length && i < 50; i++) {
      var ruby = list[i];
      var rt = ruby.querySelector('rt');
      // 基字文本可能包在 <rb> 或有声书跟随高亮的 wrapper 里（BUG-2806：wrapper 落在 ruby
      // 内部），所以按文档序找第一个不在 rt / rp 里的非空文本节点。
      var base = null;
      var walker = document.createTreeWalker(ruby, NodeFilter.SHOW_TEXT);
      for (var t = walker.nextNode(); t; t = walker.nextNode()) {
        var owner = t.parentNode;
        if (owner && owner.closest && owner.closest('rt, rp')) continue;
        if (t.nodeValue.trim()) { base = t; break; }
      }
      if (!rt || !base) continue;
      var tr = rt.getBoundingClientRect();
      if (!(tr.width > 0 && tr.height > 0)) continue;
      return { ruby: ruby, rt: rt, base: base, rtRect: tr };
    }
    return null;
  }
  function measure() {
    scheduled = false;
    var root = document.documentElement;
    if (!root || !document.body) return;
    if (getComputedStyle(root).getPropertyValue('--fushi-ruby-snap').trim() !== '1') return;
    var p = probeRuby();
    if (!p) return;
    var range = document.createRange();
    range.selectNodeContents(p.base);
    var br = range.getBoundingClientRect();
    var rcs = getComputedStyle(p.ruby);
    var tcs = getComputedStyle(p.rt);
    var fs = parseFloat(rcs.fontSize);
    var rfs = parseFloat(tcs.fontSize);
    if (!(fs > 0 && rfs > 0)) return;
    var vertical = rcs.writingMode.indexOf('vertical') === 0 ||
        rcs.writingMode.indexOf('sideways') === 0;
    var baseBox = vertical ? br.width : br.height;
    var rtBox = vertical ? p.rtRect.width : p.rtRect.height;
    if (!(baseBox > 0 && rtBox > 0)) return;
    var baseExtra, rtExtra;
    if (vertical) {
      // 竖排直立字形在内容区里居中，em 盒即内容区中线 ± 0.5em。
      baseExtra = (baseBox - fs) / 2;
      rtExtra = (rtBox - rfs) / 2;
    } else {
      var bm = inkCenterAboveBaseline(canvasFont(rcs));
      var tm = inkCenterAboveBaseline(canvasFont(tcs));
      if (!bm || !tm) return;
      // 基字：内容区顶 → em 盒顶（em 盒以汉字墨迹中心为中线）。
      baseExtra = bm.ascent - (bm.inkCenter + fs / 2);
      // 注音：em 盒底 → 注音盒底（盒 = 内容区 + 上下各半个行距）。
      var halfLeading = (rtBox - (tm.ascent + tm.descent)) / 2;
      rtExtra = halfLeading + tm.descent - (rfs / 2 - tm.inkCenter);
    }
    var pull = (baseExtra + rtExtra) / rfs;
    if (!isFinite(pull)) return;
    pull = Math.max(0, Math.min(1.5, pull));
    root.style.setProperty('--fushi-ruby-pull', pull.toFixed(3));
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(measure);
  }
  window.__fushiRubyMetrics = { measure: measure, schedule: schedule };
  try {
    if (document.fonts) {
      if (document.fonts.ready) document.fonts.ready.then(schedule);
      if (document.fonts.addEventListener) document.fonts.addEventListener('loadingdone', schedule);
    }
  } catch (e) {}
  try {
    var style = document.getElementById('fushi-reader-style');
    if (style && window.MutationObserver) {
      new MutationObserver(schedule).observe(style, { childList: true, characterData: true, subtree: true });
    }
  } catch (e) {}
  schedule();
})();
''';
