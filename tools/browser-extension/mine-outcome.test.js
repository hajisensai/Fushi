// mine-outcome.js 行为测试：content script（Netflix 回放）与 service worker（YouTube 批量）共用的
// 制卡结果分类判据。只有 done 出队（TODO-1184：duplicate 也必须出队，否则队列永不清），HTTP/网络
// 失败要给出原因（TODO-1331），success+message 是「卡建了但音频落空」的部分成功（TODO-1303）。
const { test } = require('node:test');
const assert = require('node:assert');
const { fushiMineOutcome } = require('./mine-outcome.js');

const t = (key, params) => key + (params ? JSON.stringify(params) : '');
const ok = (data) => ({ ok: true, status: 200, data });

test('success and duplicate both leave the queue; success+message warns', () => {
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'success' }), t),
    { cls: 'done', notice: null, settingsFixable: false });
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'duplicate', message: 'x' }), t),
    { cls: 'done', notice: null, settingsFixable: false });
  assert.strictEqual(fushiMineOutcome(ok({ result: 'success', message: '音频落空' }), t).notice, '⚠ 音频落空');
});

test('notConfigured stays queued without a toast; server error stays queued with its reason', () => {
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'notConfigured' }), t),
    { cls: 'unconfigured', notice: null, settingsFixable: false });
  assert.strictEqual(fushiMineOutcome(ok({ result: 'error', detail: 'resolve failed' }), t).notice, '✗ resolve failed');
  assert.strictEqual(fushiMineOutcome(ok({ result: 'error' }), t).notice, '✗ mine_err_failed_retry');
});

test('HTTP/network failures retry with a reason; only token-type errors point at settings', () => {
  const at = (status) => fushiMineOutcome({ ok: false, status, data: null }, t);
  assert.deepStrictEqual(at(401), { cls: 'retry', notice: '✗ mine_err_401', settingsFixable: true });
  assert.strictEqual(at(403).settingsFixable, true);
  assert.strictEqual(at(404).settingsFixable, false);
  assert.strictEqual(at(404).notice, '✗ mine_err_404');
  assert.strictEqual(at(502).notice, '✗ mine_err_5xx{"status":502}');
  const down = fushiMineOutcome({ ok: false, error: 'Failed to fetch' }, t);
  assert.strictEqual(down.cls, 'retry');
  assert.ok(down.notice.startsWith('✗ mine_err_unreachable'));
  assert.strictEqual(fushiMineOutcome(null, t).notice, '✗ mine_err_no_response');
});
