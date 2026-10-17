// 邮箱验证码：注册与新设备登录。
//
// 隐私：服务端**不存邮箱明文**——只存 HMAC(EMAIL_PEPPER, 规范化邮箱)，用于唯一性与登录查找；
// 验证码只发给用户当次输入的地址，所以不需要原文。验证码同样只存 HMAC，10 分钟过期，最多试 5 次。
//
// 别名：身份按 canonicalEmail 判定（Gmail 去点 / +tag、googlemail→gmail，若干域去 +tag），所以同一个
// 收件箱的别名注册不出第二个账户；发信仍发到用户输入的地址（别名照样收得到）。验证码、按邮箱限流、
// 账户查找全部以规范化哈希为 key。2026-10-17 之前注册的账户存的是旧规则（只 trim + 小写）的哈希，
// 而服务端没有明文无法批量重算：登录时 resolveEmailAccount 新旧哈希一起查，命中旧哈希就原地升级
// （新哈希已被别的账户占着则不合并、记进 email_hash_conflicts 供管理员查看）。
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
import { sendViaSmtp, smtpConfigured } from './smtp.js';

export const CODE_TTL_MS = 10 * 60 * 1000;
export const CODE_MAX_ATTEMPTS = 5;
export const PURPOSES = ['register', 'login'];
export const EMAIL_LIMITS = { perIpHour: 5, perAddressHour: 3, perAddressDay: 10 };

const EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(\.[^\s@.]+)+$/;

/**
 * 旧规则（2026-10-17 之前的 Worker 唯一的规则）：去空白、小写。现在只用来算历史 email_hash，
 * 让按旧规则注册的账户能被找到并惰性升级（见 resolveEmailAccount）。格式不对返回 null。
 */
export function legacyNormalizeEmail(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim().toLowerCase();
  if (s.length > 254 || !EMAIL_RE.test(s)) return null;
  return s;
}

/** Gmail：忽略本地部分的点号与 +tag；googlemail.com 与 gmail.com 是同一个邮箱。 */
const GMAIL_DOMAINS = new Set(['gmail.com', 'googlemail.com']);

/**
 * 官方支持「+tag」子地址（plus addressing）的域：+ 之后的部分不改变收件人。只收核实过的，
 * 不确定的一律不处理（宁可漏判，也不把两个真实不同的人归成一个）：
 * - Yahoo 的别名是独立的「一次性地址」（base-keyword@yahoo.com，base 由用户另取），不是在主地址的
 *   本地部分上加分隔符，无法从地址推回主账户 → 不处理；
 * - qq.com / 163.com / 126.com 等国内邮箱没有公开的 plus addressing 文档 → 不处理。
 */
const PLUS_TAG_DOMAINS = new Set([
  'outlook.com', 'hotmail.com', 'live.com', 'msn.com',
  'icloud.com', 'me.com', 'mac.com',
  'proton.me', 'protonmail.com', 'pm.me',
  'fastmail.com', 'fastmail.fm',
]);

/**
 * 收信地址：NFKC（全角字母 / ＠ / ．→ 半角）+ 去空白 + 小写，非 ASCII 域名转 punycode；
 * 别名（+tag、点号）原样保留，发信用它。域名在这里就转成 punycode，保证「收信的域」与
 * 「身份的域」（canonicalEmail）严格是同一个——否则 Unicode 域名交给发信服务，它若按 IDNA 过渡模式
 * 处理，会把 faß.de 投到 fass.de，而身份按非过渡模式记成 xn--fa-hia.de。
 */
export function deliveryEmail(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.normalize('NFKC').trim().toLowerCase();
  if (s.length > 254 || !EMAIL_RE.test(s)) return null;
  const at = s.lastIndexOf('@');
  let domain = s.slice(at + 1);
  if (/[^\u0000-\u007f]/.test(domain)) {
    // IDN（WHATWG URL = UTS #46 非过渡处理）：例え.jp → xn--r8jz45g.jp，零宽空格 / 软连字符被删，
    // ß 保留。只对非 ASCII 域名走 URL 解析——纯 ASCII 的 "1.2.3" 会被 URL 当成 IPv4 改写。
    try {
      domain = new URL(`http://${domain}`).hostname;
    } catch {
      return null;
    }
  }
  const out = `${s.slice(0, at)}@${domain}`;
  if (out.length > 254 || !EMAIL_RE.test(out)) return null;
  return out;
}

