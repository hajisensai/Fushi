import assert from 'node:assert/strict';
import { test } from 'node:test';

import { planMirror } from './r2_mirror_plan.mjs';

const release = (tag, sizes) => ({
  tag,
  assets: sizes.map((size, index) => ({ name: `${tag}-${index}.bin`, size })),
});

test('先删最旧版本，再把新版本纳入 8GB 预算', () => {
  const plan = planMirror({
    ledger: { schemaVersion: 2, releases: [release('v1', [2_000]), release('v2', [3_000])] },
    manifest: release('v3', [4_000]),
    keepReleases: 2,
    maxBytes: 8_000,
  });
  assert.equal(plan.allowed, true);
  assert.equal(plan.plannedBytes, 7_000);
  assert.deepEqual(plan.deleteKeys, ['releases/v1/v1-0.bin']);
  assert.deepEqual(plan.rollbackLedger.releases.map((item) => item.tag), ['v2']);
  assert.deepEqual(plan.ledger.releases.map((item) => item.tag), ['v2', 'v3']);
});

test('预计超过预算时不删旧对象，也不接纳新版本', () => {
  const ledger = { schemaVersion: 2, releases: [release('v2', [5_000])] };
  const plan = planMirror({
    ledger,
    manifest: release('v3', [4_000]),
    keepReleases: 2,
    maxBytes: 8_000,
  });
  assert.equal(plan.allowed, false);
  assert.deepEqual(plan.deleteKeys, []);
  assert.deepEqual(plan.ledger.releases, ledger.releases);
});

test('重跑同一 tag 时先删该 tag 的旧资产，避免孤儿累积', () => {
  const plan = planMirror({
    ledger: { schemaVersion: 2, releases: [release('v2', [1_000]), release('v3', [2_000])] },
    manifest: release('v3', [2_500]),
    keepReleases: 2,
    maxBytes: 8_000,
  });
  assert.equal(plan.allowed, true);
  assert.deepEqual(plan.deleteKeys, ['releases/v3/v3-0.bin']);
  assert.deepEqual(plan.ledger.releases.map((item) => item.tag), ['v2', 'v3']);
});

test('旧版无 size 台账 fail closed，不能把未知存量当 0', () => {
  assert.throws(
    () =>
      planMirror({
        ledger: { releases: [{ tag: 'v1', files: ['old.bin'] }] },
        manifest: release('v2', [1_000]),
        keepReleases: 2,
        maxBytes: 8_000,
      }),
    /legacy or invalid R2 ledger/,
  );
});

