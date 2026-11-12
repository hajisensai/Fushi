/// <reference path="../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// Fushi's bundled Bangumi tracking plugin (https://bgm.tv), a port of the former built-in Bangumi provider
// (`bangumi_tracking_provider.dart` + `bangumi_api_client.dart`). Shipped inside the app and installed on
// first start; plan: docs/specs/2026-11-11-bangumi-bundled-plugin.md. Contract:
// tools/tracking-plugin-sdk/GUIDE.md. Tests: test/*.test.mjs (fixtures, no network).
'use strict';

const { api, toSubject, int, str, TYPE_OF_KIND, STATUS_TO_TYPE, TYPE_TO_STATUS } = require('./bangumi');

/** Where a signed-in Bangumi user creates an access token. */
const TOKEN_PAGE = 'https://next.bgm.tv/demo/access-token';

/** Main-episode page size (the API allows up to 200). */
const EPISODE_PAGE = 200;

/** Collection page size for trackingList. */
const LIST_PAGE = 50;

/** @returns {Promise<string | null>} */
async function savedToken() {
  const t = await fushi.credentials.get('token');
  return t && t.trim() ? t.trim() : null;
}

/** @returns {Promise<string>} the saved token; throws unauthorized: when signed out. */
async function requireToken() {
  const token = await savedToken();
  if (!token) throw new Error('unauthorized: Sign in to Bangumi first.');
  return token;
}

/**
 * The signed-in user's name for the collection URLs: saved at sign-in; a sign-in moved from an older Fushi
 * has none yet, so it is read once from /v0/me.
 * @param {string} token
 */
async function username(token) {
  const saved = await fushi.credentials.get('username');
  if (saved) return saved;
  const { json } = await api('GET', '/v0/me', { token });
  const name = str(json?.username);
  if (!name) throw new Error('Bangumi did not return the account name.');
  await fushi.credentials.set('username', name);
  return name;
}

// ---------- account / login ----------

/** @type {FushiTracking.Plugin['account']} */
async function account() {
  if (!(await savedToken())) return { loggedIn: false };
  const name = await fushi.credentials.get('name');
  return name ? { loggedIn: true, name } : { loggedIn: true };
}

const HELP =
  'Sign in on Bangumi, create an access token on the token page, and paste it here. ' +
  'No Bangumi account yet? Create one at bgm.tv/signup first.';

/** @param {string} message @returns {FushiTracking.Challenge} */
function tokenForm(message) {
  return {
    state: 'pending',
    message,
    appUrl: TOKEN_PAGE,
    form: {
      fields: [{ id: 'token', label: 'Bangumi access token', secret: true }],
      actions: [{ id: 'save', label: 'Sign in', primary: true }],
    },
  };
}

/** @param {string} token @param {string} user @param {string} name */
async function store(token, user, name) {
  await fushi.credentials.set('token', token);
  if (user) await fushi.credentials.set('username', user);
  else await fushi.credentials.remove('username');
  if (name) await fushi.credentials.set('name', name);
  else await fushi.credentials.remove('name');
  return { state: /** @type {'done'} */ ('done'), account: name ? { loggedIn: true, name } : { loggedIn: true } };
}