/**
 * 身份规范化（纯函数）：同一个收件箱的不同写法归成同一个字符串，email_hash 由它算。
 * 在 deliveryEmail（已 NFKC、小写、域名 punycode）之上：Gmail 去点、去 +tag、googlemail→gmail；
 * PLUS_TAG_DOMAINS 去 +tag；其余域名本地部分原样。去掉别名后本地部分为空（"+tag@gmail.com"）→ null。
 */
export function canonicalEmail(raw) {
  const s = deliveryEmail(raw);
  if (!s) return null;
  const at = s.lastIndexOf('@');
  let local = s.slice(0, at);
  let domain = s.slice(at + 1);
  if (GMAIL_DOMAINS.has(domain)) {
    local = local.split('+', 1)[0].replaceAll('.', '');
    domain = 'gmail.com';
  } else if (PLUS_TAG_DOMAINS.has(domain)) {
    local = local.split('+', 1)[0];
  }
  if (!local) return null;
  const out = `${local}@${domain}`;
  if (out.length > 254 || !EMAIL_RE.test(out)) return null;
  return out;
}

/**
 * 解析一次输入：delivery 发信用；canonical 身份用；legacy 是旧 Worker 会存的形式，只在需要回退查找时给出：
 * - 与 canonical 相同 → null（没有不同的旧哈希）；
 * - 与 delivery 不逐字相同 → null。旧哈希对应的账户属于当初在「旧规则地址」收码的人；如果这次的码
 *   会发到另一个地址（NFKC 改写过，如 U+FB01「ﬁ」→ "fi"；或 IDN 域名转成了 punycode），拿这个码
 *   登进旧账户就等于让另一个收件箱的主人接管它。这类老账户宁可锁住（不能再用邮箱登录新设备）。
 * 格式不对返回 null。
 */
