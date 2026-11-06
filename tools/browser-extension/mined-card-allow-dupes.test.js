// 反馈 E0sdqm4h-F / PR #2980 审查：浏览器扩展单击已制卡 ✓ 与 app 内同一判据——app 开着
// 「允许重复」（/api/duplicate 回 allowDuplicates:true）时 bridge-shim 的 findMinedMatches 回
// {mineNew:true}，popup.js 不弹「新增为重复卡 / 取消」、直接再制一张。右键 / 长按 ✓
// （openChooser:true）以及任何拿不到这个位的情况（旧 app、请求失败）一律回 null：扩展列不出
// 命中卡，popup.js 照旧问用户，绝不误制。
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

const dupReply = (data) => (msg) => (msg.type === 'duplicate'
  ? { ok: true, status: 200, data } : null);

test('findMinedMatches：单击 + app 允许重复 → {mineNew:true}，查询带原词', async () => {
  const { call, sent } = loadShim(dupReply({ duplicate: true, allowDuplicates: true }));
  const reply = await call('findMinedMatches', { expression: '走る', reading: 'はしる', openChooser: false });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(reply)), { mineNew: true });
  const msg = sent.find((m) => m.type === 'duplicate');
  assert.ok(msg, 'asks the server for the duplicate policy');
  assert.strictEqual(msg.expression, '走る');
  assert.strictEqual(msg.reading, 'はしる');
});

test('findMinedMatches：右键 / 长按（openChooser:true）永远回 null，不发请求', async () => {
  const { call, sent } = loadShim(dupReply({ duplicate: true, allowDuplicates: true }));
  assert.strictEqual(await call('findMinedMatches', { expression: '猫', reading: '', openChooser: true }), null);
  assert.strictEqual(sent.filter((m) => m.type === 'duplicate').length, 0);
});

test('findMinedMatches：不允许重复 / 旧 app 没有这个位 / 请求失败 → null（照旧问）', async () => {
  const cases = [
    dupReply({ duplicate: true, allowDuplicates: false }),
    dupReply({ duplicate: true }),
    () => ({ ok: false, status: 404, data: null }),
    () => null,
    () => { throw new Error('extension context invalidated'); },
  ];
  for (const responder of cases) {
    const { call } = loadShim(responder);
    assert.strictEqual(await call('findMinedMatches', { expression: '猫', reading: '' }), null);
  }
});
