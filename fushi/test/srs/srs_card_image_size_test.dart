import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:material_ui/material_ui.dart';

/// 复习卡面「卡面图片大小」与 WebView 卡点图放大：
/// - 设置 → 注入卡面的 CSS（经 hostCss 走原地换主题，不重放卡片）；
/// - 页内点图脚本 [kSrsCardImageTapScript]（node + 最小 DOM 桩，跑生产常量本身）；
/// - 原生 Fushi 卡片的图片尺寸上限 [srsPictureLimits] 读同一个设置。
void main() {
  SrsCardFaceDocument doc(String hostCss) => SrsCardFaceDocument.of(
    SrsCardFace(
      cardId: 'c1',
      showingAnswer: false,
      bodyHtml: '<img src="a.png">',
      css: 'img{max-height:80px}',
      languageCode: 'ja',
      onBridgeKey: (_) {},
      hostCss: hostCss,
    ),
    dark: false,
    background: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF000000),
    accent: const Color(0xFF6750A4),
    onAccent: const Color(0xFFFFFFFF),
    mediaUrlPrefix: 'https://srs.local/media/',
    themedScrollbar: true,
  );

  group('srsReviewImageSizeCss', () {
    test('原样不注入；另两档压过牌组的 max-height 并保持比例', () {
      expect(srsReviewImageSizeCss(SrsReviewImageSize.original), isEmpty);
      final String fit = srsReviewImageSizeCss(SrsReviewImageSize.fitWidth);
      expect(fit, startsWith('.card img{'));
      expect(fit, contains('max-width:100%!important'));
      expect(fit, contains('max-height:none!important'));
      expect(fit, contains('height:auto!important'));
      expect(fit, isNot(contains('{width:')), reason: '适应宽度不放大小图');
      final String large = srsReviewImageSizeCss(SrsReviewImageSize.large);
      expect(large, contains('.card img{width:100%!important'));
      expect(large, contains('max-height:${kSrsReviewLargeImageMaxVh}vh'));
      expect(large, contains('object-fit:contain'));
    });

    test('wire 名冻结，未知值回落原样', () {
      expect(
        SrsReviewImageSize.values.map((SrsReviewImageSize v) => v.wire),
        <String>['original', 'fit_width', 'large'],
      );
      expect(SrsReviewImageSize.fromWire('bogus'), SrsReviewImageSize.original);
      expect(SrsReviewImageSize.fromWire(null), SrsReviewImageSize.original);
      expect(SrsReviewImageSize.fromWire('large'), SrsReviewImageSize.large);
    });

    test('切换档位只走原地换主题，不重放卡片', () async {
      final List<String> evaluated = <String>[];
      final SrsCardFaceSync sync = SrsCardFaceSync(
        evaluate: (String source) async {
          evaluated.add(source);
          return true;
        },
        reloadShell: () {},
      );
      sync.shellLoaded();
      sync.update(doc(''));
      final String large = srsReviewImageSizeCss(SrsReviewImageSize.large);
      sync.update(doc(large));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(evaluated.last, contains('__fushiSrsSetTheme'));
      expect(
        evaluated.last,
        contains('max-height:${kSrsReviewLargeImageMaxVh}vh!important'),
      );
      expect(evaluated.last, isNot(contains('__fushiSrsSetCard(')));
    });
  });

  group('kSrsCardImageTapScript', () {
    Future<void> runJs(String body) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-img-tap-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync('''
const assert = require('assert');
const calls = [];
globalThis.window = {
  flutter_inappwebview: { callHandler(name, v){ calls.push([name, v]); } },
};
const listeners = [];
globalThis.document = {
  addEventListener(type, fn, capture){ listeners.push([type, fn, capture]); },
};
// 最小元素桩：closest 按祖先链上的「选择器 → 是否命中」表查。
function el(tag, src, matches){
  return { tagName: tag, currentSrc: src, src: src,
    closest(sel){ return matches[sel] ? {} : null; } };
}
function click(target, opts){
  const e = Object.assign({ target, button: 0, defaultPrevented: false }, opts || {});
  for (const [type, fn] of listeners) if (type === 'click') fn(e);
}
$kSrsCardImageTapScript
$kSrsCardImageTapScript
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

    test('卡面里的图回传 currentSrc；模板自己处理的点击不抢；脚本幂等', () async {
      await runJs(r'''
assert.equal(listeners.length, 1, '注入两次只挂一个监听');
assert.equal(listeners[0][2], undefined, '冒泡阶段：模板的点击先处理');
const src = 'https://srs.local/media/pic%201.png';
click(el('IMG', src, { '.card': true }));
assert.deepEqual(calls, [['onSrsImageTap', src]]);
calls.length = 0;
click(el('IMG', src, { '.card': true, 'a[href],button,[onclick]': true }));
click(el('IMG', src, { '.card': true }), { defaultPrevented: true });
click(el('IMG', src, { '.card': true }), { button: 2 });
click(el('IMG', src, {}));
click(el('DIV', src, { '.card': true }));
click(el('IMG', '', { '.card': true }));
assert.deepEqual(calls, [], '链接 / onclick 里的图、已拦截、右键、卡外、非图、无地址都不回传');
''');
    });
  });

  // BUG-4734（反馈 w4RAto8R0x）：BUG-2825 起词典插图照上游导出成
  // `<a class="gloss-image-link" href="<媒体文件名>"><span class="gloss-image-container">…<img>`。
  // 链接脚本（捕获）与点图脚本（冒泡）同时挂在页面上，跑生产常量本身，一次点击走完两段：
  // 以前链接脚本把它当查词链接（preventDefault + 按链接文字查词，文字为空就返回），点图脚本
  // 又因 defaultPrevented / `closest('a[href]')` 不收，插图点了没反应。
  group('词典插图链接（a.gloss-image-link）点按放大', () {
    Future<void> runJs(String body) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-gloss-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync('''
const assert = require('assert');
const calls = [];
globalThis.window = {
  flutter_inappwebview: { callHandler(name, v){ calls.push([name, v]); } },
};
globalThis.URLSearchParams = URLSearchParams;
const listeners = [];
globalThis.document = {
  addEventListener(type, fn, capture){ listeners.push([type, fn, !!capture]); },
};
// 最小 DOM：tag / 类名 / 属性 / 父节点 / 子节点；选择器只认本测试用到的
// 「tag? (.类)* ([属性])*」并以逗号分隔。
function matches(node, sel){
  return sel.split(',').some((one) => {
    const m = /^([a-z]*)((?:\\.[\\w-]+)*)((?:\\[[\\w-]+\\])*)\$/i.exec(one.trim());
    if (!m) throw new Error('selector ' + one);
    if (m[1] && node.tagName !== m[1].toUpperCase()) return false;
    for (const c of (m[2].match(/[\\w-]+/g) || [])) if (!node.cls.includes(c)) return false;
    for (const a of (m[3].match(/[\\w-]+/g) || [])) if (!(a in node.attrs)) return false;
    return true;
  });
}
function el(tag, opts, kids){
  const o = opts || {};
  const node = {
    nodeType: 1, tagName: tag, cls: o.cls || [], attrs: o.attrs || {},
    childNodes: kids || [], parent: null,
    currentSrc: o.src || '', src: o.src || '',
    textContent: '',
    get classList(){ return { contains: (c) => node.cls.includes(c) }; },
    getAttribute(n){ return n in node.attrs ? node.attrs[n] : null; },
    getBoundingClientRect(){ return { left: 0, top: 0, width: 0, height: 0 }; },
    closest(sel){
      for (let n = node; n; n = n.parent) if (matches(n, sel)) return n;
      return null;
    },
    querySelector(sel){
      for (const k of node.childNodes) {
        if (k.nodeType !== 1) continue;
        if (matches(k, sel)) return k;
        const r = k.querySelector(sel);
        if (r) return r;
      }
      return null;
    },
  };
  for (const k of node.childNodes) k.parent = node;
  return node;
}
function click(target, opts){
  const e = Object.assign({ target, button: 0, defaultPrevented: false,
    preventDefault(){ this.defaultPrevented = true; } }, opts || {});
  // 先捕获阶段（链接脚本），再冒泡阶段（点图脚本）。
  for (const [type, fn, capture] of listeners) if (type === 'click' && capture) fn(e);
  for (const [type, fn, capture] of listeners) if (type === 'click' && !capture) fn(e);
  return e;
}
const SRC = 'https://srs.local/media/fushi_dict_1.png';
// 照 popup.js 导出（exporting）分支的结构：图片盒里 sizer / 底色层 / img。
function glossImage(){
  const img = el('IMG', { cls: ['gloss-image'], src: SRC });
  const background = el('SPAN', { cls: ['gloss-image-background'] });
  const container = el('SPAN', { cls: ['gloss-image-container'] }, [
    el('SPAN', { cls: ['gloss-image-sizer'] }), background, img,
  ]);
  const link = el('A', { cls: ['gloss-image-link'], attrs: { href: 'fushi_dict_1.png' } },
    [container]);
  return { link, container, background, img };
}
$kSrsCardLinkScript
$kSrsCardImageTapScript
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

    test('点 img 或图片盒内其他层：拦导航、不查词、回传图片地址', () async {
      await runJs(r'''
const g = glossImage();
el('DIV', { cls: ['card'] }, [el('DIV', { cls: ['fc-gloss'] }, [g.link])]);
let e = click(g.img);
assert.ok(e.defaultPrevented, '媒体文件名 href 不许把卡面外壳导航走');
assert.deepEqual(calls, [['onSrsImageTap', SRC]]);
calls.length = 0;
e = click(g.background);
assert.ok(e.defaultPrevented);
assert.deepEqual(calls, [['onSrsImageTap', SRC]], '点在图片盒的底色层上同样放大');
''');
    });

    test('普通链接里的图、onclick 里的插图、卡外、右键照旧不收', () async {
      await runJs(r'''
const query = el('A', { attrs: { href: '?query=%E8%AA%9E' } },
  [el('IMG', { src: SRC })]);
const g1 = glossImage();
const g2 = glossImage();
el('DIV', { cls: ['card'] }, [
  query,
  el('DIV', { attrs: { onclick: '' } }, [g1.link]),
]);
click(query.childNodes[0]);
assert.deepEqual(calls.map((c) => c[0]), ['onSrsCardLink'], '查词链接里的图仍是查词');
calls.length = 0;
click(g1.img);
click(g2.img);
const g3 = glossImage();
el('DIV', { cls: ['card'] }, [g3.link]);
click(g3.img, { button: 2 });
assert.deepEqual(calls, []);
''');
    });
  });

  group('srsPictureLimits', () {
    test('原样 = 旧上限（220 / 矮视口 120，视口高于 520 才铺满）', () {
      final SrsPictureLimits tall = srsPictureLimits(
        SrsReviewImageSize.original,
        viewport: 800,
      );
      expect(tall.maxHeight, 220);
      expect(tall.fillWidth, isTrue);
      expect(tall.maxFillHeight, 800 * kSrsPictureFillMaxViewportFraction);
      final SrsPictureLimits short = srsPictureLimits(
        SrsReviewImageSize.original,
        viewport: 500,
      );
      expect(short.maxHeight, 120);
      expect(short.fillWidth, isFalse);
    });

    test('档位越大，上限单调变大；放大档矮视口也铺满', () {
      for (final double viewport in <double>[500, 800]) {
        final List<SrsPictureLimits> l = SrsReviewImageSize.values
            .map(
              (SrsReviewImageSize s) => srsPictureLimits(s, viewport: viewport),
            )
            .toList();
        for (int i = 1; i < l.length; i++) {
          expect(
            l[i].maxHeight,
            greaterThan(l[i - 1].maxHeight),
            reason: 'viewport=$viewport #$i',
          );
          expect(l[i].maxFillHeight, greaterThan(l[i - 1].maxFillHeight));
        }
      }
      final SrsPictureLimits large = srsPictureLimits(
        SrsReviewImageSize.large,
        viewport: 500,
      );
      expect(large.fillWidth, isTrue);
      expect(large.maxHeight, 500 * kSrsReviewLargeImageMaxVh / 100);
    });
  });
}
