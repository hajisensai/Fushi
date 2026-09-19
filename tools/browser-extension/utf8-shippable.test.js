// 用户 2026-09-20：Chrome 装扩展一直弹「未能成功加载扩展程序：无法为内容脚本加载
// "subtitle-style.js" 文件。该文件采用的不是 UTF-8 编码」——源文件本身是合法 UTF-8，但
// normalizeFontFamily 的正则把范围上界 U+FFFF 当裸字符写进了源码；U+FFFF 是 Unicode 非字符，
// Chrome 校验内容脚本 / manifest 引用的每个文件用的是 base::IsStringUTF8（拒绝非字符与代理项），
// 整份扩展因此拒装，字幕外观、主题等所有新功能在用户机器上都「没变化」。
//
// 本守卫对所有会进包的文件（与 scripts/sync-mirrors.mjs 同一套排除规则）做同一标准的校验：
//  ① 严格 UTF-8 可解码；② 不含非字符（U+FDD0–U+FDEF、每个平面的 xFFFE/xFFFF）；③ 不含孤立代理项。
// 文本里真要表示这些码位一律写 \uXXXX 转义（JS 源码里转义在正则/字符串中语义不变）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = __dirname;
const TEXT_EXT = /\.(js|mjs|html|css|json|md|txt|svg)$/i;

function excluded(rel) {
  const top = rel.split(/[\\/]/)[0];
  return top === 'scripts' || /\.test\.js$/i.test(rel) || rel === 'README.md';
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules') walk(p, out); }
    else out.push(path.relative(ROOT, p).replace(/\\/g, '/'));
  }
  return out;
}

// 与 Chrome base::IsStringUTF8 同口径：非字符与代理项都算「不是 UTF-8」。
function findRejectedCodePoint(text) {
  for (let i = 0; i < text.length; i++) {
    const cp = text.codePointAt(i);
    if (cp > 0xffff) i++;
    const isSurrogate = cp >= 0xd800 && cp <= 0xdfff;
    const isNonChar = (cp >= 0xfdd0 && cp <= 0xfdef) || (cp & 0xfffe) === 0xfffe;
    if (isSurrogate || isNonChar) return { index: i, cp };
  }
  return null;
}

test('会进包的每个文本文件都是 Chrome 认可的 UTF-8：可严格解码、无非字符、无孤立代理项', () => {
  const files = walk(ROOT, []).filter((rel) => !excluded(rel) && TEXT_EXT.test(rel));
  assert.ok(files.includes('subtitle-style.js'), '扫描面必须覆盖 subtitle-style.js（回归用例）');
  assert.ok(files.includes('manifest.json'));
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const bad = [];
  for (const rel of files) {
    const bytes = fs.readFileSync(path.join(ROOT, rel));
    let text;
    try { text = decoder.decode(bytes); } catch (e) { bad.push(rel + ': 不是合法 UTF-8（' + e.message + '）'); continue; }
    const hit = findRejectedCodePoint(text);
    if (hit) {
      const line = text.slice(0, hit.index).split('\n').length;
      bad.push(rel + ':' + line + ': 含 U+' + hit.cp.toString(16).toUpperCase().padStart(4, '0') + '（非字符/代理项），请改写为 \\u 转义');
    }
  }
  assert.deepStrictEqual(bad, [], '以下文件会让 Chrome 报「该文件采用的不是 UTF-8 编码」并拒装整个扩展:\n' + bad.join('\n'));
});

test('判定函数本身：U+FFFF / U+FDD0 / 孤立代理项被拒，正常 CJK 与 NBSP 放行', () => {
  assert.ok(findRejectedCodePoint('a￿b'));
  assert.ok(findRejectedCodePoint('﷐'));
  assert.ok(findRejectedCodePoint('\ud800x'));
  assert.strictEqual(findRejectedCodePoint('字幕はこんなふうに 表示 😀'), null);
});
