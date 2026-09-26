// BUG-2697（issue #1495）：YouTube 页面报 "This document requires 'TrustedHTML' assignment and
// no 'default' policy for 'TrustedHTML' has been defined"。
//
// manifest 里 `world: "MAIN"` 的内容脚本跑在**页面自己的** JS 世界，受页面 CSP 约束；YouTube 等站
// 下发 `require-trusted-types-for 'script'`，此时任何 TrustedHTML sink（DOM 解析器 parseFromString、
// innerHTML / outerHTML 赋值、insertAdjacentHTML、document.write …）收到裸字符串都会直接抛。
// youtube-bridge.js 曾用 DOM 解析器解析 srv3 字幕，每条轨都抛一次、被 catch 吞掉后回落 json3。
//
// 本守卫从**每一份**宿主清单（真源 tools/browser-extension 与 app 打包镜像
// fushi/assets/browser_extension）动态读出 MAIN world 脚本列表，逐个扫源码，禁止出现上述 sink。
// MAIN world 桥只该读播放器状态、发纯数据，需要解析 XML/HTML 时用正则/字符串处理
// （参考 subtitle-adapters.js），或改取 JSON 格式。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..', '..');
const MANIFESTS = [
  path.join(__dirname, 'manifest.json'),
  path.join(REPO, 'fushi', 'assets', 'browser_extension', 'manifest.json'),
];

// [名称, 正则]。只匹配真实调用/赋值形态，注释里写「DOM 解析器」之类的中文描述不会误报。
const FORBIDDEN_SINKS = [
  ['DOMParser', /\bDOMParser\b/],
  ['.innerHTML', /\.innerHTML\b/],
  ['outerHTML =', /\.outerHTML\s*=(?!=)/],
  ['insertAdjacentHTML', /\binsertAdjacentHTML\b/],
  ['document.write', /\bdocument\s*\.\s*write(?:ln)?\s*\(/],
  ['createContextualFragment', /\bcreateContextualFragment\b/],
  ['setHTMLUnsafe', /\bsetHTMLUnsafe\b/],
  ['.srcdoc =', /\.srcdoc\s*=(?!=)/],
];

function mainWorldScripts(manifestPath) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const dir = path.dirname(manifestPath);
  const out = [];
  for (const entry of manifest.content_scripts || []) {
    if (entry.world !== 'MAIN') continue;
    for (const js of entry.js || []) out.push(path.join(dir, js));
  }
  return out;
}

function findSinks(source) {
  const hits = [];
  const lines = source.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    for (const [name, re] of FORBIDDEN_SINKS) {
      if (re.test(lines[i])) hits.push('L' + (i + 1) + ' ' + name + ': ' + lines[i].trim());
    }
  }
  return hits;
}

for (const manifestPath of MANIFESTS) {
  const rel = path.relative(REPO, manifestPath).replace(/\\/g, '/');
  test('MAIN world 脚本不得使用 TrustedHTML sink：' + rel, () => {
    assert.ok(fs.existsSync(manifestPath), '宿主清单不存在：' + rel);
    const scripts = mainWorldScripts(manifestPath);
    assert.ok(scripts.length > 0, rel + ' 里一个 world:MAIN 脚本都没读到——清单结构变了，守卫失效');
    const bad = [];
    for (const file of scripts) {
      assert.ok(fs.existsSync(file), 'MAIN world 脚本不存在：' + file);
      for (const hit of findSinks(fs.readFileSync(file, 'utf8'))) {
        bad.push(path.relative(REPO, file).replace(/\\/g, '/') + ' ' + hit);
      }
    }
    assert.deepStrictEqual(bad, [], 'MAIN world 脚本在强制 Trusted Types 的页面上会抛 TrustedHTML 异常');
  });
}

test('youtube-bridge.js 确实在 MAIN world 名单里（守卫覆盖到 issue #1495 的原始文件）', () => {
  const names = mainWorldScripts(MANIFESTS[0]).map((f) => path.basename(f));
  assert.ok(names.includes('youtube-bridge.js'), names.join(', '));
});

test('守卫自检：每种 sink 形态都能被识别，比较运算与中文注释不误报', () => {
  const positives = [
    "var doc = new DOMParser().parseFromString(text, 'text/xml');",
    'el.innerHTML = html;',
    'var s = el.innerHTML;',
    'el.outerHTML = html;',
    "el.insertAdjacentHTML('beforeend', html);",
    'document.write(html);',
    'document.writeln(html);',
    'range.createContextualFragment(html);',
    'el.setHTMLUnsafe(html);',
    'frame.srcdoc = html;',
  ];
  for (const line of positives) assert.ok(findSinks(line).length > 0, '应识别：' + line);
  const negatives = [
    'if (el.outerHTML === prev) return;',
    '// DOM 解析器的 parseFromString 属 TrustedHTML sink',
    'var text = el.textContent;',
  ];
  for (const line of negatives) assert.deepStrictEqual(findSinks(line), [], '不应误报：' + line);
});
