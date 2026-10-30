// Host rules mirrored from the Fushi plugin host so `check` / `run` fail the same way the app does.
// Source of truth: native/fushi_music/src/plugin/{manifest,package,policy,runtime}.rs and
// packages/fushi_music/lib/src/plugin/. The capability / permission lists are pinned to manifest.rs by
// fushi/test/build/music_plugin_sdk_sync_guard_test.dart.
import net from 'node:net';

export const HOST_API_VERSION = 1;

export const KNOWN_CAPABILITIES = [
  'search',
  'album',
  'playlist',
  'artist',
  'stream',
  'lyrics',
  'login',
  'account',
  'home',
  'library',
  'artistAlbums',
  'artistMvs',
  'mvStream',
  'searchBest',
  'like',
];

export const KNOWN_PERMISSIONS = ['network', 'storage', 'credentials', 'webAuth', 'insecureHttp'];

export const KNOWN_SEARCH_TYPES = ['song', 'album', 'artist', 'playlist'];

export const KNOWN_METHODS = ['GET', 'POST', 'HEAD', 'PUT', 'DELETE', 'PATCH'];

export const LIMITS = {
  maxFiles: 128,
  maxFileBytes: 4 * 1024 * 1024,
  maxTotalBytes: 16 * 1024 * 1024,
  memoryBytes: 64 * 1024 * 1024,
  cpuBudgetMs: 2000,
  maxHeaders: 64,
  maxHeaderBytes: 8 * 1024,
  maxRequestBodyBytes: 4 * 1024 * 1024,
  maxResponseBytes: 8 * 1024 * 1024,
  maxResultBytes: 8 * 1024 * 1024,
  maxStorageKey: 256,
  maxStorageValue: 1024 * 1024,
  maxCredentialValue: 64 * 1024,
  httpTimeoutDefaultMs: 20000,
  httpTimeoutMinMs: 1000,
  httpTimeoutMaxMs: 60000,
  maxRedirects: 5,
};

/// Headers the player accepts on `stream` / `mvStream` results (lowercase).
export const MEDIA_HEADER_ALLOWLIST = [
  'user-agent',
  'referer',
  'origin',
  'cookie',
  'authorization',
  'accept',
  'accept-language',
];

/// Custom URL schemes a login challenge's `appUrl` may use besides https.
export const APP_URL_SCHEMES = ['orpheus', 'qqmusic', 'mqqapi', 'wtloginmqq', 'kugou', 'kuwo', 'migu', 'snssdk1128'];

const MANIFEST_FIELDS = [
  'schema',
  'id',
  'name',
  'version',
  'api',
  'entry',
  'author',
  'description',
  'homepage',
  'capabilities',
  'searchTypes',
  'permissions',
  'network',
];

export function checkRelPath(p) {
  const bad =
    typeof p !== 'string' ||
    p.length === 0 ||
    Buffer.byteLength(p) > 200 ||
    p.startsWith('/') ||
    p.includes('\\') ||
    p.includes(':') ||
    /[\u0000-\u001f\u007f-\u009f]/.test(p) ||
    p.split('/').some((s) => s === '' || s === '.' || s === '..');
  if (bad) throw new Error(`invalid package path ${JSON.stringify(p)} (use "/"-separated relative paths, no "." / ".." segments)`);
}

export function validId(id) {
  return (
    typeof id === 'string' &&
    id.length >= 2 &&
    id.length <= 64 &&
    /^[a-z0-9][a-z0-9._-]*[a-z0-9]$/.test(id) &&
    !id.includes('..')
  );
}

export function validateDomainRule(rule) {
  const host = rule.startsWith('*.') ? rule.slice(2) : rule;
  const ok =
    host.length > 0 &&
    host.length <= 253 &&
    host.includes('.') &&
    host.split('.').every((l) => l.length > 0 && l.length <= 63 && /^[a-z0-9-]+$/.test(l));
  if (!ok) throw new Error(`invalid network domain rule ${JSON.stringify(rule)} (lowercase host, or *.host)`);
}

