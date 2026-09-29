// 邮箱验证码：注册与新设备登录。
//
// 隐私：服务端**不存邮箱明文**——只存 HMAC(EMAIL_PEPPER, 规范化邮箱)，用于唯一性与登录查找；
// 验证码只发给用户当次输入的地址，所以不需要原文。验证码同样只存 HMAC，10 分钟过期，最多试 5 次。
//
// 防探测：POST /v1/email/code 对任何邮箱都回 202。登录用途且邮箱没有账户时不发信、不扣预算；
// 之后的登录必然因「没有待验证码」而 400 bad_code，外人分辨不出邮箱是否已注册。
//
// 成本：发信走 Resend（免费 100 封/天、3000 封/月，不绑卡不扣费）；本服务再按 IP / 邮箱限流，
// 并扣全局日预算 email（默认 90，低于发信服务免费额度）。
// 配置：secrets EMAIL_PEPPER、RESEND_API_KEY；vars EMAIL_FROM（Resend 上已验证域名的发件地址）。
// 测试可注入 env.EMAIL_SENDER(to, subject, text) 代替真实发信。

import { HttpError, hex, timingSafeEqual } from './util.js';
import { spend } from './budget.js';
import { DAY, HOUR, hit } from './ratelimit.js';

export const CODE_TTL_MS = 10 * 60 * 1000;
export const CODE_MAX_ATTEMPTS = 5;
export const PURPOSES = ['register', 'login'];
export const EMAIL_LIMITS = { perIpHour: 5, perAddressHour: 3, perAddressDay: 10 };

const EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(\.[^\s@.]+)+$/;

/** 规范化：去空白、小写。格式不对返回 null。 */
export function normalizeEmail(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim().toLowerCase();
  if (s.length > 254 || !EMAIL_RE.test(s)) return null;
  return s;
}

function pepper(env) {
  if (!env.EMAIL_PEPPER) throw new HttpError(503, 'email_not_configured');
  return env.EMAIL_PEPPER;
}

async function hmacHex(key, message) {
  const k = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return hex(new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(message))));
}

export function emailHash(env, email) {
  return hmacHex(pepper(env), `email|${email}`);
}

function codeHash(env, hash, purpose, code) {
  return hmacHex(pepper(env), `code|${hash}|${purpose}|${code}`);
}

/** 6 位均匀随机数字（拒绝采样，避免取模偏差）。 */
export function randomCode(fill = (b) => crypto.getRandomValues(b)) {
  const buf = new Uint32Array(1);
  const limit = Math.floor(0x100000000 / 1_000_000) * 1_000_000;
  for (;;) {
    fill(buf);
    if (buf[0] < limit) return String(buf[0] % 1_000_000).padStart(6, '0');
  }
}

const MESSAGES = {
  zh: {
    subject: 'Fushi 验证码',
    body: (code) => `你的 Fushi 验证码是：${code}\n\n10 分钟内有效。如果不是你本人操作，请忽略这封邮件。`,
  },
  en: {
    subject: 'Your Fushi verification code',
    body: (code) => `Your Fushi verification code is: ${code}\n\nIt expires in 10 minutes. If you did not request it, ignore this email.`,
  },
  ja: {
    subject: 'Fushi 認証コード',
    body: (code) => `Fushi の認証コード：${code}\n\n10 分間有効です。心当たりがない場合はこのメールを無視してください。`,
  },
};

/** 发信渠道是否已配置：Cloudflare Email Service 绑定（Workers Paid）或 Resend（免费档）二选一。 */
export function emailConfigured(env) {
  if (typeof env.EMAIL_SENDER === 'function') return true;
  if (!env.EMAIL_FROM) return false;
  return Boolean((env.EMAIL && typeof env.EMAIL.send === 'function') || env.RESEND_API_KEY);
}

export async function sendEmail(env, to, subject, text) {
  if (typeof env.EMAIL_SENDER === 'function') return env.EMAIL_SENDER(to, subject, text);
  if (!emailConfigured(env)) throw new HttpError(503, 'email_not_configured');
  // Cloudflare Email Service（wrangler.toml 的 [[send_email]] name = "EMAIL"）：发往任意地址需 Workers Paid，
  // 每月含 3000 封；本服务日预算 90 封 × 31 天仍在含量内。没绑定时走 Resend。
  if (env.EMAIL && typeof env.EMAIL.send === 'function') {
    await env.EMAIL.send({ to, from: env.EMAIL_FROM, subject, text });
    return;
  }
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: env.EMAIL_FROM, to: [to], subject, text }),
  });
  if (!res.ok) throw new HttpError(502, 'email_failed', String(res.status));
}

/**
 * POST /v1/email/code。前台只做与邮箱是否注册无关的事（格式校验、按 IP 限流），立刻 202；
 * 其余（按邮箱限流、是否有账户、扣预算、写码、发信）全在后台做，任何一步不通过都静默丢弃——
 * 否则「预算耗尽时已注册邮箱 503、未注册 202」或响应时长差都能用来探测邮箱是否注册。
 */
