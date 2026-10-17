// 邮箱别名归一：一个收件箱只能有一个账户（封面投票「≥3 个不同账户」门槛的前提），
// 以及 2026-10-17 之前按旧规则（trim + 小写）存哈希的账户的惰性迁移。
import { describe, expect, it } from 'vitest';
import { call, lastCode, makeEnv, newKey, nextIp, registerUser } from './harness.js';
import {
  canonicalEmail, deliveryEmail, emailHash, emailHashes, legacyNormalizeEmail, parseEmail, resolveEmailAccount, EMAIL_LIMITS,
} from '../src/email.js';

const NOW = Date.UTC(2026, 9, 17, 12);
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

describe('canonicalEmail（表驱动）', () => {
  const cases = [
    // Gmail：去点、去 +tag、googlemail→gmail、大小写
    ['John.Doe+promo@Gmail.com', 'johndoe@gmail.com'],
    ['j.o.h.n.d.o.e@gmail.com', 'johndoe@gmail.com'],
    ['johndoe@googlemail.com', 'johndoe@gmail.com'],
    ['John.Doe+a+b@googlemail.com', 'johndoe@gmail.com'],
    ['  johndoe@gmail.com  ', 'johndoe@gmail.com'],
    // 全角（NFKC）
    ['ｊｏｈｎ．ｄｏｅ＋ｘ＠ｇｍａｉｌ．ｃｏｍ', 'johndoe@gmail.com'],
    // 支持 +tag 的域：只去 +tag，点号保留
    ['first.last+news@outlook.com', 'first.last@outlook.com'],
    ['a+b@hotmail.com', 'a@hotmail.com'],
    ['a+b@live.com', 'a@live.com'],
    ['a+b@msn.com', 'a@msn.com'],
    ['a.b+c@icloud.com', 'a.b@icloud.com'],
    ['a+c@me.com', 'a@me.com'],
    ['a+c@mac.com', 'a@mac.com'],
    ['a+c@proton.me', 'a@proton.me'],
    ['a+c@protonmail.com', 'a@protonmail.com'],
    ['a+c@pm.me', 'a@pm.me'],
    ['a+c@fastmail.com', 'a@fastmail.com'],
    ['a+c@fastmail.fm', 'a@fastmail.fm'],
    // 其余域名：本地部分原样（点号、+、- 都不动）
    ['a.b+c@example.com', 'a.b+c@example.com'],
    ['base-keyword@yahoo.com', 'base-keyword@yahoo.com'],
    ['a+b@yahoo.co.jp', 'a+b@yahoo.co.jp'],
    ['a.b+c@qq.com', 'a.b+c@qq.com'],
    ['a+b@163.com', 'a+b@163.com'],
    ['+tag@example.com', '+tag@example.com'],
    // 子域不算 Gmail
    ['a.b+c@mail.gmail.com', 'a.b+c@mail.gmail.com'],
    // IDN → punycode
    ['User@例え．ＪＰ', 'user@xn--r8jz45g.jp'],
    ['user@例え。jp', null], // 句号「。」不是域名分隔符（与旧规则一致，拒绝）
    ['user@xn--r8jz45g.jp', 'user@xn--r8jz45g.jp'],
    // 去掉别名后本地部分为空 → 拒绝
    ['+tag@gmail.com', null],
    ['...@gmail.com', null],
    ['+x@outlook.com', null],
    // 格式错误
    ['no-at-sign', null],
    ['a@b', null],
    ['a b@example.com', null],
    [42, null],
    [`${'a'.repeat(65)}@example.com`, null],
  ];
  it.each(cases)('%s → %s', (raw, want) => {
    expect(canonicalEmail(raw)).toBe(want);
  });

  it('deliveryEmail 保留别名，只做 NFKC + 去空白 + 小写 + 域名 punycode', () => {
    expect(deliveryEmail(' John.Doe+promo@Gmail.com ')).toBe('john.doe+promo@gmail.com');
    expect(deliveryEmail('ａ＠ｅｘａｍｐｌｅ．ｃｏｍ')).toBe('a@example.com');
  });

  // 收信域与身份域必须逐字相同：发信端拿到的永远是 punycode，不会按自己的 IDNA 模式再解释一遍。
  it.each([
    ['零宽空格', 'a.b@exa​mple.com', 'a.b@example.com'],
    ['软连字符', 'a.b@ex­ample.com', 'a.b@example.com'],
    ['ß（非过渡处理：保留，不变成 ss）', 'a.b@faß.de', 'a.b@xn--fa-hia.de'],
    ['Unicode 域名', 'User@例え．ＪＰ', 'user@xn--r8jz45g.jp'],
  ])('IDN %s：delivery 与 canonical 用同一个 punycode 域', (_, raw, want) => {
    expect(deliveryEmail(raw)).toBe(want);
    expect(canonicalEmail(raw)).toBe(want);
    expect(canonicalEmail(raw).split('@')[1]).toBe(deliveryEmail(raw).split('@')[1]);
  });

  it('parseEmail：legacy 只在与 canonical 不同、且与发信地址逐字相同时给出', () => {
    // U+FB01「ﬁ」：旧规则原样存，NFKC 后发信去 file@…——不同收件箱，不许回退到旧哈希
    expect(parseEmail('ﬁle@example.com')).toEqual({ delivery: 'file@example.com', canonical: 'file@example.com', legacy: null });
    expect(parseEmail('ﬁle+x@gmail.com').legacy).toBeNull();
    // IDN 老账户按 Unicode 域名存过：发信地址已是 punycode，同样不回退
    expect(parseEmail('a.b@faß.de').legacy).toBeNull();
    expect(parseEmail('Tom@Example.com')).toEqual({ delivery: 'tom@example.com', canonical: 'tom@example.com', legacy: null });
    expect(parseEmail('J.Doe+x@gmail.com')).toEqual({
      delivery: 'j.doe+x@gmail.com', canonical: 'jdoe@gmail.com', legacy: 'j.doe+x@gmail.com',
    });
    expect(legacyNormalizeEmail(' A.B@GMAIL.COM ')).toBe('a.b@gmail.com');
    expect(parseEmail('+x@gmail.com')).toBeNull();
  });
});

