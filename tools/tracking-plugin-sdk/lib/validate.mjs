// Checks a tracking capability's arguments and return value against docs/specs/2026-11-10-tracking-plugins.md
// §3 (functions and entities) and §4 ("untrusted results").
//
// errors   = the host cannot use the result at all (the call fails for the user).
// warnings = the host silently drops, caps or ignores something, or would never send these arguments.
import { ENTRY_STATUSES, KNOWN_TRACKING_KINDS, SITE_ID_PATTERN } from './rules.mjs';

/// §4 caps.
export const CAPS = {
  textChars: 500,
  titles: 50,
  authors: 20,
  linkedIds: 16,
  searchItems: 20,
  listPages: 40,
  listItems: 2000,
};

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const posInt = (v) => Number.isInteger(v) && v > 0;
const codePoints = (s) => [...s].length;
const present = (v) => v !== undefined && v !== null;

const SUBJECT_FIELDS = new Set(['id', 'name', 'kind', 'titles', 'authors', 'totalEpisodes', 'totalChapters', 'finalVolume', 'finished', 'singleVolume', 'linkedIds']);
const COUNT_FIELDS = ['totalEpisodes', 'totalChapters', 'finalVolume'];
const GAME_IGNORED_FIELDS = ['totalEpisodes', 'totalChapters', 'finalVolume', 'linkedIds'];
const LOGIN_OPS = new Set(['methods', 'begin', 'poll', 'submit', 'logout', 'import']);
const CHALLENGE_STATES = new Set(['pending', 'done', 'failed']);

class Report {
  constructor(manifest, policy) {
    this.manifest = manifest;
    this.policy = policy;
    this.errors = [];
    this.warnings = [];
  }
  error(path, msg) {
    this.errors.push(`${path}: ${msg}`);
  }
  warn(path, msg) {
    this.warnings.push(`${path}: ${msg}`);
  }

  /// A trimmed, capped string; returns whether it survives.
  text(path, v, field, { required = false } = {}) {
    if (v === undefined || v === null) {
      if (required) this.warn(path, `missing ${field}`);
      return false;
    }
    if (typeof v !== 'string') {
      this.warn(path, `${field} must be a string (got ${JSON.stringify(v)}) — ${required ? 'missing' : 'ignored'}`);
      return false;
    }
    const t = v.trim();
    if (t === '') {
      this.warn(path, `${field} is empty after trimming — ${required ? 'missing' : 'ignored'}`);
      return false;
    }
    if (codePoints(t) > CAPS.textChars) this.warn(path, `${field} is ${codePoints(t)} characters; the host cuts it to ${CAPS.textChars}`);
    return true;
  }

  textList(path, v, field, max) {
    if (v === undefined || v === null) return;
    if (!Array.isArray(v)) return this.warn(path, `${field} must be an array of strings — ignored`);
    v.forEach((x, i) => this.text(path, x, `${field}[${i}]`));
    if (v.length > max) this.warn(path, `${field} has ${v.length} entries; the host keeps the first ${max}`);
  }

  count(path, v, field) {
    if (v === undefined || v === null) return;
    if (!Number.isInteger(v) || v < 0) this.warn(path, `${field} must be a non-negative integer (got ${JSON.stringify(v)}) — treated as missing`);
  }

  /// Returns whether the subject survives the host's checks.
  subject(path, s, { kind } = {}) {
    if (!isObj(s)) {
      this.warn(path, 'not an object — dropped');
      return false;
    }
    if (!this.subjectRequired(path, s, kind)) return false;
    this.textList(path, s.titles, 'titles', CAPS.titles);
    this.textList(path, s.authors, 'authors', CAPS.authors);
    for (const f of COUNT_FIELDS) this.count(path, s[f], f);
    this.subjectFlags(path, s);
    if (s.kind === 'game') for (const f of GAME_IGNORED_FIELDS) if (s[f] !== undefined) this.warn(path, `${f} is ignored for a game`);
    if (present(s.linkedIds)) this.linkedIds(path, s);
    for (const k of Object.keys(s)) {
      if (!SUBJECT_FIELDS.has(k)) this.warn(path, `unknown field "${k}" — ignored`);
    }
    return true;
  }