export async function requestCode(env, ip, body, now, ctx) {
  const email = normalizeEmail(body && body.email);
  if (!email) throw new HttpError(400, 'bad_email');
  const purpose = body.purpose;
  if (!PURPOSES.includes(purpose)) throw new HttpError(400, 'bad_purpose');
  pepper(env); // 未配置在前台就 503（与邮箱无关，不泄露信息）
  if (!emailConfigured(env)) throw new HttpError(503, 'email_not_configured');
  const lang = MESSAGES[body.lang] ? body.lang : 'en';
  await hit(env, `email:ip:${ip}`, HOUR, EMAIL_LIMITS.perIpHour, now);
  const work = deliverCode(env, email, purpose, lang, now).catch((e) => {
    console.warn('email code dropped', e && e.code ? e.code : String(e));
  });
  if (ctx && ctx.waitUntil) ctx.waitUntil(work);
  else await work;
}

async function deliverCode(env, email, purpose, lang, now) {
  const hash = await emailHash(env, email);
  await hit(env, `email:addr:${hash}`, HOUR, EMAIL_LIMITS.perAddressHour, now);
  await hit(env, `email:addrday:${hash}`, DAY, EMAIL_LIMITS.perAddressDay, now);
  if (purpose === 'login') {
    const acc = await env.DB.prepare('SELECT 1 AS x FROM accounts WHERE email_hash = ?1').bind(hash).first();
    if (!acc) return; // 没账户：不发信
  }
  await spend(env, 'email', 1, now);
  const code = randomCode();
  await env.DB.prepare(
    `INSERT INTO email_codes (email_hash, purpose, code_hash, expires_at, attempts)
     VALUES (?1, ?2, ?3, ?4, 0)
     ON CONFLICT (email_hash, purpose) DO UPDATE SET
       code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0`,
  ).bind(hash, purpose, await codeHash(env, hash, purpose, code), now + CODE_TTL_MS).run();
  const m = MESSAGES[lang];
  await sendEmail(env, email, m.subject, m.body(code));
}

/** 每个邮箱每天累计最多猜错这么多次（跨重发、跨用途）：重发会重置单码的 5 次，但不重置它。 */
export const DAILY_FAILURES_PER_EMAIL = 10;

/**
 * 核对并消费验证码。返回邮箱哈希。
 * 错码：尝试次数 +1（原子），第 5 次后作废；过期 410；成功即删（一次性）。
 */
export async function consumeCode(env, rawEmail, purpose, code, now) {
  const email = normalizeEmail(rawEmail);
  if (!email) throw new HttpError(400, 'bad_email');
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) throw new HttpError(400, 'bad_code');
  const hash = await emailHash(env, email);
  const failBucket = `emailfail:${hash}`;
  const failWindow = Math.floor(now / DAY) * DAY;
  const fails = await env.DB.prepare('SELECT count FROM rate_limits WHERE bucket = ?1 AND window_start = ?2')
    .bind(failBucket, failWindow).first();
  if (fails && fails.count >= DAILY_FAILURES_PER_EMAIL) throw new HttpError(429, 'too_many_attempts');
  const del = () => env.DB.prepare('DELETE FROM email_codes WHERE email_hash = ?1 AND purpose = ?2')
    .bind(hash, purpose).run();
  // 先原子地占用一次尝试机会再比对：并发猜码也严格不超过 CODE_MAX_ATTEMPTS 次。
  const row = await env.DB.prepare(
    `UPDATE email_codes SET attempts = attempts + 1
     WHERE email_hash = ?1 AND purpose = ?2 AND attempts < ?3
     RETURNING code_hash, expires_at`,
  ).bind(hash, purpose, CODE_MAX_ATTEMPTS).first();
  if (!row) {
    const exists = await env.DB.prepare('SELECT 1 AS x FROM email_codes WHERE email_hash = ?1 AND purpose = ?2')
      .bind(hash, purpose).first();
    if (exists) {
      await del();
      throw new HttpError(429, 'too_many_attempts');
    }
    throw new HttpError(400, 'bad_code');
  }
  if (row.expires_at < now) {
    await del();
    throw new HttpError(410, 'code_expired');
  }
  if (!timingSafeEqual(await codeHash(env, hash, purpose, code), row.code_hash)) {
    await env.DB.prepare(
      `INSERT INTO rate_limits (bucket, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT (bucket, window_start) DO UPDATE SET count = count + 1`,
    ).bind(failBucket, failWindow).run();
    throw new HttpError(400, 'bad_code');
  }
  await del();
  return hash;
}

/** 清掉过期验证码（scheduled）。 */
export async function purgeEmailCodes(env, now) {
  await env.DB.prepare('DELETE FROM email_codes WHERE expires_at < ?1').bind(now).run();
}
