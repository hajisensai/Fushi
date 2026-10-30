// Local plugin runner: executes a plugin directory in a Node `vm` sandbox that behaves like the Fushi
// host — the same prelude (lib/prelude.js is a byte copy of native/fushi_music/src/plugin/prelude.js),
// the same globals (no fetch / setTimeout / TextEncoder / process / import), the same network policy,
// request limits, redirect checks and a per-step CPU budget.
//
// Not emulated: the 64 MiB heap limit and QuickJS-vs-V8 language differences (QuickJS supports ES2023;
// avoid engine-specific APIs like Intl and you are fine).
import crypto from 'node:crypto';
import dns from 'node:dns/promises';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { listPackFiles } from './pkg.mjs';
import { HOST_API_VERSION, KNOWN_CAPABILITIES, LIMITS, Policy, isPrivateIp } from './rules.mjs';

const PRELUDE = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'prelude.js'), 'utf8');

const toBuf = (u8) => Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength);

function bytesOf(v) {
  if (typeof v === 'string') return Buffer.from(v, 'utf8');
  if (v && typeof v === 'object' && ArrayBuffer.isView(v) && v.BYTES_PER_ELEMENT === 1) return Buffer.from(toBuf(v));
  throw new TypeError('期望 Uint8Array 或字符串');
}

function aes(mode, decrypt, key, iv, data, pkcs7) {
  if (!pkcs7 && data.length % 16 !== 0) throw new Error('无填充 AES 的数据长度必须是 16 的整数倍');
  if (![16, 24, 32].includes(key.length)) throw new Error('AES 密钥必须是 16 / 24 / 32 字节');
  if (mode !== 'cbc' && mode !== 'ecb') throw new Error(`不支持的 AES 模式 ${mode}`);
  if (mode === 'cbc' && iv.length !== 16) throw new Error('AES-CBC 的 iv 必须 16 字节');
  const alg = `aes-${key.length * 8}-${mode}`;
  const c = decrypt
    ? crypto.createDecipheriv(alg, key, mode === 'cbc' ? iv : null)
    : crypto.createCipheriv(alg, key, mode === 'cbc' ? iv : null);
  c.setAutoPadding(pkcs7);
  try {
    return Buffer.concat([c.update(data), c.final()]);
  } catch {
    throw new Error('AES 解密失败（填充不对）');
  }
}

function rsaRaw(modulusHex, exponentHex, data) {
  const n = BigInt('0x' + modulusHex);
  const e = BigInt('0x' + exponentHex);
  let m = BigInt('0x' + (data.length ? data.toString('hex') : '0'));
  let r = 1n;
  let b = m % n;
  let x = e;
  while (x > 0n) {
    if (x & 1n) r = (r * b) % n;
    b = (b * b) % n;
    x >>= 1n;
  }
  const len = Math.ceil(modulusHex.replace(/^0+/, '').length / 2);
  return Buffer.from(r.toString(16).padStart(len * 2, '0'), 'hex');
}

/// Persistent dev state (storage / credentials) under <pluginDir>/.fushi-dev/. Never packed.
class DevStore {
  constructor(dir, name) {
    this.file = path.join(dir, '.fushi-dev', `${name}.json`);
    try {
      this.data = JSON.parse(fs.readFileSync(this.file, 'utf8'));
    } catch {
      this.data = {};
    }
  }
  get(k) {
    return Object.hasOwn(this.data, k) ? this.data[k] : null;
  }
  set(k, v) {
    this.data[k] = v;
    this.save();
  }
  remove(k) {
    delete this.data[k];
    this.save();
  }
  clear() {
    this.data = {};
    this.save();
  }
  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
  }
}

export class PluginRunner {
  /// [log] receives (level, message) for plugin logs and host-call traces.
  constructor(dir, manifest, { log = () => {}, trace = false, budgetMs = LIMITS.cpuBudgetMs } = {}) {
    this.dir = dir;
    this.manifest = manifest;
    this.policy = new Policy(manifest);
    this.perms = new Set(manifest.permissions ?? []);
    this.log = log;
    this.trace = trace;
    this.budgetMs = budgetMs;
    this.storage = new DevStore(dir, 'storage');
    this.credentials = new DevStore(dir, 'credentials');
    this.nextCall = 0;
    this.pendingCalls = 0;
    this.invocations = new Map();
    this.nextInv = 0;
    this.httpCount = 0;
    this.packFiles = new Set(listPackFiles(dir));
  }