  /// id, name and kind: without any of them the host drops the subject. Reports every problem.
  subjectRequired(path, s, kind) {
    let keep = true;
    if (!posInt(s.id)) {
      const hint = typeof s.id === 'string' && /^\d+$/.test(s.id) ? ' (it is a string: use Number(x))' : '';
      this.warn(path, `id must be a positive integer (got ${JSON.stringify(s.id)})${hint} — dropped`);
      keep = false;
    }
    if (!this.text(path, s.name, 'name', { required: true })) {
      this.warn(path, 'a subject without a name is dropped');
      keep = false;
    }
    if (!KNOWN_TRACKING_KINDS.includes(s.kind)) {
      this.warn(path, `kind must be one of ${KNOWN_TRACKING_KINDS.join(', ')} (got ${JSON.stringify(s.kind)}) — dropped`);
      return false;
    }
    const declared = this.manifest.tracking?.kinds ?? [];
    if (declared.length && !declared.includes(s.kind)) this.warn(path, `kind "${s.kind}" is not in manifest tracking.kinds [${declared.join(', ')}]`);
    if (kind && s.kind !== kind) this.warn(path, `kind "${s.kind}" differs from the requested kind "${kind}"`);
    return keep;
  }

  subjectFlags(path, s) {
    if (present(s.finished) && typeof s.finished !== 'boolean') this.warn(path, 'finished must be a boolean — ignored');
    if (present(s.singleVolume) && typeof s.singleVolume !== 'boolean') this.warn(path, 'singleVolume must be a boolean — ignored');
    if (s.singleVolume === true && s.kind !== 'manga' && s.kind !== 'novel') this.warn(path, 'singleVolume is only read for manga and novels — ignored');
  }

  linkedIds(path, s) {
    if (!isObj(s.linkedIds)) return this.warn(path, 'linkedIds must be an object { idType: positive integer } — ignored');
    const p = `${path}.linkedIds`;
    const good = [];
    for (const [k, v] of Object.entries(s.linkedIds)) {
      if (!posInt(v)) {
        this.warn(p, `${k}: ${JSON.stringify(v)} is not a positive integer — dropped`);
        continue;
      }
      if (!SITE_ID_PATTERN.test(k)) this.warn(p, `key "${k}" is not "mal" or a siteId ([a-z0-9]{2,32}); no site will ever look it up`);
      good.push(k);
    }
    if (good.length > CAPS.linkedIds) this.warn(p, `${good.length} ids; the host keeps at most ${CAPS.linkedIds}`);
    const own = this.manifest.tracking?.siteId;
    if (own && Object.hasOwn(s.linkedIds, own) && s.linkedIds[own] !== s.id) this.warn(p, `"${own}" is this site's own siteId but differs from id`);
  }

  items(path, v, { max, kind } = {}) {
    if (!isObj(v)) return this.error(path, 'must return an object { items: Subject[] }');
    if (!Array.isArray(v.items)) return this.error(path, 'missing "items" array');
    if (max && v.items.length > max) this.warn(path, `${v.items.length} items; the host uses the first ${max}`);
    const used = max ? v.items.slice(0, max) : v.items;
    used.forEach((s, i) => this.subject(`${path}.items[${i}]`, s, { kind }));
  }

  entry(path, e) {
    if (!isObj(e)) return this.error(path, 'must return an Entry object or null (not on the list)');
    if (!ENTRY_STATUSES.includes(e.status)) this.error(path, `status must be one of ${ENTRY_STATUSES.join(', ')} (got ${JSON.stringify(e.status)}) — the host cannot read this entry and leaves it alone (nothing is written)`);
    if (e.progress === undefined || e.progress === null) this.warn(path, 'progress is missing — the host cannot read this entry and leaves it alone (nothing is written); return 0 if the site has no chapter counts');
    else if (!Number.isInteger(e.progress) || e.progress < 0) this.warn(path, `progress must be a non-negative integer (got ${JSON.stringify(e.progress)}) — the host cannot read this entry and leaves it alone (nothing is written)`);
    this.count(path, e.progressVolume, 'progressVolume');
    for (const k of Object.keys(e)) if (!['status', 'progress', 'progressVolume'].includes(k)) this.warn(path, `unknown field "${k}" — ignored`);
  }