async function requestCode(env, email, purpose, now = NOW) {
  return call(env, 'POST', '/v1/email/code', {
    body: { email, purpose, lang: 'zh' }, headers: { 'CF-Connecting-IP': nextIp() }, now,
  });
}

async function tryRegister(env, email, nickname = 'alias') {
  const key = await newKey();
  await requestCode(env, email, 'register');
  return call(env, 'POST', '/v1/register', {
    key, body: { pubkey: key.pubkey, nickname, email, code: lastCode(env, email) },
    headers: { 'CF-Connecting-IP': nextIp() }, now: NOW,
  });
}

async function tryLogin(env, email, now = NOW) {
  const key = await newKey();
  await requestCode(env, email, 'login', now);
  return call(env, 'POST', '/v1/login', {
    key, body: { pubkey: key.pubkey, email, code: lastCode(env, email) },
    headers: { 'CF-Connecting-IP': nextIp() }, now,
  });
}

/** 模拟 2026-10-17 之前注册的账户：email_hash 是旧规则（trim + 小写）下的哈希。 */
async function legacyUser(env, nickname, rawEmail) {
  const u = await registerUser(env, nickname, { email: `seed-${nickname}@example.com`, now: NOW });
  const old = await emailHash(env, legacyNormalizeEmail(rawEmail));
  env.DB.raw.prepare('UPDATE accounts SET email_hash = ? WHERE id = ?').run(old, u.id);
  return u;
}

const hashOf = (env, id) => env.DB.raw.prepare('SELECT email_hash FROM accounts WHERE id = ?').get(id).email_hash;

describe('别名注册被拒', () => {
  it.each([
    ['点号', 'j.o.h.n@gmail.com'],
    ['+tag', 'john+second@gmail.com'],
    ['googlemail', 'john@googlemail.com'],
    ['大小写 + 全角', 'ＪＯＨＮ＋ｚ＠ｇｍａｉｌ．ｃｏｍ'],
    ['outlook +tag', null],
  ])('%s', async (_, alias) => {
    const env = makeEnv();
    if (alias === null) {
      await registerUser(env, 'first', { email: 'me@outlook.com', now: NOW });
      const r = await tryRegister(env, 'me+alt@outlook.com');
      expect(r.data.error).toBe('email_taken');
      return;
    }
    await registerUser(env, 'first', { email: 'john@gmail.com', now: NOW });
    const key = await newKey();
    await requestCode(env, alias, 'register');
    // 发信发到用户输入的别名地址（NFKC + 小写后），别名照样收信
    const mail = env.sent.at(-1);
    expect(mail.to).toBe(deliveryEmail(alias));
    const code = /\b(\d{6})\b/.exec(mail.text)[1];
    const r = await call(env, 'POST', '/v1/register', {
      key, body: { pubkey: key.pubkey, nickname: 'second', email: alias, code }, now: NOW,
    });
    expect(r.status).toBe(409);
    expect(r.data.error).toBe('email_taken');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM accounts').get().n).toBe(1);
  });

  it('新注册也拒绝「旧规则哈希」命中的老账户（老账户按 a.b@gmail.com 原样存过）', async () => {
    const env = makeEnv();
    await legacyUser(env, 'old', 'a.b@gmail.com');
    const r = await tryRegister(env, 'a.b@gmail.com');
    expect(r.data.error).toBe('email_taken');
  });

  it('非白名单域不受影响：点号 / +tag 是不同账户', async () => {
    const env = makeEnv();
    await registerUser(env, 'first', { email: 'a.b@example.com', now: NOW });
    expect((await tryRegister(env, 'ab@example.com', 'x')).status).toBe(201);
    expect((await tryRegister(env, 'a.b+c@example.com', 'y')).status).toBe(201);
    expect((await tryRegister(env, 'a.b+c@qq.com', 'z')).status).toBe(201);
  });

  it('别名要的码用原址也能核对（验证码按规范化哈希存）', async () => {
    const env = makeEnv();
    const key = await newKey();
    await requestCode(env, 'J.Doe+x@gmail.com', 'register');
    const code = lastCode(env, 'j.doe+x@gmail.com');
    const r = await call(env, 'POST', '/v1/register', {
      key, body: { pubkey: key.pubkey, nickname: 'jd', email: 'jdoe@gmail.com', code }, now: NOW,
    });
    expect(r.status).toBe(201);
    expect(hashOf(env, r.data.id)).toBe(await emailHash(env, 'jdoe@gmail.com'));
  });
});

