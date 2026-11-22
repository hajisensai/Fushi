import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_card_defs_layout.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';

/// 复习页释义里的词典插图（拍板台 w4RAto8R0x）：对齐查词弹窗的最小宽度，并随「卡面图片
/// 大小」放大；外字 / 图标尺寸的小图不动。
void main() {
  group('srsDefsIllustrationCss', () {
    const String link = '.fc-defs-only a[data-fushi-srs-illus]';

    test('原样：只对齐查词弹窗——彩色插图至少 200px，单色不放大，不超栏宽', () {
      final String css = srsDefsIllustrationCss(
        SrsReviewImageSize.original,
        maxHeight: '75vh',
      );
      expect(kSrsDefsIllustrationMinWidth, 200, reason: '与 popup.css 同值');
      expect(css, contains('$link{width:var(--fushi-srs-illus-w)!important;}'));
      expect(
        css,
        contains(
          '.fc-defs-only a[data-fushi-srs-illus="color"]'
          '{width:max(var(--fushi-srs-illus-w), 200px)!important;}',
        ),
      );
      // 栏宽是脚本量出来的像素值（表格单元格里百分比是循环引用，BUG-5181），没量到退回 100%。
      expect(
        css,
        contains(
          '$link{max-width:var(--fushi-srs-illus-avail, 100%)!important;}',
        ),
      );
      expect(css, isNot(contains('max-height:none')), reason: '原样保留导出的高度上限');
      expect(css, isNot(contains('75vh')));
      // 只作用于标记过的插图：不写裸 img / 链接规则（外字、小图标不受影响）。
      expect(css, isNot(contains('.card img')));
      for (final String rule in css.split('}')) {
        if (rule.trim().isEmpty) continue;
        expect(rule, contains('[data-fushi-srs-illus'), reason: rule);
      }
    });

    test('适应宽度：再去掉导出内联的 max-height', () {
      final String css = srsDefsIllustrationCss(
        SrsReviewImageSize.fitWidth,
        maxHeight: '75vh',
      );
      expect(css, contains('max(var(--fushi-srs-illus-w), 200px)'));
      expect(
        css,
        contains('$link>span:first-child{max-height:none!important;}'),
      );
    });

    test('放大：铺满栏宽、按宽高比限高（窄版式传像素）', () {
      final String css = srsDefsIllustrationCss(
        SrsReviewImageSize.large,
        maxHeight: '480px',
      );
      expect(
        css,
        contains(
          '$link{width:calc(480px * '
          'var(--fushi-srs-illus-ar))!important;}',
        ),
      );
      // 宽度里不再写百分比：词典把插图放进表格单元格时 `min(100%, …)` 被算成 0 宽（BUG-5181）。
      expect(css, isNot(contains('min(100%')));
      expect(css, contains('var(--fushi-srs-illus-avail, 100%)'));
      expect(css, isNot(contains('--fushi-srs-illus-w)')));
      expect(css, contains('max-height:none!important'));
    });

    test('排版脚本在分列前调分级脚本、分列前后都量栏宽', () {
      const String layout = kSrsDefsLayoutScript;
      expect(
        layout,
        contains(
          'if (window.__fushiSrsMarkIllustrations) '
          'window.__fushiSrsMarkIllustrations(fc);',
        ),
      );
      expect(
        layout.indexOf('__fushiSrsMarkIllustrations(fc)'),
        lessThan(layout.indexOf('pack(list, groups, cols, lead)')),
      );
      expect(
        layout.indexOf('__fushiSrsSizeIllustrations(fc)'),
        lessThan(layout.indexOf('pack(list, groups, cols, lead)')),
      );
      expect(
        layout.indexOf('__fushiSrsSizeIllustrations(list)'),
        greaterThan(layout.indexOf('pack(list, groups, cols, lead)')),
      );
    });

    test('释义页装上分级脚本与插图样式', () {
      final String view = File(
        'lib/src/pages/implementations/srs/srs_fushi_card_view.dart',
      ).readAsStringSync();
      expect(
        view,
        contains(
          'hostScript: kSrsDefsIllustrationScript + kSrsDefsLayoutScript',
        ),
      );
      expect(view, contains('srsDefsIllustrationCss('));
      expect(view, contains('ref.watch(srsReviewImageSizeProvider)'));
    });
  });

  group('kSrsDefsIllustrationScript', () {
    Future<void> runJs(String body) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-illus-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync('''
const assert = require('assert');
globalThis.window = {};
// 最小 DOM：getComputedStyle 读桩上的 fs（报出来的计算字号 px），style 记内联值；
// 排版里 em 按 layoutFs 解析（默认同 fs）。Android WebView 的最小字号把计算字号 1px
// 报成 8px、排版仍按 1px，用 fs: 8, layoutFs: 1 模拟（BUG-5181）。
globalThis.getComputedStyle = (el) => ({ fontSize: el.fs + 'px' });
globalThis.document = {
  addEventListener(){},
  // 分级脚本的长度探针：挂进盒子后 offsetWidth 按盒子的排版字号解析 width。
  createElement(tag){
    const probe = el(tag.toUpperCase(), {});
    Object.defineProperty(probe, 'offsetWidth', { get(){
      const m = /width:([0-9.]+)(em|px)\$/.exec(probe.style.cssText || '');
      assert.ok(m, probe.style.cssText);
      assert.ok(probe.parentElement, '探针要挂进盒子再量');
      const n = parseFloat(m[1]);
      return Math.round(m[2] === 'px' ? n : n * probe.parentElement.layoutFs);
    } });
    return probe;
  },
};
function style(init){
  const s = Object.assign({}, init);
  s.setProperty = (k, v) => { s[k] = v; };
  return s;
}
function el(tag, opts, kids){
  const o = opts || {};
  const node = {
    tagName: tag, fs: o.fs || 16, layoutFs: o.layoutFs || o.fs || 16,
    style: style(o.style), attrs: Object.assign({}, o.attrs),
    children: kids || [], parentElement: null, gaiji: !!o.gaiji,
    complete: o.complete !== false, naturalWidth: o.nw || 0, naturalHeight: o.nh || 0,
    listeners: {},
    get firstElementChild(){ return node.children[0] || null; },
    getAttribute(n){ return n in node.attrs ? node.attrs[n] : null; },
    setAttribute(n, v){ node.attrs[n] = v; },
    addEventListener(t, fn){ node.listeners[t] = fn; },
    appendChild(k){ k.parentElement = node; node.children.push(k); },
    removeChild(k){ node.children = node.children.filter((x) => x !== k); k.parentElement = null; },
    closest(sel){
      assert.equal(sel, '[data-sc-class="gaiji"]');
      for (let n = node; n; n = n.parentElement) if (n.gaiji) return n;
      return null;
    },
    querySelector(sel){
      for (const k of node.children) {
        if (sel === 'img' && k.tagName === 'IMG') return k;
        if (sel === 'span[style*="mask-image"]' && k.tagName === 'SPAN' &&
            k.style['mask-image']) return k;
        const r = k.querySelector(sel);
        if (r) return r;
      }
      return null;
    },
  };
  for (const k of node.children) k.parentElement = node;
  return node;
}
// 制卡导出的图片盒：<a><span 盒子 font-size/width><span sizer padding-top%><span 背景><img>。
function exported(o){
  const img = el('IMG', { complete: o.complete, nw: o.nw, nh: o.nh, style: o.imgStyle || {} });
  const box = el('SPAN', { fs: o.boxFs, layoutFs: o.boxLayoutFs, style: { width: o.width } }, [
    el('SPAN', { style: o.ratio ? { paddingTop: (o.ratio * 100) + '%' } : { display: 'none' } }),
    el('SPAN', { style: o.mono ? { 'mask-image': 'var(--image)' } : {} }),
    img,
  ]);
  const a = el('A', { attrs: { href: 'fushi_dict_0.png' } }, [box]);
  const p = el('SPAN', { fs: 16, gaiji: o.gaiji }, [a]);
  return { a, img, p };
}
function run(list){
  window.__fushiSrsMarkIllustrations({
    querySelectorAll(sel){
      assert.equal(sel, '.fc-gloss a[href], .fc-gloss .gloss-image-link');
      return list.map((x) => x.a);
    },
  });
}
$kSrsDefsIllustrationScript
$body
''');
        final ProcessResult result = await Process.run(
          'node',
          <String>[script.path],
          runInShell: Platform.isWindows,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test('按导出几何分级：插图标记 + 声明宽度 / 宽高比；图标、外字不标', () async {
      await runJs(r'''
// 非 em 插图：font-size:1px;width:120em → 120px，高 90px。
const px = exported({ boxFs: 1, width: '120em', ratio: 0.75 });
// em 插图（Yomitan 的 font-size:1px;font-size:1em 由浏览器算成正文字号）：8.5em × 16 = 136px。
const em = exported({ boxFs: 16, width: '8.5em', ratio: 1.25 });
const mono = exported({ boxFs: 1, width: '300em', ratio: 0.5, mono: true });
// 1.2em 的行内小图标：宽高都不超过 3 个正文字号。
const icon = exported({ boxFs: 16, width: '1.2em', ratio: 1 });
// 宽 40px、高 60px（> 48px）：只要一维超过就算插图。
const tall = exported({ boxFs: 1, width: '40em', ratio: 1.5 });
// 外字：明鏡这类 150px 方块也不碰（卡面模板另有外字规则）。
const gaiji = exported({ boxFs: 1, width: '150em', ratio: 1, gaiji: true });
run([px, em, mono, icon, tall, gaiji]);
assert.equal(px.a.attrs['data-fushi-srs-illus'], 'color');
assert.equal(px.a.style['--fushi-srs-illus-w'], '120px');
assert.equal(Number(px.a.style['--fushi-srs-illus-ar']).toFixed(4), (4 / 3).toFixed(4));
assert.equal(em.a.attrs['data-fushi-srs-illus'], 'color');
assert.equal(em.a.style['--fushi-srs-illus-w'], '136px');
assert.equal(mono.a.attrs['data-fushi-srs-illus'], 'mono');
assert.equal(tall.a.attrs['data-fushi-srs-illus'], 'color');
assert.equal(icon.a.attrs['data-fushi-srs-illus'], undefined);
assert.equal(icon.a.style['--fushi-srs-illus-w'], undefined);
assert.equal(gaiji.a.attrs['data-fushi-srs-illus'], undefined);
// 量完把探针摘掉，盒子里只剩导出的子元素。
assert.equal(px.a.children[0].children.length, 3);
// 每个链接只判一次：再跑不重复处理。
px.a.attrs['data-fushi-srs-illus'] = 'x';
run([px]);
assert.equal(px.a.attrs['data-fushi-srs-illus'], 'x');
''');
    });

    test('Android WebView 最小字号：声明宽度取排版宽度，不是 em × 被抬高的计算字号（BUG-5181）', () async {
      await runJs(r'''
// font-size:1px;width:239em：计算字号被最小字号抬成 8px，排版里 1em 仍是 1px。
const fig = exported({ boxFs: 8, boxLayoutFs: 1, width: '239em', ratio: 320 / 239 });
// 没量到真实尺寸、词典声明了 120em 宽的导出：同样按排版宽度算。
const nat = exported({ boxFs: 8, boxLayoutFs: 1, width: 'auto', nw: 600, nh: 300, imgStyle: { width: '120em' } });
run([fig, nat]);
assert.equal(fig.a.attrs['data-fushi-srs-illus'], 'color');
assert.equal(fig.a.style['--fushi-srs-illus-w'], '239px');
assert.equal(nat.a.style['--fushi-srs-illus-w'], '120px');
''');
    });

    test('没量到真实尺寸的导出：等图片载入按自然尺寸 / 声明的一维算', () async {
      await runJs(r'''
const late = exported({ boxFs: 1, width: 'auto', complete: false, nw: 300, nh: 150 });
const oneDim = exported({ boxFs: 16, width: 'auto', nw: 200, nh: 100, imgStyle: { height: '10em' } });
const small = exported({ boxFs: 1, width: 'auto', nw: 20, nh: 20 });
const sized = [];
window.__fushiSrsSizeIllustration = (a) => sized.push(a);
run([late, oneDim, small]);
assert.equal(late.a.attrs['data-fushi-srs-illus'], undefined, '未载入先不标');
late.img.listeners.load();
// 载入后才标上的插图当场量栏宽（不等下一轮排版）。
assert.ok(sized.includes(late.a));
assert.equal(late.a.attrs['data-fushi-srs-illus'], 'color');
assert.equal(late.a.attrs['data-fushi-srs-natural'], '');
assert.equal(late.a.style['--fushi-srs-illus-w'], '300px');
// 词典只声明高 10em（160px），宽按自然宽高比 2:1 = 320px。
assert.equal(oneDim.a.style['--fushi-srs-illus-w'], '320px');
assert.equal(small.a.attrs['data-fushi-srs-illus'], undefined);
assert.equal(small.a.attrs['data-fushi-srs-natural'], undefined);
''');
    });
  });
}
