// 极简 SMTP 客户端（经 Workers TCP sockets 连域名邮箱服务商的 SMTP 服务器发信）。
//
// 为什么需要它：Workers 屏蔽出站 25 端口，不能直投收件人 MX；免费档 Cloudflare Email Service 也不能
// 发往任意地址。用域名邮箱（免费档）的 SMTP 提交端口（465 隐式 TLS / 587 STARTTLS）发信是零成本方案。
//
// 配置（secrets）：SMTP_HOST、SMTP_PORT（465 或 587，默认 465）、SMTP_USER、SMTP_PASS；发件人取 EMAIL_FROM。
// 只实现发一封纯文本邮件所需的最小子集：EHLO → [STARTTLS → EHLO] → AUTH LOGIN → MAIL/RCPT/DATA → QUIT。
// 测试注入 env.SMTP_CONNECT（与 cloudflare:sockets 的 connect 同签名）。

import { connect as cfConnect } from 'cloudflare:sockets';
import { HttpError } from './util.js';

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(s) {
  const bytes = enc.encode(s);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

/** 从 `Name <addr>` 或裸地址里取出 addr。 */
export function addressOf(from) {
  const m = /<([^>]+)>/.exec(from);
  return (m ? m[1] : from).trim();
}

/** RFC 2047 编码的主题 + base64 正文的 MIME 报文（CRLF 行尾）。 */
export function buildMessage({ from, to, subject, text, now = Date.now(), id = crypto.randomUUID() }) {
  const domain = addressOf(from).split('@')[1] || 'localhost';
  const body = b64(text).replace(/.{1,76}/g, '$&\r\n');
  return [
    `From: ${from}`,
    `To: <${to}>`,
    `Subject: =?UTF-8?B?${b64(subject)}?=`,
    `Date: ${new Date(now).toUTCString()}`,
    `Message-ID: <${id}@${domain}>`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    body,
  ].join('\r\n');
}

class Conn {
  constructor(socket) {
    this.setSocket(socket);
    this.buf = '';
  }

  setSocket(socket) {
    this.socket = socket;
    this.reader = socket.readable.getReader();
    this.writer = socket.writable.getWriter();
  }

  /** 读一条完整应答（多行应答以 `xyz-` 续行、`xyz ` 结束），返回 {code, text}。 */
  async reply() {
    for (;;) {
      const lines = this.buf.split('\r\n');
      for (let i = 0; i < lines.length - 1; i++) {
        if (/^\d{3} /.test(lines[i]) || /^\d{3}$/.test(lines[i])) {
          const text = lines.slice(0, i + 1).join('\n');
          this.buf = lines.slice(i + 1).join('\r\n');
          return { code: Number(lines[i].slice(0, 3)), text };
        }
      }
      const { value, done } = await this.reader.read();
      if (done) throw new HttpError(502, 'email_failed', 'smtp connection closed');
      this.buf += dec.decode(value, { stream: true });
    }
  }

  async send(line) {
    await this.writer.write(enc.encode(`${line}\r\n`));
  }

  async expect(line, codes) {
    if (line !== null) await this.send(line);
    const r = await this.reply();
    if (!codes.includes(r.code)) {
      throw new HttpError(502, 'email_failed', `smtp ${r.code}: ${r.text.slice(0, 120)}`);
    }
    return r;
  }

  /** STARTTLS 后换成 TLS socket（Workers 的 socket.startTls()）。 */
  upgrade() {
    this.reader.releaseLock();
    this.writer.releaseLock();
    this.setSocket(this.socket.startTls());
    this.buf = '';
  }

  async close() {
    try {
      await this.socket.close();
    } catch {
      /* 已关 */
    }
  }
}


export function smtpConfigured(env) {
  return Boolean(env.SMTP_HOST && env.SMTP_USER && env.SMTP_PASS);
}

/** 经 SMTP 发一封纯文本邮件；任何非预期应答抛 502 email_failed。 */
export async function sendViaSmtp(env, to, subject, text) {
  const port = Number(env.SMTP_PORT || 465);
  const implicitTls = port === 465;
  const connect = env.SMTP_CONNECT || cfConnect;
  const socket = await connect({ hostname: env.SMTP_HOST, port }, {
    secureTransport: implicitTls ? 'on' : 'starttls',
    allowHalfOpen: false,
  });
  const c = new Conn(socket);
  const heloName = addressOf(env.EMAIL_FROM).split('@')[1] || 'localhost';
  try {
    await c.expect(null, [220]);
    await c.expect(`EHLO ${heloName}`, [250]);
    if (!implicitTls) {
      await c.expect('STARTTLS', [220]);
      c.upgrade();
      await c.expect(`EHLO ${heloName}`, [250]);
    }
    await c.expect('AUTH LOGIN', [334]);
    await c.expect(b64(env.SMTP_USER), [334]);
    await c.expect(b64(env.SMTP_PASS), [235]);
    await c.expect(`MAIL FROM:<${addressOf(env.EMAIL_FROM)}>`, [250]);
    await c.expect(`RCPT TO:<${to}>`, [250, 251]);
    await c.expect('DATA', [354]);
    // 点填充：行首的 '.' 前再加一个 '.'（base64 正文不会出现，头部保险起见也处理）。
    const msg = buildMessage({ from: env.EMAIL_FROM, to, subject, text }).replace(/^\./gm, '..');
    await c.expect(`${msg}\r\n.`, [250]);
    await c.send('QUIT');
  } finally {
    await c.close();
  }
}
