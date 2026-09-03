// popup-size.js 的行为测试：扩展独立尺寸覆盖 + 侧边栏空间不足时的收敛。
const { test } = require('node:test');
const assert = require('node:assert');
const {
  FUSHI_POPUP_MIN_WIDTH,
  FUSHI_POPUP_MIN_HEIGHT,
  FUSHI_POPUP_MAX_WIDTH,
  FUSHI_POPUP_MAX_HEIGHT,
  FUSHI_POPUP_MIN_ZOOM,
  fushiParsePx,
  fushiClampPopupSize,
  fushiResolvePopupBox,
} = require('./popup-size.js');

const THEME = {
  '--fushi-popup-max-width': '520px',
  '--fushi-popup-max-height': '400px',
  '--fushi-popup-zoom': '1.4',
};

test('无覆盖、无视口时原样采用 app 下发的 theme 尺寸', () => {
  const box = fushiResolvePopupBox(THEME, null);
  assert.strictEqual(box.width, 520);
  assert.strictEqual(box.maxHeight, 400);
  assert.strictEqual(box.zoom, 1.4);
  assert.strictEqual(box.clamped, false);
});

test('theme 缺失时回落到内置默认，不产生 NaN/0 尺寸', () => {
  const box = fushiResolvePopupBox(null, null);
  assert.strictEqual(box.width, 400);
  assert.strictEqual(box.maxHeight, 360);
  assert.strictEqual(box.zoom, 1);
});

// ── 尺寸真相源唯一：app 的 extension_popup_* 偏好，经 theme 下发 ──
// 扩展设置页「查词框大小」写的是同一条通道（POST /api/extension/popup-size），
// **不得**在扩展本地另存一份尺寸——那会变成第二个真相源，用户在 app 设置页调完不生效。
test('扩展本地不得存尺寸：三个消费端都不读任何本地尺寸键', () => {
  const fsx = require('node:fs');
  const pathx = require('node:path');
  for (const f of ['content.js', 'side-panel.js', 'options.js']) {
    const src = fsx.readFileSync(pathx.join(__dirname, f), 'utf8');
    assert.doesNotMatch(src, /popupSizeOverride/,
      f + ' 不得引入本地尺寸覆盖键（第二真相源）');
  }
  // 设置页只能经既有的 popupSize 消息写回 app，不能自己 storage.set 尺寸。
  const options = fsx.readFileSync(pathx.join(__dirname, 'options.js'), 'utf8');
  assert.match(options, /type: 'popupSize', maxWidth: size\.width, maxHeight: size\.height/);
});

test('本地 clamp 与 app 滑杆同源，非法输入返回 null（不提交）', () => {
  const big = fushiClampPopupSize(99999, 99999);
  assert.strictEqual(big.width, FUSHI_POPUP_MAX_WIDTH);
  assert.strictEqual(big.height, FUSHI_POPUP_MAX_HEIGHT);
  const small = fushiClampPopupSize(10, 10);
  assert.strictEqual(small.width, FUSHI_POPUP_MIN_WIDTH);
  assert.strictEqual(small.height, FUSHI_POPUP_MIN_HEIGHT);
  for (const bad of [['', ''], ['abc', 300], [0, 300], [-1, 300], [400, 0]]) {
    assert.strictEqual(fushiClampPopupSize(bad[0], bad[1]), null,
      JSON.stringify(bad) + ' 应判为不成立、不提交');
  }
});

// 边界必须与 content.js 拖拽把手、app 设置页滑杆、Dart kLookupPopup* 同源——四条路径
// 写同一个真值，数字各写一份迟早分叉（拖拽能拖出滑杆写不出的尺寸）。
test('最小宽/高常量是唯一定义：content.js 不得再复制这两个数字', () => {
  const content = require('node:fs').readFileSync(
    require('node:path').join(__dirname, 'content.js'), 'utf8');
  assert.doesNotMatch(content, /const FUSHI_POPUP_MIN_WIDTH\s*=/);
  assert.doesNotMatch(content, /const FUSHI_POPUP_MIN_HEIGHT\s*=/);
  assert.match(content, /minW: FUSHI_POPUP_MIN_WIDTH/, '拖拽下限仍引用同一常量');
});

test('边界值与 Dart 侧 kLookupPopup* 一致（250-2000 / 200-1600）', () => {
  assert.strictEqual(FUSHI_POPUP_MIN_WIDTH, 250);
  assert.strictEqual(FUSHI_POPUP_MAX_WIDTH, 2000);
  assert.strictEqual(FUSHI_POPUP_MIN_HEIGHT, 200);
  assert.strictEqual(FUSHI_POPUP_MAX_HEIGHT, 1600);
});

// ── 根因回归：CSS zoom 之下的 px 宽度在窄侧边栏里必定溢出 ──
// 修复前 side-panel.js 直接写 `width: <theme>px` + `max-width: calc(100vw - 16px)`：
// vw 上限本身也被 zoom 放大，拦不住，弹窗渲染宽 = 520 × 1.4 = 728px 落在 320px 的
// 侧边栏里，右半边被 overflow-x:hidden 永久切掉。
test('窄侧边栏：渲染宽度（基准 × zoom）绝不超过可用宽度', () => {
  const viewport = { width: 320, height: 900 };
  const box = fushiResolvePopupBox(THEME, viewport);
  const rendered = box.width * box.zoom;
  assert.ok(rendered <= 320 - 16 + 0.5,
    '渲染宽 ' + rendered + ' 必须 <= 可用宽 ' + (320 - 16));
  assert.strictEqual(box.clamped, true);
});