  boot() {
    const ctx = vm.createContext({}, { name: `plugin:${this.manifest.id}`, microtaskMode: 'afterEvaluate', codeGeneration: { strings: true, wasm: false } });
    this.ctx = ctx;
    const CU8 = vm.runInContext('Uint8Array', ctx);
    const u8 = (buf) => {
      const out = new CU8(buf.length);
      out.set(buf);
      return out;
    };
    this.u8 = u8;
    const self = this;
    const n = {
      apiVersion: HOST_API_VERSION,
      hostCall(op, argsJson, body) {
        return self.hostCall(op, argsJson, body === undefined || body === null ? undefined : bytesOf(body));
      },
      settle(inv, ok, payload) {
        const p = self.invocations.get(inv);
        if (!p) return;
        self.invocations.delete(inv);
        if (Buffer.byteLength(payload) > LIMITS.maxResultBytes) return p.reject(new Error('插件返回值超过 8 MiB'));
        if (ok) p.resolve(JSON.parse(payload));
        else p.reject(new PluginError(payload));
      },
      log(level, msg) {
        self.log(['debug', 'info', 'warn', 'error'].includes(level) ? level : 'info', String(msg).slice(0, 4000));
      },
      compile(p) {
        // Only files that `pack` would include are loadable, like the installed package.
        if (!self.packFiles.has(p)) return undefined;
        const file = path.join(self.dir, ...p.split('/'));
        const src = fs.readFileSync(file, 'utf8');
        return vm.runInContext(`(function (module, exports, require) {\n${src}\n})`, ctx, { filename: file, lineOffset: -1 });
      },
      utf8Encode: (s) => u8(Buffer.from(String(s), 'utf8')),
      utf8Decode: (v) => bytesOf(v).toString('utf8'),
      b64Encode: (v) => bytesOf(v).toString('base64'),
      b64Decode(s) {
        const cleaned = String(s).replace(/\s+/g, '');
        if (!/^[A-Za-z0-9+/]*={0,2}$/.test(cleaned) || cleaned.length % 4 !== 0) throw new Error('base64 解码失败');
        return u8(Buffer.from(cleaned, 'base64'));
      },
      hexEncode: (v) => bytesOf(v).toString('hex'),
      hexDecode(s) {
        if (!/^[0-9a-fA-F]*$/.test(s) || s.length % 2) throw new Error('十六进制解码失败');
        return u8(Buffer.from(s, 'hex'));
      },
      digest(alg, v) {
        if (!['md5', 'sha1', 'sha256'].includes(alg)) throw new Error('不支持的摘要算法');
        return u8(crypto.createHash(alg).update(bytesOf(v)).digest());
      },
      hmac(alg, key, data) {
        if (!['md5', 'sha1', 'sha256'].includes(alg)) throw new Error('不支持的 HMAC 算法');
        return u8(crypto.createHmac(alg, bytesOf(key)).update(bytesOf(data)).digest());
      },
      aes: (mode, decrypt, key, iv, data, padding) => u8(aes(mode, decrypt, bytesOf(key), bytesOf(iv), bytesOf(data), padding === 'pkcs7')),
      rsaRaw: (m, e, data) => u8(rsaRaw(String(m), String(e), bytesOf(data))),
      randomBytes(len) {
        if (!(len >= 0 && len <= 4096)) throw new Error('randomBytes 长度须在 0–4096');
        return u8(crypto.randomBytes(len));
      },
    };
    // Errors thrown by host functions must be the sandbox's own Error type (like QuickJS's throw), or
    // `instanceof Error` checks in plugin code and the prelude fail.
    const CError = vm.runInContext('Error', ctx);
    const CTypeError = vm.runInContext('TypeError', ctx);
    for (const [k, f] of Object.entries(n)) {
      if (typeof f !== 'function') continue;
      n[k] = function (...args) {
        try {
          return f.apply(this, args);
        } catch (e) {
          if (e instanceof CError) throw e;
          throw e instanceof TypeError ? new CTypeError(e.message) : new CError(e.message);
        }
      };
    }
    ctx.__n = n;
    this.step(() => vm.runInContext(PRELUDE, ctx, { filename: 'prelude.js', timeout: this.budgetMs }));
    this.step(() => vm.runInContext(`__fushi_load_entry(${JSON.stringify(this.manifest.entry)})`, ctx, { timeout: this.budgetMs }), `加载入口 ${this.manifest.entry} 失败`);
    const exported = JSON.parse(vm.runInContext('JSON.stringify(Object.keys(__fushi_exports || {}).filter(function (k) { return typeof __fushi_exports[k] === "function"; }))', ctx));
    for (const cap of this.manifest.capabilities ?? []) {
      if (!exported.includes(cap)) throw new Error(`清单声明了能力 ${cap}，入口却没有导出同名函数 (module.exports.${cap})`);
    }
    this.bootWarnings = exported
      .filter((fn) => !(this.manifest.capabilities ?? []).includes(fn) && KNOWN_CAPABILITIES.includes(fn))
      .map((fn) => `module.exports.${fn} exists but "${fn}" is not in manifest.capabilities — the host never calls it`);
    return exported;
  }

