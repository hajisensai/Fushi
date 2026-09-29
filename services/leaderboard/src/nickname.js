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

/** 一次只探这么多个随机候选：读取量有上界（旧实现读出全部同名账户，常见昵称可达 1 万行 / 次）。 */
export const DISCRIMINATOR_PROBES = 20;

/**
 * 为 nickname 分配未占用的 0..9999 判别码：随机取 DISCRIMINATOR_PROBES 个候选，一次查询（走
 * UNIQUE(nickname, discriminator) 索引）排除已占用的。全被占（同名极多）抛 409 nickname_crowded，
 * 让用户换个昵称。rand 可注入（测试）。
 */
export async function allocateDiscriminator(env, nickname, exceptAccountId = '', rand = Math.random) {
  const candidates = new Set();
  while (candidates.size < DISCRIMINATOR_PROBES) candidates.add(Math.floor(rand() * 10000));
  const rows = await env.DB
    .prepare(
      `SELECT discriminator FROM accounts
       WHERE nickname = ?1 AND id != ?2 AND discriminator IN (SELECT value FROM json_each(?3))`,
    )
    .bind(nickname, exceptAccountId, JSON.stringify([...candidates]))
    .all();
  const used = new Set(rows.results.map((r) => r.discriminator));
  for (const d of candidates) if (!used.has(d)) return d;
  throw new HttpError(409, 'nickname_crowded');
}
