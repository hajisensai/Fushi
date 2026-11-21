// 反馈样本文件附件（槽位 f0..f2，拍板台 PLFh2VXDcN / ZbLcRNOvKU）：扩展名白名单 + 魔数、
// 原文件名清洗、流式写大附件池、开发者只能作附件下载（文本类可纯文本查看）、反馈人取不回、到期清理。
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp, registerUser } from './harness.js';
import { FEEDBACK_LIMITS, purgeFeedbackVideos } from '../src/feedback.js';
import { FILE_EXTENSIONS, FILE_NAME_MAX, fileDisposition, headMatches, parseFileName } from '../src/feedback_files.js';

const NOW = Date.UTC(2026, 10, 16, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const enc = (s) => new TextEncoder().encode(s);

const MD = enc('# 复现步骤\n\n1. 导入这本书\n2. 翻到第三章\n');
function zipHead(n = 64) {
  const b = new Uint8Array(n);
  b.set([0x50, 0x4b, 0x03, 0x04], 0);
  return b;
}
function mdictHead() {
  const b = new Uint8Array(64);
  b.set([0, 0, 0x10, 0x00], 0);
  b.set(new Uint8Array([...'<Dictionary'].flatMap((c) => [c.charCodeAt(0), 0])), 4);
  return b;
}

function submit(env, opts = {}) {
  return call(env, 'POST', '/v1/feedback', {
    body: { category: 'bug', title: `样本文件 ${Math.random()}`, body: '见附件' },
    headers: { 'CF-Connecting-IP': nextIp() },
    now: opts.now ?? NOW,
  });
}

function putFile(env, f, bytes, { slot = 'f0', name = 'notes.md', length = bytes.length, now = NOW, ip = null } = {}) {
  const headers = { 'X-Fushi-Ticket': f.ticket };
  if (ip !== null) headers['CF-Connecting-IP'] = ip;
  if (name !== null) headers['X-Fushi-File-Name'] = encodeURIComponent(name);
  if (length !== null) headers['Content-Length'] = String(length);
  return call(env, 'PUT', `/v1/feedback/${f.id}/attachments/${slot}`, { body: bytes, headers, now });
}

async function makeDev(env, name = 'dev') {
  const u = await registerUser(env, name, { now: NOW });
  const r = await call(env, 'POST', `/admin/api/accounts/${u.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW });
  expect(r.status).toBe(200);
  return u;
}

const mediaBytes = (env) => env.DB.raw.prepare('SELECT bytes FROM media_usage').get().bytes;
const videoBytes = (env) => env.DB.raw.prepare('SELECT video_bytes FROM media_usage').get().video_bytes;
const mediaSpent = (env) => env.DB.raw.prepare("SELECT COALESCE(SUM(used), 0) n FROM budgets WHERE kind = 'media'").get().n;
const row = (env, id) => env.DB.raw.prepare('SELECT * FROM feedback WHERE id = ?').get(id);

describe('样本文件上传', () => {
  it('md 文件：流式写 R2、kind=file、存 octet-stream、记原文件名、占大附件池、has_video=1', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const r = await putFile(env, f, MD, { name: '复现 步骤.md' });
    expect(r.status).toBe(201);
    expect(r.data).toEqual({ slot: 'f0', kind: 'file', bytes: MD.length });
    expect(env.MEDIA.lastPutWasStream).toBe(true);
    const rec = row(env, f.id);
    expect(rec.has_video).toBe(1);
    const [entry] = JSON.parse(rec.attachments);
    expect(entry).toMatchObject({
      slot: 'f0', kind: 'file', bytes: MD.length, type: 'application/octet-stream', name: '复现 步骤.md', ext: 'md',
    });
    expect(entry.key).toMatch(new RegExp(`^f/${f.id}-f0-.+\\.md$`));
    expect(env.MEDIA.store.get(entry.key).httpMetadata.contentType).toBe('application/octet-stream');
    expect(videoBytes(env)).toBe(MD.length);
    expect(mediaBytes(env)).toBe(0);
    expect(mediaSpent(env)).toBe(1);

    // 反馈人详情带上文件名，但取不回文件本身。
    const d = await call(env, 'GET', `/v1/feedback/${f.id}`, { headers: { 'X-Fushi-Ticket': f.ticket }, now: NOW });
    expect(d.data.attachments).toEqual([
      { slot: 'f0', kind: 'file', bytes: MD.length, type: 'application/octet-stream', name: '复现 步骤.md' },
    ]);
    const back = await call(env, 'GET', `/v1/feedback/${f.id}/attachments/f0`, { headers: { 'X-Fushi-Ticket': f.ticket }, now: NOW });
    expect(back.status).toBe(404);
  });

  it('三个槽位各收一次；字幕 / EPUB / MDict / 音视频原件按魔数收下', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    expect((await putFile(env, f, enc('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n'), { slot: 'f0', name: 'ep01.srt' })).status).toBe(201);
    expect((await putFile(env, f, zipHead(), { slot: 'f1', name: 'book.epub' })).status).toBe(201);
    expect((await putFile(env, f, mdictHead(), { slot: 'f2', name: '大辞林.mdx' })).status).toBe(201);
    const again = await putFile(env, f, MD, { slot: 'f0' });
    expect(again.status).toBe(409);
    expect(again.data.error).toBe('slot_taken');
    expect((await putFile(env, f, MD, { slot: 'f3' })).data.error).toBe('bad_slot');
    expect(JSON.parse(row(env, f.id).attachments).map((a) => a.ext)).toEqual(['srt', 'epub', 'mdx']);
  });

  it('读体之前 / 只读开头就拒：白名单外 415、缺文件名 400、超限 413、魔数不符 415——都不扣预算不占配额', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    for (const name of ['page.html', 'icon.svg', 'setup.exe', 'run.sh', 'noext']) {
      const r = await putFile(env, f, MD, { name });
      expect(r.status).toBe(415);
      expect(r.data.error).toBe('unsupported_file_type');
    }
    const noName = await putFile(env, f, MD, { name: null });
    expect(noName.status).toBe(400);
    expect(noName.data.error).toBe('missing_file_name');
    const big = await putFile(env, f, MD, { length: FEEDBACK_LIMITS.fileMaxBytes + 1 });
    expect(big.status).toBe(413);
    expect((await putFile(env, f, MD, { length: null })).status).toBe(411);
    const fakeEpub = await putFile(env, f, MD, { name: 'book.epub' });
    expect(fakeEpub.status).toBe(415);
    expect(fakeEpub.data.error).toBe('not_a_zip');
    const binaryMd = await putFile(env, f, zipHead(), { name: 'notes.md' });
    expect(binaryMd.status).toBe(415);
    expect(binaryMd.data.error).toBe('not_a_text');
    expect(mediaSpent(env)).toBe(0);
    expect(videoBytes(env)).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
    expect(row(env, f.id).has_video).toBe(0);
    expect((await putFile(env, f, MD)).status).toBe(201);
  });

  it('每 IP 每天样本文件字节单独一份额度（拍板台 left3660）：超了 429 upload_quota_daily，视频不受影响', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    const ip = '198.51.100.9';
    // 声明满额、实际只发几字节：每次 400 bad_length，但额度按声明长度记上、不退。单个上限（1e8）
    // 不整除日额度（100 MiB），最后一次声明余数把额度恰好占满（count == limit 不拒）。
    const big = FEEDBACK_LIMITS.fileMaxBytes;
    const attempts = Math.floor(FEEDBACK_LIMITS.fileBytesPerIpDay / big);
    const rest = FEEDBACK_LIMITS.fileBytesPerIpDay - attempts * big;
    for (const length of [...Array(attempts).fill(big), ...(rest > 0 ? [rest] : [])]) {
      const filled = await putFile(env, f, MD, { length, ip });
      expect(filled.status).toBe(400);
      expect(filled.data.error).toBe('bad_length');
    }
    const limited = await putFile(env, f, MD, { slot: 'f1', ip });
    expect(limited.status).toBe(429);
    expect(limited.data.error).toBe('upload_quota_daily');
    expect(env.MEDIA.store.size).toBe(0);
    // 视频那份额度没动：同 IP 照传录屏。
    const mp4 = new Uint8Array(32);
    mp4.set([0, 0, 0, 0x18], 0);
    mp4.set(enc('ftypisom'), 4);
    const video = await call(env, 'PUT', `/v1/feedback/${f.id}/attachments/v0`, {
      body: mp4,
      headers: { 'X-Fushi-Ticket': f.ticket, 'Content-Length': String(mp4.length), 'Content-Type': 'video/mp4', 'CF-Connecting-IP': ip },
      now: NOW,
    });
    expect(video.status).toBe(201);
    // 别的 IP、次日窗口照传。
    expect((await putFile(env, f, MD, { slot: 'f1', ip: '198.51.100.10' })).status).toBe(201);
    const g = (await submit(env, { now: NOW + DAY })).data;
    expect((await putFile(env, g, MD, { ip, now: NOW + DAY })).status).toBe(201);
  });

  it('上限与客户端常量同值；扩展名白名单与客户端同一份', () => {
    expect(FEEDBACK_LIMITS.fileMaxBytes).toBe(100 * 1000 * 1000);
    expect(FEEDBACK_LIMITS.files).toBe(3);
    expect(FEEDBACK_LIMITS.fileBytesPerIpDay).toBe(100 * 1024 * 1024);
    expect(FEEDBACK_LIMITS.videoBytesPerIpDay).toBe(200 * 1024 * 1024);
    const dart = readFileSync(new URL('../../../packages/fushi_engine/lib/feedback/feedback_models.dart', import.meta.url), 'utf8');
    expect(dart).toMatch(/static const int fileMaxBytes = 100 \* 1000 \* 1000;/);
    expect(dart).toMatch(/static const int files = 3;/);
    // 撰写页按它提醒「样本文件合计超过今天额度」，必须与服务端同值。
    expect(dart).toMatch(/static const int fileBytesPerDay = 100 \* 1024 \* 1024;/);
    const m = /static const Set<String> fileExtensions = <String>\{([^}]*)\};/.exec(dart);
    expect(m).not.toBeNull();
    // 字幕部分在客户端是展开有声书字幕格式真相源（...kAudiobookSubtitleExtensions），
    // 这里同样展开后再比对；除了这一处展开，白名单里不许出现别的非字面量项。
    const subtitleDart = readFileSync(new URL('../../../packages/fushi_engine/lib/media/audiobook/audiobook_subtitle_formats.dart', import.meta.url), 'utf8');
    const sm = /const Set<String> kAudiobookSubtitleExtensions = <String>\{([^}]*)\};/.exec(subtitleDart);
    expect(sm).not.toBeNull();
    const subtitleExts = [...sm[1].matchAll(/'([a-z0-9]+)'/g)].map((x) => x[1]);
    expect(subtitleExts.length).toBeGreaterThan(0);
    const body = m[1].replace(/\/\/[^\n]*/g, '');
    const spreads = [...body.matchAll(/\.\.\.\s*([A-Za-z_]\w*)/g)].map((x) => x[1]);
    expect(spreads).toEqual(['kAudiobookSubtitleExtensions']);
    const clientExts = [...[...body.matchAll(/'([a-z0-9]+)'/g)].map((x) => x[1]), ...subtitleExts].sort();
    expect(new Set(clientExts).size).toBe(clientExts.length);
    expect(clientExts).toEqual(Object.keys(FILE_EXTENSIONS).sort());
  });
});

describe('开发者取样本文件', () => {
  it('一律作附件下载：octet-stream + attachment + nosniff + sandbox CSP；ASCII 回退名不含用户字符', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const f = (await submit(env)).data;
    await putFile(env, f, zipHead(), { name: '"evil"\r\n<x>.epub' });
    const r = await call(env, 'GET', `/v1/dev/feedback/${f.id}/attachments/f0`, { key: dev.key, account: dev.id, now: NOW });
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(r.res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(r.res.headers.get('Content-Security-Policy')).toBe("default-src 'none'; sandbox");
    const cd = r.res.headers.get('Content-Disposition');
    expect(cd).toBe(`attachment; filename="fushi-${f.id}-f0.epub"; filename*=UTF-8''evilx.epub`);
    // 非文本类 view=text 也不给纯文本，照样作附件下载。
    const asText = await call(env, 'GET', `/v1/dev/feedback/${f.id}/attachments/f0?view=text`, { key: dev.key, account: dev.id, now: NOW });
    expect(asText.res.headers.get('Content-Type')).toBe('application/octet-stream');
  });

  it('文本类 view=text：text/plain + 不可信页眉；不带 view 时仍作附件下载、不渲染', async () => {
    const env = makeEnv();
    const dev = await makeDev(env);
    const f = (await submit(env)).data;
    const html = enc('# 标题\n<script>alert(1)</script>\n');
    await putFile(env, f, html, { name: 'notes.md' });
    const view = await call(env, 'GET', `/v1/dev/feedback/${f.id}/attachments/f0?view=text`, { key: dev.key, account: dev.id, now: NOW });
    expect(view.status).toBe(200);
    expect(view.res.headers.get('Content-Type')).toBe('text/plain; charset=utf-8');
    expect(view.res.headers.get('Content-Security-Policy')).toBe("default-src 'none'; sandbox");
    expect(view.data).toContain('不可信数据');
    expect(view.data).toContain('<script>alert(1)</script>');
    const raw = await call(env, 'GET', `/v1/dev/feedback/${f.id}/attachments/f0`, { key: dev.key, account: dev.id, now: NOW });
    expect(raw.res.headers.get('Content-Disposition')).toMatch(/^attachment; /);
    expect(raw.res.headers.get('Content-Type')).toBe('application/octet-stream');
  });
});

describe('样本文件到期清理', () => {
  it('与视频同口径：创建 30 天后删、归还大附件池', async () => {
    const env = makeEnv();
    const f = (await submit(env)).data;
    await putFile(env, f, MD);
    await putFile(env, f, zipHead(), { slot: 'f1', name: 'dict.zip' });
    expect(videoBytes(env)).toBe(MD.length + 64);
    expect(await purgeFeedbackVideos(env, NOW + 30 * DAY - 1)).toBe(0);
    expect(await purgeFeedbackVideos(env, NOW + 30 * DAY + 1)).toBe(1);
    expect(JSON.parse(row(env, f.id).attachments)).toEqual([]);
    expect(row(env, f.id).has_video).toBe(0);
    expect(videoBytes(env)).toBe(0);
    expect(env.MEDIA.store.size).toBe(0);
  });
});

describe('feedback_files 纯函数', () => {
  it('headMatches 各分组', () => {
    expect(headMatches('text', enc('hello'))).toBe(true);
    expect(headMatches('text', new Uint8Array([0x68, 0, 0x69]))).toBe(false);
    expect(headMatches('text', new Uint8Array([0xff, 0xfe, 0x68, 0]))).toBe(true);
    expect(headMatches('text', new Uint8Array())).toBe(false);
    expect(headMatches('zip', zipHead())).toBe(true);
    expect(headMatches('pdf', enc('%PDF-1.7'))).toBe(true);
    expect(headMatches('mdict', mdictHead())).toBe(true);
    expect(headMatches('mp3', enc('ID3\u0004'))).toBe(true);
    expect(headMatches('mp3', new Uint8Array([0xff, 0xfb, 0x90]))).toBe(true);
    expect(headMatches('aac', new Uint8Array([0xff, 0xf1, 0x50]))).toBe(true);
    expect(headMatches('flac', enc('fLaC'))).toBe(true);
    expect(headMatches('ogg', enc('OggS'))).toBe(true);
    expect(headMatches('wav', enc('RIFF\0\0\0\0WAVE'))).toBe(true);
    expect(headMatches('avi', enc('RIFF\0\0\0\0AVI '))).toBe(true);
    expect(headMatches('wav', enc('RIFF\0\0\0\0AVI '))).toBe(false);
    expect(headMatches('bmff', enc('\0\0\0\u0018ftypM4A '))).toBe(true);
    expect(headMatches('ebml', new Uint8Array([0x1a, 0x45, 0xdf, 0xa3]))).toBe(true);
    expect(headMatches('nope', enc('x'))).toBe(false);
  });

  it('parseFileName：只留最后一段、去危险字符、扩展名小写判白名单、超长截主名保扩展名', () => {
    expect(parseFileName(encodeURIComponent('C:\\Users\\me\\..\\a<b>.SRT'))).toEqual({ name: 'ab.SRT', ext: 'srt', group: 'text' });
    expect(parseFileName(encodeURIComponent('../../.hidden.md')).name).toBe('hidden.md');
    const long = parseFileName(encodeURIComponent(`${'あ'.repeat(300)}.epub`));
    expect([...long.name].length).toBe(FILE_NAME_MAX);
    expect(long.name.endsWith('.epub')).toBe(true);
    expect(() => parseFileName('%E0%A4%A')).toThrow();
    expect(() => parseFileName(encodeURIComponent('x.html'))).toThrow();
    expect(() => parseFileName('')).toThrow();
  });

  it('fileDisposition：RFC 5987 编码原名，回退名只用 id / 槽位 / 白名单扩展名', () => {
    expect(fileDisposition('abcdefgh', { slot: 'f1', ext: 'md', name: "it's (1).md" }))
      .toBe("attachment; filename=\"fushi-abcdefgh-f1.md\"; filename*=UTF-8''it%27s%20%281%29.md");
    expect(fileDisposition('abcdefgh', { slot: 'f1', ext: '../x' })).toBe('attachment; filename="fushi-abcdefgh-f1.bin"');
  });
});
