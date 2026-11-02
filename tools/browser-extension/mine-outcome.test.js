// mine-outcome.js 行为测试：content script（Netflix 回放）与 service worker（YouTube 批量）共用的
// 制卡结果分类判据。只有 done 出队（TODO-1184：duplicate 也必须出队，否则队列永不清），HTTP/网络
// 失败要给出原因（TODO-1331），success+message 是「卡建了但音频落空」的部分成功（TODO-1303）。
const { test } = require('node:test');
const assert = require('node:assert');
const {
  fushiMineOutcome, fushiQueueItemPending, fushiQueueAfterMineFailure, fushiQueueRetryFailed,
  FUSHI_MINE_MAX_ITEM_ATTEMPTS,
} = require('./mine-outcome.js');

const t = (key, params) => key + (params ? JSON.stringify(params) : '');
const ok = (data) => ({ ok: true, status: 200, data });

test('success and duplicate both leave the queue; success+message warns', () => {
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'success' }), t),
    { cls: 'done', notice: null, settingsFixable: false, itemFault: false, reason: null });
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'duplicate', message: 'x' }), t),
    { cls: 'done', notice: null, settingsFixable: false, itemFault: false, reason: null });
  assert.strictEqual(fushiMineOutcome(ok({ result: 'success', message: '音频落空' }), t).notice, '⚠ 音频落空');
});

test('notConfigured stays queued without a toast; server error stays queued with its reason', () => {
  assert.deepStrictEqual(fushiMineOutcome(ok({ result: 'notConfigured' }), t),
    { cls: 'unconfigured', notice: null, settingsFixable: false, itemFault: false, reason: null });
  assert.strictEqual(fushiMineOutcome(ok({ result: 'error', detail: 'resolve failed' }), t).notice, '✗ resolve failed');
  assert.strictEqual(fushiMineOutcome(ok({ result: 'error' }), t).notice, '✗ mine_err_failed_retry');
});

test('HTTP/network failures retry with a reason; only token-type errors point at settings', () => {
  const at = (status) => fushiMineOutcome({ ok: false, status, data: null }, t);
  assert.deepStrictEqual(at(401),
    { cls: 'retry', notice: '✗ mine_err_401', settingsFixable: true, itemFault: false, reason: 'mine_err_401' });
  assert.strictEqual(at(403).settingsFixable, true);
  assert.strictEqual(at(404).settingsFixable, false);
  assert.strictEqual(at(404).notice, '✗ mine_err_404');
  assert.strictEqual(at(502).notice, '✗ mine_err_5xx{"status":502}');
  const down = fushiMineOutcome({ ok: false, error: 'Failed to fetch' }, t);
  assert.strictEqual(down.cls, 'retry');
  assert.ok(down.notice.startsWith('✗ mine_err_unreachable'));
  assert.strictEqual(fushiMineOutcome(null, t).notice, '✗ mine_err_no_response');
});

// EMI05fe8RJ：永久失败分型——付费电影的卡不能永远留在待生成队列里、每次生成都重跑一遍。
test('server errorKind permanent and HTTP 400/422 classify as failed; transient stays retry', () => {
  const perm = fushiMineOutcome(ok({ result: 'error', message: 'YouTube 视频流解析失败，未制卡', errorKind: 'permanent' }), t);
  assert.strictEqual(perm.cls, 'failed');
  assert.strictEqual(perm.itemFault, true);
  assert.strictEqual(perm.reason, 'YouTube 视频流解析失败，未制卡');
  const trans = fushiMineOutcome(ok({ result: 'error', message: 'x', errorKind: 'transient' }), t);
  assert.strictEqual(trans.cls, 'retry');
  assert.strictEqual(trans.itemFault, true);
  assert.strictEqual(fushiMineOutcome(ok({ result: 'error' }), t).cls, 'retry', '旧服务端不回 errorKind：按可重试');
  assert.strictEqual(fushiMineOutcome({ ok: false, status: 400, data: null }, t).cls, 'failed');
  assert.strictEqual(fushiMineOutcome({ ok: false, status: 422, data: null }, t).cls, 'failed');
  for (const st of [401, 403, 404, 500, 502]) {
    const o = fushiMineOutcome({ ok: false, status: st, data: null }, t);
    assert.strictEqual(o.cls, 'retry', String(st));
    assert.strictEqual(o.itemFault, false, st + ' 是环境问题，不计入该项尝试次数');
  }
  assert.strictEqual(fushiMineOutcome({ ok: false, error: 'Failed to fetch' }, t).itemFault, false);
});

test('queue bookkeeping: failed moves out of pending; item-fault retries escalate; env failures untouched', () => {
  const q = [{ id: 'a', site: 'youtube' }, { id: 'b', site: 'youtube' }];
  const perm = fushiMineOutcome(ok({ result: 'error', message: '需购买', errorKind: 'permanent' }), t);
  let r = fushiQueueAfterMineFailure(q, 'a', perm);
  assert.strictEqual(r.movedToFailed, true);
  assert.strictEqual(r.queue[0].failed, true);
  assert.strictEqual(r.queue[0].lastError, '需购买');
  assert.strictEqual(fushiQueueItemPending(r.queue[0]), false);
  assert.strictEqual(fushiQueueItemPending(r.queue[1]), true);
  assert.strictEqual(q[0].failed, undefined, '纯函数：不改入参');

  const down = fushiMineOutcome({ ok: false, error: 'Failed to fetch' }, t);
  assert.deepStrictEqual(fushiQueueAfterMineFailure(q, 'b', down).queue, q, 'app 没开不算该项失败');

  const trans = fushiMineOutcome(ok({ result: 'error', message: 'timeout' }), t);
  let cur = q;
  for (let i = 1; i < FUSHI_MINE_MAX_ITEM_ATTEMPTS; i++) {
    r = fushiQueueAfterMineFailure(cur, 'b', trans);
    cur = r.queue;
    assert.strictEqual(cur[1].attempts, i);
    assert.strictEqual(fushiQueueItemPending(cur[1]), true);
  }
  r = fushiQueueAfterMineFailure(cur, 'b', trans);
  assert.strictEqual(r.movedToFailed, true, '达到上限降级为失败项');
  assert.strictEqual(fushiQueueItemPending(r.queue[1]), false);

  const back = fushiQueueRetryFailed(r.queue, 'b');
  assert.strictEqual(fushiQueueItemPending(back[1]), true);
  assert.strictEqual(back[1].attempts, undefined);
  assert.strictEqual(back[1].lastError, undefined);
});
