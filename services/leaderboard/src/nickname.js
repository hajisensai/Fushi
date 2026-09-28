// 昵称规则：NFC、折叠空白、1–24 个码点、无控制字符 / '#'（'#' 是判别码分隔符）。
// 屏蔽词不入库：部署方用 env.BANNED_WORDS（逗号分隔）配置，大小写不敏感子串匹配。

import { HttpError } from './util.js';

export const NICKNAME_MAX = 24;

export function normalizeNickname(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.normalize('NFC').replace(/\s+/g, ' ').trim();
  const len = [...s].length;
  if (len < 1 || len > NICKNAME_MAX) return null;
  // Cc 控制、Cf 格式（零宽/方向控制符，能伪造别人的昵称外观）、'#'。
  if (/[\p{Cc}\p{Cf}#]/u.test(s)) return null;
  return s;
}

export function bannedWords(env) {
  return String(env.BANNED_WORDS || '')
    .split(',')
    .map((w) => w.trim().toLowerCase())
    .filter(Boolean);
}

export function checkNickname(raw, env) {
  const nick = normalizeNickname(raw);
  if (!nick) throw new HttpError(400, 'bad_nickname');
  const lower = nick.toLowerCase();
  if (bannedWords(env).some((w) => lower.includes(w))) throw new HttpError(400, 'nickname_rejected');
  return nick;
}

/** 为 nickname 分配未占用的 0..9999 判别码；全满抛 409。rand 可注入（测试）。 */
export async function allocateDiscriminator(env, nickname, exceptAccountId = '', rand = Math.random) {
  const rows = await env.DB
    .prepare('SELECT discriminator FROM accounts WHERE nickname = ?1 AND id != ?2')
    .bind(nickname, exceptAccountId)
    .all();
  const used = new Set(rows.results.map((r) => r.discriminator));
  if (used.size >= 10000) throw new HttpError(409, 'nickname_full');
  for (let i = 0; i < 64; i++) {
    const d = Math.floor(rand() * 10000);
    if (!used.has(d)) return d;
  }
  for (let d = 0; d < 10000; d++) if (!used.has(d)) return d;
  throw new HttpError(409, 'nickname_full');
}
