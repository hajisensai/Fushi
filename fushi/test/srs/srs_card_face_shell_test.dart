import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:material_ui/material_ui.dart';

/// 复习卡面「外壳只加载一次、换卡经 JS 原地换内容」：
/// - [SrsCardFaceSync]：外壳就绪前排队、就绪后整份下发、之后只下发变了的部分，
///   正常流程里从不重载外壳；
/// - 生成的调用串转义正确（在 node 里真的执行，取回根节点收到的字符串逐字比对）；
/// - 外壳脚本 [kSrsCardShellScript] 的脚本重放顺序 / 外部脚本等待 / 被新卡打断 /
///   `onUpdateHook`·`onShownHook` 约定（node + 最小 DOM 桩，跑的是生产常量本身）。
void main() {
  const String prefix = 'https://srs.local/media/';

  SrsCardFaceDocument doc({
    String cardId = 'c1',
    bool answer = false,
    String body = '<b>Q</b>',
    String css = '.card{}',
    bool dark = false,
  }) => SrsCardFaceDocument.of(
    SrsCardFace(
      cardId: cardId,
      showingAnswer: answer,
      bodyHtml: body,
      css: css,
      languageCode: 'ja',
      onBridgeKey: (_) {},
    ),
    dark: dark,
    background: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
    foreground: dark ? const Color(0xFFEEEEEE) : const Color(0xFF000000),
    accent: const Color(0xFF6750A4),
    onAccent: const Color(0xFFFFFFFF),
    mediaUrlPrefix: prefix,
    themedScrollbar: true,
  );

  group('SrsCardFaceSync', () {
    late List<String> evaluated;
    late int shellReloads;
    late SrsCardFaceSync sync;

    setUp(() {
      evaluated = <String>[];
      shellReloads = 0;
      sync = SrsCardFaceSync(
        evaluate: (String source) async {
          evaluated.add(source);
          return true;
        },
        reloadShell: () => shellReloads++,
      );
    });

    test('外壳就绪前只排队最后一次内容，就绪后一次下发', () async {
      sync.update(doc(body: 'first'));
      sync.update(doc(body: 'second'));
      expect(evaluated, isEmpty);
      sync.shellLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(1));
      expect(evaluated.single, contains('__fushiSrsSetTheme'));
      expect(evaluated.single, contains('__fushiSrsSetCard'));
      expect(evaluated.single, contains('second'));
      expect(evaluated.single, isNot(contains('first')));
    });

    test('翻面 / 下一张只下发换卡调用，连续 10 张从不重载外壳', () async {
      sync.shellLoaded();
      for (int i = 0; i < 10; i++) {
        sync.update(doc(cardId: 'c$i', body: 'Q$i'));
        sync.update(doc(cardId: 'c$i', answer: true, body: 'Q$i<hr>A$i'));
      }
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(20));
      // 第一次带主题，之后主题没变只换卡。
      expect(evaluated.first, contains('__fushiSrsSetTheme'));
      for (final String s in evaluated.skip(1)) {
        expect(s, isNot(contains('__fushiSrsSetTheme')));
        expect(s, contains('__fushiSrsSetCard'));
      }
      expect(shellReloads, 0);
    });

    test('内容没变不下发；同样正文的另一张卡照样下发（要重放脚本、滚回顶部）', () async {
      sync.shellLoaded();
      sync.update(doc());
      sync.update(doc());
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(1));
      sync.update(doc(cardId: 'other'));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
    });

    test('只换主题走原地换主题，不重跑卡片', () async {
      sync.shellLoaded();
      sync.update(doc());
      sync.update(doc(dark: true));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(evaluated.last, contains('__fushiSrsSetTheme'));
      expect(evaluated.last, contains('nightMode night_mode'));
      expect(evaluated.last, isNot(contains('__fushiSrsSetCard(')));
      expect(shellReloads, 0);
    });

    test('renderer 重建（detach → 新外壳 onLoadStop）后整份重放当前内容', () async {
      sync.shellLoaded();
      sync.update(doc(body: 'now'));
      await Future<void>.delayed(Duration.zero);
      sync.detach();
      sync.update(doc(body: 'later'));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(1), reason: '外壳没就绪不下发');
      sync.shellLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(evaluated.last, contains('__fushiSrsSetTheme'));
      expect(evaluated.last, contains('later'));
    });

    test('同一笔记类型连续换卡：笔记类型 CSS 正文只下发一次', () async {
      const String css = '.fushi-type-css{color:#123456}';
      sync.shellLoaded();
      for (int i = 0; i < 6; i++) {
        sync.update(doc(cardId: 'c$i', body: 'Q$i', css: css));
        sync.update(doc(cardId: 'c$i', answer: true, body: 'A$i', css: css));
      }
      await Future<void>.delayed(Duration.zero);
      final String all = evaluated.join('\n');
      expect(
        RegExp(RegExp.escape('fushi-type-css')).allMatches(all),
        hasLength(1),
      );
      expect(sync.definedStyles, hasLength(1));
      for (final String s in evaluated.skip(1)) {
        expect(s, isNot(contains('__fushiSrsDefineCss')));
      }
    });

    test('正文里的词典 <style> 抽出、去重，跨卡只登记一次', () async {
      const String dictStyle =
          '.yomitan-glossary [data-dictionary="D"] .x{color:red}';
      String glossary(String text) =>
          '<div class="yomitan-glossary"><ol><li data-dictionary="D">$text'
          '</li></ol><style>$dictStyle</style></div>';
      sync.shellLoaded();
      sync.update(doc(cardId: 'a', body: glossary('one') + glossary('two')));
      sync.update(doc(cardId: 'b', body: glossary('three')));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(
        RegExp(
          RegExp.escape(dictStyle.substring(0, 30)),
        ).allMatches(evaluated.join()),
        hasLength(1),
        reason: '同一段词典样式（一张卡里两份、跨两张卡）只下发一次',
      );
      expect(evaluated.last, isNot(contains('<style>')));
      expect(evaluated.last, contains('three'));
      expect(sync.definedStyles, hasLength(2));
    });

    test('外壳重载后已登记样式作废、整份重新登记', () async {
      sync.shellLoaded();
      sync.update(doc(css: '.replay-me{}'));
      await Future<void>.delayed(Duration.zero);
      sync.detach();
      expect(sync.definedStyles, isEmpty);
      sync.shellLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(evaluated.last, contains('__fushiSrsDefineCss'));
      expect(evaluated.last, contains('.replay-me{}'));
    });

    test('页面已不是外壳（调用返回 false）时重载外壳一次，不循环', () async {
      int calls = 0;
      final SrsCardFaceSync s = SrsCardFaceSync(
        evaluate: (String source) async {
          calls++;
          return false;
        },
        reloadShell: () => shellReloads++,
      );
      s.shellLoaded();
      s.update(doc());
      await Future<void>.delayed(Duration.zero);
      expect(shellReloads, 1);
      s.shellLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(shellReloads, 1, reason: '连续第二次失败不再重载');
      expect(calls, 2);
    });
  });

  group('外壳 HTML / 主题样式', () {
    test('外壳带基础样式、媒体脚本、换内容脚本与空的卡片槽', () {
      final SrsCardFaceDocument d = doc(dark: true);
      final String shell = d.shellHtml;
      expect(shell, contains('<style id="fushi-theme-css">'));
      expect(
        shell,
        contains(
          '<style id="fushi-css-tpl"></style><style id="fushi-css-body"></style>',
        ),
      );
      expect(shell, contains('id="fushi-card-root"'));
      expect(shell, contains('class="card nightMode night_mode"'));
      expect(shell, contains(kSrsPlaySoundHandler));
      expect(shell, contains('__fushiSrsSetCard'));
      // 卡片内容不进外壳：外壳与卡无关，换卡不需要重载。
      expect(shell, isNot(contains('<b>Q</b>')));
      expect(doc(cardId: 'x', body: 'zzz', dark: true).shellHtml, shell);
    });

    test('抽 <style>：脚本里的不碰、带 media 的留在正文、同段只留一份', () {
      final ({String body, List<String> styles}) r = srsExtractCardStyles(
        '<p>x</p><style>.a{}</style><script>var s="<style>.no{}</style>";'
        '</script><style media="print">.p{}</style><STYLE type="text/css">'
        '.a{}</STYLE><style>.b{}</style>',
      );
      expect(r.styles, <String>['.a{}', '.b{}']);
      expect(
        r.body,
        contains('<script>var s="<style>.no{}</style>";</script>'),
      );
      expect(r.body, contains('<style media="print">.p{}</style>'));
      expect(r.body, isNot(contains('.a{}')));
      expect(r.body, isNot(contains('.b{}')));
      const String plain = '<b>no styles</b>';
      expect(identical(srsExtractCardStyles(plain).body, plain), isTrue);
    });

    test('卡面内容做媒体改写与 lang 包裹', () {
      final SrsCardFaceDocument d = doc(
        body: '<img src="a.png">[sound:b.mp3]',
        css: '.card{background:url(bg.jpg)}',
      );
      expect(d.bodyHtml, startsWith('<div lang="ja">'));
      expect(d.bodyHtml, contains('src="${prefix}a.png"'));
      expect(d.bodyHtml, contains('data-sound="b.mp3"'));
      expect(d.cardCss, contains('url("${prefix}bg.jpg")'));
    });

    test('细滚动条：去箭头、透明 track、前景色低透明度 thumb、悬停加深', () {
      final String css = srsCardScrollbarCss(const Color(0xFF102030));
      expect(css, contains('::-webkit-scrollbar{width:8px;'));
      expect(css, contains('::-webkit-scrollbar-button{display:none;'));
      expect(css, contains('rgba(16,32,48,0.28)'));
      expect(css, contains(':hover'));
      expect(css, contains('rgba(16,32,48,0.50)'));
      // 标准属性只给不认伪元素的引擎（Chromium 121+ 标准属性会整族禁用伪元素）。
      expect(
        css,
        contains('@supports not selector(::-webkit-scrollbar){html{'),
      );
      final String themed = srsCardThemeCss(
        dark: false,
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF000000),
        accent: const Color(0xFF6750A4),
        onAccent: const Color(0xFFFFFFFF),
        themedScrollbar: false,
      );
      expect(themed, isNot(contains('scrollbar')));
      expect(themed, contains('color-scheme:light'));
    });
  });

  group('外壳脚本（node）', () {
    /// 最小 DOM 桩 + 生产外壳脚本。innerHTML 只解析 `<script ...>...</script>`，
    /// 脚本元素被插入文档时：内联的立即在全局作用域执行，`src` 的进 pendingLoads
    /// 等测试手动 `loadNext()`（先执行 window.__remote[src] 再派发 load）。
    String harness(String body) =>
        '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
globalThis.log = [];
const pendingLoads = [];
let scrolled = 0;
window.scrollTo = function(){ scrolled++; };
window.__remote = {};
function el(tag){
  return {
    tagName: tag.toUpperCase(), attrs: {}, children: [], parentNode: null,
    text: '', textContent: '', className: '', listeners: {},
    get attributes(){ return Object.keys(this.attrs).map(n => ({name: n, value: this.attrs[n]})); },
    setAttribute(n, v){ this.attrs[n] = String(v); },
    hasAttribute(n){ return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    getAttribute(n){ return this.hasAttribute(n) ? this.attrs[n] : null; },
    removeAttribute(n){ delete this.attrs[n]; },
    addEventListener(t, f){ (this.listeners[t] = this.listeners[t] || []).push(f); },
    dispatch(t){ (this.listeners[t] || []).forEach(f => f()); },
    replaceChild(nu, old){
      const i = this.children.indexOf(old);
      this.children[i] = nu; nu.parentNode = this; old.parentNode = null;
      if (nu.tagName === 'SCRIPT') {
        if (nu.hasAttribute('src')) pendingLoads.push(nu);
        else (0, eval)(nu.text);
      }
    },
    querySelectorAll(){ return []; },
    getElementsByTagName(t){ return this.children.filter(c => c.tagName === t.toUpperCase()); },
    insertBefore(nu, ref){
      const i = this.children.indexOf(ref);
      this.children.splice(i < 0 ? this.children.length : i, 0, nu);
      nu.parentNode = this;
    },
  };
}
const root = el('div');
let rootHtml = '';
Object.defineProperty(root, 'innerHTML', {
  get(){ return rootHtml; },
  set(v){
    rootHtml = v;
    root.children = [];
    const re = /<script([^>]*)>([\\s\\S]*?)<\\/script>/g;
    let m;
    while ((m = re.exec(v))) {
      const s = el('script');
      const am = /src="([^"]*)"/.exec(m[1]);
      if (am) s.setAttribute('src', am[1]);
      s.text = m[2];
      s.parentNode = root;
      root.children.push(s);
    }
  },
});
const themeCss = el('style');
const head = el('head');
const tplAnchor = el('style'), bodyAnchor = el('style');
head.insertBefore(tplAnchor, null);
head.insertBefore(bodyAnchor, null);
// 当前启用的注册表样式（文档顺序，`|` 连接）。
function cssOn(){
  return head.children
    .filter(c => c.hasAttribute('data-fushi-css') && !c.disabled)
    .map(c => c.textContent).join('|');
}
function cssAll(){
  return head.children.filter(c => c.hasAttribute('data-fushi-css')).map(c => c.textContent);
}
globalThis.document = {
  body: { className: '' },
  head,
  getElementById(id){
    return { 'fushi-card-root': root, 'fushi-theme-css': themeCss,
      'fushi-css-tpl': tplAnchor, 'fushi-css-body': bodyAnchor }[id] || null;
  },
  createElement: el,
};
function defCss(hash, kind, text){ __fushiSrsDefineCss(hash, kind, text); }
async function loadNext(){
  const s = pendingLoads.shift();
  assert.ok(s, 'no pending external script');
  const code = window.__remote[s.getAttribute('src')];
  if (code) (0, eval)(code);
  s.dispatch('load');
  for (let i = 0; i < 5; i++) await Promise.resolve();
}
$kSrsCardShellScript
(async () => {
$body
})().catch(e => { console.error(e); process.exit(1); });
''';

    Future<String> runJs(String code) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-shell-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(code);
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
        return '${result.stdout}';
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test('内联脚本按文档顺序同步执行，钩子在脚本之后（onUpdateHook 先于 onShownHook）', () async {
      await runJs(
        harness(r'''
defCss('ha', 't', '.a{}');
__fushiSrsSetCard(['ha'],
  '<p>x</p><script>log.push("s1"); onShownHook.push(function(){log.push("shown")}); onUpdateHook.push(function(){log.push("update")});</script>'
  + '<script>log.push("s2")</script>', 'nightMode night_mode');
assert.deepEqual(log, ['s1', 's2', 'update', 'shown'], '同步完成：' + log);
assert.equal(cssOn(), '.a{}');
assert.equal(document.body.className, 'card nightMode night_mode');
assert.equal(root.className, 'card nightMode night_mode');
assert.equal(scrolled, 1);
assert.equal(root.children[0].text.indexOf('log.push("s1")'), 0, '换成了新建的 script 元素');
// 下一张：上一张压的钩子不再跑。
log.length = 0;
__fushiSrsSetCard([], '<script>log.push("n1")</script>', '');
assert.deepEqual(log, ['n1']);
assert.equal(document.body.className, 'card');
'''),
      );
    });

    test('外部脚本加载完（或失败）后才执行后面的脚本，钩子最后', () async {
      await runJs(
        harness(r'''
window.__remote['lib.js'] = 'log.push("lib")';
__fushiSrsSetCard([], '<script>log.push("a"); onShownHook.push(function(){log.push("shown")})</script>'
  + '<script src="lib.js"></script><script>log.push("b")</script>', '');
assert.deepEqual(log, ['a'], '外部脚本没加载完，后面的不跑');
await loadNext();
assert.deepEqual(log, ['a', 'lib', 'b', 'shown']);
'''),
      );
    });

    test('外部脚本还在加载时换了下一张：旧卡剩下的脚本与钩子不跑', () async {
      await runJs(
        harness(r'''
__fushiSrsSetCard([], '<script src="slow.js"></script><script>log.push("old-tail")</script>'
  + '<script>onShownHook.push(function(){log.push("old-shown")})</script>', '');
__fushiSrsSetCard([], '<script>log.push("new"); onShownHook.push(function(){log.push("new-shown")})</script>', '');
await loadNext();
assert.deepEqual(log, ['new', 'new-shown']);
'''),
      );
    });

    test('样式注册表：只启用当前卡引用的样式，上一张卡的词典样式不串到下一张', () async {
      await runJs(
        harness(r'''
defCss('t1', 't', '.tpl{}');
defCss('d1', 'd', '[data-dictionary="A"] b{color:red}');
defCss('d1', 'd', 'ignored duplicate');
__fushiSrsSetCard(['t1', 'd1'], '<p>A</p>', '');
assert.equal(cssOn(), '.tpl{}|[data-dictionary="A"] b{color:red}');
defCss('d2', 'd', '.loose{color:blue}');
__fushiSrsSetCard(['t1', 'd2'], '<p>B</p>', '');
assert.equal(cssOn(), '.tpl{}|.loose{color:blue}', '上一张的 d1 已停用');
assert.deepEqual(cssAll(), ['.tpl{}', '[data-dictionary="A"] b{color:red}', '.loose{color:blue}'],
  '同一哈希只建一次，模板样式排在正文样式之前');
defCss('t2', 't', '.other-type{}');
__fushiSrsSetCard(['t2'], '<p>C</p>', '');
assert.equal(cssOn(), '.other-type{}');
assert.equal(head.children.indexOf(tplAnchor) < head.children.findIndex(c => c.textContent === '.loose{color:blue}'), true);
'''),
      );
    });

    test('换主题只换主题样式与类名', () async {
      await runJs(
        harness(r'''
defCss('hc', 't', '.c{}');
__fushiSrsSetCard(['hc'], '<script>log.push("run")</script>', '');
__fushiSrsSetTheme('html{color:red}', 'nightMode night_mode');
assert.equal(themeCss.textContent, 'html{color:red}');
assert.equal(document.body.className, 'card nightMode night_mode');
assert.equal(cssOn(), '.c{}');
assert.deepEqual(log, ['run'], '没重跑卡片脚本');
'''),
      );
    });

    test('调用串转义：引号 / 反斜杠 / </script> / U+2028 / 模板串原样送达', () async {
      const String nasty =
          '<p title="a\'b">"q" \\ \\n </script> \u2028 \u2029 `\${x}` 日本語</p>';
      const String css = '.x::after{content:"\\201C"}';
      final SrsCardStyle style = SrsCardStyle.of('t', css);
      final String call =
          srsCardDefineCssScript(style) +
          srsCardSetCardScript(
            styleRefs: <String>[style.hash],
            bodyHtml: nasty,
            classes: 'nightMode',
          );
      final String out = await runJs(
        harness('''
$call
process.stdout.write(JSON.stringify({html: root.innerHTML, css: cssOn(), cls: root.className}));
'''),
      );
      final Map<String, dynamic> got = jsonDecode(out) as Map<String, dynamic>;
      expect(got['html'], nasty);
      expect(got['css'], css);
      expect(got['cls'], 'card nightMode');
      final String theme = srsCardSetThemeScript(
        themeCss: 'a{b:"c\\d"}',
        classes: '',
      );
      expect(
        theme,
        startsWith('window.__fushiSrsSetTheme("a{b:\\"c\\\\d\\"}"'),
      );
    });
  });

  group('卡面链接 / 取词脚本（node）', () {
    /// 最小 DOM 桩：document 级监听、elementFromPoint 返回的元素链、计算样式、
    /// 选区；fushiSelection.selectText 与宿主 callHandler 都只记账。
    String harness(String body) =>
        '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
const calls = [];
const selects = [];
const listeners = {};
let hitEl = null;
let selection = '';
function el(tag, attrs, parent, cursor){
  return {
    nodeType: 1, tagName: tag.toUpperCase(), attrs: attrs || {}, parentElement: parent || null,
    isContentEditable: false, cursor: cursor || 'auto',
    hasAttribute(n){ return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    getAttribute(n){ return this.hasAttribute(n) ? this.attrs[n] : null; },
    closest(sel){
      for (let n = this; n; n = n.parentElement) {
        if (sel === 'a[href]' && n.tagName === 'A' && n.hasAttribute('href')) return n;
      }
      return null;
    },
  };
}
const body = el('body');
globalThis.document = {
  body, documentElement: el('html'),
  addEventListener(t, f){ (listeners[t] = listeners[t] || []).push(f); },
  elementFromPoint(){ return hitEl; },
};
window.getComputedStyle = function(n){ return { cursor: n.cursor }; };
window.getSelection = function(){ return { isCollapsed: !selection, toString(){ return selection; } }; };
window.flutter_inappwebview = { callHandler(name, v){ calls.push([name, v]); } };
window.fushiSelection = { selectText(x, y, max, hover){ selects.push([x, y, max, hover]); } };
function fire(type, ev){
  let prevented = false;
  ev.preventDefault = function(){ prevented = true; };
  (listeners[type] || []).forEach(f => f(ev));
  return prevented;
}
function tap(x, y, dx){
  fire('pointerdown', {pointerType: 'mouse', button: 0, clientX: x, clientY: y});
  if (dx) fire('pointermove', {pointerType: 'mouse', clientX: x + dx, clientY: y});
  fire('pointerup', {pointerType: 'mouse', button: 0, clientX: x + (dx || 0), clientY: y});
}
$kSrsCardLinkScript
$kSrsCardLookupScript
$body
''';

    Future<void> runJs(String code) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-lookup-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(code);
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

    test('来源链接交给宿主；其它链接只拦导航；页内锚点放行', () async {
      await runJs(
        harness(r'''
const p = el('p', {}, body);
const src = el('a', {href: 'fushi://source?v=1&kind=book'}, p);
const span = el('span', {}, src);
assert.equal(fire('click', {target: span}), true);
assert.deepEqual(calls, [['onSrsSourceLink', 'fushi://source?v=1&kind=book']]);
assert.equal(fire('click', {target: el('a', {href: 'https://example.com/'}, p)}), true);
assert.equal(calls.length, 1, '其它链接不交给宿主');
assert.equal(fire('click', {target: el('a', {href: '#top'}, p)}), false);
assert.equal(fire('click', {target: p}), false);
'''),
      );
    });

    test('点按取词：按门控走、拖动 / 可点元素 / 弹窗打开 / 有原生选区时不取词', () async {
      await runJs(
        harness(
          r'''
const text = el('span', {}, body);
hitEl = text;
tap(10, 20);
assert.equal(selects.length, 0, '门控没下发前不取词');
'''
          '${srsCardLookupGateScript(tap: true, hover: false, hostHover: false, open: false)}'
          r'''
tap(10, 20);
assert.deepEqual(selects, [[10, 20, 400, false]]);
tap(10, 20, 30);
assert.equal(selects.length, 1, '拖动不是点按');
hitEl = el('span', {}, el('div', {}, body, 'pointer'));
tap(10, 20);
assert.equal(selects.length, 1, '卡片模板自己的可点元素（cursor:pointer）照旧');
hitEl = el('span', {}, el('a', {href: 'fushi://source?x'}, body));
tap(10, 20);
assert.equal(selects.length, 1, '链接不取词');
hitEl = text;
selection = '拖选';
tap(10, 20);
assert.equal(selects.length, 1, '有原生选区（拖选复制）时不取词');
selection = '';
window.__fushiSrsLookup.open = true;
tap(10, 20);
assert.equal(selects.length, 1, '弹窗打开期间点按交给宿主 barrier');
window.__fushiSrsLookup.open = false;
window.__fushiSrsLookup.tap = false;
tap(10, 20);
assert.equal(selects.length, 1, '关了「点按查词」');
''',
        ),
      );
    });

    test('悬停取词：Shift 或「悬停即查词」，8px 节流；宿主接管悬停时让路', () async {
      await runJs(
        harness(
          r'''
hitEl = el('span', {}, body);
'''
          '${srsCardLookupGateScript(tap: true, hover: false, hostHover: false, open: false)}'
          r'''
fire('mousemove', {clientX: 5, clientY: 5, shiftKey: false});
assert.equal(selects.length, 0);
fire('mousemove', {clientX: 5, clientY: 5, shiftKey: true});
fire('mousemove', {clientX: 7, clientY: 6, shiftKey: true});
assert.deepEqual(selects, [[5, 5, 400, true]]);
window.__fushiSrsLookup.hover = true;
fire('mousemove', {clientX: 40, clientY: 5, shiftKey: false});
assert.equal(selects.length, 2);
window.__fushiSrsLookup.hostHover = true;
fire('mousemove', {clientX: 90, clientY: 5, shiftKey: true});
assert.equal(selects.length, 2);
''',
        ),
      );
    });
  });
}