  /// trackingList page: { items: ListItem[], next? }.
  listPage(path, v, { kind, status, offset } = {}) {
    if (!isObj(v)) return this.error(path, 'must return an object { items: ListItem[], next?: number }');
    if (!Array.isArray(v.items)) return this.error(path, 'missing "items" array');
    v.items.forEach((it, i) => {
      const p = `${path}.items[${i}]`;
      if (!isObj(it)) return this.warn(p, 'not an object — dropped');
      if (!this.subject(`${p}.subject`, it.subject, { kind })) this.warn(p, 'the subject is dropped, so the item is dropped');
      if (!ENTRY_STATUSES.includes(it.status)) this.warn(p, `status must be one of ${ENTRY_STATUSES.join(', ')} — dropped`);
      else if (status && it.status !== status) this.warn(p, `status "${it.status}" differs from the requested "${status}"`);
      if (!Number.isInteger(it.progress) || it.progress < 0) this.warn(p, `progress must be a non-negative integer (got ${JSON.stringify(it.progress)}) — dropped`);
      this.count(p, it.progressVolume, 'progressVolume');
      if (it.updatedAt !== undefined && (typeof it.updatedAt !== 'string' || Number.isNaN(Date.parse(it.updatedAt)))) this.warn(p, 'updatedAt must be an ISO 8601 string — ignored');
      for (const k of Object.keys(it)) if (!['subject', 'status', 'progress', 'progressVolume', 'updatedAt'].includes(k)) this.warn(p, `unknown field "${k}" — ignored`);
    });
    if (v.next !== undefined && v.next !== null) {
      if (!Number.isInteger(v.next) || v.next < 0) this.warn(path, 'next must be a non-negative integer — treated as the last page');
      else if (Number.isInteger(offset) && v.next <= offset) this.warn(path, `next ${v.next} is not past offset ${offset}: the host stops here`);
    }
  }

  /// https inside the network grant, shown as "Open site". No app schemes for tracking plugins.
  appUrl(path, v) {
    if (v === undefined || v === null) return;
    if (typeof v !== 'string' || !v.startsWith('https://')) return this.warn(path, `appUrl must be an https:// link (got ${JSON.stringify(v)}) — dropped`);
    try {
      this.policy.checkUrl(v);
    } catch (e) {
      this.warn(path, `appUrl is outside the network grant — dropped: ${e.message}`);
    }
  }

  challenge(path, c) {
    if (!isObj(c)) return this.error(path, 'login must return a Challenge object');
    if (!CHALLENGE_STATES.has(c.state)) this.error(path, `state must be pending | done | failed (got ${JSON.stringify(c.state)})`);
    this.challengeExtras(path, c);
    this.appUrl(path, c.appUrl);
    if (c.state === 'pending') {
      if (isObj(c.form)) this.form(`${path}.form`, c.form);
      else this.error(path, 'a pending challenge needs a form (the tracking host renders nothing else)');
    } else if (c.form !== undefined) this.warn(path, `form is ignored when state is ${c.state}`);
    if (c.state === 'done') {
      if (isObj(c.account)) this.account(`${path}.account`, c.account);
      else this.warn(path, 'state=done should carry account { loggedIn: true, name? }');
    }
  }

  /// Optional challenge fields the tracking host reads loosely or not at all.
  challengeExtras(path, c) {
    if (present(c.session) && typeof c.session !== 'string') this.warn(path, 'session must be a string (opaque, passed back verbatim)');
    if (present(c.message) && typeof c.message !== 'string') this.warn(path, 'message must be a string — ignored');
    if (c.qr !== undefined) this.warn(path, 'qr is not rendered by the tracking host (v1 renders form sign-in only)');
    if (c.web !== undefined) this.warn(path, 'web is not rendered by the tracking host (v1 renders form sign-in only)');
    if (c.pollMs !== undefined) this.warn(path, 'pollMs is unused: the tracking host never polls');
  }

