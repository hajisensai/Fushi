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
/// 内容被实时换掉（改字体 / 字号走这条）；在为当前字体量成功之前，`body` 子树的节点
/// 增删也会再量（BUG-2810：VN 的 `body` 只放当前屏，开书那屏常常没有注音）。
///
/// BUG-2810：量的必须是**排成一整段**的注音盒。分页多列里落在页顶那一行的注音会伸出
/// 本栏顶、被切进上一栏（BUG-2761 的几何；页顶预留按行高算，度量写入前的缺省拉力下
/// Klee One 这类字体照样伸出去），这时 `<rt>` 有两个 client rect，
/// `getBoundingClientRect` 是两栏的并集——竖排宽 ≈ 整页。拿它当注音盒，拉力直接顶到
/// 上限 1.5，整章注音压进基字（iOS 模拟器 Safari、俺ガイル真章节 + 生产 CSS：首颗注音
/// 「由」在第 3 页首列，`<rt>` 2 段、并集 385.9 × 818px，写出 1.500）。所以跨栏的注音
/// 跳过、换下一颗量；基字只量第一个非空白字符的单字 Range，同样只认一段。
const String kReaderRubyMetricsJs = r'''
(function() {
  if (window.__fushiRubyMetrics) return;
  var scheduled = false;
  // 还没为当前字体量成功（本页还没有排出来的注音，或换字体 / 样式后还没重量）。
  // BUG-2810：VN 把整章挪进脱离文档的 sourceRoot、body 里只剩当前屏，开书时首屏常常
  // 没有注音；只在安装 / 字体 / 样式时量一次就永远写不进变量，注音落回缺省拉力。
  // 所以挂着这个标记时，body 子树的节点增删（换屏、换章、懒加载）都再量一次。
  var pending = true;
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
  // 只认排成一整段的盒：分页页顶被切进上一栏的注音有两个 client rect（BUG-2810）。
  function singleRect(rects) {
    if (!rects || rects.length !== 1) return null;
    var r = rects[0];
    return r.width > 0 && r.height > 0 ? r : null;
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
      var tr = singleRect(rt.getClientRects());
      if (!tr) continue;
      // 内容区高度逐字相同，量第一个非空白字符（代理对取两个码元）就够，也不会跨行。
      var text = base.nodeValue;
      var at = text.search(/\S/);
      var code = text.charCodeAt(at);
      var end = at + (code >= 0xD800 && code <= 0xDBFF && at + 1 < text.length ? 2 : 1);
      var range = document.createRange();
      range.setStart(base, at);
      range.setEnd(base, end);
      var br = singleRect(range.getClientRects());
      if (!br) continue;
      return { ruby: ruby, rt: rt, rtRect: tr, baseRect: br };
    }
    return null;
  }
  function measure() {
    scheduled = false;
    var root = document.documentElement;
    if (!root || !document.body) return;
    // 先做最便宜的判断：body 里一颗 ruby 都没有就不碰样式 / 布局（pending 期间每次
    // 节点增删都会走到这里）。
    if (!document.body.getElementsByTagName('ruby').length) return;
    if (getComputedStyle(root).getPropertyValue('--fushi-ruby-snap').trim() !== '1') return;
    var p = probeRuby();
    if (!p) return;
    var br = p.baseRect;
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
    pending = false;
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(measure);
  }
  // 字体 / 样式变了：旧值不再可信，重新挂起直到量成功。
  function remeasure() {
    pending = true;
    schedule();
  }
  window.__fushiRubyMetrics = { measure: measure, schedule: remeasure };
  try {
    if (document.fonts) {
      if (document.fonts.ready) document.fonts.ready.then(remeasure);
      if (document.fonts.addEventListener) document.fonts.addEventListener('loadingdone', remeasure);
    }
  } catch (e) {}
  try {
    var style = document.getElementById('fushi-reader-style');
    if (style && window.MutationObserver) {
      new MutationObserver(remeasure).observe(style, { childList: true, characterData: true, subtree: true });
    }
  } catch (e) {}
  try {
    if (document.body && window.MutationObserver) {
      new MutationObserver(function() { if (pending) schedule(); })
        .observe(document.body, { childList: true, subtree: true });
    }
  } catch (e) {}
  schedule();
})();
''';
