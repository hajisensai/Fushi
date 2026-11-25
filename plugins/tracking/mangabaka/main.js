/// <reference path="../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// MangaBaka tracking plugin (https://mangabaka.org): manga and novels, by chapter or volume. Port of Fushi's
// former built-in MangaBaka provider. Included with Fushi (installed on first start, removable); plan:
// docs/specs/2026-11-11-bangumi-bundled-plugin.md §9. Sign-in is a pasted personal access token only (no
// OAuth, no app registration). Contract: tools/tracking-plugin-sdk/GUIDE.md. Tests: test/*.test.mjs
// (fixtures, no network). No fetch / timers / Node APIs: only `fushi.*`.
'use strict';

const { ApiFailure, request, call, hostError } = require('./lib/api');
const { TYPES_BY_KIND, toInt, parseSeries, parseSeriesList } = require('./lib/series');

/** Where a user creates a personal access token (MangaBaka developer guide "Authenticate with a token"). */
const TOKEN_PAGE = 'https://mangabaka.org/my/settings/api-and-apps';

/** A merged series points at its replacement; follow at most this many hops. */
const MAX_MERGE_HOPS = 3;

/** MangaBaka library `state` -> Fushi status. `considering` has no counterpart: read as planned. */
/** @type {{ [state: string]: FushiTracking.Status }} */
const STATUS_FROM_SITE = {
  considering: 'planned',
  plan_to_read: 'planned',
  reading: 'current',
  rereading: 'repeating',
  paused: 'paused',
  dropped: 'dropped',
  completed: 'completed',
};

/** Fushi status -> MangaBaka library `state`. */
/** @type {{ [status: string]: string }} */
const STATUS_TO_SITE = {
  planned: 'plan_to_read',
  current: 'reading',
  repeating: 'rereading',
  paused: 'paused',
  dropped: 'dropped',
  completed: 'completed',
};

// ---------- Account and sign-in ----------

/** @returns {Promise<string>} the saved token; throws the "sign in again" error when there is none. */
async function requireToken() {
  const token = await fushi.credentials.get('token');
  if (!token) throw new Error('unauthorized: Sign in to MangaBaka first.');
  return token;
}

/** @type {FushiTracking.Plugin['account']} */
async function account() {
  // No network call: the name was saved at sign-in.
  const token = await fushi.credentials.get('token');
  if (!token) return { loggedIn: false };
  const name = await fushi.credentials.get('name');
  return name ? { loggedIn: true, name } : { loggedIn: true };
}

/** @param {string} message @returns {FushiTracking.Challenge} */
function tokenForm(message) {
  return {
    state: 'pending',
    message,
    appUrl: TOKEN_PAGE,
    form: {
      fields: [{ id: 'token', label: 'Personal access token', secret: true, placeholder: 'mb-...' }],
      actions: [{ id: 'save', label: 'Sign in', primary: true }],
    },
  };
}

const BEGIN_MESSAGE =
  'Sign in to mangabaka.org, open Settings › API and apps, press "New token" under Personal access tokens, ' +
  'and paste the token (it starts with "mb-") here. MangaBaka shows it only once.';

/**
 * Checks a token against GET /v1/my/profile.
 * @param {string} token
 * @returns {Promise<{ ok: true, name: string } | { ok: false, message: string }>}
 */
async function checkToken(token) {
  let data;
  try {
    data = await request('/v1/my/profile', { token });
  } catch (e) {
    if (e instanceof ApiFailure && (e.status === 401 || e.status === 403)) {
      return { ok: false, message: 'MangaBaka did not accept that token. Copy it again from your account settings.' };
    }
    if (e instanceof ApiFailure && e.status === 429) {
      return { ok: false, message: 'MangaBaka asks to slow down. Wait a few seconds and try again.' };
    }
    const reason = e instanceof ApiFailure ? `HTTP ${e.status}: ${e.message}` : String(/** @type {any} */ (e)?.message ?? e);
    return { ok: false, message: `Could not check the token with MangaBaka (${reason}). Try again.` };
  }
  // A profile without a string id means the token is not usable.
  if (!data || typeof data !== 'object' || typeof data.id !== 'string') {
    return { ok: false, message: 'MangaBaka did not accept that token. Copy it again from your account settings.' };
  }
  const pick = (/** @type {unknown} */ v) => (typeof v === 'string' ? v.trim() : '');
  return { ok: true, name: pick(data.preferred_username) || pick(data.nickname) };
}

/** @type {FushiTracking.Plugin['login']} */
async function login(args) {
  switch (args.op) {
    case 'methods':
      return {
        methods: [
          {
            id: 'token',
            type: 'form',
            label: 'Paste a personal access token',
            description: 'Create one in your MangaBaka account settings (API and apps).',
          },
        ],
      };
    case 'begin':
      return tokenForm(BEGIN_MESSAGE);
    case 'submit': {
      const token = String(args.inputs?.token ?? '').trim();
      if (!token) return tokenForm('Paste your personal access token first.');
      const result = await checkToken(token);
      if (!result.ok) return tokenForm(result.message); // nothing stored
      await fushi.credentials.set('token', token);
      if (result.name) await fushi.credentials.set('name', result.name);
      else await fushi.credentials.remove('name');
      return {
        state: 'done',
        account: result.name ? { loggedIn: true, name: result.name } : { loggedIn: true },
      };
    }
    case 'logout':
      await fushi.credentials.remove('token');
      await fushi.credentials.remove('name');
      return null;
    default:
      throw new Error('Unsupported sign-in step.');
  }
}