  form(path, f) {
    if (!Array.isArray(f.fields) || f.fields.length === 0) this.error(path, 'fields must be a non-empty array');
    else {
      const ids = new Set();
      f.fields.forEach((x, i) => {
        const p = `${path}.fields[${i}]`;
        if (!isObj(x) || typeof x.id !== 'string' || !x.id || typeof x.label !== 'string' || !x.label) return this.warn(p, 'needs string id and label — dropped');
        if (ids.has(x.id)) this.warn(p, `duplicate field id "${x.id}"`);
        ids.add(x.id);
        for (const b of ['secret', 'multiline']) if (x[b] !== undefined && typeof x[b] !== 'boolean') this.warn(p, `${b} must be a boolean`);
        if (x.value !== undefined && typeof x.value !== 'string') this.warn(p, 'value must be a string');
      });
    }
    if (!Array.isArray(f.actions) || f.actions.length === 0) this.error(path, 'actions must be a non-empty array (the user needs a button)');
    else
      f.actions.forEach((a, i) => {
        if (!isObj(a) || typeof a.id !== 'string' || !a.id || typeof a.label !== 'string' || !a.label) this.warn(`${path}.actions[${i}]`, 'needs string id and label — dropped');
      });
  }

  account(path, a) {
    if (!isObj(a)) return this.error(path, 'must return { loggedIn, name? }');
    if (typeof a.loggedIn !== 'boolean') this.warn(path, 'loggedIn must be a boolean (anything but true = signed out)');
    if (a.name !== undefined && a.name !== null) this.text(path, a.name, 'name');
    for (const k of Object.keys(a)) if (!['loggedIn', 'name'].includes(k)) this.warn(path, `extra field "${k}" is ignored: the host reads only loggedIn and name`);
  }
}

/// Collects warnings about one call's arguments.
class ArgCheck {
  constructor(args, manifest) {
    this.a = isObj(args) ? args : {};
    this.manifest = manifest;
    this.kinds = manifest.tracking?.kinds ?? KNOWN_TRACKING_KINDS;
    this.w = [];
  }
  kind(required) {
    const { a, kinds } = this;
    if (a.kind === undefined) {
      if (required) this.w.push(`args.kind is required (one of ${kinds.join(', ')})`);
    } else if (!kinds.includes(a.kind)) this.w.push(`args.kind ${JSON.stringify(a.kind)} is not in tracking.kinds [${kinds.join(', ')}]`);
  }
  id() {
    if (!posInt(this.a.id)) this.w.push(`args.id must be a positive integer (got ${JSON.stringify(this.a.id)})`);
  }
  status() {
    if (!ENTRY_STATUSES.includes(this.a.status)) this.w.push(`args.status must be one of ${ENTRY_STATUSES.join(', ')}`);
  }
}

/// Per-capability argument checks (what the host sends, spec §3).
const ARG_CHECKS = {
  trackingSubject(c) {
    c.id();
    c.kind(false);
  },
  trackingSearch(c) {
    if (typeof c.a.query !== 'string' || !c.a.query.trim()) c.w.push('args.query must be a non-empty string');
    c.kind(true);
  },
  trackingLookup(c) {
    const { a } = c;
    if (typeof a.idType !== 'string' || !SITE_ID_PATTERN.test(a.idType)) c.w.push('args.idType must be "mal" or another site\'s siteId');
    else if (a.idType === c.manifest.tracking?.siteId) c.w.push('args.idType is this site\'s own siteId; the host looks those up with trackingSubject');
    c.id();
    c.kind(false);
  },
  trackingEntry(c) {
    const { a } = c;
    if (a.op !== 'get' && a.op !== 'set') {
      c.w.push('args.op must be "get" or "set"');
      return;
    }
    c.id();
    c.kind(true);
    if (a.op === 'set') entrySetArgs(c);
  },
  trackingList(c) {
    c.kind(true);
    c.status();
    if (!Number.isInteger(c.a.offset) || c.a.offset < 0) c.w.push('args.offset must be a non-negative integer (0 for the first page, then the previous "next")');
  },
  login(c) {
    if (!LOGIN_OPS.has(c.a.op)) c.w.push('args.op must be methods | begin | submit | logout | import');
    else if (c.a.op === 'poll') c.w.push('the tracking host never calls poll (form sign-in only)');
  },
};

