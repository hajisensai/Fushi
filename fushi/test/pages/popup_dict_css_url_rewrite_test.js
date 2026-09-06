// 行为守卫：真跑 assets/popup/dict-media.js 的 constructDictCss，断言词典 CSS 里的
// 相对 url() 被重写到媒体通道（BUG-2147）。
//
// 词典样式表被内联成 <style> 注入弹窗文档，相对 URL 于是相对**弹窗文档**解析
// （Android 是 file:///android_asset/.../popup/，Windows/iOS 是 initialData 的
// opaque origin），与词典目录毫无关系 —— 不重写就永远 404。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const repoRoot = process.cwd();
const source = fs.readFileSync(
  path.join(repoRoot, 'assets', 'popup', 'dict-media.js'),
  'utf8',
);

const sandbox = { window: {}, console };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(source, sandbox);

const { constructDictCss } = sandbox;
assert.strictEqual(
  typeof constructDictCss,
  'function',
  'dict-media.js must expose constructDictCss',
);

const DICT = 'CamPron';
const enc = encodeURIComponent;

// 1. 裸名 url() -> image:// 媒体通道
{
  const out = constructDictCss('.sp{background:url(sound.png)}', DICT, '.s');
  assert.ok(
    out.includes(`image://?dictionary=${enc(DICT)}&path=${enc('sound.png')}`),
    `bare url() must be rewritten to the media channel, got: ${out}`,
  );
}

// 2. ?query 必须剥掉：导入侧按裸文件名入库（extract_css_url_names）
{
  const out = constructDictCss(
    '.sp{background:url("sprite.gif?version=5.0.287")}',
    DICT,
    '.s',
  );
  assert.ok(
    out.includes(`path=${enc('sprite.gif')}`),
    `?query must be stripped so the media key matches the import side, got: ${out}`,
  );
  assert.ok(
    !out.includes('version=5.0.287'),
    'the query string must not survive into the media path',
  );
}

// 3. 单引号 / 无引号 / 带空白三种写法都要认
{
  for (const css of [
    ".a{background:url('bg.png')}",
    '.a{background:url(bg.png)}',
    '.a{background:url(  bg.png  )}',
  ]) {
    const out = constructDictCss(css, DICT, '.s');
    assert.ok(
      out.includes(`path=${enc('bg.png')}`),
      `url() quoting variant not handled: ${css} -> ${out}`,
    );
  }
}

// 4. 带 scheme 的 / 协议相对的 URL 原样保留（不能被解析到词典目录里去）
{
  const css =
    '.b{background:url(https://dictionary.cambridge.org/x.png)}' +
    '.c{background:url(data:image/gif;base64,AAAA)}' +
    '.d{background:url(//cdn.example.com/y.png)}';
  const out = constructDictCss(css, DICT, '.s');
  assert.ok(out.includes('url(https://dictionary.cambridge.org/x.png)'), 'remote URL must be kept');
  assert.ok(out.includes('url(data:image/gif;base64,AAAA)'), 'data: URL must be kept');
  assert.ok(out.includes('url(//cdn.example.com/y.png)'), 'protocol-relative URL must be kept');
  assert.ok(!out.includes('image://'), `nothing here may reach the media channel: ${out}`);
}

// 4b. 前导 `/` 在 MDict 里表示「.mdd 根」，不是文件系统绝对路径 —— 剥掉它，与
//     <img src="/x.png"> 走的 normalizeDictMediaPath 同解。两条通道对同一个写法
//     必须解出同一个 media key，否则同一份资源在 CSS 里和在条目里指向两个 key。
{
  const out = constructDictCss('.a{background:url(/sub/logo.png)}', DICT, '.s');
  assert.ok(
    out.includes(`path=${enc('sub/logo.png')}`),
    `a leading slash is mdd-root-relative and must be stripped, got: ${out}`,
  );
}

// 5. 字体已在 Dart 侧内联成 data:（强制 CORS 子资源，媒体通道带不了 CORS 头），
//    到这里必须原样放过 —— 重写成 image:// 只会把它变成被 CORS 拒绝。
{
  const out = constructDictCss(
    "@font-face{font-family:'ico-c';src:url(data:font/woff;base64,d09GRg) format('woff')}",
    DICT,
    '.s',
  );
  assert.ok(
    out.includes('url(data:font/woff;base64,d09GRg)'),
    `an already-inlined font must pass through untouched, got: ${out}`,
  );
  assert.ok(!out.includes('image://'), 'a font must never be routed through image://');
}

// 6. 没有 url() 的 CSS 不受影响（早退路径）
{
  const out = constructDictCss('.a{color:red}', DICT, '.s');
  assert.ok(out.includes('color:red'), 'plain CSS must survive scoping');
}

console.log('all assertions passed');
