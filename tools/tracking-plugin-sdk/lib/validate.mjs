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
      keep = false;
    } else {
      const declared = this.manifest.tracking?.kinds ?? [];
      if (declared.length && !declared.includes(s.kind)) this.warn(path, `kind "${s.kind}" is not in manifest tracking.kinds [${declared.join(', ')}]`);
      if (kind && s.kind !== kind) this.warn(path, `kind "${s.kind}" differs from the requested kind "${kind}"`);
    }
    if (!keep) return false;
    this.textList(path, s.titles, 'titles', CAPS.titles);
    this.textList(path, s.authors, 'authors', CAPS.authors);
    for (const f of ['totalEpisodes', 'totalChapters', 'finalVolume']) this.count(path, s[f], f);
    if (s.finished !== undefined && s.finished !== null && typeof s.finished !== 'boolean') this.warn(path, 'finished must be a boolean — ignored');
    if (s.singleVolume !== undefined && s.singleVolume !== null && typeof s.singleVolume !== 'boolean') this.warn(path, 'singleVolume must be a boolean — ignored');
    if (s.singleVolume === true && s.kind !== 'manga' && s.kind !== 'novel') this.warn(path, 'singleVolume is only read for manga and novels — ignored');
    if (s.kind === 'game') for (const f of ['totalEpisodes', 'totalChapters', 'finalVolume', 'linkedIds']) if (s[f] !== undefined) this.warn(path, `${f} is ignored for a game`);
    if (s.linkedIds !== undefined && s.linkedIds !== null) {
      if (!isObj(s.linkedIds)) this.warn(path, 'linkedIds must be an object { idType: positive integer } — ignored');
      else {
        const good = [];
        for (const [k, v] of Object.entries(s.linkedIds)) {
          if (!posInt(v)) {
            this.warn(`${path}.linkedIds`, `${k}: ${JSON.stringify(v)} is not a positive integer — dropped`);
            continue;
          }
          if (!SITE_ID_PATTERN.test(k)) this.warn(`${path}.linkedIds`, `key "${k}" is not "mal" or a siteId ([a-z0-9]{2,32}); no site will ever look it up`);
          good.push(k);
        }
        if (good.length > CAPS.linkedIds) this.warn(`${path}.linkedIds`, `${good.length} ids; the host keeps at most ${CAPS.linkedIds}`);
        const own = this.manifest.tracking?.siteId;
        if (own && Object.hasOwn(s.linkedIds, own) && s.linkedIds[own] !== s.id) this.warn(`${path}.linkedIds`, `"${own}" is this site's own siteId but differs from id`);
      }
    }
    for (const k of Object.keys(s)) {
      if (!['id', 'name', 'kind', 'titles', 'authors', 'totalEpisodes', 'totalChapters', 'finalVolume', 'finished', 'singleVolume', 'linkedIds'].includes(k)) {
        this.warn(path, `unknown field "${k}" — ignored`);
      }
    }
    return true;
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
    if (!['pending', 'done', 'failed'].includes(c.state)) this.error(path, `state must be pending | done | failed (got ${JSON.stringify(c.state)})`);
    if (c.session !== undefined && c.session !== null && typeof c.session !== 'string') this.warn(path, 'session must be a string (opaque, passed back verbatim)');
    if (c.message !== undefined && c.message !== null && typeof c.message !== 'string') this.warn(path, 'message must be a string — ignored');
    if (c.qr !== undefined) this.warn(path, 'qr is not rendered by the tracking host (v1 renders form sign-in only)');
    if (c.web !== undefined) this.warn(path, 'web is not rendered by the tracking host (v1 renders form sign-in only)');
    if (c.pollMs !== undefined) this.warn(path, 'pollMs is unused: the tracking host never polls');
    this.appUrl(path, c.appUrl);
    if (c.state === 'pending') {
      if (!isObj(c.form)) this.error(path, 'a pending challenge needs a form (the tracking host renders nothing else)');
      else this.form(`${path}.form`, c.form);
    } else if (c.form !== undefined) this.warn(path, `form is ignored when state is ${c.state}`);
    if (c.state === 'done') {
      if (!isObj(c.account)) this.warn(path, 'state=done should carry account { loggedIn: true, name? }');
      else this.account(`${path}.account`, c.account);
    }
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

