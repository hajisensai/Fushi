const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// 查词弹窗性能：`constructDictCss` 的调用点是 createGlossarySection，即「每条词条的
// 每个词典块」各调一次。N 条词条 × M 本词典 = N×M 次对同一本词典那份（Yomitan 词典
// 动辄几十 KB 的）CSS 做完全相同的逐字符扫描。于是给它加了 memo。
//
// memo 的正确性风险只有一个方向：**串味**——把 A 词典的作用域化结果发给 B 词典，或者
// 词典集换了以后还发旧内容。本 harness 就钉这件事：
//   ① 缓存版与未缓存版对同一输入必须逐字节相同（memo 不得改变语义）；
//   ② 同一份 css、不同 dictName / scopePrefix 必须各得其所（内层 key 完整）；
//   ③ 不同 css 内容必须各得其所（外层按 css 串分桶）；
//   ④ 桶数超上限触发 clear() 之后，结果仍然正确（缓存只是加速，不是真相源）。
// 无 node 时由 .dart 侧 skip；源码级守卫见 popup_dict_css_atrule_scope_test.dart。

// 三份 dict-media.js：app 弹窗用的那份，以及浏览器扩展的两个镜像（扩展那份是**有意
// 分叉**的——它多一条把 `image://` 改写到同步服务器 HTTP 端点的分支——但
// constructDictCss 本体逐字相同，同样被「每条词条 × 每本词典」重复调用，所以 memo
// 必须三份都在。逐份跑同一套断言，任何一份漏了移植都会在这里红。
const DICT_MEDIA_PATHS = [
  path.resolve(__dirname, '../../../assets/popup/dict-media.js'),
  path.resolve(__dirname, '../../../assets/browser_extension/vendor/dict-media.js'),
  path.resolve(__dirname, '../../../../tools/browser-extension/vendor/dict-media.js'),
];

function load(dictMediaPath) {
  const context = { console, window: {} };
  context.globalThis = context;
  vm.runInNewContext(fs.readFileSync(dictMediaPath, 'utf8'), context, {
    filename: dictMediaPath,
  });
  return context;
}

for (const dictMediaPath of DICT_MEDIA_PATHS) {
  assert.ok(fs.existsSync(dictMediaPath), `missing mirror: ${dictMediaPath}`);
  runSuite(load(dictMediaPath), dictMediaPath);
}

console.log('all assertions passed');

