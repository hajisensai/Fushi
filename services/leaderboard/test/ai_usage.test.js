import { describe, expect, it } from 'vitest';
import { call, makeEnv } from './harness.js';
import { MODEL_RE, normalizeUsage, weightedCost } from '../src/ai_usage.js';
import { MODEL_RE as UPLOADER_MODEL_RE } from '../../../tool/claude_usage_upload.mjs';

const NOW = Date.UTC(2026, 9, 29, 12);
const TOKEN = 'usage-token-0123456789abcdef';
const auth = { Authorization: `Bearer ${TOKEN}` };
const row = (day, model, over = {}) => ({ day, model, requests: 10, input: 5, output: 100, cacheRead: 1_000_000, cacheWrite: 2000, ...over });
const post = (env, body, headers = auth) => call(env, 'POST', '/v1/ci/usage', { body, headers, now: NOW });

describe('AI 额度上传', () => {
  it('没配 token 一律 404；token 不对 401', async () => {
    const body = { source: 'pc', rows: [row('2026-10-28', 'claude-opus-5-5')] };
    expect((await post(makeEnv(), body)).status).toBe(404);
    const env = makeEnv({ USAGE_UPLOAD_TOKEN: TOKEN });
    expect((await post(env, body, { Authorization: 'Bearer nope' })).status).toBe(401);
    expect((await post(env, body, {})).status).toBe(401);
  });

  it('整行覆盖：重传同一天不累加，多机器按日合并', async () => {
    const env = makeEnv({ USAGE_UPLOAD_TOKEN: TOKEN });
    expect((await post(env, { source: 'pc', rows: [row('2026-10-28', 'claude-opus-5-5')] })).data).toEqual({ accepted: 1 });
    await post(env, { source: 'pc', rows: [row('2026-10-28', 'claude-opus-5-5', { requests: 20 })] });
    await post(env, { source: 'laptop', rows: [row('2026-10-28', 'claude-opus-5-5', { requests: 5 })] });
    const r = await call(env, 'GET', '/usage', { now: NOW });
    expect(r.status).toBe(200);
    expect(r.data).toContain('claude-opus-5-5');
    expect(r.data).toContain('<b>25</b> 次请求');
    expect(r.data).not.toMatch(/<script/i);
  });

  it('拒绝坏数据', () => {
    const ok = row('2026-10-28', 'm');
    const bad = (b) => expect(() => normalizeUsage(b, NOW)).toThrow();
    bad(null);
    bad({ source: 'A B', rows: [ok] });
    bad({ source: 'pc', rows: [] });
    bad({ source: 'pc', rows: [{ ...ok, day: '2026-13-99x' }] });
    bad({ source: 'pc', rows: [{ ...ok, day: '2030-01-01' }] });
    bad({ source: 'pc', rows: [{ ...ok, output: -1 }] });
    bad({ source: 'pc', rows: [{ ...ok, output: 1.5 }] });
    bad({ source: 'pc', rows: [{ ...ok, model: '<x>' }] });
    bad({ source: 'pc', rows: [ok, ok] });
    expect(normalizeUsage({ source: 'pc', rows: [ok] }, NOW).rows).toHaveLength(1);
    // Vertex / Bedrock 形态的模型名合法，不能让整批被拒。
    for (const model of ['claude-opus-4-5@20251101', 'us.anthropic.claude-opus-4-5-v1:0', 'arn:aws:bedrock:us-east-1:1:inference-profile/x']) {
      expect(normalizeUsage({ source: 'pc', rows: [row('2026-10-28', model)] }, NOW).rows).toHaveLength(1);
    }
  });

  it('空库页面不报错；转义模型名', async () => {
    const env = makeEnv({ USAGE_UPLOAD_TOKEN: TOKEN });
    const r = await call(env, 'GET', '/usage', { now: NOW });
    expect(r.status).toBe(200);
    expect(r.data).toContain('还没有上传数据');
  });

  it('上传脚本与服务端的模型名规则一致（否则一行坏数据让整批 400）', () => {
    expect(UPLOADER_MODEL_RE.source).toBe(MODEL_RE.source);
  });

  it('weightedCost 按缓存计价比例折算', () => {
    expect(weightedCost({ input: 10, output: 2, cacheRead: 100, cacheWrite: 4 })).toBe(10 + 10 + 5 + 10);
  });
});