/// Warns about arguments the host would never send, so a local `run` does not test an impossible input.
export function validateArgs(method, args, manifest) {
  const w = [];
  const a = isObj(args) ? args : {};
  const kinds = manifest.tracking?.kinds ?? KNOWN_TRACKING_KINDS;
  const kindArg = (required) => {
    if (a.kind === undefined) {
      if (required) w.push(`args.kind is required (one of ${kinds.join(', ')})`);
    } else if (!kinds.includes(a.kind)) w.push(`args.kind ${JSON.stringify(a.kind)} is not in tracking.kinds [${kinds.join(', ')}]`);
  };
  const id = () => {
    if (!posInt(a.id)) w.push(`args.id must be a positive integer (got ${JSON.stringify(a.id)})`);
  };
  switch (method) {
    case 'trackingSubject':
      id();
      kindArg(false);
      break;
    case 'trackingSearch':
      if (typeof a.query !== 'string' || !a.query.trim()) w.push('args.query must be a non-empty string');
      kindArg(true);
      break;
    case 'trackingLookup':
      if (typeof a.idType !== 'string' || !SITE_ID_PATTERN.test(a.idType)) w.push('args.idType must be "mal" or another site\'s siteId');
      else if (a.idType === manifest.tracking?.siteId) w.push('args.idType is this site\'s own siteId; the host looks those up with trackingSubject');
      id();
      kindArg(false);
      break;
    case 'trackingEntry':
      if (a.op !== 'get' && a.op !== 'set') {
        w.push('args.op must be "get" or "set"');
        break;
      }
      id();
      kindArg(true);
      if (a.op === 'set') {
        if (typeof a.create !== 'boolean') w.push('args.create must be a boolean (true = the host saw no entry)');
        if (!ENTRY_STATUSES.includes(a.status)) w.push(`args.status must be one of ${ENTRY_STATUSES.join(', ')}`);
        for (const f of ['progress', 'progressVolume']) if (a[f] !== undefined && (!Number.isInteger(a[f]) || a[f] < 0)) w.push(`args.${f} must be a non-negative integer`);
        if (a.kind === 'game' && (a.progress !== undefined || a.progressVolume !== undefined)) w.push('a game write never carries progress (status only)');
      }
      break;
    case 'trackingList':
      kindArg(true);
      if (!ENTRY_STATUSES.includes(a.status)) w.push(`args.status must be one of ${ENTRY_STATUSES.join(', ')}`);
      if (!Number.isInteger(a.offset) || a.offset < 0) w.push('args.offset must be a non-negative integer (0 for the first page, then the previous "next")');
      break;
    case 'login':
      if (!['methods', 'begin', 'poll', 'submit', 'logout', 'import'].includes(a.op)) w.push('args.op must be methods | begin | submit | logout | import');
      else if (a.op === 'poll') w.push('the tracking host never calls poll (form sign-in only)');
      break;
  }
  return w;
}

/// Validates the return value of [method] called with [args].
export function validateResult(method, args, value, { manifest, policy }) {
  const r = new Report(manifest, policy);
  const p = method;
  switch (method) {
    case 'account':
      r.account(p, value);
      break;
    case 'login':
      if (args?.op === 'methods') {
        if (!isObj(value) || !Array.isArray(value.methods) || value.methods.length === 0) {
          r.error(p, 'methods must return { methods: [...] } with at least one method');
          break;
        }
        let forms = 0;
        value.methods.forEach((m, i) => {
          const mp = `${p}.methods[${i}]`;
          if (!isObj(m) || typeof m.id !== 'string' || !m.id || typeof m.label !== 'string' || !m.label) return r.warn(mp, 'needs string id, label and type — dropped');
          if (m.type === 'form') forms++;
          else r.warn(mp, `type ${JSON.stringify(m.type)} is not shown: the tracking host renders only "form" methods in v1`);
        });
        if (!forms) r.error(p, 'no "form" method: the user has no way to sign in from the tracking host');
      } else if (args?.op === 'logout') {
        if (value !== null && value !== undefined) r.warn(p, 'logout should return null — the value is ignored');
      } else if (args?.op === 'import') {
        if (!isObj(value) || value.state !== 'done') r.error(p, 'import must return { state: "done", account } (the host moves a saved sign-in, nothing to show)');
        else if (isObj(value.account)) r.account(`${p}.account`, value.account);
      } else r.challenge(p, value);
      break;
    case 'trackingSubject':
      if (value === null) break;
      if (!r.subject(p, value, { kind: args?.kind })) r.warn(p, 'the subject is dropped, so the host treats the answer as null (not found)');
      else if (posInt(args?.id) && value.id !== args.id) r.warn(p, `id ${value.id} differs from the requested id ${args.id}`);
      break;
    case 'trackingSearch':
      r.items(p, value, { max: CAPS.searchItems, kind: args?.kind });
      break;
    case 'trackingLookup':
      r.items(p, value, { max: CAPS.searchItems, kind: args?.kind });
      break;
    case 'trackingList':
      r.listPage(p, value, { kind: args?.kind, status: args?.status, offset: args?.offset });
      break;
    case 'trackingEntry':
      if (args?.op === 'set') {
        if (value !== null && value !== undefined) r.warn(p, 'set should return null — the value is ignored');
      } else if (value !== null) r.entry(p, value);
      break;
  }
  return r;
}
