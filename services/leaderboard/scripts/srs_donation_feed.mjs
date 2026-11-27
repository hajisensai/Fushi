#!/usr/bin/env node
// SRS 复习历史捐赠：管理长期下载 feed（src/srs_donations.js「管理」），链接交给 anki-rwkv 作者。
//
//   ADMIN_USER=… ADMIN_PASS=… node scripts/srs_donation_feed.mjs <命令> [--base https://rank.fushi.moe]
//
//   stats（默认）：GET /v1/admin/srs-donations，统计与全部 feed（id / 标签 / 签发 / 吊销时刻）。
//   create <label>：POST /v1/admin/srs-donations/feeds → 打印链接。token 明文只出现这一次，丢了就吊销重发。
//   revoke <id>：DELETE /v1/admin/srs-donations/feeds/<id>，链接立即 404。
//   --base：服务地址，默认环境变量 LEADERBOARD_URL，再默认 https://rank.fushi.moe。

import { pathToFileURL } from 'node:url';

const DEFAULT_BASE = 'https://rank.fushi.moe';

/**
 * @param {string[]} argv
 * @returns {{cmd: 'stats' | 'create' | 'revoke', arg: string | null, base: string}}
 */
export function parseArgs(argv) {
  let base = process.env.LEADERBOARD_URL || DEFAULT_BASE;
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--base') {
      base = argv[++i];
      if (!base) throw new Error('--base needs a value');
    } else if (a.startsWith('--')) {
      throw new Error(`unknown argument: ${a}`);
    } else {
      pos.push(a);
    }
  }
  const cmd = pos[0] || 'stats';
  if (cmd === 'stats') {
    if (pos.length > 1) throw new Error('stats takes no arguments');
    return { cmd, arg: null, base: base.replace(/\/+$/, '') };
  }
  if (cmd === 'create') {
    if (pos.length !== 2) throw new Error('usage: create <label>');
    return { cmd, arg: pos[1], base: base.replace(/\/+$/, '') };
  }
  if (cmd === 'revoke') {
    if (pos.length !== 2 || !/^\d+$/.test(pos[1])) throw new Error('usage: revoke <id>');
    return { cmd, arg: pos[1], base: base.replace(/\/+$/, '') };
  }
  throw new Error(`unknown command: ${cmd}`);
}

/**
 * @param {{cmd: string, arg: string | null, base: string}} args
 * @returns {{url: string, init: {method: string, body?: string, headers?: Record<string, string>}}}
 */
export function requestOf({ cmd, arg, base }) {
  if (cmd === 'create') {
    return {
      url: `${base}/v1/admin/srs-donations/feeds`,
      init: { method: 'POST', body: JSON.stringify({ label: arg }), headers: { 'Content-Type': 'application/json' } },
    };
  }
  if (cmd === 'revoke') return { url: `${base}/v1/admin/srs-donations/feeds/${arg}`, init: { method: 'DELETE' } };
  return { url: `${base}/v1/admin/srs-donations`, init: { method: 'GET' } };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const user = process.env.ADMIN_USER;
  const pass = process.env.ADMIN_PASS;
  if (!user || !pass) {
    console.error('ADMIN_USER / ADMIN_PASS must be set');
    process.exit(2);
  }
  const { url, init } = requestOf(args);
  const res = await fetch(url, {
    ...init,
    headers: { ...(init.headers || {}), Authorization: `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}` },
  });
  const text = await res.text();
  if (!res.ok) {
    console.error(`HTTP ${res.status}: ${text}`);
    process.exit(1);
  }
  const data = JSON.parse(text);
  if (args.cmd === 'create') {
    console.log(data.url);
    console.log(`id=${data.id} label=${data.label} (the token is shown only once)`);
    return;
  }
  console.log(JSON.stringify(data, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(e && e.message ? e.message : e);
    process.exit(1);
  });
}