test('宽视口下不做任何收敛（夹取只缩不放）', () => {
  const box = fushiResolvePopupBox(THEME, { width: 1600, height: 1200 });
  assert.strictEqual(box.width, 520);
  assert.strictEqual(box.zoom, 1.4);
  assert.strictEqual(box.clamped, false);
});

test('极窄侧边栏：压到最窄可读宽度仍放不下时改压 zoom，而不是继续切内容', () => {
  const viewport = { width: 200, height: 900 };
  const box = fushiResolvePopupBox(THEME, viewport);
  assert.ok(box.zoom < 1.4, 'zoom 应被降下来，实际 ' + box.zoom);
  assert.ok(box.zoom >= FUSHI_POPUP_MIN_ZOOM, 'zoom 不得低于可读下限');
  assert.ok(box.width * box.zoom <= 200 - 16 + 0.5,
    '渲染宽 ' + box.width * box.zoom + ' 仍须落在可用宽内');
});

test('theme 宽度本就低于最小基准宽时，zoom 绝不被反向放大', () => {
  // 老 profile 里存着抬滑杆下限之前写的 <250 值（偏好是持久化的，历史值不受
  // 当前滑杆约束）。此前 `width < MIN_WIDTH` 的分支是无条件覆盖赋值
  // `zoom = max(MIN_ZOOM, availW / MIN_WIDTH)`，丢掉了传入的 zoom：400px 侧边栏下
  // 240px 的小窗会被放大成 zoom≈1.54 铺满整条侧边栏——与「夹取只缩不放」的契约相反。
  const theme = { '--fushi-popup-max-width': '240px', '--fushi-popup-max-height': '300px' };
  const box = fushiResolvePopupBox(theme, { width: 400, height: 900 });
  assert.strictEqual(box.zoom, 1, 'zoom 必须原样保留，不得被抬高');
  assert.strictEqual(box.width, 240, '放得下就别动用户设的宽度');
  assert.strictEqual(box.clamped, false, '没被视口压过就不该标记 clamped');
});

// 正向契约护栏（不是上一条那种回归守卫——原实现在这条路径上也是对的）：视口放得下
// 时 zoom 必须原样透传。挡的是「在 vw>0 分支开头无条件夹一次 zoom」这类未来改动。
// --fushi-popup-zoom = dictionaryFontSize/16，app 侧 clamp 到 0.3~8.0，所以 0.3 是
// 可下发的真实值；FUSHI_POPUP_MIN_ZOOM 只是「空间不足要压 zoom 时」的下限，不是给
// 下发值兜底的地方。
test('视口放得下时下发 zoom 原样透传，不被 MIN_ZOOM 抬高', () => {
  const theme = {
    '--fushi-popup-max-width': '600px',
    '--fushi-popup-max-height': '300px',
    '--fushi-popup-zoom': '0.3',
  };
  const box = fushiResolvePopupBox(theme, { width: 400, height: 900 });
  assert.strictEqual(box.zoom, 0.3, '视口放得下时 zoom 原样透传，不得抬到 MIN_ZOOM');
});

test('高度上限按「视口 80% ÷ zoom」折回基准尺度', () => {
  const box = fushiResolvePopupBox(THEME, { width: 1600, height: 500 });
  // 80% × 500 = 400 渲染 px；zoom=1.4 → 基准上限 ≈ 285.7
  assert.ok(box.maxHeight < 400, '高度应被夹小，实际 ' + box.maxHeight);
  assert.ok(box.maxHeight * box.zoom <= 500 * 0.8 + 0.5,
    '渲染高 ' + box.maxHeight * box.zoom + ' 必须 <= 视口 80%');
});

test('zoom=1 时视口夹取退化为「不超过可用宽/80% 高」，与旧 CSS 语义一致', () => {
  const theme = { '--fushi-popup-max-width': '400px', '--fushi-popup-max-height': '360px' };
  const box = fushiResolvePopupBox(theme, { width: 300, height: 400 });
  assert.strictEqual(box.zoom, 1);
  assert.strictEqual(box.width, 284, '300 - 16');
  assert.strictEqual(box.maxHeight, 320, '400 × 0.8');
});

test('fushiParsePx 只接受纯 px 数值，函数式长度回落 fallback', () => {
  assert.strictEqual(fushiParsePx('400px', 1), 400);
  assert.strictEqual(fushiParsePx('400', 1), 400);
  assert.strictEqual(fushiParsePx(400, 1), 400);
  assert.strictEqual(fushiParsePx('min(400px, 80vh)', 7), 7);
  assert.strictEqual(fushiParsePx('', 7), 7);
  assert.strictEqual(fushiParsePx(undefined, 7), 7);
});
