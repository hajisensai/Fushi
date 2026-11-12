// Tracking-plugin manifest rules, mirrored from the Fushi plugin host so `check` / `run` / `pack` fail the
// same way the app does. Source of truth: native/fushi_music/src/plugin/manifest.rs (`validate_tracking`)
// and docs/specs/2026-11-10-tracking-plugins.md §2. The vocabulary lists, the requestsPerMinute bounds and
// the siteId pattern are pinned to manifest.rs by fushi/test/build/tracking_plugin_sdk_sync_guard_test.dart.
//
// Everything generic (API version, HTTP methods, package limits, path / id / domain checks, the network
// policy) comes from the music kit: both plugin kinds run in the same sandbox engine.
import {
  HOST_API_VERSION,
  KNOWN_METHODS,
  checkRelPath,
  validId,
  validateDomainRule,
} from '../../music-plugin-sdk/lib/rules.mjs';

export { HOST_API_VERSION, KNOWN_METHODS, LIMITS, Policy, isPrivateIp } from '../../music-plugin-sdk/lib/rules.mjs';

export const PLUGIN_KIND = 'tracking';

export const KNOWN_TRACKING_CAPABILITIES = [
  'login',
  'account',
  'trackingEntry',
  'trackingSubject',
  'trackingSearch',
  'trackingLookup',
  'trackingList',
];

export const REQUIRED_TRACKING_CAPABILITIES = ['login', 'account', 'trackingEntry', 'trackingSubject'];

export const KNOWN_TRACKING_PERMISSIONS = ['network', 'storage', 'credentials'];

export const REQUIRED_TRACKING_PERMISSIONS = ['network', 'credentials'];

export const KNOWN_TRACKING_KINDS = ['anime', 'manga', 'novel', 'game'];

export const KNOWN_TRACKING_MODES = ['episode', 'chapter', 'volume', 'status'];

/// manifest.rs `validate_tracking`: `(1..=600).contains(&t.requests_per_minute)`.
export const REQUESTS_PER_MINUTE_MIN = 1;
export const REQUESTS_PER_MINUTE_MAX = 600;

/// manifest.rs `valid_site_id`: 2..=32 bytes, ASCII lowercase letters and digits.
export const SITE_ID_MIN = 2;
export const SITE_ID_MAX = 32;

/// Site ids the engine reserves for the host's own id spaces (MyAnimeList); a plugin may not claim them.
export const RESERVED_SITE_IDS = ['mal'];

/// Site ids only the plugin bundled with the app may claim: the host registers a package claiming one
/// only when its digest equals the bundled package's (docs/specs/2026-11-11-bangumi-bundled-plugin.md §3).
export const HOST_PINNED_SITE_IDS = ['bangumi'];
export const SITE_ID_PATTERN = /^[a-z0-9]{2,32}$/;

/// Entry statuses (spec §3 `Entry.status`).
export const ENTRY_STATUSES = ['planned', 'current', 'completed', 'paused', 'dropped', 'repeating'];

/// Message prefixes the tracking host reads from a thrown Error (spec §3).
export const ERROR_PREFIXES = {
  'unauthorized:': 'unauthorized — the app marks the account as signed out and asks the user to sign in again',
  'rate_limited:': 'rate limited — the app stops this sync round and tries again later',
  'not_found:': 'not found — permanent for this item; the app stops asking about it',
};

const MANIFEST_FIELDS = new Set([
  'schema',
  'kind',
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
  'tracking',
]);

const TRACKING_FIELDS = new Set(['siteId', 'siteHost', 'kinds', 'defaultKinds', 'modes', 'requestsPerMinute', 'subjectUrl']);

