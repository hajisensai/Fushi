import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const popupCss = fs.readFileSync(path.join(ROOT, 'vendor', 'popup.css'), 'utf8');
const contentCss = fs.readFileSync(path.join(ROOT, 'vendor', 'content.css'), 'utf8');
const popupJs = fs.readFileSync(path.join(ROOT, 'vendor', 'popup.js'), 'utf8');

// 静息制卡 '+' 的可见大小与可见位置。BUG-932 / BUG-1895 两轮都靠放大 font-size
// （18px → 24px → 30px）去凑相邻 1em SVG 的可见轮廓，但文本字形的垂直位置只由字体
// 度量决定（偏移 = (ascent - descent) / 2 - 数学轴；Edge 4x 实测 Segoe UI (Symbol)
// = +0.125em、DejaVu Sans +0.066em、Roboto ≈ +0.02em、Arial 0），字号越大偏得越多，
// 于是 30px 下加号比同排图标低 3.75px（BUG-1923）。BUG-1923 改成用两条绝对居中的
// 矩形几何绘制十字，位置与大小都与平台字体无关。下面锁住这组不变式。
const STATIC_BLOCK = /\.mine-button:not\(\.duplicate\)\s*\{([^}]*)\}/;
const ARMS_BLOCK =
  /\.mine-button:not\(\.duplicate\)::before,\s*\.mine-button:not\(\.duplicate\)::after\s*\{([^}]*)\}/;
const BEFORE_ARM =
  /\.mine-button:not\(\.duplicate\)::before\s*\{\s*width:\s*([\d.]+)em;\s*height:\s*([\d.]+)em;\s*\}/;
const AFTER_ARM =
  /\.mine-button:not\(\.duplicate\)::after\s*\{\s*width:\s*([\d.]+)em;\s*height:\s*([\d.]+)em;\s*\}/;

// popup.css 是真源，content.css 由它生成——两份一起锁，才能抓到「改了 popup.css
// 但忘了重新跑 generate-content-css.mjs」。
for (const [name, css] of [['popup.css', popupCss], ['content.css', contentCss]]) {
  test(`BUG-1923 [${name}]: 静息制卡 + 的字形不参与呈现`, () => {
    const block = STATIC_BLOCK.exec(css);
    assert.ok(block, '缺 .mine-button:not(.duplicate) 静息态规则块');
    assert.match(block[1], /-webkit-text-fill-color:\s*transparent/);
  });

  test(`BUG-1923 [${name}]: 十字两条臂以按钮盒为参照绝对居中`, () => {
    const arms = ARMS_BLOCK.exec(css);
    assert.ok(arms, '缺 ::before/::after 共享块，静息 + 没有几何绘制的十字');
    for (const decl of [
      /content:\s*''/,
      /position:\s*absolute/,
      /top:\s*50%/,
      /left:\s*50%/,
      /transform:\s*translate\(\s*-50%\s*,\s*-50%\s*\)/,
      /background:\s*currentColor/,
    ]) {
      assert.match(arms[1], decl);
    }
  });

  test(`BUG-1923 [${name}]: 横臂与竖臂互为转置且用 em`, () => {
    const b = BEFORE_ARM.exec(css);
    const a = AFTER_ARM.exec(css);
    assert.ok(b, '::before 横臂必须声明 em 单位的 width/height（px 不跟踪内容缩放）');
    assert.ok(a, '::after 竖臂必须声明 em 单位的 width/height（px 不跟踪内容缩放）');
    const [bw, bh] = [Number(b[1]), Number(b[2])];
    const [aw, ah] = [Number(a[1]), Number(a[2])];
    assert.ok(bw > bh, '::before 是横臂，宽必须大于高');
    assert.deepEqual([aw, ah], [bh, bw], '竖臂必须是横臂的转置，否则十字不再等臂');
  });

  test(`BUG-1923 [${name}]: 静息态本体不得再靠垂直位移补偿字形`, () => {
    const block = STATIC_BLOCK.exec(css);
    assert.ok(block);
    assert.ok(
      !/translateY|translate\s*\(/.test(block[1]),
      '静息态本体不得加 translate/translateY「补正」加号位置——补偿量随平台字体在 ' +
        '0 ~ 0.125em 之间变，补正 Windows 会把 Arial/Roboto 反向补歪',
    );
  });
}

test('BUG-1895: mine button reuses clickable action layout', () => {
  assert.match(popupJs, /className:\s*'inline-action-button mine-button'/);
});

test('BUG-1923: 静息态 textContent 仍是 + 文本标记', () => {
  assert.match(popupJs, /mineButton\.textContent\s*=\s*isMined\s*\?/);
});
