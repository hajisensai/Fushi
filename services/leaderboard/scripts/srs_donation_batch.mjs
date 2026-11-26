#!/usr/bin/env node
// SRS 复习历史捐赠：生成本月私有批次链接（src/srs_donations.js「管理」）并打印，交给 anki-rwkv 作者。
//
//   ADMIN_USER=… ADMIN_PASS=… node scripts/srs_donation_batch.mjs [--stats] [--base https://rank.fushi.moe]
//
//   默认：POST /v1/admin/srs-donations/batch → 打印链接（30 天有效）、捐赠者数 / 复习数 / 撤回数。
//         生成批次会把尚未报告的撤回 ID 标成「本批已报告」，所以别为了看数字反复生成——看数字用 --stats。
//   --stats：GET /v1/admin/srs-donations，只看统计与历史批次，不生成。
//   --base：服务地址，默认环境变量 LEADERBOARD_URL，再默认 https://rank.fushi.moe。

import { pathToFileURL } from 'node:url';

const DEFAULT_BASE = 'https://rank.fushi.moe';

/**
 * @param {string[]} argv
 * @returns {{stats: boolean, base: string}}
 */
export function parseArgs(argv) {
  let stats = false;
  let base = process.env.LEADERBOARD_URL || DEFAULT_BASE;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--stats') stats = true;
    else if (a === '--base') base = argv[++i];
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!base) throw new Error('--base needs a value');
  return { stats, base: base.replace(/\/+$/, '') };
}

async function main() {
  const { stats, base } = parseArgs(process.argv.slice(2));
  const user = process.env.ADMIN_USER;
  const pass = process.env.ADMIN_PASS;
  if (!user || !pass) {
    console.error('ADMIN_USER / ADMIN_PASS must be set');
    process.exit(2);
  }
  const auth = `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}`;
  const res = await fetch(`${base}/v1/admin/srs-donations${stats ? '' : '/batch'}`, {
    method: stats ? 'GET' : 'POST',
    headers: { Authorization: auth },
  });
  const text = await res.text();
  if (!res.ok) {
    console.error(`HTTP ${res.status}: ${text}`);
    process.exit(1);
  }
  const data = JSON.parse(text);
  if (stats) {
    console.log(JSON.stringify(data, null, 2));
    return;
  }
  console.log(data.url);
  console.log(`donors=${data.donors} reviews=${data.reviews} withdrawn=${data.withdrawn} `
    + `expires=${new Date(data.expiresAt).toISOString()}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(e && e.message ? e.message : e);
    process.exit(1);
  });
}
