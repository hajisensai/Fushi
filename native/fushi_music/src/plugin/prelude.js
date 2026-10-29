// 插件运行时前奏：在插件代码之前执行，搭出插件可见的全局 `fushi` / `console` / `require`。
// 原生能力全部挂在 `__n`（Rust 注入，见 runtime.rs），执行完本文件后从全局删掉，插件拿不到。
// 契约见 docs/specs/2026-10-28-music-plugins.md §3。
(function (n) {
  'use strict';
  var pendingCalls = Object.create(null);

  function hostCall(op, args) {
    return new Promise(function (resolve, reject) {
      var id = n.hostCall(op, JSON.stringify(args === undefined ? null : args));
      pendingCalls[id] = { resolve: resolve, reject: reject };
    });
  }

  function errorString(e) {
    if (e instanceof Error) {
      var s = (e.name || 'Error') + ': ' + e.message;
      if (e.stack) s += '\n' + e.stack;
      return s;
    }
    try {
      return typeof e === 'string' ? e : JSON.stringify(e);
    } catch (_) {
      return String(e);
    }
  }

  // Rust 侧在宿主调用完成后调它（成功：payload 是 JSON 文本；失败：错误信息）。
  globalThis.__fushi_complete = function (id, ok, payload) {
    var p = pendingCalls[id];
    if (!p) return;
    delete pendingCalls[id];
    if (ok) p.resolve(JSON.parse(payload));
    else p.reject(new Error(payload));
  };

  // Rust 侧发起一次能力调用；结束时经 n.settle 回报（JSON 文本 / 错误串）。
  globalThis.__fushi_invoke = function (inv, method, argsJson) {
    var exp = globalThis.__fushi_exports;
    Promise.resolve()
      .then(function () {
        var f = exp && exp[method];
        if (typeof f !== 'function') throw new Error('插件没有导出 ' + method);
        return f(JSON.parse(argsJson));
      })
      .then(
        function (v) {
          var json = JSON.stringify(v === undefined ? null : v);
          n.settle(inv, true, json === undefined ? 'null' : json);
        },
        function (e) {
          n.settle(inv, false, errorString(e));
        }
      );
  };

  function bytes(x) {
    if (x instanceof Uint8Array) return x;
    if (typeof x === 'string') return n.utf8Encode(x);
    if (x instanceof ArrayBuffer) return new Uint8Array(x);
    throw new TypeError('期望 Uint8Array 或字符串');
  }

  var encoding = Object.freeze({
    utf8Encode: function (s) { return n.utf8Encode(String(s)); },
    utf8Decode: function (b) { return n.utf8Decode(bytes(b)); },
    base64Encode: function (b) { return n.b64Encode(bytes(b)); },
    base64Decode: function (s) { return n.b64Decode(String(s)); },
    hexEncode: function (b) { return n.hexEncode(bytes(b)); },
    hexDecode: function (s) { return n.hexDecode(String(s)); }
  });

  var crypto = Object.freeze({
    md5: function (d) { return n.digest('md5', bytes(d)); },
    sha1: function (d) { return n.digest('sha1', bytes(d)); },
    sha256: function (d) { return n.digest('sha256', bytes(d)); },
    hmac: function (alg, key, data) { return n.hmac(String(alg), bytes(key), bytes(data)); },
    // opts: { mode: 'cbc' | 'ecb', key, iv?, data, decrypt?: boolean, padding?: 'pkcs7' | 'none' }
    aes: function (o) {
      return n.aes(
        String(o.mode),
        !!o.decrypt,
        bytes(o.key),
        o.iv === undefined ? new Uint8Array(0) : bytes(o.iv),
        bytes(o.data),
        o.padding === 'none' ? 'none' : 'pkcs7'
      );
    },
    // 无填充 RSA：data^e mod n，结果左补零到模长。modulus / exponent 为十六进制串。
    rsaRaw: function (o) { return n.rsaRaw(String(o.modulus), String(o.exponent), bytes(o.data)); },
    randomBytes: function (len) { return n.randomBytes(len | 0); }
  });

  // opts: { url, method?, headers?, body?: string, bodyBytes?: Uint8Array, timeoutMs?,
  //         responseType?: 'text' | 'json' | 'bytes' }
  function request(o) {
    if (!o || typeof o.url !== 'string') return Promise.reject(new TypeError('request 需要 url'));
    var args = {
      url: o.url,
      method: (o.method || 'GET').toUpperCase(),
      headers: o.headers || {},
      timeoutMs: o.timeoutMs || 0
    };
    if (o.bodyBytes !== undefined) args.bodyBase64 = n.b64Encode(bytes(o.bodyBytes));
    else if (o.body !== undefined) args.bodyBase64 = n.b64Encode(n.utf8Encode(String(o.body)));
    var type = o.responseType || 'text';
    return hostCall('http', args).then(function (r) {
      var raw = n.b64Decode(r.bodyBase64 || '');
      var out = {
        status: r.status, url: r.url, headers: r.headers || {},
        setCookies: Array.isArray(r.setCookies) ? r.setCookies.slice() : []
      };
      if (type === 'bytes') out.bytes = raw;
      else {
        out.text = n.utf8Decode(raw);
        if (type === 'json') out.json = JSON.parse(out.text);
      }
      return out;
    });
  }

  var storage = Object.freeze({
    get: function (k) { return hostCall('storage.get', { key: String(k) }); },
    set: function (k, v) { return hostCall('storage.set', { key: String(k), value: String(v) }); },
    remove: function (k) { return hostCall('storage.remove', { key: String(k) }); }
  });

  function fmt(args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      parts.push(typeof a === 'string' ? a : errorString(a));
    }
    return parts.join(' ');
  }
  function logger(level) {
    return function () { n.log(level, fmt(arguments)); };
  }

  var credentials = Object.freeze({
    get: function (k) { return hostCall('credentials.get', { key: String(k) }); },
    set: function (k, v) { return hostCall('credentials.set', { key: String(k), value: String(v) }); },
    remove: function (k) { return hostCall('credentials.remove', { key: String(k) }); }
  });

  globalThis.console = Object.freeze({
    log: logger('info'), info: logger('info'), debug: logger('debug'),
    warn: logger('warn'), error: logger('error')
  });

  globalThis.fushi = Object.freeze({
    host: Object.freeze({ api: n.apiVersion, name: 'fushi' }),
    http: Object.freeze({ request: request }),
    storage: storage,
    credentials: credentials,
    crypto: crypto,
    encoding: encoding,
    log: logger('info')
  });

  // CommonJS：只能 require 包内已校验的相对 .js 文件。
  var cache = Object.create(null);
  function resolvePath(from, spec) {
    if (spec.indexOf('./') !== 0 && spec.indexOf('../') !== 0) {
      throw new Error('只能 require 包内相对路径：' + spec);
    }
    var base = from.split('/');
    base.pop();
    var segs = spec.split('/');
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i];
      if (s === '.' || s === '') continue;
      if (s === '..') {
        if (base.length === 0) throw new Error('require 越出插件包：' + spec);
        base.pop();
      } else base.push(s);
    }
    var p = base.join('/');
    if (!/\.js$/.test(p)) p += '.js';
    return p;
  }
  function load(path) {
    if (cache[path]) return cache[path].exports;
    var fn = n.compile(path);
    if (!fn) throw new Error('插件包里没有 ' + path);
    var module = { exports: {} };
    cache[path] = module;
    fn(module, module.exports, function (spec) { return load(resolvePath(path, spec)); });
    return module.exports;
  }
  globalThis.__fushi_load_entry = function (entry) {
    globalThis.__fushi_exports = load(entry);
  };
})(globalThis.__n);
delete globalThis.__n;