function entrySetArgs(c) {
  const { a } = c;
  if (typeof a.create !== 'boolean') c.w.push('args.create must be a boolean (true = the host saw no entry)');
  c.status();
  for (const f of ['progress', 'progressVolume']) if (a[f] !== undefined && (!Number.isInteger(a[f]) || a[f] < 0)) c.w.push(`args.${f} must be a non-negative integer`);
  if (a.kind === 'game' && (a.progress !== undefined || a.progressVolume !== undefined)) c.w.push('a game write never carries progress (status only)');
}

/// Warns about arguments the host would never send, so a local `run` does not test an impossible input.
export function validateArgs(method, args, manifest) {
  const c = new ArgCheck(args, manifest);
  if (Object.hasOwn(ARG_CHECKS, method)) ARG_CHECKS[method](c);
  return c.w;
}

function loginMethodsResult(r, p, value) {
  if (!isObj(value) || !Array.isArray(value.methods) || value.methods.length === 0) {
    return r.error(p, 'methods must return { methods: [...] } with at least one method');
  }
  let forms = 0;
  value.methods.forEach((m, i) => {
    const mp = `${p}.methods[${i}]`;
    if (!isObj(m) || typeof m.id !== 'string' || !m.id || typeof m.label !== 'string' || !m.label) return r.warn(mp, 'needs string id, label and type — dropped');
    if (m.type === 'form') forms++;
    else r.warn(mp, `type ${JSON.stringify(m.type)} is not shown: the tracking host renders only "form" methods in v1`);
  });
  if (!forms) r.error(p, 'no "form" method: the user has no way to sign in from the tracking host');
}

function loginResult(r, p, args, value) {
  switch (args?.op) {
    case 'methods':
      return loginMethodsResult(r, p, value);
    case 'logout':
      if (present(value)) r.warn(p, 'logout should return null — the value is ignored');
      return;
    case 'import':
      if (!isObj(value) || value.state !== 'done') r.error(p, 'import must return { state: "done", account } (the host moves a saved sign-in, nothing to show)');
      else if (isObj(value.account)) r.account(`${p}.account`, value.account);
      return;
    default:
      r.challenge(p, value);
  }
}

/// Per-capability result checks: (report, path, args, value).
const RESULT_CHECKS = {
  account: (r, p, _args, value) => r.account(p, value),
  login: loginResult,
  trackingSubject(r, p, args, value) {
    if (value === null) return;
    if (!r.subject(p, value, { kind: args?.kind })) r.warn(p, 'the subject is dropped, so the host treats the answer as null (not found)');
    else if (posInt(args?.id) && value.id !== args.id) r.warn(p, `id ${value.id} differs from the requested id ${args.id}`);
  },
  trackingSearch: (r, p, args, value) => r.items(p, value, { max: CAPS.searchItems, kind: args?.kind }),
  trackingLookup: (r, p, args, value) => r.items(p, value, { max: CAPS.searchItems, kind: args?.kind }),
  trackingList: (r, p, args, value) => r.listPage(p, value, { kind: args?.kind, status: args?.status, offset: args?.offset }),
  trackingEntry(r, p, args, value) {
    if (args?.op === 'set') {
      if (present(value)) r.warn(p, 'set should return null — the value is ignored');
    } else if (value !== null) r.entry(p, value);
  },
};

/// Validates the return value of [method] called with [args].
export function validateResult(method, args, value, { manifest, policy }) {
  const r = new Report(manifest, policy);
  if (Object.hasOwn(RESULT_CHECKS, method)) RESULT_CHECKS[method](r, method, args, value);
  return r;
}
