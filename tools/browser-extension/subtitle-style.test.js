// 视频上字幕的外观设置（用户 2026-09-19：「浏览器字幕字体加入字体管理，比如大小、字重、间距、
// 行高、字体、对齐还有背景管理」）。
//  ① subtitle-style.js：normalize 夹值/回默认、字体串消毒；toCssVars 只给「与默认不同」的变量，
//     默认项为 null（覆盖层 removeProperty 交还 CSS）；底板颜色+不透明度合成 rgba。
//  ② content-css-overlay.css 的 #fushi-subtitle-overlay 每一项外观都读 --fushi-sub-* 且给默认值；
//     options.css 的预览节点默认值与之逐项一致（否则设置页预览和视频上不一样）。
//  ③ subtitle-panel.js 首读 + storage.onChanged 都把 subtitleStyle 落到覆盖层根；同一份设置在
//     200ms tick 里不重复写；删键回默认（全部 removeProperty）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT();

const STYLE_SRC = fs.readFileSync(path.join(__dirname, 'subtitle-style.js'), 'utf8');

function loadStyle() {
  const sandbox = { console };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(STYLE_SRC, sandbox, { filename: 'subtitle-style.js' });
  return sandbox.fushiSubtitleStyle;
}

// ───────── ① 纯函数 ─────────

test('normalize：缺省全默认；越界夹住；字重取整到百位；坏枚举回默认；字体串剥掉分号花括号', () => {
  const S = loadStyle();
  assert.deepEqual(S.normalize(undefined), S.DEFAULTS);
  assert.strictEqual(S.isDefault(null), true);
  const n = S.normalize({
    fontScale: 999, fontWeight: 650, letterSpacing: -40, lineHeight: '180', textAlign: 'justify',
    textColor: 'FFF', shadow: 'blurry', backgroundColor: '#12ab', backgroundOpacity: 101, borderRadius: -3,
    padding: 'x', fontFamily: '"Noto Sans JP"; } body { display:none',
  });
  assert.strictEqual(n.fontScale, 300);
  assert.strictEqual(n.fontWeight, 700);
  assert.strictEqual(n.letterSpacing, -5);
  assert.strictEqual(n.lineHeight, 180);
  assert.strictEqual(n.textAlign, 'center');
  assert.strictEqual(n.textColor, '#ffffff');
  assert.strictEqual(n.shadow, 'soft');
  assert.strictEqual(n.backgroundColor, '', '坏 hex 当没设');
  assert.strictEqual(n.backgroundOpacity, 100);
  assert.strictEqual(n.borderRadius, 0);
  assert.strictEqual(n.padding, 100);
  assert.strictEqual(n.fontFamily, '"Noto Sans JP" body displaynone');
  assert.doesNotMatch(n.fontFamily, /[;{}:]/);
});

test('toCssVars：默认设置全 null；改过的项给出变量；底板颜色 + 不透明度合成 rgba', () => {
  const S = loadStyle();
  const def = S.toCssVars(null);
  for (const k of Object.keys(def)) assert.strictEqual(def[k], null, k + ' 默认应交还 CSS');
  assert.deepEqual(Object.keys(def).sort(), [
    '--fushi-sub-align', '--fushi-sub-bg', '--fushi-sub-color', '--fushi-sub-family', '--fushi-sub-line-height',
    '--fushi-sub-padding', '--fushi-sub-radius', '--fushi-sub-scale', '--fushi-sub-shadow', '--fushi-sub-spacing',
    '--fushi-sub-weight',
  ]);
  const v = S.toCssVars({
    fontFamily: 'serif', fontScale: 150, fontWeight: 400, letterSpacing: 10, lineHeight: 200, textAlign: 'left',
    textColor: '#ffee00', shadow: 'none', backgroundColor: '#112233', backgroundOpacity: 50, borderRadius: 0, padding: 50,
  });
  assert.strictEqual(v['--fushi-sub-family'], 'serif');
  assert.strictEqual(v['--fushi-sub-scale'], '1.5');
  assert.strictEqual(v['--fushi-sub-weight'], '400');
  assert.strictEqual(v['--fushi-sub-spacing'], '0.1em');
  assert.strictEqual(v['--fushi-sub-line-height'], '2');
  assert.strictEqual(v['--fushi-sub-align'], 'left');
  assert.strictEqual(v['--fushi-sub-color'], '#ffee00');
  assert.strictEqual(v['--fushi-sub-shadow'], 'none');
  assert.strictEqual(v['--fushi-sub-bg'], 'rgba(17, 34, 51, 0.5)');
  assert.strictEqual(v['--fushi-sub-radius'], '0px');
  assert.strictEqual(v['--fushi-sub-padding'], '3.0px 6.0px 3.5px');
  // 只改不透明度：颜色用主题 scrim 的 rgb（#0c0f0d），不透明度用用户的。
  assert.strictEqual(S.toCssVars({ backgroundOpacity: 20 })['--fushi-sub-bg'], 'rgba(12, 15, 13, 0.2)');
  // 只改颜色：不透明度用默认 72%。
  assert.strictEqual(S.toCssVars({ backgroundColor: '#000000' })['--fushi-sub-bg'], 'rgba(0, 0, 0, 0.72)');
  // strong 描边是多层 text-shadow。
  assert.ok(S.toCssVars({ shadow: 'strong' })['--fushi-sub-shadow'].split(',').length >= 4);
});

