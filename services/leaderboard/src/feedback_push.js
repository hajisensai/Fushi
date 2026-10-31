// 反馈回复的 APNs 推送（iOS；Android 无 GMS 不接 FCM，继续走 App 的后台检查；桌面不变）。
//
// 反馈人（凭本条反馈的 ticket 或提交所用账户的签名，与其它反馈人接口同一口径 feedbackForReporter）：
//   PUT    /v1/feedback/:id/push   [凭据] {token, lang?} → 200 {registered: true, delivering}
//   DELETE /v1/feedback/:id/push   [凭据] {token}        → 200 {registered: false}
// 令牌是 APNs device token 的十六进制串；一条反馈最多 PUSH_LIMITS.tokensPerFeedback 个，
// 满了挤掉最久没登记过的那个（换机 / 重装后的新令牌总能登记上）。已结案的反馈不收登记。
//
// 发送：开发者回复 / 改状态（devUpdate，App 处理台与网页处理台同一个函数）写库之后，经
// ctx.waitUntil 在后台给该反馈的令牌各发一条推送。文案只有通用的「有新回复 / 状态有更新」
// 与反馈 id（点击直达工单），**不带回复正文、不带标题**——推送内容经 Apple 中转、显示在锁屏上。
// 推送失败只记日志，不影响回复已经写入。
//
// 配置（Worker secrets，缺任何一项 = 不发送、不报错，每个 isolate 只记一次日志）：
//   APNS_KEY_P8     APNs Auth Key（.p8 PEM 全文）
//   APNS_KEY_ID     Key ID（10 位）
//   APNS_TEAM_ID    Team ID（10 位）
//   APNS_BUNDLE_ID  App 的 bundle id（apns-topic，如 app.fushi.reader）
//   APNS_ENV        sandbox | production（TestFlight / App Store 包都是 production）
//
// 清理：反馈结案时（开发者结案在推送发完之后、反馈人标记完成时立即）删掉该反馈的全部令牌；
// APNs 回 410 Unregistered / 400 BadDeviceToken / DeviceTokenNotForTopic 时删掉该令牌在所有反馈下的登记。
//
// 成本：登记扣 write_rows 预算并按单条反馈每小时限次；每次处理最多 tokensPerFeedback 个出站
// 请求（远低于 Workers Free 每请求 50 个子请求的上限）。APNs 本身免费。

import { HttpError, b64urlEncode, hex, pemToDer, sha256 } from './util.js';
import { spend } from './budget.js';
import { HOUR, hit } from './ratelimit.js';

export const PUSH_LIMITS = {
  tokensPerFeedback: 5,
  registerPerFeedbackHour: 20,
  /** provider token（JWT）复用上限：Apple 要求 20–60 分钟之间刷新，取 50 分钟。 */
  jwtMaxAgeMs: 50 * 60 * 1000,
  /** APNs 离线暂存期限：设备 3 天内上线还能收到，过期的「有新回复」没有意义了。 */
  expirationSeconds: 3 * 24 * 3600,
};

/** APNs device token：十六进制（目前 32 字节 = 64 位，Apple 声明长度可能变，放宽到 200）。 */
const TOKEN_RE = /^[0-9a-f]{64,200}$/;

const APNS_HOSTS = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};

/** 通知文案：只有通用说法（隐私），按反馈人界面语言选。 */
export const PUSH_TEXT = {
  zh: { title: 'Fushi 反馈', reply: '开发者回复了你的反馈', status: '你的反馈状态有更新' },
  'zh-Hant': { title: 'Fushi 回饋', reply: '開發者回覆了你的回饋', status: '你的回饋狀態有更新' },
  ja: { title: 'Fushi フィードバック', reply: '開発者がフィードバックに返信しました', status: 'フィードバックの状態が更新されました' },
  ko: { title: 'Fushi 피드백', reply: '개발자가 피드백에 답변했습니다', status: '피드백 상태가 업데이트되었습니다' },
  en: { title: 'Fushi feedback', reply: 'A developer replied to your feedback', status: 'Your feedback status was updated' },
};

