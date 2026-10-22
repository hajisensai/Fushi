#!/usr/bin/env node
// 部署时判断「触发器（自定义域名 / 路由 / crons / workers.dev）是否已与 wrangler.toml 一致」。
//
// 为什么需要它：wrangler 3 的 `deploy` / `triggers deploy` 每次都先读 zone 的 /workers/routes 查路由冲突，
// 哪怕只配了 custom_domain、什么都没变；部署 token 没有该 zone 的「Workers Routes」权限时整次部署报红
// （Worker 本体其实已上线）。所以部署 workflow 改成 `versions upload` + `versions deploy`（不碰触发器），
// 再用本脚本只读账户级 API 核对触发器；一致就跳过 `triggers deploy`，不一致或核不了才跑它（没权限照样红）。
//
// 用法：node scripts/triggers_in_sync.mjs <wrangler.toml>
// 环境：CLOUDFLARE_API_TOKEN、CLOUDFLARE_ACCOUNT_ID。
// 退出码：0 = 一致；1 = 不一致（需要 triggers deploy）；2 = 核不了（同样需要 triggers deploy）。

import { pathToFileURL } from 'node:url';

/**
 * 纯比较：wrangler 配置 vs 线上状态。返回不一致的原因列表（空 = 一致），或 throw 表示核不了。
 * @param {{routes?: Array<string|{pattern:string, custom_domain?:boolean}>, route?: string, workers_dev?: boolean,
 *          preview_urls?: boolean, triggers?: {crons?: string[]}}} config
 * @param {{domains: string[], crons: string[], subdomain: {enabled: boolean, previews_enabled: boolean}}} live
 * @returns {string[]}
 */
export function triggerDrift(config, live) {
  const routes = config.routes ?? (config.route ? [config.route] : []);
  const plainRoutes = routes.filter((r) => typeof r === 'string' || !r.custom_domain);
  // 普通 zone 路由只能经 zone 级 API 核对（正是缺的那个权限），一律当核不了。
  if (plainRoutes.length > 0) throw new Error('config has zone routes; cannot verify without zone access');

  const drift = [];
  const wantDomains = routes.map((r) => r.pattern).sort();
  const haveDomains = [...live.domains].sort();
  if (JSON.stringify(wantDomains) !== JSON.stringify(haveDomains)) {
    drift.push(`custom domains: want ${JSON.stringify(wantDomains)}, live ${JSON.stringify(haveDomains)}`);
  }
  const wantCrons = [...(config.triggers?.crons ?? [])].sort();
  const haveCrons = [...live.crons].sort();
  if (JSON.stringify(wantCrons) !== JSON.stringify(haveCrons)) {
    drift.push(`crons: want ${JSON.stringify(wantCrons)}, live ${JSON.stringify(haveCrons)}`);
  }
  // 与 wrangler triggersDeploy 同一判据：workers_dev 缺省 = 没配任何路由。
  const wantWorkersDev = config.workers_dev ?? routes.length === 0;
  if (wantWorkersDev !== live.subdomain.enabled) {
    drift.push(`workers.dev: want ${wantWorkersDev}, live ${live.subdomain.enabled}`);
  }
  if (config.preview_urls !== undefined && config.preview_urls !== live.subdomain.previews_enabled) {
    drift.push(`preview urls: want ${config.preview_urls}, live ${live.subdomain.previews_enabled}`);
  }
  return drift;
}

/** 读 Cloudflare API 的 result；非 success 直接 throw（调用方按「核不了」处理）。 */
async function cfResult(path, token) {
  const res = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body || body.success !== true) {
    const errs = body && Array.isArray(body.errors) ? body.errors.map((e) => `${e.code} ${e.message}`).join('; ') : '';
    throw new Error(`GET ${path} -> HTTP ${res.status} ${errs}`);
  }
  return body.result;
}

/** @param {string} accountId @param {string} name @param {string} token */
async function readLive(accountId, name, token) {
  const script = `/accounts/${accountId}/workers/scripts/${encodeURIComponent(name)}`;
  const [domains, schedules, subdomain] = await Promise.all([
    cfResult(`/accounts/${accountId}/workers/domains?service=${encodeURIComponent(name)}`, token),
    cfResult(`${script}/schedules`, token),
    cfResult(`${script}/subdomain`, token),
  ]);
  return {
    domains: domains.filter((d) => d.service === name && (d.environment ?? 'production') === 'production')
      .map((d) => d.hostname),
    crons: (schedules.schedules ?? []).map((s) => s.cron),
    subdomain: { enabled: Boolean(subdomain.enabled), previews_enabled: Boolean(subdomain.previews_enabled) },
  };
}

/** @param {string[]} argv @returns {Promise<number>} */
async function main(argv) {
  const configPath = argv[2];
  const token = process.env.CLOUDFLARE_API_TOKEN;
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!configPath || !token || !accountId) {
    console.error('usage: CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… node triggers_in_sync.mjs <wrangler.toml>');
    return 2;
  }
  try {
    const { unstable_readConfig } = await import('wrangler');
    const config = unstable_readConfig({ config: configPath });
    const drift = triggerDrift(config, await readLive(accountId, config.name, token));
    if (drift.length === 0) {
      console.log('triggers in sync with wrangler.toml');
      return 0;
    }
    for (const d of drift) console.log(`drift: ${d}`);
    return 1;
  } catch (e) {
    console.log(`cannot verify triggers: ${e && e.message ? e.message : String(e)}`);
    return 2;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  process.exitCode = await main(process.argv);
}