test('applyTo：非默认 setProperty、默认 removeProperty；坏元素不抛', () => {
  const S = loadStyle();
  const set = {}, removed = [];
  const el = { style: { setProperty: (k, v) => { set[k] = v; }, removeProperty: (k) => removed.push(k) } };
  S.applyTo(el, { fontScale: 120 });
  assert.strictEqual(set['--fushi-sub-scale'], '1.2');
  assert.ok(removed.includes('--fushi-sub-weight') && removed.includes('--fushi-sub-bg'));
  assert.doesNotThrow(() => S.applyTo(null, {}));
});

// 用户 2026-09-20：「浏览器插件底板长宽无法自定义」——底板宽 / 高是视频盒的百分比（0 = 随内容），
// 覆盖层是 fixed 定位、CSS 百分比只对视口算，所以不走 --fushi-sub-* 变量，而是 boxPx 按视频盒折 px、
// applyBox 写 style.width / minHeight；覆盖层与设置页预览同一算法。
test('底板宽 / 高：默认 0 = 随内容；非 0 夹进 [下限, 上限]；boxPx 按 frame 折 px；applyBox 非 0 写 px、0 清空', () => {
  const S = loadStyle();
  assert.strictEqual(S.DEFAULTS.boxWidth, 0);
  assert.strictEqual(S.DEFAULTS.boxHeight, 0);
  assert.deepEqual(S.toCssVars({ boxWidth: 80, boxHeight: 30 }), S.toCssVars(null), '宽高不产生 CSS 变量');
  assert.strictEqual(S.isDefault({ boxWidth: 80 }), false);
  // 0 与「坏值」都回 0；1–19 抬到下限 20；越上限夹到 100。高同理（下限 5、上限 60）。
  assert.strictEqual(S.normalize({ boxWidth: 0 }).boxWidth, 0);
  assert.strictEqual(S.normalize({ boxWidth: 'x' }).boxWidth, 0);
  assert.strictEqual(S.normalize({ boxWidth: 5 }).boxWidth, 20);
  assert.strictEqual(S.normalize({ boxWidth: 250 }).boxWidth, 100);
  assert.strictEqual(S.normalize({ boxHeight: 2 }).boxHeight, 5);
  assert.strictEqual(S.normalize({ boxHeight: 99 }).boxHeight, 60);
  assert.strictEqual(S.normalize({ boxHeight: -3 }).boxHeight, 0, '负数夹到 0 = 随内容');
  const frame = { width: 1280, height: 720 };
  assert.deepEqual(S.boxPx(null, frame), { width: 0, minHeight: 0 });
  assert.deepEqual(S.boxPx({ boxWidth: 75, boxHeight: 20 }, frame), { width: 960, minHeight: 144 });
  assert.deepEqual(S.boxPx({ boxWidth: 75, boxHeight: 20 }, null), { width: 0, minHeight: 0 }, '没有盒就随内容');
  assert.deepEqual(S.boxPx({ boxWidth: 75 }, { width: 0, height: 720 }), { width: 0, minHeight: 0 });
  const el = { style: { width: '1px', minHeight: '1px' } };
  S.applyBox(el, { boxWidth: 50, boxHeight: 10 }, frame);
  assert.strictEqual(el.style.width, '640px');
  assert.strictEqual(el.style.minHeight, '72px');
  S.applyBox(el, null, frame);
  assert.strictEqual(el.style.width, '', '回默认要清空，交还 CSS 的随内容');
  assert.strictEqual(el.style.minHeight, '');
  assert.doesNotThrow(() => S.applyBox(null, {}, frame));
});

// 用户 2026-09-21：「浏览器插件右下角可以做成跟查词弹窗一样可以拖动大小，并且支持自适应调整
// 缩放包括大小和可展示内容多少」。拖拽把手量到的像素要经 boxFromPx 折回百分比（与 options 两根
// 滑杆同一处夹取），自适应缩放由 nextFitScale / fitTextInto 决定。
test('boxFromPx：像素折回百分比并按滑杆同一处夹取；frame 坏掉返回 null', () => {
  const S = loadStyle();
  const frame = { width: 1000, height: 500 };
  assert.deepEqual(S.boxFromPx(400, 100, frame), { boxWidth: 40, boxHeight: 20 });
  // 越界：宽上限 100%、高上限 60%。
  assert.deepEqual(S.boxFromPx(5000, 5000, frame), { boxWidth: 100, boxHeight: 60 });
  // 非 0 下限（20% / 5%）——拖到极小也不会变成「随内容」那个 0。
  assert.deepEqual(S.boxFromPx(10, 2, frame), { boxWidth: 20, boxHeight: 5 });
  assert.strictEqual(S.boxFromPx(400, 100, { width: 0, height: 500 }), null);
  assert.strictEqual(S.boxFromPx(NaN, 100, frame), null);
});