/** @type {FushiTracking.Plugin['login']} */
async function login(args) {
  switch (args.op) {
    case 'methods':
      return { methods: [{ id: 'token', type: 'form', label: 'Sign in with an access token' }] };
    case 'begin':
      return tokenForm(HELP);
    case 'submit': {
      const token = (args.inputs?.token ?? '').trim();
      if (!token) return tokenForm(`Paste the token first. ${HELP}`);
      /** @type {any} */
      let me;
      try {
        me = (await api('GET', '/v0/me', { token })).json;
      } catch (e) {
        const msg = /** @type {Error} */ (e).message;
        if (msg.startsWith('unauthorized:')) return tokenForm(`Bangumi did not accept that token. Copy it again. ${HELP}`);
        if (msg.startsWith('rate_limited:')) return tokenForm('Bangumi is busy right now. Try again in a minute.');
        return tokenForm(`Could not reach Bangumi (${msg}). Try again.`);
      }
      const user = str(me?.username);
      if (!user) return tokenForm(`Bangumi did not accept that token. Copy it again. ${HELP}`);
      return store(token, user, str(me?.nickname) || user);
    }
    case 'import': {
      // The host moves a token saved by Fushi's former built-in Bangumi: stored without a network check.
      const token = (args.inputs?.token ?? '').trim();
      if (!token) throw new Error('Nothing to import.');
      return store(token, '', (args.inputs?.name ?? '').trim());
    }
    case 'logout':
      for (const k of ['token', 'username', 'name']) await fushi.credentials.remove(k);
      return null;
    default:
      throw new Error('Unsupported sign-in step.');
  }
}

// ---------- subjects ----------

/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id, kind }) {
  /** @type {any} */
  let json;
  try {
    json = (await api('GET', `/v0/subjects/${id}`, { token: await savedToken() })).json;
  } catch (e) {
    if (/** @type {Error} */ (e).message.startsWith('not_found:')) return null;
    throw e;
  }
  // Wrong-kind guard (built-in `subjectById`): a subject of another Bangumi type is "not this".
  if (kind && int(json?.type) !== TYPE_OF_KIND[kind]) return null;
  return toSubject(json, kind);
}

/** @type {FushiTracking.Plugin['trackingSearch']} */
async function trackingSearch({ query, kind }) {
  const keyword = (query ?? '').trim();
  if (!keyword) return { items: [] };
  const { json } = await api('POST', '/v0/search/subjects?limit=20&offset=0', {
    token: await savedToken(),
    body: { keyword, sort: 'match', filter: { type: [TYPE_OF_KIND[kind]] } },
  });
  const data = Array.isArray(json?.data) ? json.data : [];
  /** @type {FushiTracking.Subject[]} */
  const items = [];
  for (const s of data) {
    if (int(s?.type) !== TYPE_OF_KIND[kind]) continue;
    const subject = toSubject(s, kind);
    if (subject) items.push(subject);
  }
  return { items: items.slice(0, 20) };
}

// ---------- the user's collection entry ----------

/**
 * The collection entry, or null when the subject is not collected.
 * @param {number} id @param {string} token
 */
async function collection(id, token) {
  const user = await username(token);
  const { status, json } = await api('GET', `/v0/users/${encodeURIComponent(user)}/collections/${id}`, {
    token,
    ok: [200, 404],
  });
  return status === 404 ? null : json;
}

/** @type {FushiTracking.Plugin['trackingEntry']} */
async function trackingEntry(args) {
  const token = await requireToken();
  if (args.op === 'get') {
    const c = await collection(args.id, token);
    if (!c) return null;
    const status = TYPE_TO_STATUS[int(c.type)];
    // An unknown collection type is sent as is: the host then leaves the entry alone.
    /** @type {any} */
    const entry = { status: status ?? `type ${c.type}`, progress: int(c.ep_status) };
    if (args.kind !== 'anime' && args.kind !== 'game') entry.progressVolume = int(c.vol_status);
    return entry;
  }
  const type = STATUS_TO_TYPE[args.status];
  if (!type) throw new Error(`not_found: unknown status ${args.status}.`);
  if (args.kind === 'game') {
    await write(args.id, args.create, { type }, token);
  } else if (args.kind === 'anime') {
    await setAnime(args, type, token);
  } else {
    /** @type {{[k: string]: number}} */
    const payload = { type };
    if (args.progress !== undefined) payload.ep_status = args.progress;
    if (args.progressVolume !== undefined) payload.vol_status = args.progressVolume;
    await write(args.id, args.create, payload, token);
  }
  return null;
}

