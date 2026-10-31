// Apple Music API 的 developer token 代签（MusicKit）。
//
//   GET /v1/musickit/token → 200 {token, expiresAt}；没配 secret → 503 musickit_not_configured
//
// developer token 是 ES256 JWT（header {alg, kid}，claims {iss: Team ID, iat, exp}），App 调
// api.music.apple.com 时放进 `Authorization: Bearer`。签名用的 .p8 私钥只放在 Worker secret 里，
// **不进 App 包、不进 git**：私钥一旦随包分发就只能作废重建。token 本身对所有调用方都一样
// （Apple 不区分用户），所以不要求账户签名，只按 IP 过 READ_LIMITER。
//
// 同一 isolate 内复用同一枚 token：有效期 MUSICKIT_LIMITS.tokenTtlMs，剩余不足一半就重签，
// 客户端拿到的 token 至少还有半个有效期，可以缓存到 expiresAt 前再来取。
//
// 配置（Worker secrets，缺任何一项 = 503，不影响其它接口）：
//   MUSICKIT_KEY_P8   Media Services 密钥（.p8 PEM 全文）
//   MUSICKIT_KEY_ID   Key ID（10 位）
//   MUSICKIT_TEAM_ID  Team ID（10 位）

import { HttpError, b64urlEncode, pemToDer } from './util.js';

export const MUSICKIT_LIMITS = {
  /** developer token 有效期。Apple 上限 6 个月；取一天，泄露了影响面也只有一天。 */
  tokenTtlMs: 24 * 3600 * 1000,
};

/** 缓存的 developer token：{ cacheKey, token, issuedAt, expiresAt }。同一 isolate 内跨请求复用。 */
let cached = null;

/** 只给测试用：清掉 token 缓存。 */
export function resetMusicKitStateForTests() {
  cached = null;
}

/** 读 MusicKit 配置；缺项返回 null。 */
export function musicKitConfig(env) {
  const keyP8 = env.MUSICKIT_KEY_P8;
  const keyId = env.MUSICKIT_KEY_ID;
  const teamId = env.MUSICKIT_TEAM_ID;
  if (keyP8 && keyId && teamId) return { keyP8, keyId, teamId };
  return null;
}

/** 签一枚 developer token；有效期过半之前复用缓存。返回 { token, expiresAt }（expiresAt 为毫秒）。 */
export async function musicKitDeveloperToken(cfg, now) {
  const cacheKey = `${cfg.teamId}:${cfg.keyId}`;
  if (cached && cached.cacheKey === cacheKey && now >= cached.issuedAt
      && now - cached.issuedAt < MUSICKIT_LIMITS.tokenTtlMs / 2) {
    return { token: cached.token, expiresAt: cached.expiresAt };
  }
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToDer(cfg.keyP8), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  );
  const iat = Math.floor(now / 1000);
  const exp = iat + Math.floor(MUSICKIT_LIMITS.tokenTtlMs / 1000);
  const enc = (o) => b64urlEncode(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: 'ES256', kid: cfg.keyId })}.${enc({ iss: cfg.teamId, iat, exp })}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned)),
  );
  const token = `${unsigned}.${b64urlEncode(sig)}`;
  cached = { cacheKey, token, issuedAt: now, expiresAt: exp * 1000 };
  return { token, expiresAt: cached.expiresAt };
}

/** GET /v1/musickit/token 的处理体。 */
export async function issueMusicKitToken(env, now) {
  const cfg = musicKitConfig(env);
  if (!cfg) throw new HttpError(503, 'musickit_not_configured');
  return musicKitDeveloperToken(cfg, now);
}