// ---------- Subjects (public: no token needed) ----------

/**
 * The live series for `id`, following merges. Null when a series on the way does not exist or the chain is
 * deeper than MAX_MERGE_HOPS. Each hop depends on the previous answer, so the hops are sequential.
 * @param {number} id @param {number} [hopsLeft] @returns {Promise<import('./lib/series').Series | null>}
 */
async function liveSeries(id, hopsLeft = MAX_MERGE_HOPS) {
  const series = parseSeries(await call(`/v1/series/${id}`, { notFoundIsNull: true }));
  if (!series) return null;
  const next = series.mergedWith;
  if (next === null || next === id) return series;
  return hopsLeft > 0 ? liveSeries(next, hopsLeft - 1) : null;
}

/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id, kind }) {
  const series = await liveSeries(id);
  const subject = series?.subject ?? null; // null too for types that are not books ("other")
  if (!subject) return null;
  if (kind && subject.kind !== kind) return null;
  return subject;
}

/** @type {FushiTracking.Plugin['trackingSearch']} */
async function trackingSearch({ query, kind }) {
  const types = TYPES_BY_KIND[kind];
  const q = String(query ?? '').trim();
  if (!types || !q) return { items: [] };
  const data = await call('/v2/series/search', {
    query: { q, type: types, limit: 20, schema: 'full' },
  });
  return { items: liveSubjects(data, kind) };
}

/**
 * Live (not merged) book subjects of `data`, of `kind` when given.
 * @param {unknown} data @param {FushiTracking.Kind | undefined} kind @returns {FushiTracking.Subject[]}
 */
function liveSubjects(data, kind) {
  /** @type {FushiTracking.Subject[]} */
  const items = [];
  for (const series of parseSeriesList(data)) {
    // A merged result is a duplicate of the series it points at.
    if (series.mergedWith !== null || !series.subject) continue;
    if (kind && series.subject.kind !== kind) continue;
    items.push(series.subject);
  }
  return items;
}

/** Source endpoints for other id spaces: `/v1/source/<name>/{id}`. */
/** @type {{ [idType: string]: string }} */
const SOURCE_PATHS = { anilist: 'anilist', mal: 'my-anime-list' };

/** @type {FushiTracking.Plugin['trackingLookup']} */
async function trackingLookup({ idType, id, kind }) {
  const source = SOURCE_PATHS[idType];
  if (!source) return { items: [] };
  // Every live match is returned; the host applies the "exactly one" rule itself.
  const data = await call(`/v1/source/${source}/${id}`, { notFoundIsNull: true });
  return { items: data && typeof data === 'object' ? liveSubjects(data.series, kind) : [] };
}

// ---------- The user's library entry (needs the token) ----------

/** @type {FushiTracking.Plugin['trackingEntry']} */
async function trackingEntry(args) {
  const token = await requireToken();
  // MangaBaka series ids are global: `kind` is not needed to address the entry.
  if (args.op === 'get') return getEntry(args.id, token);
  if (args.op !== 'set') throw new Error('Unsupported entry operation.');
  return setEntry(args, token);
}

/**
 * The library entry of series `id`; null when it is not in the library.
 * @param {number} id @param {string} token @returns {Promise<FushiTracking.Entry | null>}
 */
async function getEntry(id, token) {
  const data = await call(`/v1/my/library/${id}`, { token, notFoundIsNull: true });
  if (!data || typeof data !== 'object') return null; // not in the library
  // A missing state reads as "reading".
  const state = typeof data.state === 'string' ? data.state : 'reading';
  /** @type {FushiTracking.Entry} */
  const entry = { status: STATUS_FROM_SITE[state] ?? 'current', progress: toInt(data.progress_chapter) ?? 0 };
  const volume = toInt(data.progress_volume);
  if (volume !== undefined) entry.progressVolume = volume;
  return entry;
}

/**
 * Writes exactly the given fields: state + the progress counters that came.
 * @param {FushiTracking.EntryArgs & { op: 'set' }} args @param {string} token @returns {Promise<null>}
 */
async function setEntry(args, token) {
  const state = STATUS_TO_SITE[args.status];
  if (!state) throw new Error(`Unsupported status "${args.status}".`);
  /** @type {Record<string, unknown>} */
  const body = { state };
  if (args.progress !== undefined) body.progress_chapter = args.progress;
  if (args.progressVolume !== undefined) body.progress_volume = args.progressVolume;
  const path = `/v1/my/library/${args.id}`;
  if (args.create && (await createEntry(path, body, token))) return null;
  // PATCH changes only the fields sent. 404 = the entry (or series) is gone -> not_found.
  await call(path, { method: 'PATCH', body, token });
  return null;
}

/**
 * POSTs a new library entry. False when the entry appeared since the host read it (MangaBaka answers 400
 * with code `duplicate_entry`): the spec says to update it then. Anything else is a real failure.
 * @param {string} path @param {Record<string, unknown>} body @param {string} token @returns {Promise<boolean>}
 */
async function createEntry(path, body, token) {
  try {
    await request(path, { method: 'POST', body, token });
    return true;
  } catch (e) {
    const duplicate = e instanceof ApiFailure && (e.code === 'duplicate_entry' || e.status === 409);
    if (!duplicate) throw hostError(e);
    return false;
  }
}

module.exports = { account, login, trackingSubject, trackingSearch, trackingLookup, trackingEntry };