  /// Runs [fn] (which evaluates in the context; microtasks drain inside the same timeout).
  step(fn, prefix) {
    try {
      return fn();
    } catch (e) {
      if (e && e.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT') throw new Error(`插件单步 CPU 超过 ${this.budgetMs} ms，已终止（宿主会作废这个实例）`);
      if (prefix) throw new Error(`${prefix}：${e && e.stack ? e.stack : e}`);
      throw e;
    }
  }

  invoke(method, args) {
    const inv = ++this.nextInv;
    const p = new Promise((resolve, reject) => this.invocations.set(inv, { resolve, reject }));
    this.ctx.__dev_args = [inv, method, JSON.stringify(args ?? {})];
    this.step(() => vm.runInContext('__fushi_invoke.apply(null, __dev_args)', this.ctx, { timeout: this.budgetMs }));
    return p;
  }

  complete(id, ok, payload, body) {
    this.ctx.__dev_args = [id, ok, payload, body === undefined ? undefined : this.u8(body)];
    this.step(() => vm.runInContext('__fushi_complete.apply(null, __dev_args)', this.ctx, { timeout: this.budgetMs }));
  }

  hostCall(op, argsJson, body) {
    const args = JSON.parse(argsJson);
    if (body && op !== 'http') throw new Error(`宿主调用 ${op} 不收二进制数据`);
    if (body && body.length > LIMITS.maxRequestBodyBytes) throw new Error('请求体超过 4 MiB');
    let run;
    if (op === 'http') {
      const req = this.checkHttp(args);
      run = () => this.http(req, body);
    } else if (op.startsWith('storage.') || op.startsWith('credentials.')) {
      const [kind, action] = op.split('.');
      const store = kind === 'storage' ? this.storage : this.credentials;
      if (!this.perms.has(kind)) throw new Error(`插件没有 ${kind} 权限`);
      if (!['get', 'set', 'remove'].includes(action)) throw new Error(`未知宿主调用 ${op}`);
      const key = args?.key;
      const maxKey = kind === 'storage' ? LIMITS.maxStorageKey : 256;
      if (typeof key !== 'string' || key.length === 0 || Buffer.byteLength(key) > maxKey) throw new Error(`${kind} key 为空或过长`);
      if (action === 'set') {
        if (typeof args.value !== 'string') throw new Error(`${op} 需要字符串 value`);
        const max = kind === 'storage' ? LIMITS.maxStorageValue : LIMITS.maxCredentialValue;
        if (Buffer.byteLength(args.value) > max) throw new Error(`${kind} value 超过上限`);
      }
      run = async () => {
        if (action === 'get') return { value: store.get(key) };
        if (action === 'set') store.set(key, args.value);
        else store.remove(key);
        return { value: null };
      };
    } else throw new Error(`未知宿主调用 ${op}`);
    if (this.pendingCalls >= 32) throw new Error('在途宿主调用超过 32 个，插件已终止');
    const id = ++this.nextCall;
    this.pendingCalls++;
    run().then(
      (r) => {
        this.pendingCalls--;
        this.complete(id, true, JSON.stringify(r.value ?? null), r.body);
      },
      (e) => {
        this.pendingCalls--;
        this.complete(id, false, e.message);
      },
    );
    return id;
  }

  checkHttp(args) {
    if (!this.perms.has('network')) throw new Error('插件没有 network 权限');
    if (!args || typeof args.url !== 'string' || typeof args.method !== 'string') throw new Error('http 参数不合法');
    this.policy.checkMethod(args.method);
    const url = this.policy.checkUrl(args.url);
    const headers = args.headers ?? {};
    if (Object.keys(headers).length > LIMITS.maxHeaders) throw new Error('请求头过多');
    for (const [k, v] of Object.entries(headers)) {
      if (typeof v !== 'string') throw new Error(`请求头 ${k} 的值必须是字符串`);
      if (!/^[A-Za-z0-9_-]+$/.test(k) || v.length > LIMITS.maxHeaderBytes || /[\r\n]/.test(v)) throw new Error(`请求头不合法：${k}`);
      if (['host', 'content-length', 'connection', 'transfer-encoding'].includes(k.toLowerCase())) throw new Error(`不允许设置请求头 ${k}`);
    }
    const t = Number(args.timeoutMs) || 0;
    const timeoutMs = t === 0 ? LIMITS.httpTimeoutDefaultMs : Math.min(Math.max(t, LIMITS.httpTimeoutMinMs), LIMITS.httpTimeoutMaxMs);
    return { url, method: args.method, headers, timeoutMs };
  }

  async pin(url) {
    const host = new URL(url).hostname;
    const addrs = await dns.lookup(host, { all: true });
    for (const a of addrs) {
      // 198.18.0.0/15 (fake-ip proxies) is allowed after DNS, like the host.
      if (isPrivateIp(a.address)) throw new Error(`${host} 解析到本机 / 局域网地址 ${a.address}，宿主拒绝连接`);
    }
  }

  async http(req, body) {
    let { url, method, headers } = req;
    const started = Date.now();
    this.httpCount++;
    for (let hop = 0; ; hop++) {
      await this.pin(url);
      // The app's HTTP client is Dart's: without a plugin-set User-Agent the site sees Dart's default.
      const hasUa = Object.keys(headers).some((k) => k.toLowerCase() === 'user-agent');
      const res = await fetch(url, {
        method,
        headers: hasUa ? headers : { ...headers, 'User-Agent': 'Dart/3.11 (dart:io)' },
        body: body && method !== 'GET' && method !== 'HEAD' ? body : undefined,
        redirect: 'manual',
        signal: AbortSignal.timeout(req.timeoutMs),
      }).catch((e) => {
        throw new Error(e.name === 'TimeoutError' ? '请求超时' : `网络错误：${e.cause?.message ?? e.message}`);
      });
      const location = res.headers.get('location');
      if ([301, 302, 303, 307, 308].includes(res.status) && location) {
        await res.arrayBuffer().catch(() => {});
        if (hop >= LIMITS.maxRedirects) throw new Error('重定向次数过多');
        const target = new URL(location, url).toString();
        try {
          url = this.policy.checkUrl(target);
        } catch (e) {
          throw new Error(`重定向到 ${target} 不在插件网络授权内（${e.message}）`);
        }
        if (res.status === 303 || ((res.status === 301 || res.status === 302) && method === 'POST')) {
          method = 'GET';
          body = undefined;
          headers = Object.fromEntries(Object.entries(headers).filter(([k]) => k.toLowerCase() !== 'content-type'));
        }
        continue;
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of res.body ?? []) {
        size += chunk.length;
        if (size > LIMITS.maxResponseBytes) throw new Error('响应体超过 8 MiB');
        chunks.push(chunk);
      }
      const outHeaders = {};
      res.headers.forEach((v, k) => {
        if (k !== 'set-cookie') outHeaders[k.toLowerCase()] = v;
      });
      const setCookies = res.headers.getSetCookie?.() ?? [];
      if (setCookies.length) outHeaders['set-cookie'] = setCookies.join(', ');
      if (this.trace) this.log('trace', `${method} ${url} → ${res.status} (${size} B, ${Date.now() - started} ms)`);
      return { value: { status: res.status, url, headers: outHeaders, setCookies }, body: Buffer.concat(chunks) };
    }
  }
}

export class PluginError extends Error {}