/** 客户端报的语言标签 → PUSH_TEXT 的键。 */
export function normalizePushLang(lang) {
  if (typeof lang !== 'string') return 'en';
  const tag = lang.trim().replace(/_/g, '-').toLowerCase();
  if (tag.startsWith('zh')) return /(hant|hk|tw|mo)/.test(tag) ? 'zh-Hant' : 'zh';
  if (tag.startsWith('ja')) return 'ja';
  if (tag.startsWith('ko')) return 'ko';
  return 'en';
}

async function tokenHash(token) {
  return hex(await sha256(new TextEncoder().encode(token)));
}

function cleanToken(body) {
  const raw = body && typeof body.token === 'string' ? body.token.trim().toLowerCase() : '';
  if (!TOKEN_RE.test(raw)) throw new HttpError(400, 'bad_token');
  return raw;
}

/**
 * PUT /v1/feedback/:id/push。调用方已用 feedbackForReporter 核对过凭据；[closed] = 该反馈
 * 已结案（结案后不再有回复可推，登记了也会在下次处理时被清掉，直接拒）。
 */
export async function registerPushToken(env, row, body, now, { closed }) {
  if (closed) throw new HttpError(409, 'feedback_closed');
  const token = cleanToken(body);
  const lang = normalizePushLang(body && body.lang);
  await hit(env, `feedback:push:${row.id}`, HOUR, PUSH_LIMITS.registerPerFeedbackHour, now);
  await spend(env, 'write_rows', 3, now);
  const h = await tokenHash(token);
  // 一个批次（事务）里先挤掉超额的旧令牌、再 upsert：并发登记也不会越过上限。
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM feedback_push_tokens WHERE feedback_id = ?1 AND token_hash != ?2
         AND token_hash NOT IN (
           SELECT token_hash FROM feedback_push_tokens WHERE feedback_id = ?1 AND token_hash != ?2
           ORDER BY updated_at DESC, token_hash LIMIT ?3)`,
    ).bind(row.id, h, PUSH_LIMITS.tokensPerFeedback - 1),
    env.DB.prepare(
      `INSERT INTO feedback_push_tokens (feedback_id, token_hash, token, lang, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?5)
       ON CONFLICT (feedback_id, token_hash) DO UPDATE SET lang = excluded.lang, updated_at = excluded.updated_at`,
    ).bind(row.id, h, token, lang, now),
  ]);
  // delivering：服务端此刻真的会发推送（APNs 已配置）。App 据此决定这条反馈的新回复是否交给远程
  // 推送、本机后台检查不再另发本地通知——没配置时照旧走本机检查，不会两头落空。
  return { registered: true, delivering: apnsConfig(env) !== null };
}

/** DELETE /v1/feedback/:id/push：注销本条反馈下的这个令牌（不存在也算成功）。 */
export async function unregisterPushToken(env, row, body) {
  const token = cleanToken(body);
  await env.DB.prepare('DELETE FROM feedback_push_tokens WHERE feedback_id = ?1 AND token_hash = ?2')
    .bind(row.id, await tokenHash(token)).run();
  return { registered: false };
}

/** 反馈结案：该反馈的令牌全部作废。 */
export async function clearFeedbackPushTokens(env, feedbackId) {
  await env.DB.prepare('DELETE FROM feedback_push_tokens WHERE feedback_id = ?1').bind(feedbackId).run();
}

// ---- APNs ----

let missingConfigLogged = false;
/** 缓存的 provider token：{ cacheKey, jwt, issuedAt }。同一 isolate 内跨请求复用。 */
let cachedJwt = null;

/** 只给测试用：重置「已记过缺配置日志」与 JWT 缓存。 */
export function resetPushStateForTests() {
  missingConfigLogged = false;
  cachedJwt = null;
}

/** 读 APNs 配置；缺项或 APNS_ENV 不认识返回 null（并且每个 isolate 只记一次日志）。 */
export function apnsConfig(env) {
  const keyP8 = env.APNS_KEY_P8;
  const keyId = env.APNS_KEY_ID;
  const teamId = env.APNS_TEAM_ID;
  const bundleId = env.APNS_BUNDLE_ID;
  const host = APNS_HOSTS[env.APNS_ENV];
  if (keyP8 && keyId && teamId && bundleId && host) return { keyP8, keyId, teamId, bundleId, host };
  if (!missingConfigLogged) {
    missingConfigLogged = true;
    console.log('apns: push not configured (APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID / APNS_ENV=sandbox|production); skipping feedback pushes');
  }
  return null;
}

/**
 * APNs provider token（ES256 JWT）。WebCrypto 的 ECDSA 签名输出就是 JWS 要的 r||s 原始 64 字节。
 * 同一把钥匙 [PUSH_LIMITS.jwtMaxAgeMs] 内复用（Apple 对过于频繁地换 token 会回 429 TooManyProviderTokenUpdates）。
 */
export async function apnsJwt(cfg, now) {
  const cacheKey = `${cfg.teamId}:${cfg.keyId}`;
  if (cachedJwt && cachedJwt.cacheKey === cacheKey && now - cachedJwt.issuedAt < PUSH_LIMITS.jwtMaxAgeMs
      && now >= cachedJwt.issuedAt) {
    return cachedJwt.jwt;
  }
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToDer(cfg.keyP8), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  );
  const enc = (o) => b64urlEncode(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: 'ES256', kid: cfg.keyId })}.${enc({ iss: cfg.teamId, iat: Math.floor(now / 1000) })}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned)),
  );
  const jwt = `${unsigned}.${b64urlEncode(sig)}`;
  cachedJwt = { cacheKey, jwt, issuedAt: now };
  return jwt;
}

/** 推送载荷：通用文案 + 反馈 id（App 据 `fushi.feedback` 打开对应工单）。不含回复正文 / 标题。 */
export function pushPayload(kind, lang, feedbackId) {
  const text = PUSH_TEXT[lang] || PUSH_TEXT.en;
  return {
    aps: {
      alert: { title: text.title, body: kind === 'reply' ? text.reply : text.status },
      sound: 'default',
      'thread-id': 'fushi-feedback',
    },
    fushi: { feedback: feedbackId },
  };
}

/** APNs 判定令牌永久失效的回应（之后再发也不会到）。 */
function tokenIsDead(status, reason) {
  return status === 410 || (status === 400 && (reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic'));
}

async function sendOne(env, cfg, jwt, row, kind, feedbackId, now) {
  const doFetch = env.APNS_FETCH || fetch;
  const res = await doFetch(`${cfg.host}/3/device/${row.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': cfg.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      // 同一条反馈的多次回复在通知中心合并成一条。
      'apns-collapse-id': `feedback-${feedbackId}`,
      'apns-expiration': String(Math.floor(now / 1000) + PUSH_LIMITS.expirationSeconds),
      'content-type': 'application/json',
    },
    body: JSON.stringify(pushPayload(kind, row.lang, feedbackId)),
  });
  if (res.status === 200) return;
  let reason = '';
  try {
    reason = (await res.json()).reason || '';
  } catch {
    reason = '';
  }
  if (tokenIsDead(res.status, reason)) {
    await env.DB.prepare('DELETE FROM feedback_push_tokens WHERE token_hash = ?1').bind(row.token_hash).run();
    return;
  }
  // provider token 被拒：丢掉缓存，下次处理重新签。
  if (res.status === 403) cachedJwt = null;
  console.log(`apns: push for feedback ${feedbackId} failed: ${res.status} ${reason}`);
}

/**
 * 开发者处理（回复 / 改状态）之后的推送与清理。[kind] = 'reply'（有回复正文）/ 'status'（只改状态）；
 * [closed] = 处理后的状态已结案：推送发完把该反馈的令牌全部删掉。
 *
 * 在后台跑（ctx.waitUntil）：**从不抛**——推送失败只记日志，回复早已写入。
 */
export async function notifyFeedbackUpdate(env, feedbackId, { kind, closed }, now) {
  try {
    const cfg = apnsConfig(env);
    if (cfg) {
      const rows = await env.DB.prepare(
        'SELECT token_hash, token, lang FROM feedback_push_tokens WHERE feedback_id = ?1',
      ).bind(feedbackId).all();
      if (rows.results.length > 0) {
        const jwt = await apnsJwt(cfg, now);
        for (const row of rows.results) {
          try {
            await sendOne(env, cfg, jwt, row, kind, feedbackId, now);
          } catch (e) {
            console.log(`apns: push for feedback ${feedbackId} failed: ${e && e.message ? e.message : e}`);
          }
        }
      }
    }
    if (closed) await clearFeedbackPushTokens(env, feedbackId);
  } catch (e) {
    console.error('apns: feedback push task failed', e && e.stack ? e.stack : e);
  }
}
