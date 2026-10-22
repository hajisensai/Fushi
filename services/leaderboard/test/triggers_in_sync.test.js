import { describe, expect, it } from 'vitest';
import { triggerDrift } from '../scripts/triggers_in_sync.mjs';

// 与本仓 wrangler.toml 同形：只有一个 custom_domain + 一条 cron，未写 workers_dev。
const CONFIG = {
  routes: [{ pattern: 'rank.fushi.moe', custom_domain: true }],
  triggers: { crons: ['*/30 * * * *'] },
};
const LIVE = {
  domains: ['rank.fushi.moe'],
  crons: ['*/30 * * * *'],
  subdomain: { enabled: false, previews_enabled: false },
};

describe('triggerDrift', () => {
  it('reports no drift when live triggers match the config', () => {
    expect(triggerDrift(CONFIG, LIVE)).toEqual([]);
  });

  it('flags a missing or extra custom domain', () => {
    expect(triggerDrift(CONFIG, { ...LIVE, domains: [] })).toHaveLength(1);
    expect(triggerDrift(CONFIG, { ...LIVE, domains: ['rank.fushi.moe', 'old.fushi.moe'] })).toHaveLength(1);
  });

  it('flags changed crons', () => {
    expect(triggerDrift(CONFIG, { ...LIVE, crons: ['0 * * * *'] })[0]).toMatch(/^crons:/);
    expect(triggerDrift({ ...CONFIG, triggers: { crons: [] } }, LIVE)[0]).toMatch(/^crons:/);
  });

  it('uses the wrangler workers_dev default (off when routes exist)', () => {
    expect(triggerDrift(CONFIG, { ...LIVE, subdomain: { enabled: true, previews_enabled: false } })[0])
      .toMatch(/^workers\.dev:/);
    expect(triggerDrift({ ...CONFIG, workers_dev: true }, LIVE)[0]).toMatch(/^workers\.dev:/);
  });

  it('ignores preview urls while workers.dev is off, compares them while it is on', () => {
    // wrangler 3 的 unstable_readConfig 把 preview_urls 缺省成 true；workers.dev 关着时线上恒为 false。
    expect(triggerDrift({ ...CONFIG, preview_urls: true }, LIVE)).toEqual([]);
    const on = { ...CONFIG, workers_dev: true, preview_urls: true };
    expect(triggerDrift(on, { ...LIVE, subdomain: { enabled: true, previews_enabled: false } })[0])
      .toMatch(/^preview urls:/);
  });

  it('cannot verify plain zone routes without zone access', () => {
    expect(() => triggerDrift({ ...CONFIG, routes: ['rank.fushi.moe/*'] }, LIVE)).toThrow(/zone routes/);
  });
});