/// manifest.rs `check_subject_url`: https, host = siteHost or a subdomain, `{id}` present, only `{id}` /
/// `{kind}` placeholders, at most 300 bytes, no whitespace. Returns the problem or null. Applied to the
/// single template and to each value of the per-kind object form.
export function subjectUrlProblem(url, siteHost) {
  if (typeof url !== 'string') return 'must be a string';
  if (Buffer.byteLength(url) > 300) return 'longer than 300 bytes';
  if (!url.startsWith('https://')) return 'must start with https://';
  const host = url.slice('https://'.length).split(/[/?#]/)[0];
  if (host !== siteHost && !host.endsWith(`.${siteHost}`)) return 'the host must be tracking.siteHost or a subdomain of it';
  if (!url.includes('{id}')) return 'missing {id}';
  const stripped = url.replaceAll('{id}', '').replaceAll('{kind}', '');
  if (/[{}]/.test(stripped) || host.includes('{')) return 'only {id} and {kind} placeholders, never in the host';
  if (/[\s\x00-\x08\x0e-\x1f\x7f]/.test(url)) return 'contains whitespace or control characters';
  return null;
}

/// Non-fatal notes from the last validateManifest call (e.g. a host-pinned siteId).
export const warnings = [];

/// Collects the problems of one validateManifest call.
class ManifestCheck {
  constructor() {
    this.errors = [];
  }
  fail(msg) {
    this.errors.push(msg);
  }
  /// `obj[k]` as a string array ([] when absent; reported and [] when not an array of strings).
  strings(obj, k, label = k) {
    if (obj[k] === undefined) return [];
    if (!Array.isArray(obj[k]) || obj[k].some((x) => typeof x !== 'string')) {
      this.fail(`"${label}" must be an array of strings`);
      return [];
    }
    return obj[k];
  }
  /// Every value is in [list] and none repeats.
  known(label, values, list) {
    for (const v of values) if (!list.includes(v)) this.fail(`unknown ${label} "${v}" (allowed: ${list.join(', ') || 'none'})`);
    if (new Set(values).size !== values.length) this.fail(`duplicate ${label}`);
  }
}

/// Returns a list of error strings (empty = valid). Mirrors Manifest::validate + validate_tracking in
/// manifest.rs (the host stops at the first error; this reports all of them, in this order).
export function validateManifest(m) {
  warnings.length = 0;
  if (m === null || typeof m !== 'object' || Array.isArray(m)) return ['manifest.json must be a JSON object'];
  const check = new ManifestCheck();
  checkFieldsAndKind(check, m);
  const caps = check.strings(m, 'capabilities');
  const perms = check.strings(m, 'permissions');
  const searchTypes = check.strings(m, 'searchTypes');
  const network = checkNetworkShape(check, m);
  checkIdentity(check, m);
  checkCapabilities(check, caps);
  checkPermissions(check, perms);
  if ((network.domains.length > 0) !== perms.includes('network')) check.fail('the "network" permission and a non-empty network.domains must be declared together');
  if (searchTypes.length > 0) check.fail('"searchTypes" must be absent or empty in a tracking plugin');
  checkTracking(check, m.tracking);
  checkNetworkRules(check, network);
  return check.errors;
}

function checkFieldsAndKind(check, m) {
  for (const k of Object.keys(m)) {
    if (!MANIFEST_FIELDS.has(k)) check.fail(`unknown manifest field "${k}" (unknown fields are rejected)`);
  }
  if (m.kind === undefined || m.kind === 'music') {
    check.fail('"kind" must be "tracking" (absent or "music" means a music plugin: build those with tools/music-plugin-sdk)');
  } else if (m.kind !== PLUGIN_KIND) {
    check.fail(`unknown plugin "kind" ${JSON.stringify(m.kind)} (a tracking plugin declares "kind": "tracking")`);
  }
  for (const k of ['schema', 'id', 'name', 'version', 'api', 'entry']) {
    if (m[k] === undefined) check.fail(`missing required field "${k}"`);
  }
  for (const k of ['author', 'description', 'homepage']) {
    if (m[k] !== undefined && m[k] !== null && typeof m[k] !== 'string') check.fail(`"${k}" must be a string`);
  }
}

/// Returns { domains, methods } (arrays, empty when absent or malformed).
function checkNetworkShape(check, m) {
  const network = m.network ?? {};
  if (typeof network !== 'object' || Array.isArray(network)) check.fail('"network" must be an object');
  for (const k of Object.keys(network)) {
    if (k !== 'domains' && k !== 'methods') check.fail(`unknown field network.${k}`);
  }
  return {
    domains: Array.isArray(network.domains) ? network.domains : [],
    methods: Array.isArray(network.methods) ? network.methods : [],
  };
}

function checkIdentity(check, m) {
  if (m.schema !== 1) check.fail('"schema" must be 1');
  if (!validId(m.id)) check.fail(`invalid "id" ${JSON.stringify(m.id)}: 2-64 chars of a-z 0-9 . _ -, starting and ending with a letter/digit, no ".."`);
  if (typeof m.name !== 'string' || m.name.trim() === '' || [...m.name].length > 64) check.fail('"name" must be 1-64 characters');
  if (typeof m.version !== 'string' || !/^\d{1,6}\.\d{1,6}\.\d{1,6}$/.test(m.version)) check.fail(`"version" must be X.Y.Z (got ${JSON.stringify(m.version)})`);
  if (!Number.isInteger(m.api) || m.api < 1 || m.api > HOST_API_VERSION) check.fail(`"api" must be 1..${HOST_API_VERSION}`);
  if (typeof m.entry === 'string') {
    try {
      checkRelPath(m.entry);
    } catch (e) {
      check.fail(`"entry": ${e.message}`);
    }
    if (!m.entry.endsWith('.js')) check.fail('"entry" must be a .js file');
  }
}

function checkCapabilities(check, caps) {
  check.known('capability', caps, KNOWN_TRACKING_CAPABILITIES);
  for (const c of REQUIRED_TRACKING_CAPABILITIES) {
    if (!caps.includes(c)) check.fail(`missing capability "${c}" (a tracking plugin must declare ${REQUIRED_TRACKING_CAPABILITIES.join(', ')})`);
  }
}

function checkPermissions(check, perms) {
  for (const p of perms) {
    if (p === 'webAuth') check.fail('"webAuth" is not available to tracking plugins (the tracking host renders form sign-in only)');
    else if (p === 'insecureHttp') check.fail('"insecureHttp" is not available to tracking plugins (https only)');
  }
  check.known('permission', perms.filter((p) => p !== 'webAuth' && p !== 'insecureHttp'), KNOWN_TRACKING_PERMISSIONS);
  for (const p of REQUIRED_TRACKING_PERMISSIONS) {
    if (!perms.includes(p)) check.fail(`missing permission "${p}" (a tracking plugin must declare ${REQUIRED_TRACKING_PERMISSIONS.join(', ')})`);
  }
}

function checkTracking(check, t) {
  if (t === undefined || t === null) return check.fail('missing "tracking" (siteId, siteHost, kinds, modes, requestsPerMinute)');
  if (typeof t !== 'object' || Array.isArray(t)) return check.fail('"tracking" must be an object');
  for (const k of Object.keys(t)) {
    if (!TRACKING_FIELDS.has(k)) check.fail(`unknown field tracking.${k} (unknown fields are rejected)`);
  }
  for (const k of ['siteId', 'siteHost', 'kinds', 'modes', 'requestsPerMinute']) {
    if (t[k] === undefined) check.fail(`missing required field tracking.${k}`);
  }
  checkSiteId(check, t.siteId);
  checkSiteHost(check, t.siteHost);
  const kinds = checkKindsAndModes(check, t);
  checkSubjectUrl(check, t, kinds);
  const rpm = t.requestsPerMinute;
  if (rpm !== undefined && (!Number.isInteger(rpm) || rpm < REQUESTS_PER_MINUTE_MIN || rpm > REQUESTS_PER_MINUTE_MAX)) {
    check.fail(`tracking.requestsPerMinute must be an integer ${REQUESTS_PER_MINUTE_MIN}-${REQUESTS_PER_MINUTE_MAX} (got ${JSON.stringify(rpm)})`);
  }
}

function checkSiteId(check, siteId) {
  if (siteId === undefined) return;
  if (typeof siteId !== 'string' || !SITE_ID_PATTERN.test(siteId)) {
    check.fail(`invalid tracking.siteId ${JSON.stringify(siteId)}: ${SITE_ID_MIN}-${SITE_ID_MAX} characters of a-z 0-9`);
  }
  if (typeof siteId !== 'string') return;
  if (RESERVED_SITE_IDS.includes(siteId)) {
    check.fail(`tracking.siteId ${JSON.stringify(siteId)} is reserved (${RESERVED_SITE_IDS.join(', ')} are the host's own id spaces): pick another id`);
  }
  if (HOST_PINNED_SITE_IDS.includes(siteId)) {
    warnings.push(`tracking.siteId ${JSON.stringify(siteId)} belongs to the plugin bundled with Fushi: the app registers only the bundled package for it, any other package is shown as "reserved site"`);
  }
}

function checkSiteHost(check, siteHost) {
  if (siteHost === undefined) return;
  if (typeof siteHost !== 'string') return check.fail('tracking.siteHost must be a string');
  if (siteHost.startsWith('*.')) return check.fail(`tracking.siteHost must not be a wildcard: ${JSON.stringify(siteHost)}`);
  try {
    validateDomainRule(siteHost);
  } catch {
    check.fail(`tracking.siteHost is not a plain lowercase host name (no scheme, path or port): ${JSON.stringify(siteHost)}`);
  }
}

/// Returns the declared kinds.
function checkKindsAndModes(check, t) {
  const kinds = check.strings(t, 'kinds', 'tracking.kinds');
  check.known('tracking.kinds value', kinds, KNOWN_TRACKING_KINDS);
  if (t.kinds !== undefined && kinds.length === 0) check.fail('tracking.kinds must not be empty');
  const defaultKinds = check.strings(t, 'defaultKinds', 'tracking.defaultKinds');
  for (const k of defaultKinds) if (!kinds.includes(k)) check.fail(`tracking.defaultKinds "${k}" is not in tracking.kinds (defaultKinds must be a subset of kinds)`);
  if (new Set(defaultKinds).size !== defaultKinds.length) check.fail('duplicate tracking.defaultKinds value');
  const modes = check.strings(t, 'modes', 'tracking.modes');
  check.known('tracking.modes value', modes, KNOWN_TRACKING_MODES);
  if (t.modes !== undefined && modes.length === 0) check.fail('tracking.modes must not be empty');
  if (kinds.includes('game') !== modes.includes('status')) check.fail('tracking.kinds "game" and tracking.modes "status" must be declared together');
  return kinds;
}

function checkSubjectUrl(check, t, kinds) {
  const su = t.subjectUrl;
  if (su === undefined) return;
  if (su === null || typeof su !== 'object' || Array.isArray(su)) {
    const why = subjectUrlProblem(su, t.siteHost);
    if (why) check.fail(`invalid tracking.subjectUrl ${JSON.stringify(su)}: ${why}`);
    return;
  }
  // Per-kind form: { "<kind>": "<template>" }; a kind left out has no page address.
  const entries = Object.entries(su);
  if (entries.length === 0) check.fail('tracking.subjectUrl must not be an empty object');
  for (const [kind, url] of entries) {
    if (!kinds.includes(kind)) check.fail(`tracking.subjectUrl kind "${kind}" is not in tracking.kinds`);
    const why = subjectUrlProblem(url, t.siteHost);
    if (why) check.fail(`invalid tracking.subjectUrl.${kind} ${JSON.stringify(url)}: ${why}`);
  }
}

function checkNetworkRules(check, { domains, methods }) {
  if (domains.length > 32) check.fail('network.domains has more than 32 entries');
  for (const d of domains) {
    if (typeof d !== 'string') {
      check.fail('network.domains entries must be strings');
      continue;
    }
    try {
      validateDomainRule(d);
    } catch (e) {
      check.fail(e.message);
    }
  }
  for (const x of methods) if (!KNOWN_METHODS.includes(x)) check.fail(`unknown HTTP method ${JSON.stringify(x)} (allowed: ${KNOWN_METHODS.join(', ')})`);
}

/// JS error type prefixes the host strips from the first line of a thrown error
/// (packages/fushi_music/lib/src/plugin/plugin_instance.dart `musicPluginErrorSummary`). Any other name
/// (a custom `class MyError extends Error`) stays in front of the message, so a prefix after it is not seen.
export const STRIPPED_ERROR_NAMES = ['Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError'];

/// How the tracking host classifies the error string the engine reports for a thrown value.
/// The engine reports `<Name>: <message>\n<stack>` for an Error and the raw text for a thrown string;
/// the host keeps the first line and strips a STRIPPED_ERROR_NAMES prefix, then reads ERROR_PREFIXES.
export function classifyError(raw) {
  const head = String(raw).split('\n')[0].trim();
  const nameMatch = /^([A-Za-z_$][\w$]*): /.exec(head);
  const stripped = nameMatch && STRIPPED_ERROR_NAMES.includes(nameMatch[1]);
  const message = stripped ? head.slice(nameMatch[0].length) : head;
  const errorName = nameMatch?.[1].endsWith('Error') ? nameMatch[1] : null;
  for (const [prefix, meaning] of Object.entries(ERROR_PREFIXES)) {
    if (message.startsWith(prefix)) return { kind: prefix.slice(0, -1), meaning, shown: message.slice(prefix.length).trim(), errorName, message };
  }
  return { kind: 'temporary', meaning: 'temporary — the app retries later', shown: message, errorName, message };
}