function runSuite(ctx, where) {
assert.strictEqual(
  typeof ctx.constructDictCss, 'function',
  `constructDictCss must be defined (${where})`);
assert.strictEqual(
  typeof ctx.constructDictCssUncached, 'function',
  `constructDictCssUncached (the un-memoised implementation) must be defined (${where})`);

// 覆盖到 scoper 的各条分支：普通选择器、逗号选择器列表、条件组 at-rule（内部递归）、
// 非条件组 at-rule（整块透传）、语句型 at-rule、嵌套规则、注释。
const SAMPLES = [
  '',
  '.gloss { color: red; }',
  '.a, .b > .c { margin: 0; padding: 1px }',
  '@media (max-width: 500px) { .img { width: 50%; } }',
  '@font-face { font-family: X; src: url(a.ttf); }',
  '@keyframes spin { from { transform: rotate(0) } to { transform: rotate(360deg) } }',
  '@import url("x.css"); .after-import { color: blue; }',
  '/* leading comment */ .commented { color: green; }',
  '.outer { color: red; .nested { color: blue; } }',
  '@supports (display: grid) { .g, .h { display: grid; } }',
];

const DICTS = ['明鏡国語辞典', 'JMdict', 'a b', ''];
const SCOPES = [undefined, '.yomitan-glossary [data-dictionary="X"]', 'a', 'a b'];

// ① 等价性：memo 版必须与未 memo 版逐字节相同，且重复调用稳定。
for (const css of SAMPLES) {
  for (const dict of DICTS) {
    for (const scope of SCOPES) {
      const expected = ctx.constructDictCssUncached(css, dict, scope);
      const first = ctx.constructDictCss(css, dict, scope);
      const second = ctx.constructDictCss(css, dict, scope);
      assert.strictEqual(
        first, expected,
        `memo 首次调用与未 memo 实现不一致: css=${JSON.stringify(css)} dict=${JSON.stringify(dict)} scope=${JSON.stringify(scope)}`);
      assert.strictEqual(
        second, expected,
        `memo 命中后与未 memo 实现不一致: css=${JSON.stringify(css)} dict=${JSON.stringify(dict)} scope=${JSON.stringify(scope)}`);
    }
  }
}

// ② 同一份 css、不同 dictName 不得串味（先热身建缓存，再交叉比对）。
{
  const css = '.x { color: red; }';
  const a = ctx.constructDictCss(css, 'DictA');
  const b = ctx.constructDictCss(css, 'DictB');
  assert.notStrictEqual(a, b, '不同 dictName 必须产出不同作用域前缀');
  assert.ok(a.includes('[data-dictionary="DictA"]'), 'DictA 前缀缺失');
  assert.ok(b.includes('[data-dictionary="DictB"]'), 'DictB 前缀缺失');
  assert.strictEqual(
    ctx.constructDictCss(css, 'DictA'), a, 'DictA 二次取值被 DictB 覆盖了');
}

// ②b 同一份 css、同一 dictName、不同 scopePrefix 不得串味。
{
  const css = '.y { color: red; }';
  const bare = ctx.constructDictCss(css, 'D');
  const scoped = ctx.constructDictCss(css, 'D', '.wrap [data-dictionary="D"]');
  assert.notStrictEqual(bare, scoped, '不同 scopePrefix 必须产出不同结果');
  assert.ok(scoped.includes('.wrap [data-dictionary="D"] .y'), 'scopePrefix 未生效');
  assert.strictEqual(ctx.constructDictCss(css, 'D'), bare, 'scopePrefix 变体污染了无前缀取值');
}

// ②c key 拼接不得因分隔符产生碰撞：(dict='a b', scope='') 与 (dict='a', scope='b')
// 在朴素的 `dict + ' ' + scope` 方案下会撞成同一个 key。
{
  const css = '.z { color: red; }';
  const first = ctx.constructDictCss(css, 'a b', '');
  const second = ctx.constructDictCss(css, 'a', 'b');
  assert.strictEqual(
    first, ctx.constructDictCssUncached(css, 'a b', ''), 'key 碰撞: (a b, "") 被覆盖');
  assert.strictEqual(
    second, ctx.constructDictCssUncached(css, 'a', 'b'), 'key 碰撞: (a, b) 取到了别人的值');
  assert.notStrictEqual(first, second, '两组不同输入不应产出相同结果');
}

// ③ 不同 css 内容各自分桶：同 dictName 下换 css 必须重新作用域化。
{
  const one = ctx.constructDictCss('.p { color: red; }', 'Same');
  const two = ctx.constructDictCss('.q { color: blue; }', 'Same');
  assert.ok(one.includes('.p'), '第一份 css 结果异常');
  assert.ok(two.includes('.q'), '换 css 后仍拿到旧桶的结果');
  assert.ok(!two.includes('.p'), '换 css 后结果里混入了旧 css');
}

// ④ 撑爆桶上限触发 clear() 之后仍然正确（缓存只是加速，不是真相源）。
{
  const dict = 'Overflow';
  const probeCss = '.probe { color: red; }';
  const before = ctx.constructDictCss(probeCss, dict);
  // 上限是 64 个桶；灌 200 份互不相同的 css 必定跨过 clear()。
  for (let i = 0; i < 200; i++) {
    ctx.constructDictCss(`.gen${i} { color: red; }`, dict);
  }
  const after = ctx.constructDictCss(probeCss, dict);
  assert.strictEqual(
    after, before, 'clear() 之后重算的结果与首次不一致');
  assert.strictEqual(
    after, ctx.constructDictCssUncached(probeCss, dict),
    'clear() 之后的结果与未 memo 实现不一致');
}

}
