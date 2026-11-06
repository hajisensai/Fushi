// Fushi 复习（SRS）词状态标记在浏览器扩展里的接线：
//   popup callHandler('srsTermStatus') → bridge-shim → background 'srsTermStatus'
//   → POST /api/srs/term-status {expression,reading} → {status: null | {...}}。
// app 的复习模块关着时服务端 404：shim 记住一段时间不再转发（每次查词不白跑一趟 HTTP），
// 任何失败都回 null（弹窗不显示复习标记），绝不阻断查词。点标记走 srsOpenCard → /api/srs/open。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadShim(responder) {
  const sent = [];
  const chrome = {
    runtime: {
      sendMessage: (msg, cb) => {
        sent.push(msg);
        const res = responder(msg);
        if (typeof cb === 'function') cb(res);
        return Promise.resolve(res);
      },
    },
    storage: { onChanged: { addListener: () => {} } },
  };
  const windowObj = {};
  const ctx = { window: windowObj, chrome };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'bridge-shim.js'), 'utf8'), ctx);
  return { call: windowObj.flutter_inappwebview.callHandler, sent };
}

test('srsTermStatus：转发词形与读音，回服务端的状态对象', async () => {
  const status = { queue: 'review', dueLabel: 'Review in 3 days', cardId: 'c1', noteId: 'n1' };
  const { call, sent } = loadShim((msg) =>
    msg.type === 'srsTermStatus' ? { ok: true, status: 200, data: { status } } : null);
  const result = await call('srsTermStatus', { expression: '雪', reading: 'ゆき' });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(result)), status);
  const msg = sent.find((m) => m.type === 'srsTermStatus');
  assert.strictEqual(msg.expression, '雪');
  assert.strictEqual(msg.reading, 'ゆき');
});

test('srsTermStatus：复习模块关着（404）后退避，不再每次查词都问', async () => {
  const { call, sent } = loadShim(() => ({ ok: false, status: 404, data: null }));
  assert.strictEqual(await call('srsTermStatus', { expression: '雪' }), null);
  assert.strictEqual(await call('srsTermStatus', { expression: '雨' }), null);
  assert.strictEqual(sent.filter((m) => m.type === 'srsTermStatus').length, 1);
});

test('srsTermStatus：失败一律回 null（不显示标记，不抛）', async () => {
  for (const responder of [
    () => null,
    () => ({ ok: false, status: 500, data: null }),
    () => ({ ok: true, status: 200, data: {} }),
    () => { throw new Error('extension context invalidated'); },
  ]) {
    const { call } = loadShim(responder);
    assert.strictEqual(await call('srsTermStatus', { expression: '猫' }), null);
  }
});

test('srsOpenCard：转发 cardId / noteId，回是否打开', async () => {
  const { call, sent } = loadShim((msg) =>
    msg.type === 'srsOpenCard' ? { ok: true, status: 200, data: { opened: true } } : null);
  assert.strictEqual(await call('srsOpenCard', { cardId: 'c1', noteId: 'n1' }), true);
  const msg = sent.find((m) => m.type === 'srsOpenCard');
  assert.strictEqual(msg.cardId, 'c1');
  assert.strictEqual(msg.noteId, 'n1');
  const failing = loadShim(() => ({ ok: false, status: 404, data: null }));
  assert.strictEqual(await failing.call('srsOpenCard', { cardId: 'c1' }), false);
});

test('background 把两条消息转到 /api/srs/term-status 与 /api/srs/open；嵌套弹窗放行两根桥', () => {
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.ok(bg.includes("msg.type === 'srsTermStatus'") && bg.includes("'/api/srs/term-status'"));
  assert.ok(bg.includes("msg.type === 'srsOpenCard'") && bg.includes("'/api/srs/open'"));
  const host = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
  assert.ok(host.includes("'srsTermStatus'") && host.includes("'srsOpenCard'"));
});

// srs_followup K：popup.js 一轮可见批次合成一次 srsTermStatusBatch → 一条
// /api/srs/term-status-batch。退避期回等长全 null（不是「不支持」）；老 app 没有批量端点
// （404 / 其它失败）回 null，popup.js 本批退回逐条（老端点照旧）。
test('srsTermStatusBatch：一批词一条消息，回等长同序的状态', async () => {
  const s1 = { queue: 'new', dueLabel: 'New', cardId: 'c1', noteId: 'n1' };
  const { call, sent } = loadShim((msg) => msg.type === 'srsTermStatusBatch'
    ? { ok: true, status: 200, data: { statuses: [s1, null] } } : null);
  const result = await call('srsTermStatusBatch', {
    terms: [{ expression: '雪', reading: 'ゆき' }, { expression: '雨', reading: '' }],
  });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(result)), { statuses: [s1, null] });
  const msgs = sent.filter((m) => m.type.startsWith('srsTermStatus'));
  assert.strictEqual(msgs.length, 1, '一个可见批次只发一次请求');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(msgs[0].terms)),
    [{ expression: '雪', reading: 'ゆき' }, { expression: '雨', reading: '' }]);
});

test('srsTermStatusBatch：老 app（404 / 形状不对 / 失败）回 null 让 popup 退回逐条', async () => {
  for (const responder of [
    () => ({ ok: false, status: 404, data: null }),
    () => ({ ok: false, status: 500, data: null }),
    () => ({ ok: true, status: 200, data: { statuses: [null] } }),
    () => { throw new Error('extension context invalidated'); },
  ]) {
    const { call } = loadShim(responder);
    assert.strictEqual(await call('srsTermStatusBatch', {
      terms: [{ expression: '雪' }, { expression: '雨' }],
    }), null);
  }
  // 批量 404 不触发退避：逐条端点还要能问到（真关着时由它 404 并退避）。
  const { call, sent } = loadShim((msg) => msg.type === 'srsTermStatus'
    ? { ok: true, status: 200, data: { status: null } }
    : { ok: false, status: 404, data: null });
  await call('srsTermStatusBatch', { terms: [{ expression: '雪' }, { expression: '雨' }] });
  await call('srsTermStatus', { expression: '雪' });
  assert.strictEqual(sent.filter((m) => m.type === 'srsTermStatus').length, 1);
});

test('srsTermStatusBatch：复习模块关着的退避期内回等长全 null，不发消息', async () => {
  const { call, sent } = loadShim(() => ({ ok: false, status: 404, data: null }));
  await call('srsTermStatus', { expression: '雪' });
  const result = await call('srsTermStatusBatch', {
    terms: [{ expression: '雪' }, { expression: '雨' }],
  });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(result)), { statuses: [null, null] });
  assert.strictEqual(sent.filter((m) => m.type === 'srsTermStatusBatch').length, 0);
});

test('background / side-panel / 嵌套弹窗都接上批量桥', () => {
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.ok(bg.includes("msg.type === 'srsTermStatusBatch'") &&
    bg.includes("'/api/srs/term-status-batch'"));
  const side = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  assert.ok(side.includes("name === 'srsTermStatusBatch'"));
  const host = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
  assert.ok(host.includes("'srsTermStatusBatch'"));
});