describe('老账户惰性迁移', () => {
  it('用当初注册的别名原样登录：成功并升级成规范化哈希；之后用任意别名都能登录', async () => {
    const env = makeEnv();
    const u = await legacyUser(env, 'old', 'J.Doe+promo@gmail.com');
    const r = await tryLogin(env, 'j.doe+promo@gmail.com');
    expect(r.status).toBe(200);
    expect(r.data.id).toBe(u.id);
    expect(hashOf(env, u.id)).toBe(await emailHash(env, 'jdoe@gmail.com'));
    const again = await tryLogin(env, 'jdoe+other@googlemail.com');
    expect(again.status).toBe(200);
    expect(again.data.id).toBe(u.id);
  });

  it('当初按规范形式注册的老账户（哈希本来就相同）：用别名直接登录，不需要升级', async () => {
    const env = makeEnv();
    const u = await legacyUser(env, 'old', 'jdoe@gmail.com');
    const before = hashOf(env, u.id);
    const r = await tryLogin(env, 'J.Doe+x@gmail.com');
    expect(r.status).toBe(200);
    expect(r.data.id).toBe(u.id);
    expect(hashOf(env, u.id)).toBe(before);
  });

  it('老账户能收到登录码（发码时新旧哈希都查）', async () => {
    const env = makeEnv();
    await legacyUser(env, 'old', 'a.b@gmail.com');
    await requestCode(env, 'a.b@gmail.com', 'login');
    expect(lastCode(env, 'a.b@gmail.com')).toMatch(/^\d{6}$/);
  });

  it('开发者网页登录同样走惰性迁移', async () => {
    const env = makeEnv();
    const u = await legacyUser(env, 'dev', 'd.e.v@gmail.com');
    env.DB.raw.prepare("UPDATE accounts SET role = 'dev' WHERE id = ?").run(u.id);
    const form = (f) => new URLSearchParams(f).toString();
    const hdr = { 'Content-Type': 'application/x-www-form-urlencoded', Origin: 'https://rank.example.com', 'CF-Connecting-IP': nextIp() };
    await call(env, 'POST', '/dev/code', { body: new TextEncoder().encode(form({ email: 'd.e.v@gmail.com' })), headers: hdr, now: NOW });
    const code = lastCode(env, 'd.e.v@gmail.com');
    const r = await call(env, 'POST', '/dev/login', {
      body: new TextEncoder().encode(form({ email: 'd.e.v@gmail.com', code })), headers: hdr, now: NOW,
    });
    expect(r.status).toBe(303);
    expect(hashOf(env, u.id)).toBe(await emailHash(env, 'dev@gmail.com'));
  });

  it('升级冲突：规范化哈希已被另一账户占用 → 不合并、保留旧哈希、记录冲突；管理员只看到账户 id 与计数', async () => {
    const env = makeEnv();
    const holder = await registerUser(env, 'holder', { email: 'jdoe@gmail.com', now: NOW });
    const old = await legacyUser(env, 'old', 'j.doe@gmail.com');
    const oldHash = hashOf(env, old.id);
    // 逐字输入老账户当初的地址：登进的是老账户（与旧 Worker 一致），而不是占用者
    const r = await tryLogin(env, 'j.doe@gmail.com');
    expect(r.status).toBe(200);
    expect(r.data.id).toBe(old.id);
    expect(hashOf(env, old.id)).toBe(oldHash);
    expect(hashOf(env, holder.id)).toBe(await emailHash(env, 'jdoe@gmail.com'));
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM accounts').get().n).toBe(2);
    // 再登一次：同一对只记一行，次数累加
    await tryLogin(env, 'j.doe@gmail.com', NOW + 1000);
    const a = await call(env, 'GET', '/admin/api/email-conflicts', { headers: basic, now: NOW });
    expect(a.status).toBe(200);
    expect(a.data.count).toBe(1);
    expect(a.data.rows).toEqual([{ accountId: old.id, holderId: holder.id, firstSeenAt: NOW, lastSeenAt: NOW + 1000, seenCount: 2 }]);
    expect(JSON.stringify(a.data)).not.toMatch(/@|gmail/);
    // 用规范形式登录的是占用者（隔两小时：同一规范化邮箱每小时只发 3 封码）
    const h = await tryLogin(env, 'jdoe@gmail.com', NOW + 2 * 3600 * 1000);
    expect(h.data.id).toBe(holder.id);
  });

  it('占用者删号后，冲突账户下次登录即升级，冲突记录清掉', async () => {
    const env = makeEnv();
    const holder = await registerUser(env, 'holder', { email: 'jdoe@gmail.com', now: NOW });
    const old = await legacyUser(env, 'old', 'j.doe@gmail.com');
    await tryLogin(env, 'j.doe@gmail.com');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM email_hash_conflicts').get().n).toBe(1);
    const del = await call(env, 'DELETE', '/v1/me', { key: holder.key, account: holder.id, now: NOW + 10 });
    expect(del.status).toBeLessThan(300);
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM email_hash_conflicts').get().n).toBe(0);
    const r = await tryLogin(env, 'j.doe@gmail.com', NOW + 20);
    expect(r.data.id).toBe(old.id);
    expect(hashOf(env, old.id)).toBe(await emailHash(env, 'jdoe@gmail.com'));
  });

  it('NFKC 改写过的老账户不回退旧哈希：码不会发到别的收件箱、登不进旧账户（宁可锁住）', async () => {
    const env = makeEnv();
    // 旧 Worker 按原样存了「ﬁle@example.com」（U+FB01）——那是另一个收件箱
    const victim = await legacyUser(env, 'victim', 'ﬁle@example.com');
    const before = env.sent.length;
    await requestCode(env, 'ﬁle@example.com', 'login');
    expect(env.sent.length).toBe(before); // 规范化哈希无账户、不回退 → 不发信
    const key = await newKey();
    const r = await call(env, 'POST', '/v1/login', {
      key, body: { pubkey: key.pubkey, email: 'ﬁle@example.com', code: '123456' }, now: NOW,
    });
    expect(r.status).toBe(400);
    expect(r.data.error).toBe('bad_code');
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM device_keys WHERE account_id = ?').get(victim.id).n).toBe(1);
  });

  it('读完旧账户行到 batch 之间账户被删：不写孤儿冲突记录、不返回已删账户', async () => {
    const env = makeEnv();
    await registerUser(env, 'holder', { email: 'jdoe@gmail.com', now: NOW });
    const old = await legacyUser(env, 'old', 'j.doe@gmail.com');
    const ids = await emailHashes(env, parseEmail('j.doe@gmail.com'));
    // 在 batch 执行前插入一次删除，模拟并发删号
    const db = env.DB;
    const racing = {
      ...db,
      prepare: db.prepare,
      batch: async (stmts) => {
        db.raw.prepare('DELETE FROM accounts WHERE id = ?').run(old.id);
        return db.batch(stmts);
      },
    };
    const acc = await resolveEmailAccount({ ...env, DB: racing }, ids, NOW);
    expect(acc).toBeNull();
    expect(db.raw.prepare('SELECT COUNT(*) AS n FROM email_hash_conflicts').get().n).toBe(0);
  });

  it('管理接口要鉴权', async () => {
    const env = makeEnv();
    const r = await call(env, 'GET', '/admin/api/email-conflicts', { now: NOW });
    expect(r.status).toBe(401);
  });
});

describe('限流按规范化邮箱计', () => {
  it('换着别名发码也共用「每邮箱每小时」桶', async () => {
    const env = makeEnv();
    const aliases = ['john@gmail.com', 'j.ohn@gmail.com', 'john+1@gmail.com', 'john+2@googlemail.com', 'jo.hn+3@gmail.com'];
    for (const a of aliases) await requestCode(env, a, 'register');
    expect(env.sent).toHaveLength(EMAIL_LIMITS.perAddressHour);
  });

  it('非白名单域的不同写法是不同的桶', async () => {
    const env = makeEnv();
    for (const a of ['a.b@example.com', 'ab@example.com', 'a.b+1@example.com', 'a.b+2@example.com']) {
      await requestCode(env, a, 'register');
    }
    expect(env.sent).toHaveLength(4);
  });
});