/**
 * Creates (POST) or changes (PATCH) the collection entry. `create: false` on a vanished entry is a 404 from
 * the PATCH, thrown as not_found: (spec §3).
 * @param {number} id @param {boolean} create @param {{[k: string]: number}} payload @param {string} token
 */
async function write(id, create, payload, token) {
  await api(create ? 'POST' : 'PATCH', `/v0/users/-/collections/${id}`, { token, body: payload, ok: [200, 202, 204] });
}

/**
 * Anime: marks the first `progress` main episodes watched (by position, not by Bangumi's `sort`, which is the
 * series-wide number and may start at 51), then sets the collection type. Created as "do" (3) first, like the
 * built-in provider, so the episodes are marked on an existing entry.
 * @param {any} args @param {number} type @param {string} token
 */
async function setAnime(args, type, token) {
  if (args.create) await write(args.id, true, { type: 3 }, token);
  const progress = int(args.progress);
  if (progress > 0) {
    const episodes = await mainEpisodes(args.id, token);
    const ids = episodes.slice(0, progress).map((e) => e.id);
    if (ids.length === 0) throw new Error(`Bangumi subject ${args.id} has no main episodes to mark.`);
    await api('PATCH', `/v0/users/-/collections/${args.id}/episodes`, {
      token,
      body: { episode_id: ids, type: 2 },
      ok: [200, 204],
    });
  }
  const current = args.create ? 3 : int((await collection(args.id, token))?.type);
  if (current !== type) await write(args.id, false, { type }, token);
}

/**
 * Main episodes (type 0) sorted by `sort`.
 * @param {number} id @param {string} token @returns {Promise<{ id: number, sort: number }[]>}
 */
async function mainEpisodes(id, token) {
  /** @type {{ id: number, sort: number }[]} */
  const all = [];
  for (let offset = 0, total = 1, page = 0; offset < total && page < 20; page++) {
    const { json } = await api('GET', `/v0/episodes?subject_id=${id}&type=0&limit=${EPISODE_PAGE}&offset=${offset}`, {
      token,
    });
    const data = Array.isArray(json?.data) ? json.data : [];
    for (const e of data) {
      if (int(e?.type) === 0 && int(e?.id) > 0 && typeof e.sort === 'number') all.push({ id: int(e.id), sort: e.sort });
    }
    total = int(json?.total);
    if (data.length === 0) break;
    offset += data.length;
  }
  return all.sort((a, b) => a.sort - b.sort);
}

// ---------- the user's list ----------

/** @type {FushiTracking.Plugin['trackingList']} */
async function trackingList({ kind, status, offset }) {
  const token = await requireToken();
  const user = await username(token);
  const type = STATUS_TO_TYPE[status];
  const { json } = await api(
    'GET',
    `/v0/users/${encodeURIComponent(user)}/collections?subject_type=${TYPE_OF_KIND[kind]}&type=${type}` +
      `&limit=${LIST_PAGE}&offset=${offset}`,
    { token },
  );
  const data = Array.isArray(json?.data) ? json.data : [];
  /** @type {FushiTracking.ListItem[]} */
  const items = [];
  for (const c of data) {
    const subject = toSubject(c?.subject, kind);
    const itemStatus = TYPE_TO_STATUS[int(c?.type)];
    if (!subject || subject.kind !== kind || !itemStatus) continue;
    /** @type {FushiTracking.ListItem} */
    const item = { subject, status: itemStatus, progress: int(c.ep_status) };
    if (kind !== 'anime' && kind !== 'game') item.progressVolume = int(c.vol_status);
    const updated = str(c.updated_at);
    if (updated && !Number.isNaN(Date.parse(updated))) item.updatedAt = updated;
    items.push(item);
  }
  const next = offset + data.length;
  return data.length > 0 && next < int(json?.total) ? { items, next } : { items };
}

module.exports = { account, login, trackingSubject, trackingSearch, trackingEntry, trackingList };