/// Returns a list of error strings (empty = valid). Mirrors Manifest::validate in manifest.rs.
export function validateManifest(m) {
  const errors = [];
  const fail = (msg) => errors.push(msg);
  if (m === null || typeof m !== 'object' || Array.isArray(m)) return ['manifest.json must be a JSON object'];
  for (const k of Object.keys(m)) {
    if (!MANIFEST_FIELDS.includes(k)) fail(`unknown manifest field "${k}" (unknown fields are rejected)`);
  }
  for (const k of ['schema', 'id', 'name', 'version', 'api', 'entry']) {
    if (m[k] === undefined) fail(`missing required field "${k}"`);
  }
  for (const k of ['author', 'description', 'homepage']) {
    if (m[k] !== undefined && m[k] !== null && typeof m[k] !== 'string') fail(`"${k}" must be a string`);
  }
  const arr = (k) => {
    if (m[k] === undefined) return [];
    if (!Array.isArray(m[k]) || m[k].some((x) => typeof x !== 'string')) {
      fail(`"${k}" must be an array of strings`);
      return [];
    }
    return m[k];
  };
  const caps = arr('capabilities');
  const perms = arr('permissions');
  const searchTypes = arr('searchTypes');
  const network = m.network ?? {};
  if (typeof network !== 'object' || Array.isArray(network)) fail('"network" must be an object');
  for (const k of Object.keys(network)) {
    if (k !== 'domains' && k !== 'methods') fail(`unknown field network.${k}`);
  }
  const domains = Array.isArray(network.domains) ? network.domains : [];
  const methods = Array.isArray(network.methods) ? network.methods : [];

  if (m.schema !== 1) fail(`"schema" must be 1`);
  if (!validId(m.id)) fail(`invalid "id" ${JSON.stringify(m.id)}: 2-64 chars of a-z 0-9 . _ -, starting and ending with a letter/digit, no ".."`);
  if (typeof m.name !== 'string' || m.name.trim() === '' || [...m.name].length > 64) fail('"name" must be 1-64 characters');
  if (typeof m.version !== 'string' || !/^\d{1,6}\.\d{1,6}\.\d{1,6}$/.test(m.version)) fail(`"version" must be X.Y.Z (got ${JSON.stringify(m.version)})`);
  if (!Number.isInteger(m.api) || m.api < 1 || m.api > HOST_API_VERSION) fail(`"api" must be 1..${HOST_API_VERSION}`);
  if (typeof m.entry === 'string') {
    try {
      checkRelPath(m.entry);
    } catch (e) {
      fail(`"entry": ${e.message}`);
    }
    if (!m.entry.endsWith('.js')) fail('"entry" must be a .js file');
  }
  const known = (label, values, list) => {
    for (const v of values) if (!list.includes(v)) fail(`unknown ${label} "${v}" (allowed: ${list.join(', ')})`);
    if (new Set(values).size !== values.length) fail(`duplicate ${label}`);
  };
  known('capability', caps, KNOWN_CAPABILITIES);
  known('permission', perms, KNOWN_PERMISSIONS);
  known('search type', searchTypes, KNOWN_SEARCH_TYPES);
  const has = (c) => caps.includes(c);
  const perm = (p) => perms.includes(p);
  if (caps.length === 0) fail('declare at least one capability');
  if (has('search') && searchTypes.length === 0) fail('"search" needs a non-empty "searchTypes"');
  const wantsNetwork = domains.length > 0;
  if (wantsNetwork !== perm('network')) fail('the "network" permission and network.domains must be declared together');
  if (perm('insecureHttp') && !wantsNetwork) fail('"insecureHttp" needs the "network" permission');
  if (perm('webAuth') && !wantsNetwork) fail('"webAuth" needs the "network" permission (the login page must be in network.domains)');
  if ((has('login') || has('account')) && !perm('credentials')) fail('"login" / "account" need the "credentials" permission');
  if (has('login') !== has('account')) fail('"login" and "account" must be declared together');
  if (has('library') && !has('account')) fail('"library" needs "login" + "account"');
  if ((has('artistAlbums') || has('artistMvs')) && !has('artist')) fail('"artistAlbums" / "artistMvs" need "artist"');
  if (has('artistMvs') && !has('mvStream')) fail('"artistMvs" needs "mvStream"');
  if (has('searchBest') && !has('search')) fail('"searchBest" needs "search"');
  if (has('like') && !has('account')) fail('"like" needs "login" + "account"');
  if (domains.length > 32) fail('network.domains has more than 32 entries');
  for (const d of domains) {
    if (typeof d !== 'string') {
      fail('network.domains entries must be strings');
      continue;
    }
    try {
      validateDomainRule(d);
    } catch (e) {
      fail(e.message);
    }
  }
  for (const x of methods) if (!KNOWN_METHODS.includes(x)) fail(`unknown HTTP method ${JSON.stringify(x)} (allowed: ${KNOWN_METHODS.join(', ')})`);
  return errors;
}

