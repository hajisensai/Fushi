import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
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
      expect(shell, contains('<style id="fushi-card-css"></style>'));
      expect(shell, contains('id="fushi-card-root"'));
      expect(shell, contains('class="card nightMode night_mode"'));
      expect(shell, contains(kSrsPlaySoundHandler));
      expect(shell, contains('__fushiSrsSetCard'));
      // 卡片内容不进外壳：外壳与卡无关，换卡不需要重载。
      expect(shell, isNot(contains('<b>Q</b>')));
      expect(doc(cardId: 'x', body: 'zzz', dark: true).shellHtml, shell);
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
const cardCss = el('style'), themeCss = el('style');
globalThis.document = {
  body: { className: '' },
  getElementById(id){
    return { 'fushi-card-root': root, 'fushi-card-css': cardCss, 'fushi-theme-css': themeCss }[id] || null;
  },
  createElement: el,
};
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
__fushiSrsSetCard('.a{}',
  '<p>x</p><script>log.push("s1"); onShownHook.push(function(){log.push("shown")}); onUpdateHook.push(function(){log.push("update")});</script>'
  + '<script>log.push("s2")</script>', 'nightMode night_mode');
assert.deepEqual(log, ['s1', 's2', 'update', 'shown'], '同步完成：' + log);
assert.equal(cardCss.textContent, '.a{}');
assert.equal(document.body.className, 'card nightMode night_mode');
assert.equal(root.className, 'card nightMode night_mode');
assert.equal(scrolled, 1);
assert.equal(root.children[0].text.indexOf('log.push("s1")'), 0, '换成了新建的 script 元素');
// 下一张：上一张压的钩子不再跑。
log.length = 0;
__fushiSrsSetCard('', '<script>log.push("n1")</script>', '');
assert.deepEqual(log, ['n1']);
assert.equal(document.body.className, 'card');
'''),
      );
    });

    test('外部脚本加载完（或失败）后才执行后面的脚本，钩子最后', () async {
      await runJs(
        harness(r'''
window.__remote['lib.js'] = 'log.push("lib")';
__fushiSrsSetCard('', '<script>log.push("a"); onShownHook.push(function(){log.push("shown")})</script>'
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
__fushiSrsSetCard('', '<script src="slow.js"></script><script>log.push("old-tail")</script>'
  + '<script>onShownHook.push(function(){log.push("old-shown")})</script>', '');
__fushiSrsSetCard('', '<script>log.push("new"); onShownHook.push(function(){log.push("new-shown")})</script>', '');
await loadNext();
assert.deepEqual(log, ['new', 'new-shown']);
'''),
      );
    });

    test('换主题只换主题样式与类名', () async {
      await runJs(
        harness(r'''
__fushiSrsSetCard('.c{}', '<script>log.push("run")</script>', '');
__fushiSrsSetTheme('html{color:red}', 'nightMode night_mode');
assert.equal(themeCss.textContent, 'html{color:red}');
assert.equal(document.body.className, 'card nightMode night_mode');
assert.equal(cardCss.textContent, '.c{}');
assert.deepEqual(log, ['run'], '没重跑卡片脚本');
'''),
      );
    });

    test('调用串转义：引号 / 反斜杠 / </script> / U+2028 / 模板串原样送达', () async {
      const String nasty =
          '<p title="a\'b">"q" \\ \\n </script> \u2028 \u2029 `\${x}` 日本語</p>';
      const String css = '.x::after{content:"\\201C"}';
      final String call = srsCardSetCardScript(
        css: css,
        bodyHtml: nasty,
        classes: 'nightMode',
      );
      final String out = await runJs(
        harness('''
$call
process.stdout.write(JSON.stringify({html: root.innerHTML, css: cardCss.textContent, cls: root.className}));
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
}