test('boxAutoFit：默认开；显式 false 才关；只有底板有高度时才介入', () => {
  const S = loadStyle();
  assert.strictEqual(S.DEFAULTS.boxAutoFit, true);
  assert.strictEqual(S.normalize(undefined).boxAutoFit, true);
  assert.strictEqual(S.normalize({ boxAutoFit: false }).boxAutoFit, false);
  // 开关本身不进 CSS 变量（它决定的是 --fushi-sub-fit 怎么算，不是一个外观值）。
  assert.ok(!('--fushi-sub-autofit' in S.toCssVars({ boxAutoFit: false })));
  assert.strictEqual(S.fitEnabled({ boxHeight: 20 }), true);
  assert.strictEqual(S.fitEnabled({ boxHeight: 20, boxAutoFit: false }), false);
  // 高 = 0（随内容）时盒子本来就随字长高，没有「放不放得下」可言。
  assert.strictEqual(S.fitEnabled({ boxWidth: 60 }), false);
});

test('nextFitScale：放不下就收、有富余就放、刚好就收手；顶到区间边界不再空转', () => {
  const S = loadStyle();
  // 内容比可用空间高一倍 → 倍率减半。
  let step = S.nextFitScale(1, { contentH: 200, availH: 100, contentW: 0, availW: 0 });
  assert.ok(step.fit < 1 && Math.abs(step.fit - 0.5) < 0.001);
  assert.strictEqual(step.done, false);
  // 只占一半 → 放大一倍（「底板越大字越大」）。
  step = S.nextFitScale(1, { contentH: 50, availH: 100, contentW: 0, availW: 0 });
  assert.ok(Math.abs(step.fit - 2) < 0.001);
  // 刚好放下（容差内）→ 收手。
  assert.strictEqual(S.nextFitScale(1, { contentH: 99, availH: 100 }).done, true);
  // 横向溢出只许收不许放：高度还有富余也不放大。
  step = S.nextFitScale(1, { contentH: 50, availH: 100, contentW: 200, availW: 100 });
  assert.ok(step.fit < 1);
  // 顶到下限后不再同方向空转。
  step = S.nextFitScale(S.FIT_RANGE[0], { contentH: 900, availH: 100 });
  assert.strictEqual(step.fit, S.FIT_RANGE[0]);
  assert.strictEqual(step.done, true);
  // 测不到内容（还没排版）时原样收手，不写坏值。
  assert.deepEqual(S.nextFitScale(1, { contentH: 0, availH: 100 }), { fit: 1, done: true });
});

// 一个会换行的文字层模型：字号 = 30 × fit，一行装 floor(可用宽 / 字号) 个字，
// scrollHeight = 行数 × 字号 × 行高。fitTextInto 每轮写 --fushi-sub-fit，读到的尺寸随之变化。
function makeFitPair(opts) {
  const o = Object.assign({ chars: 20, base: 30, lineHeight: 1.45, pad: 12, wrap: true }, opts);
  const props = new Map();
  const el = {
    clientWidth: o.clientWidth || 0,
    style: {
      setProperty: (k, v) => props.set(k, v),
      removeProperty: (k) => props.delete(k),
    },
    ownerDocument: {
      defaultView: {
        getComputedStyle: () => ({
          paddingTop: o.pad + 'px', paddingBottom: o.pad + 'px',
          paddingLeft: o.pad + 'px', paddingRight: o.pad + 'px',
        }),
      },
    },
  };
  const fit = () => parseFloat(props.get('--fushi-sub-fit') || '1');
  const font = () => o.base * fit();
  const textEl = {
    get scrollWidth() {
      const w = o.chars * font();
      return o.wrap ? Math.min(w, o.availW) : w;
    },
    get scrollHeight() {
      const perLine = Math.max(1, Math.floor(o.availW / font()));
      const lines = o.wrap ? Math.ceil(o.chars / perLine) : 1;
      return lines * font() * o.lineHeight;
    },
  };
  return { el, textEl, props, fit, font };
}

test('fitTextInto：长句缩到放得下、短句放大填满盒子；关掉自适应/随内容时交还 CSS', () => {
  const S = loadStyle();
  const frame = { width: 1000, height: 600 };
  // 底板 40% 宽 × 20% 高 = 400 × 120 px，扣掉上下内边距 24 后可用高 96。
  const style = { boxWidth: 40, boxHeight: 20 };
  const availW = 400 - 24;
  const availH = 96;

  // ① 长句（60 字）：默认字号下要折好几行，远超 96px → 必须缩小，且最终真的放得下。
  const long = makeFitPair({ chars: 60, availW: availW });
  const fitLong = S.fitTextInto(long.el, long.textEl, style, frame);
  assert.ok(fitLong < 1, '长句必须缩小，实得 ' + fitLong);
  assert.ok(long.textEl.scrollHeight <= availH + 0.5, '收手时必须真的放得下');

  // ② 短句（3 字）：一行绰绰有余 → 放大到把盒子填满（「底板越大字越大」）。
  const short = makeFitPair({ chars: 3, availW: availW });
  const fitShort = S.fitTextInto(short.el, short.textEl, style, frame);
  assert.ok(fitShort > 1, '短句应放大，实得 ' + fitShort);
  assert.ok(short.textEl.scrollHeight <= availH + 0.5, '放大后仍不许溢出');
  // 同一个盒子里，长句的字比短句小 = 「可展示内容多少」随盒子变。
  assert.ok(fitLong < fitShort);

  // ③ 关掉自适应：倍率交还 CSS（字号回到用户设的「大小」）。
  const off = makeFitPair({ chars: 60, availW: availW });
  assert.strictEqual(S.fitTextInto(off.el, off.textEl, { boxWidth: 40, boxHeight: 20, boxAutoFit: false }, frame), 1);
  assert.strictEqual(off.props.has('--fushi-sub-fit'), false);

  // ④ 底板回到随内容：同样不写倍率。
  const auto = makeFitPair({ chars: 60, availW: availW });
  assert.strictEqual(S.fitTextInto(auto.el, auto.textEl, { boxWidth: 0, boxHeight: 0 }, frame), 1);
  assert.strictEqual(auto.props.has('--fushi-sub-fit'), false);
});