function isPrivateV4(o) {
  return (
    o[0] === 0 ||
    o[0] === 10 ||
    o[0] === 127 ||
    (o[0] === 100 && (o[1] & 0xc0) === 64) ||
    (o[0] === 169 && o[1] === 254) ||
    (o[0] === 172 && (o[1] & 0xf0) === 16) ||
    (o[0] === 192 && o[1] === 168) ||
    (o[0] === 192 && o[1] === 0 && o[2] === 0) ||
    o[0] >= 224
  );
}

function v6Segments(ip) {
  let [head, tail] = ip.split('::');
  const parse = (s) => {
    if (!s) return [];
    const parts = s.split(':');
    const out = [];
    for (const p of parts) {
      if (p.includes('.')) {
        const o = p.split('.').map(Number);
        out.push((o[0] << 8) | o[1], (o[2] << 8) | o[3]);
      } else out.push(parseInt(p, 16));
    }
    return out;
  };
  const h = parse(head);
  const t = tail === undefined ? [] : parse(tail);
  const fill = tail === undefined ? [] : new Array(8 - h.length - t.length).fill(0);
  return [...h, ...fill, ...t];
}

/// Whether an IP is loopback / private / link-local / reserved (the host refuses those, including after DNS).
export function isPrivateIp(ip) {
  if (net.isIPv4(ip)) return isPrivateV4(ip.split('.').map(Number));
  if (!net.isIPv6(ip)) return false;
  const s = v6Segments(ip.replace(/%.*$/, ''));
  const embedded = (hi, lo) => isPrivateV4([hi >> 8, hi & 0xff, lo >> 8, lo & 0xff]);
  if (s.slice(0, 6).every((x) => x === 0)) return (s[6] === 0 && s[7] <= 1) || embedded(s[6], s[7]);
  if (s.slice(0, 5).every((x) => x === 0) && s[5] === 0xffff) return embedded(s[6], s[7]);
  if (s[0] === 0x64 && s[1] === 0xff9b) {
    if (s.slice(2, 6).every((x) => x === 0)) return embedded(s[6], s[7]);
    if (s[2] === 1) return true;
  }
  if (s[0] === 0x2002) return embedded(s[1], s[2]);
  return (
    (s[0] & 0xfe00) === 0xfc00 || (s[0] & 0xffc0) === 0xfe80 || (s[0] & 0xffc0) === 0xfec0 || (s[0] & 0xff00) === 0xff00
  );
}

function ruleMatches(rule, host) {
  if (rule.startsWith('*.')) {
    const suffix = rule.slice(2);
    return host.length > suffix.length + 1 && host.endsWith('.' + suffix);
  }
  return rule === host;
}

/// Network policy built from a manifest (mirrors policy.rs).
export class Policy {
  constructor(manifest) {
    this.rules = manifest.network?.domains ?? [];
    this.methods = manifest.network?.methods?.length ? manifest.network.methods : ['GET'];
    this.insecureHttp = (manifest.permissions ?? []).includes('insecureHttp');
  }

  checkMethod(method) {
    if (!this.methods.includes(method)) throw new Error(`HTTP method ${method} is not in network.methods (${this.methods.join(', ')})`);
  }

  /// Returns the normalized URL or throws with the reason the host would give.
  checkUrl(raw) {
    let url;
    try {
      url = new URL(raw);
    } catch {
      throw new Error(`invalid URL ${JSON.stringify(raw)}`);
    }
    if (url.protocol === 'http:') {
      if (!this.insecureHttp) throw new Error(`http:// needs the "insecureHttp" permission: ${raw}`);
    } else if (url.protocol !== 'https:') throw new Error(`scheme ${url.protocol} is not allowed: ${raw}`);
    if (url.username || url.password) throw new Error('URLs must not carry a username / password');
    const host = url.hostname.toLowerCase();
    const bare = host.replace(/^\[|\]$/g, '');
    if (net.isIP(bare)) {
      if (isPrivateIp(bare)) throw new Error(`local / private address ${bare} is not allowed`);
      throw new Error(`IP literals are not allowed (${bare}); use a host name listed in network.domains`);
    }
    if (host === 'localhost' || host.endsWith('.localhost')) throw new Error('localhost is not allowed');
    if (!this.rules.some((r) => ruleMatches(r, host))) {
      throw new Error(`host ${host} is not covered by network.domains [${this.rules.join(', ')}]`);
    }
    return url.toString();
  }
}
