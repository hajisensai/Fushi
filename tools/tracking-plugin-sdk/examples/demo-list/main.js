/// <reference path="../../fushi-tracking-plugin.d.ts" />
// Example Fushi tracking plugin for a made-up site ("Demo List"). It needs no account and sends no HTTP
// requests: the catalog is in catalog.js and the user's list lives in fushi.storage, so `check`, `run`,
// `login` and `pack` work offline. Sign-in shows the real pattern: a form where the user pastes an API
// token, stored with fushi.credentials. Any token starting with "demo-" is accepted.
'use strict';

const { SUBJECTS, byId } = require('./catalog');

const SITE = 'https://demolist.example.org';
const STATUSES = new Set(['planned', 'current', 'completed', 'paused', 'dropped', 'repeating']);

/** @returns {Promise<string | null>} */
async function token() {
  return fushi.credentials.get('token');
}

/** Throws the host's "sign in again" error when there is no token. @returns {Promise<string>} */
async function requireToken() {
  const t = await token();
  if (!t) throw new Error('unauthorized: Sign in to Demo List first.');
  return t;
}

/** @param {string} t */
const accountName = (t) => t.slice('demo-'.length) || 'demo user';

/** @type {FushiTracking.Plugin['account']} */
async function account() {
  const t = await token();
  return t ? { loggedIn: true, name: accountName(t) } : { loggedIn: false };
}

/** @returns {FushiTracking.Challenge} */
function tokenForm(/** @type {string | undefined} */ message) {
  return {
    state: 'pending',
    message: message ?? 'Open the site, create a personal access token, and paste it here.',
    appUrl: `${SITE}/settings/tokens`,
    form: {
      fields: [{ id: 'token', label: 'Access token', secret: true, placeholder: 'demo-yourname' }],
      actions: [{ id: 'save', label: 'Sign in', primary: true }],
    },
  };
}

/** @type {FushiTracking.Plugin['login']} */
async function login(args) {
  switch (args.op) {
    case 'methods':
      return { methods: [{ id: 'token', type: 'form', label: 'Paste an access token' }] };
    case 'begin':
      return tokenForm();
    case 'submit': {
      const t = (args.inputs.token ?? '').trim();
      // A real plugin verifies the token with one request (e.g. GET /me) before saving it.
      if (!t.startsWith('demo-')) return tokenForm('That token was not accepted. Tokens start with "demo-".');
      await fushi.credentials.set('token', t);
      return { state: 'done', account: { loggedIn: true, name: accountName(t) } };
    }
    case 'logout':
      await fushi.credentials.remove('token');
      return null;
    default:
      throw new Error(`Unsupported login step ${/** @type {any} */ (args).op}`);
  }
}

/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id }) {
  return byId(id); // null = no such subject on this site
}

/** @param {string} s */
const fold = (s) => s.normalize('NFKC').toLowerCase();

/** @type {FushiTracking.Plugin['trackingSearch']} */
async function trackingSearch({ query, kind }) {
  const q = fold(query.trim());
  const items = SUBJECTS.filter((s) => s.kind === kind && (s.titles ?? [s.name]).some((t) => fold(t).includes(q)));
  return { items: items.slice(0, 10) };
}

/** @type {FushiTracking.Plugin['trackingLookup']} */
async function trackingLookup({ idType, id, kind }) {
  const items = SUBJECTS.filter((s) => s.linkedIds?.[idType] === id && (!kind || s.kind === kind));
  return { items };
}

/** @param {number} id */
const entryKey = (id) => `entry:${id}`;

/**
 * `args.kind` ('anime' | 'manga' | 'novel') is always sent. This demo has one id space, so it ignores it;
 * a site whose ids are per list would use it to pick the right list.
 * @type {FushiTracking.Plugin['trackingEntry']}
 */
async function trackingEntry(args) {
  await requireToken();
  if (!byId(args.id)) throw new Error(`not_found: Demo List has no work with id ${args.id}.`);
  const raw = await fushi.storage.get(entryKey(args.id));
  /** @type {FushiTracking.Entry | null} */
  const current = raw ? JSON.parse(raw) : null;
  if (args.op === 'get') return current;

  // set: write exactly what the host asked for. The host already decided (it never lowers progress);
  // the plugin must not "improve" the values.
  if (!STATUSES.has(args.status)) throw new Error(`Unknown status ${args.status}`);
  if (!current && !args.create) throw new Error('not_found: The entry is no longer on your list.');
  /** @type {FushiTracking.Entry} */
  const next = { ...(current ?? { status: args.status, progress: 0 }), status: args.status };
  if (args.progress !== undefined) next.progress = args.progress;
  if (args.progressVolume !== undefined) next.progressVolume = args.progressVolume;
  await fushi.storage.set(entryKey(args.id), JSON.stringify(next));
  return null;
}

module.exports = { account, login, trackingSubject, trackingSearch, trackingLookup, trackingEntry };