export function parseEmail(raw) {
  const delivery = deliveryEmail(raw);
  const canonical = canonicalEmail(raw);
  if (!delivery || !canonical) return null;
  const legacy = legacyNormalizeEmail(raw);
  return { delivery, canonical, legacy: legacy && legacy !== canonical && legacy === delivery ? legacy : null };
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

/**
 * 一次输入的两个哈希：hash = 规范化身份（新账户、验证码、限流都用它）；legacyHash = 旧规则下的
 * 哈希（与 hash 相同则为 null）。前缀沿用 `email|`：不含别名的地址新旧哈希天然相同，不需要迁移。
 */
export async function emailHashes(env, parsed) {
  return {
    hash: await emailHash(env, parsed.canonical),
    legacyHash: parsed.legacy ? await emailHash(env, parsed.legacy) : null,
  };
}

/** 新旧任一哈希命中的账户（注册查重：别名与「旧规则存下的原样地址」都算已占用）。 */
export async function emailTaken(env, ids) {
  const row = await env.DB.prepare('SELECT 1 AS x FROM accounts WHERE email_hash IN (?1, ?2)')
    .bind(ids.hash, ids.legacyHash ?? ids.hash).first();
  return Boolean(row);
}

/**
 * 按邮箱找账户并做惰性迁移。返回账户行（email_hash 为升级后的值）或 null。
 *
 * - 只命中规范化哈希：就是它。
 * - 命中旧哈希：同一个事务里把它升级成规范化哈希；规范化哈希已被**另一个**账户占用时不合并、
 *   保留旧哈希，把（本账户, 占用者）记进 email_hash_conflicts（只有账户 id，不含邮箱）。
 * - 两个都命中且不是同一账户（同一收件箱在旧规则下注册过两个账户）：返回旧哈希那个——
 *   它是用户这次逐字输入的地址，与旧 Worker 的行为一致，不会把人登进另一个账户；冲突照记。
 */
export async function resolveEmailAccount(env, ids, now) {
  if (!ids.legacyHash) {
    return env.DB.prepare('SELECT * FROM accounts WHERE email_hash = ?1').bind(ids.hash).first();
  }
  const rows = (await env.DB.prepare('SELECT * FROM accounts WHERE email_hash IN (?1, ?2)')
    .bind(ids.hash, ids.legacyHash).all()).results;
  const legacy = rows.find((r) => r.email_hash === ids.legacyHash);
  if (!legacy) return rows.find((r) => r.email_hash === ids.hash) ?? null;
  const res = await env.DB.batch([
    // NOT EXISTS 与 UNIQUE(email_hash) 双保险：绝不把两个账户并成一个。
    env.DB.prepare(
      `UPDATE accounts SET email_hash = ?2
       WHERE id = ?1 AND email_hash = ?3 AND NOT EXISTS (SELECT 1 FROM accounts WHERE email_hash = ?2)`,
    ).bind(legacy.id, ids.hash, ids.legacyHash),
    // 没升级成（规范化哈希被别的账户占着）才会选出行：记冲突 / 刷新最近一次看到的时刻。
    // EXISTS：读完旧行到这个 batch 之间本账户被删了（UPDATE 0 行）时不留孤儿冲突记录。
    env.DB.prepare(
      `INSERT INTO email_hash_conflicts (account_id, holder_id, first_seen_at, last_seen_at, seen_count)
       SELECT ?1, id, ?3, ?3, 1 FROM accounts
       WHERE email_hash = ?2 AND id <> ?1 AND EXISTS (SELECT 1 FROM accounts WHERE id = ?1)
       ON CONFLICT (account_id, holder_id) DO UPDATE SET
         last_seen_at = excluded.last_seen_at, seen_count = seen_count + 1`,
    ).bind(legacy.id, ids.hash, now),
    // 升级成功：本账户以前记过的冲突（占用者后来删号了）已经不成立。
    env.DB.prepare(
      `DELETE FROM email_hash_conflicts
       WHERE account_id = ?1 AND (SELECT email_hash FROM accounts WHERE id = ?1) = ?2`,
    ).bind(legacy.id, ids.hash),
  ]);
  if (res[0].meta.changes === 1) return { ...legacy, email_hash: ids.hash };
  // 没升级：冲突（账户仍在）或中途被删（返回 null，不给已删账户绑设备）。只在这条少见的路径上多读一次。
  return env.DB.prepare('SELECT * FROM accounts WHERE id = ?1').bind(legacy.id).first();
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

/** 发信渠道是否已配置：Cloudflare Email Service 绑定（Workers Paid）/ 域名邮箱 SMTP / Resend，按此优先级取第一个。 */
export function emailConfigured(env) {
  if (typeof env.EMAIL_SENDER === 'function') return true;
  if (!env.EMAIL_FROM) return false;
  return Boolean((env.EMAIL && typeof env.EMAIL.send === 'function') || smtpConfigured(env) || env.RESEND_API_KEY);
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
  // 域名邮箱（免费档）的 SMTP 提交端口：见 smtp.js。
  if (smtpConfigured(env)) {
    await sendViaSmtp(env, to, subject, text);
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
  const email = parseEmail(body && body.email);
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
  // 限流桶与验证码都挂在规范化哈希上：换着别名发码绕不过「每邮箱每小时 3 封 / 每天 10 封」。
  const ids = await emailHashes(env, email);
  const { hash } = ids;
  await hit(env, `email:addr:${hash}`, HOUR, EMAIL_LIMITS.perAddressHour, now);
  await hit(env, `email:addrday:${hash}`, DAY, EMAIL_LIMITS.perAddressDay, now);
  if (purpose === 'login') {
    if (!(await emailTaken(env, ids))) return; // 没账户（新旧哈希都没命中）：不发信
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
  // 发到用户输入的地址（保留 +tag / 点号）：别名本来就投递到同一个收件箱。
  await sendEmail(env, email.delivery, m.subject, m.body(code));
}

/** 每个邮箱每天累计最多猜错这么多次（跨重发、跨用途）：重发会重置单码的 5 次，但不重置它。 */
export const DAILY_FAILURES_PER_EMAIL = 10;

/**
 * 核对并消费验证码。返回 {hash, legacyHash}（见 emailHashes；验证码按规范化哈希存，
 * 所以用别名要的码用原址也能核对——它们是同一个收件箱）。
 * 错码：尝试次数 +1（原子），第 5 次后作废；过期 410；成功即删（一次性）。
 */
export async function consumeCode(env, rawEmail, purpose, code, now) {
  const email = parseEmail(rawEmail);
  if (!email) throw new HttpError(400, 'bad_email');
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) throw new HttpError(400, 'bad_code');
  const ids = await emailHashes(env, email);
  const { hash } = ids;
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
  return ids;
}

/** 清掉过期验证码（scheduled）。 */
export async function purgeEmailCodes(env, now) {
  await env.DB.prepare('DELETE FROM email_codes WHERE expires_at < ?1').bind(now).run();
}
