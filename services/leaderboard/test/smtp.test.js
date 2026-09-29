import { describe, expect, it } from 'vitest';
import { addressOf, buildMessage, sendViaSmtp } from '../src/smtp.js';
import { call, lastCode, makeEnv, nextIp } from './harness.js';

const NOW = Date.UTC(2026, 8, 30, 12);

/**
 * 脚本化的假 SMTP 服务器：按收到的命令逐条应答，记录会话。
 * authOk=false 时密码步骤回 535。STARTTLS 后 startTls() 返回一个新的假 socket（同一会话继续）。
 */
function fakeSmtp({ authOk = true } = {}) {
  const log = [];
  const state = { connects: [], upgraded: false, stage: 'greet', data: '' };
  function makeSocket() {
    let push;
    const readable = new ReadableStream({
      start(controller) {
        push = (s) => controller.enqueue(new TextEncoder().encode(s));
      },
    });
    let pending = '';
    const writable = new WritableStream({
      write(chunk) {
        pending += new TextDecoder().decode(chunk);
        let i;
        while ((i = pending.indexOf('\r\n')) >= 0) {
          const line = pending.slice(0, i);
          pending = pending.slice(i + 2);
          if (state.stage === 'data') {
            if (line === '.') {
              state.stage = 'cmd';
              push('250 queued\r\n');
            } else {
              state.data += `${line}\n`;
            }
            continue;
          }
          log.push(line);
          if (/^EHLO /.test(line)) push('250-smtp.example\r\n250-AUTH LOGIN\r\n250 STARTTLS\r\n');
          else if (line === 'STARTTLS') push('220 go ahead\r\n');
          else if (line === 'AUTH LOGIN') push('334 VXNlcm5hbWU6\r\n');
          else if (state.stage === 'user') { state.stage = 'pass'; push('334 UGFzc3dvcmQ6\r\n'); }
          else if (state.stage === 'pass') { state.stage = 'cmd'; push(authOk ? '235 ok\r\n' : '535 bad credentials\r\n'); }
          else if (/^MAIL FROM:/.test(line) || /^RCPT TO:/.test(line)) push('250 ok\r\n');
          else if (line === 'DATA') { state.stage = 'data'; push('354 end with .\r\n'); }
          else if (line === 'QUIT') push('221 bye\r\n');
          if (line === 'AUTH LOGIN') state.stage = 'user';
        }
      },
    });
    const socket = {
      readable,
      writable,
      close: async () => {},
      startTls: () => {
        state.upgraded = true;
        return makeSocket().socket; // TLS 握手后服务器不再发 greeting，等客户端 EHLO
      },
    };
    return { socket, push };
  }
  const connect = (address, options) => {
    state.connects.push({ address, options });
    const { socket, push } = makeSocket();
    push('220 smtp.example ESMTP\r\n');
    return socket;
  };
  return { connect, log, state };
}

const baseEnv = (over) => ({
  EMAIL_FROM: 'Fushi <no-reply@fushi.moe>',
  SMTP_HOST: 'smtp.example.com',
  SMTP_USER: 'no-reply@fushi.moe',
  SMTP_PASS: 'app-password',
  ...over,
});

describe('SMTP 发信（域名邮箱）', () => {
  it('465 隐式 TLS：AUTH LOGIN（base64 凭据）→ MAIL/RCPT/DATA，报文带 UTF-8 主题与 base64 正文', async () => {
    const srv = fakeSmtp();
    await sendViaSmtp(baseEnv({ SMTP_CONNECT: srv.connect }), 'user@example.com', 'Fushi 验证码', '你的验证码是：123456');
    expect(srv.state.connects[0]).toMatchObject({ address: { hostname: 'smtp.example.com', port: 465 }, options: { secureTransport: 'on' } });
    expect(srv.state.upgraded).toBe(false);
    expect(srv.log).toEqual([
      'EHLO fushi.moe', 'AUTH LOGIN', btoa('no-reply@fushi.moe'), btoa('app-password'),
      'MAIL FROM:<no-reply@fushi.moe>', 'RCPT TO:<user@example.com>', 'DATA', 'QUIT',
    ]);
    expect(srv.state.data).toContain('Subject: =?UTF-8?B?');
    const body = srv.state.data.split('\n\n')[1].replace(/\n/g, '');
    const decoded = new TextDecoder().decode(Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0)));
    expect(decoded).toBe('你的验证码是：123456');
  });

  it('587 STARTTLS：先明文 EHLO → STARTTLS → 升级后再 EHLO', async () => {
    const srv = fakeSmtp();
    await sendViaSmtp(baseEnv({ SMTP_PORT: '587', SMTP_CONNECT: srv.connect }), 'u@example.com', 's', 't');
    expect(srv.state.connects[0].options.secureTransport).toBe('starttls');
    expect(srv.state.upgraded).toBe(true);
    expect(srv.log.slice(0, 4)).toEqual(['EHLO fushi.moe', 'STARTTLS', 'EHLO fushi.moe', 'AUTH LOGIN']);
  });

  it('认证失败 → 502 email_failed（不吞错）', async () => {
    const srv = fakeSmtp({ authOk: false });
    await expect(sendViaSmtp(baseEnv({ SMTP_CONNECT: srv.connect }), 'u@example.com', 's', 't'))
      .rejects.toMatchObject({ status: 502, code: 'email_failed' });
  });

  it('addressOf / buildMessage', () => {
    expect(addressOf('Fushi <no-reply@fushi.moe>')).toBe('no-reply@fushi.moe');
    expect(addressOf('a@b.c')).toBe('a@b.c');
    const m = buildMessage({ from: 'Fushi <a@b.c>', to: 'x@y.z', subject: 's', text: 't', now: 0, id: 'id1' });
    expect(m).toContain('Message-ID: <id1@b.c>');
    expect(m.includes('\r\n')).toBe(true);
  });

  it('端到端：配置 SMTP_* 后发码走 SMTP，收件人能拿到 6 位码', async () => {
    const srv = fakeSmtp();
    const env = makeEnv({ EMAIL_SENDER: undefined, ...baseEnv({ SMTP_CONNECT: srv.connect }) });
    const r = await call(env, 'POST', '/v1/email/code', {
      body: { email: 'e2e@example.com', purpose: 'register', lang: 'zh' },
      headers: { 'CF-Connecting-IP': nextIp() },
      now: NOW,
    });
    expect(r.status).toBe(202);
    expect(srv.log).toContain('RCPT TO:<e2e@example.com>');
    expect(lastCode(env, 'e2e@example.com')).toBeNull(); // 没走测试发信器
    const body = srv.state.data.split('\n\n')[1].replace(/\n/g, '');
    const decoded = new TextDecoder().decode(Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0)));
    expect(decoded).toMatch(/\d{6}/);
  });
});