test('fitTextInto：压到可读下限仍放不下就停在下限（底板自己长高，不裁字）；横向溢出也收', () => {
  const S = loadStyle();
  const frame = { width: 1000, height: 600 };
  // 400 × 30px 的极扁底板里塞 400 字：压到下限也放不下。
  const huge = makeFitPair({ chars: 400, availW: 376 });
  const fit = S.fitTextInto(huge.el, huge.textEl, { boxWidth: 40, boxHeight: 5 }, frame);
  assert.strictEqual(fit, S.FIT_RANGE[0], '停在可读下限，剩下的交给 min-height 长高');

  // 断不开的长词（wrap:false）：高度方向明明有富余，也不许为了填满而放大到横向溢出。
  const wide = makeFitPair({ chars: 20, availW: 376, wrap: false });
  const fitWide = S.fitTextInto(wide.el, wide.textEl, { boxWidth: 40, boxHeight: 30 }, frame);
  assert.ok(wide.textEl.scrollWidth <= 376 + 0.5, '横向不许溢出，实得 ' + wide.textEl.scrollWidth);
  assert.ok(fitWide < 1);
});

test('applyFit：非 1 写 --fushi-sub-fit、回 1 清掉；坏元素不抛', () => {
  const S = loadStyle();
  const props = new Map();
  const el = { style: { setProperty: (k, v) => props.set(k, v), removeProperty: (k) => props.delete(k) } };
  S.applyFit(el, 1.234);
  assert.strictEqual(props.get('--fushi-sub-fit'), '1.234');
  S.applyFit(el, 1);
  assert.strictEqual(props.has('--fushi-sub-fit'), false);
  // 区间外的值夹住，坏值当 1。
  S.applyFit(el, 99);
  assert.strictEqual(props.get('--fushi-sub-fit'), String(S.FIT_RANGE[1]));
  S.applyFit(el, NaN);
  assert.strictEqual(props.has('--fushi-sub-fit'), false);
  assert.doesNotThrow(() => S.applyFit(null, 2));
});

// 用户 2026-09-20：「字体不要手填而是下拉框并且可以下载字体」——下拉两组：本机字体栈
// （FONT_SUGGESTIONS）+ Fushi 字体库（app /api/extension/fonts）；库字体经 @font-face 挂进页面。
test('字体库辅助：栈标签取前两个 family；库条目值带引号且剥引号反斜杠；命中判据与存值同形', () => {
  const S = loadStyle();
  assert.strictEqual(S.fontStackLabel('"Hiragino Sans", "Yu Gothic UI", sans-serif'), 'Hiragino Sans / Yu Gothic UI');
  assert.strictEqual(S.fontStackLabel('monospace'), 'monospace');
  assert.strictEqual(S.fontFamilyValueOf('Klee "One" ' + String.fromCharCode(92) + 'x'), '"Klee One x"');
  assert.strictEqual(S.fontFamilyValueOf('   '), '');
  // 导入文件名带 [wght] / (1) 之类：与 normalizeFontFamily 同字符集，下拉回显与
  // @font-face 两边一致，matchesFushiFont 才命中。
  assert.strictEqual(S.fontFamilyValueOf('NotoSansJP[wght]'), '"NotoSansJPwght"');
  assert.ok(S.matchesFushiFont(S.normalize({ fontFamily: '"NotoSansJP[wght]"' }).fontFamily, 'NotoSansJP[wght]'));
  assert.ok(S.fontFaceCss([{ family: 'NotoSansJP[wght]', url: 'http://127.0.0.1:1/f.ttf', ext: 'ttf' }])
    .indexOf('font-family:"NotoSansJPwght";') >= 0);
  assert.strictEqual(S.matchesFushiFont('"Klee One"', 'Klee One'), true);
  assert.strictEqual(S.matchesFushiFont('Klee One', 'Klee One'), false, '未加引号的手填值不当作库条目');
  assert.strictEqual(S.matchesFushiFont('"Klee One"', ''), false);
});

test('fontFaceCss：每条库字体一条 @font-face（src 为 app 文件端点、按扩展名给 format）；非 http(s)/含引号空白的 url 与空 family 一律丢弃', () => {
  const S = loadStyle();
  const css = S.fontFaceCss([
    { family: 'Klee One', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=abc', ext: 'ttf' },
    { family: 'Noto Sans JP', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_2&token=abc', ext: 'woff2' },
    { family: 'Bad', url: 'javascript:alert(1)', ext: 'ttf' },
    { family: 'Bad2', url: 'http://127.0.0.1/a") } body { display:none', ext: 'ttf' },
    { family: '', url: 'http://127.0.0.1/x', ext: 'ttf' },
    { family: 'NoFmt', url: 'http://127.0.0.1/y', ext: 'bin' },
  ]);
  const lines = css.split('\n');
  assert.strictEqual(lines.length, 3);
  assert.strictEqual(lines[0],
    '@font-face{font-family:"Klee One";src:url("http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=abc") format("truetype");font-display:swap;}');
  assert.match(lines[1], /format\("woff2"\)/);
  assert.strictEqual(lines[2], '@font-face{font-family:"NoFmt";src:url("http://127.0.0.1/y");font-display:swap;}');
  assert.doesNotMatch(css, /javascript:|display:none/);
  assert.strictEqual(S.fontFaceCss(null), '');
});

// ───────── ② CSS 契约 ─────────

function subVarDefaults(block) {
  const out = {};
  for (const m of block.matchAll(/(--fushi-sub-[a-z-]+):\s*([^;]+);/g)) out[m[1]] = m[2].trim();
  return out;
}

test('覆盖层 CSS：每项外观读 --fushi-sub-* 并有默认值；options.css 预览默认值逐项一致；生成的 content.css 已含', () => {
  const overlay = fs.readFileSync(path.join(__dirname, 'scripts', 'content-css-overlay.css'), 'utf8');
  const block = /#fushi-subtitle-overlay \{([\s\S]*?)\n\}/.exec(overlay)[1];
  const defaults = subVarDefaults(block);
  const S = loadStyle();
  // --fushi-sub-fit 不经 toCssVars（它不是用户设的值，而是 applyFit 按实测内容算出来的自适应
  // 倍率），但同样必须在 CSS 里有默认值——没人写它时 font-size 的 calc 不能整条失效。
  assert.deepEqual(
    Object.keys(defaults).sort(),
    Object.keys(S.toCssVars(null)).concat(['--fushi-sub-fit']).sort(),
    'CSS 默认变量集 = toCssVars 输出集 + 自适应倍率',
  );
  assert.strictEqual(defaults['--fushi-sub-fit'], '1', '不写自适应倍率时零影响');
  for (const [prop, v] of [
    ['font-family', 'var(--fushi-sub-family)'], ['font-weight', 'var(--fushi-sub-weight)'],
    ['line-height', 'var(--fushi-sub-line-height)'], ['letter-spacing', 'var(--fushi-sub-spacing)'],
    ['text-align', 'var(--fushi-sub-align)'], ['text-shadow', 'var(--fushi-sub-shadow)'],
    ['color', 'var(--fushi-sub-color)'], ['background', 'var(--fushi-sub-bg)'],
    ['border-radius', 'var(--fushi-sub-radius)'], ['padding', 'var(--fushi-sub-padding)'],
  ]) {
    assert.ok(block.includes('\n    ' + prop + ': ' + v + ';'), prop + ' 应读 ' + v);
  }
  assert.match(block, /font-size: calc\(clamp\(18px, 2\.2vw, 32px\) \* var\(--fushi-sub-scale\) \* var\(--fushi-sub-fit\)\);/);
  assert.match(overlay, /#fushi-subtitle-overlay:has\(ruby\) \{\s*line-height: max\(2, var\(--fushi-sub-line-height\)\);/);
  // 默认值与旧观感一字不差（老用户零变化）。
  assert.strictEqual(defaults['--fushi-sub-family'], '"Hiragino Sans", "Yu Gothic UI", sans-serif');
  assert.strictEqual(defaults['--fushi-sub-weight'], '600');
  assert.strictEqual(defaults['--fushi-sub-line-height'], '1.45');
  assert.strictEqual(defaults['--fushi-sub-spacing'], '0.01em');
  assert.strictEqual(defaults['--fushi-sub-shadow'], '0 1px 3px #000, 1px 0 2px #000, -1px 0 2px #000');
  assert.strictEqual(defaults['--fushi-sub-padding'], '6px 12px 7px');
  // 设置页预览与覆盖层同一组默认值。
  const options = fs.readFileSync(path.join(__dirname, 'options.css'), 'utf8');
  const previewBlock = /\.subtitle-preview-cue \{([\s\S]*?)\n\}/.exec(options)[1];
  assert.deepEqual(subVarDefaults(previewBlock), defaults, 'options.css 预览默认值必须与覆盖层一致');
  const content = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  assert.match(content, /#fushi-subtitle-overlay \{[\s\S]*?--fushi-sub-scale: 1;/);
  // 底板宽 / 高写的是 border-box 的外尺寸；底板高于文字时文字垂直居中——覆盖层与预览都得是
  // grid + align-content:center + box-sizing:border-box，少一处两边观感就不一样。
  for (const [name, b] of [['覆盖层', block], ['预览', previewBlock]]) {
    assert.match(b, /box-sizing: border-box;/, name + ' 应 border-box');
    assert.match(b, /display: grid;/, name + ' 应 display:grid');
    assert.match(b, /align-content: center;/, name + ' 应 align-content:center');
  }
  assert.match(overlay, /#fushi-subtitle-overlay \.fushi-subtitle-overlay-text \{\s*display: block;/, '文字层是网格项，块级');
});

// ───────── ③ subtitle-panel.js 接线 ─────────

const CONTENT = path.join(__dirname, 'content.js');
const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const PANEL = path.join(__dirname, 'subtitle-panel.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');

function makeEl(tag) {
  const listeners = Object.create(null);
  const attrs = Object.create(null);
  const props = {};
  const el = {
    tagName: (tag || 'div').toUpperCase(), _id: '', className: '', textContent: '',
    style: {
      cssText: '', props, writes: 0,
      setProperty(k, v) { props[k] = v; this.writes++; },
      removeProperty(k) { delete props[k]; this.writes++; },
      getPropertyValue: (k) => props[k] || '',
    },
    dataset: {}, children: [], parentNode: null, offsetHeight: 40,
    setAttribute(k, v) { if (k === 'id') el._id = v; attrs[k] = String(v); },
    removeAttribute(k) { delete attrs[k]; },
    getAttribute(k) { return k in attrs ? attrs[k] : null; },
    hasAttribute(k) { return k in attrs; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    setPointerCapture() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) { const i = el.children.indexOf(child); if (i >= 0) el.children.splice(i, 1); child.parentNode = null; return child; },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

function findById(root, id) {
  if (root._id === id) return root;
  for (const c of root.children) { const hit = findById(c, id); if (hit) return hit; }
  return null;
}

function loadWorld(prefs) {
  const head = makeEl('head'), body = makeEl('body'), html = makeEl('html');
  html.appendChild(head); html.appendChild(body);
  const stored = Object.assign({ netflixSubtitlePanel: true, subtitleOverlayAllTracks: true }, prefs || {});
  const changeListeners = [];
  const intervals = [];
  const rect = { x: 100, y: 50, left: 100, top: 50, right: 1380, bottom: 770, width: 1280, height: 720 };
  const video = { currentTime: 0, paused: false, playbackRate: 1, textTracks: [], getBoundingClientRect: () => rect };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0, clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {}, requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: { hostname: 'www.youtube.com', href: 'https://www.youtube.com/watch?v=abc123', pathname: '/watch', search: '?v=abc123', protocol: 'https:' },
  };
  sandbox.document = {
    documentElement: html, head, body, fullscreenElement: null,
    addEventListener() {},
    getElementById: (id) => findById(html, id),
    querySelector: (sel) => (sel === 'video' ? video : null),
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: { id: 'test-ext-id', getURL: (rel) => 'chrome-extension://test-ext-id/' + rel, lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
    storage: {
      local: {
        get: (keys, cb) => {
          const out = {};
          for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k];
          if (cb) { cb(out); return undefined; }
          return { then: (fn) => { fn(out); return { catch() {} }; }, catch() {} };
        },
        set: (patch, cb) => {
          const changes = {};
          for (const k of Object.keys(patch)) { changes[k] = { oldValue: stored[k], newValue: patch[k] }; stored[k] = patch[k]; }
          for (const fn of changeListeners) fn(changes, 'local');
          if (cb) cb();
          return Promise.resolve();
        },
        remove: (keys) => {
          const changes = {};
          for (const k of [].concat(keys)) { changes[k] = { oldValue: stored[k] }; delete stored[k]; }
          for (const fn of changeListeners) fn(changes, 'local');
          return Promise.resolve();
        },
      },
      onChanged: { addListener: (fn) => changeListeners.push(fn) },
    },
  };
  sandbox.window = {
    fushiT: FUSHI_T,
    addEventListener() {}, removeEventListener() {}, postMessage() {},
    innerWidth: 1600, innerHeight: 900,
    matchMedia: () => ({ matches: false }),
    getSelection: () => ({ removeAllRanges() {} }),
    fushiSelection: { getCharacterAtPoint: () => null, selectFromPosition: () => '', clearSelection() {} },
  };
  sandbox.window.window = sandbox.window;
  sandbox.self = sandbox.window;
  sandbox.globalThis = sandbox;
  sandbox.navigator = { clipboard: { writeText: () => Promise.resolve() } };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), sandbox, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), sandbox, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), sandbox, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), sandbox, { filename: 'subtitle-providers.js' });
  vm.runInContext(STYLE_SRC, sandbox, { filename: 'subtitle-style.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), sandbox, { filename: 'content.js' });
  vm.runInContext(fs.readFileSync(PANEL, 'utf8'), sandbox, { filename: 'subtitle-panel.js' });
  sandbox.window.fushiLookupAtPoint = () => {};
  const tick = () => { for (const it of intervals) if (it.ms === 200) it.fn(); };
  const overlayEl = () => findById(html, 'fushi-subtitle-overlay');
  const setTrack = (lang, cues) => {
    const key = 'yt-abc123|' + lang;
    sandbox.window.fushiEpisodeCues[key] = cues;
    sandbox.window.fushiSubtitlePanelOnCues(key);
  };
  return { sandbox, stored, tick, overlayEl, setTrack, storage: sandbox.chrome.storage.local };
}

const CUES = [{ startMs: 0, endMs: 3000, text: '君の名は' }, { startMs: 3000, endMs: 6000, text: '大丈夫だ' }];

test('首读 subtitleStyle 落到覆盖层根；同一份设置在 tick 里不重复写 style', () => {
  const w = loadWorld({ subtitleStyle: { fontScale: 130, fontWeight: 700, textAlign: 'left' } });
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.ok(el, '覆盖层应已挂出');
  assert.strictEqual(el.style.props['--fushi-sub-scale'], '1.3');
  assert.strictEqual(el.style.props['--fushi-sub-weight'], '700');
  assert.strictEqual(el.style.props['--fushi-sub-align'], 'left');
  assert.strictEqual(el.style.props['--fushi-sub-color'], undefined, '默认项不写');
  const writes = el.style.writes;
  w.tick(); w.tick(); w.tick();
  assert.strictEqual(el.style.writes, writes, 'tick 不该反复重写 style');
});

test('设置页改动经 storage.onChanged 立刻生效；删键回默认（全部 removeProperty）；旧布尔底板开关照旧', () => {
  const w = loadWorld();
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.strictEqual(el.style.props['--fushi-sub-scale'], undefined);
  w.storage.set({ subtitleStyle: { fontFamily: 'serif', backgroundColor: '#000000', backgroundOpacity: 30 } });
  assert.strictEqual(el.style.props['--fushi-sub-family'], 'serif');
  assert.strictEqual(el.style.props['--fushi-sub-bg'], 'rgba(0, 0, 0, 0.3)');
  w.storage.set({ subtitleOverlayBackground: false });
  assert.strictEqual(el.hasAttribute('data-bare'), true, '底板开关仍是 data-bare');
  assert.strictEqual(el.style.props['--fushi-sub-family'], 'serif', '改别的键不能把外观刷掉');
  w.storage.remove('subtitleStyle');
  assert.deepEqual(el.style.props, {}, '删键后全部变量交还 CSS');
});

// ───────── ④ Fushi 字体库 @font-face ─────────

function withFontMessages(w, fonts) {
  const calls = [];
  w.sandbox.chrome.runtime.sendMessage = (msg, cb) => {
    calls.push(msg);
    if (msg && msg.type === 'subtitleFonts' && cb) cb(fonts ? { ok: true, fonts } : { ok: false });
  };
  return calls;
}

test('外观选了字体 → 向 background 要一次字体清单并把 @font-face 挂进 <head>；没选字体不请求；app 没开不挂且允许重试', () => {
  const FONTS = [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'ttf', url: 'http://127.0.0.1:19633/api/extension/fonts/file?id=font_1&token=t' }];
  // ① 没选字体：不请求。
  const w0 = loadWorld({ subtitleStyle: { fontScale: 120 } });
  const calls0 = withFontMessages(w0, FONTS);
  w0.setTrack('ja', CUES); w0.tick();
  assert.strictEqual(calls0.filter((m) => m.type === 'subtitleFonts').length, 0);
  // ② 选了库字体：请求一次，<head> 里出现 @font-face；再 tick 不重复请求。
  const w = loadWorld({ subtitleStyle: { fontFamily: '"Klee One"' } });
  const calls = withFontMessages(w, FONTS);
  w.setTrack('ja', CUES); w.tick(); w.tick();
  assert.strictEqual(calls.filter((m) => m.type === 'subtitleFonts').length, 1);
  const styleEl = w.sandbox.document.getElementById('fushi-subtitle-fontfaces');
  assert.ok(styleEl, '应注入 <style id=fushi-subtitle-fontfaces>');
  assert.strictEqual(styleEl.parentNode, w.sandbox.document.head);
  assert.match(styleEl.textContent, /@font-face\{font-family:"Klee One";src:url\("http:\/\/127\.0\.0\.1:19633\/api\/extension\/fonts\/file\?id=font_1&token=t"\) format\("truetype"\)/);
  assert.strictEqual(w.overlayEl().style.props['--fushi-sub-family'], '"Klee One"');
  // ③ 设置页又改了外观：允许再拉一次清单（可能刚下载了新字体），清单没变不重写。
  const text = styleEl.textContent;
  w.storage.set({ subtitleStyle: { fontFamily: '"Klee One"', fontScale: 150 } });
  assert.strictEqual(calls.filter((m) => m.type === 'subtitleFonts').length, 2);
  assert.strictEqual(styleEl.textContent, text);
  // ④ app 没开：不挂，且下次外观变化会重试。
  const w2 = loadWorld({ subtitleStyle: { fontFamily: '"Klee One"' } });
  const calls2 = withFontMessages(w2, null);
  w2.setTrack('ja', CUES); w2.tick();
  assert.strictEqual(calls2.filter((m) => m.type === 'subtitleFonts').length, 1);
  assert.strictEqual(w2.sandbox.document.getElementById('fushi-subtitle-fontfaces'), null);
  w2.storage.set({ subtitleStyle: { fontFamily: '"Klee One"', fontScale: 110 } });
  assert.strictEqual(calls2.filter((m) => m.type === 'subtitleFonts').length, 2, '失败后允许重试');
});

// ───────── ⑤ background：subtitleFonts / subtitleFontDownload ─────────

function loadBackground(routes) {
  const stored = { host: '127.0.0.1', port: 19733, token: 'tk' };
  const fetches = [];
  const sandbox = {
    console, URL, btoa: (s) => Buffer.from(s).toString('base64'),
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval,
    performance: { now: () => 1, timeOrigin: 0 },
    AbortSignal: { timeout: () => null },
    fetch: (url, init) => {
      const u = new URL(url);
      fetches.push({ path: u.pathname, method: init && init.method, auth: init && init.headers && init.headers.Authorization, body: init && init.body ? JSON.parse(init.body) : null });
      const r = routes[u.pathname];
      if (!r) return Promise.reject(new Error('ECONNREFUSED'));
      return Promise.resolve({ ok: r.status === 200, status: r.status, headers: { get: () => null }, json: () => Promise.resolve(r.body), text: () => Promise.resolve(JSON.stringify(r.body)) });
    },
    importScripts() {},
    chrome: {
      storage: { local: { get: (keys) => Promise.resolve(Object.fromEntries([].concat(keys).filter((k) => k in stored).map((k) => [k, stored[k]]))), set: () => Promise.resolve() }, onChanged: { addListener() {} } },
      runtime: { onMessage: { addListener: (fn) => { sandbox._onMessage = fn; } }, onStartup: { addListener() {} }, onInstalled: { addListener() {} }, getURL: (r) => r, id: 'x' },
      alarms: { create() {}, onAlarm: { addListener() {} } },
      action: { setBadgeText() {}, setBadgeBackgroundColor() {}, setTitle() {}, onClicked: { addListener() {} } },
      tabs: { onUpdated: { addListener() {} }, onRemoved: { addListener() {} }, query: () => Promise.resolve([]) },
      webNavigation: { onCompleted: { addListener() {} } },
      sidePanel: { setPanelBehavior: () => Promise.resolve(), setOptions() {} },
      offscreen: { hasDocument: () => Promise.resolve(false) },
      cookies: { getAll: () => Promise.resolve([]) },
    },
  };
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'), sandbox, { filename: 'background.js' });
  const ask = (msg) => new Promise((resolve) => { sandbox._onMessage(msg, { tab: { id: 1 } }, resolve); });
  return { ask, fetches };
}

test('background subtitleFonts：POST /api/extension/fonts 带 Basic 鉴权；每条字体拼上带 token 的文件 URL；坏条目丢弃；app 没开 ok:false', async () => {
  const status = { status: 200, body: { app: 'fushi' } };
  const bg = loadBackground({
    '/api/extension/status': status,
    '/api/extension/fonts': { status: 200, body: {
      fonts: [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'TTF' }, { id: '', family: 'x' }, { id: 'font_3' }],
      recommended: [{ name: 'Klee One', nameJa: 'クレー One', installed: true }],
    } },
  });
  const r = await bg.ask({ type: 'subtitleFonts' });
  assert.strictEqual(r.ok, true);
  const call = bg.fetches.find((f) => f.path === '/api/extension/fonts');
  assert.strictEqual(call.method, 'POST');
  assert.strictEqual(call.auth, 'Basic ' + Buffer.from('fushi:tk').toString('base64'));
  assert.deepEqual(r.fonts, [{ id: 'font_1', name: 'Klee One', family: 'Klee One', ext: 'ttf', url: 'http://127.0.0.1:19733/api/extension/fonts/file?id=font_1&token=tk' }]);
  assert.deepEqual(r.recommended, [{ name: 'Klee One', nameJa: 'クレー One', installed: true }]);
  const off = loadBackground({});
  const r2 = await off.ask({ type: 'subtitleFonts' });
  assert.strictEqual(r2.ok, false);
});

test('background subtitleFontDownload：POST /api/extension/fonts/download {name}；app 的 ok/error 原样透传，新字体同样拼 URL', async () => {
  const bg = loadBackground({
    '/api/extension/status': { status: 200, body: { app: 'fushi' } },
    '/api/extension/fonts/download': { status: 200, body: { ok: true, fonts: [{ id: 'font_9', name: 'Noto Sans JP', family: 'Noto Sans JP', ext: 'ttf' }] } },
  });
  const r = await bg.ask({ type: 'subtitleFontDownload', name: 'Noto Sans JP' });
  const call = bg.fetches.find((f) => f.path === '/api/extension/fonts/download');
  assert.deepEqual(call.body, { name: 'Noto Sans JP' });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.fonts[0].url, 'http://127.0.0.1:19733/api/extension/fonts/file?id=font_9&token=tk');
  const bad = loadBackground({
    '/api/extension/status': { status: 200, body: { app: 'fushi' } },
    '/api/extension/fonts/download': { status: 404, body: { ok: false, error: 'unknown_font' } },
  });
  const r2 = await bad.ask({ type: 'subtitleFontDownload', name: 'Nope' });
  assert.strictEqual(r2.ok, false);
  assert.strictEqual(r2.error, 'unknown_font');
  assert.strictEqual(r2.status, 404);
});

test('底板宽 / 高落到覆盖层：按视频盒折 px 写 style.width / minHeight；设置改动经 storage 立刻重摆；回默认清空', () => {
  const w = loadWorld({ subtitleStyle: { boxWidth: 50, boxHeight: 10 } });
  w.setTrack('ja', CUES);
  w.tick();
  const el = w.overlayEl();
  assert.ok(el, '覆盖层应已挂出');
  // loadWorld 的视频盒 1280×720。
  assert.strictEqual(el.style.width, '640px');
  assert.strictEqual(el.style.minHeight, '72px');
  assert.strictEqual(el.style.maxWidth, '1468px', '视口夹取照旧，宽写的是 width、不动 max-width');
  w.storage.set({ subtitleStyle: { boxWidth: 100 } });
  assert.strictEqual(el.style.width, '1280px');
  assert.strictEqual(el.style.minHeight, '', '高回 0 = 清空');
  w.storage.remove('subtitleStyle');
  assert.strictEqual(el.style.width, '', '删键回默认：宽清空、随内容');
  assert.strictEqual(el.style.minHeight, '');
});
