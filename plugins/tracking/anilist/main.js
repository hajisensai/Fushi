/// <reference path="../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// AniList tracking plugin (https://anilist.co), a port of Fushi's former built-in AniList provider. Included
// with Fushi (installed on first start, removable); plan: docs/specs/2026-11-11-bangumi-bundled-plugin.md §9.
// Contract: tools/tracking-plugin-sdk/GUIDE.md. Tests: test/*.test.mjs (fixtures, no network).
// Sandbox: no fetch / timers / Node APIs; only fushi.http and fushi.credentials are used.
'use strict';

const {
  MEDIA_FIELDS,
  FORMATS_BY_KIND,
  STATUS_FROM_SITE,
  STATUS_TO_SITE,
  mediaTypeFor,
  toSubject,
  isNotFound,
  gql,
} = require('./anilist');

/**
 * AniList hands out tokens only to a registered API client (implicit grant, no secret). Fushi ships no
 * client registration of its own: the user creates one once (any name, redirect URL
 * https://anilist.co/api/v2/oauth/pin) and enters its id. A Fushi-owned client id may be set here later
 * to prefill that field; empty = none.
 */
const DEFAULT_CLIENT_ID = '';

/** Where an AniList user creates an API client. */
const DEVELOPER_PAGE = 'https://anilist.co/settings/developer';

/** The redirect URL the client must be registered with: AniList then shows the token on its own page. */
const PIN_REDIRECT = 'https://anilist.co/api/v2/oauth/pin';

/** An AniList API client id is a number. */
const CLIENT_ID_PATTERN = /^\d{1,10}$/;

/** @param {string} clientId @returns {string} the implicit-grant authorize page for [clientId]. */
function authorizeUrl(clientId) {
  return `https://anilist.co/api/v2/oauth/authorize?client_id=${clientId}&response_type=token`;
}

/** @returns {Promise<string | null>} the saved token, or null when signed out. */
async function savedToken() {
  const t = await fushi.credentials.get('token');
  return t?.trim() ? t.trim() : null;
}

/** @returns {Promise<string>} the client id entered before (kept across sign-outs), else the default. */
async function savedClientId() {
  return (await fushi.credentials.get('clientId')) ?? DEFAULT_CLIENT_ID;
}

// ---------- account / login ----------

/** @type {FushiTracking.Plugin['account']} */
async function account() {
  // No request: the name was cached at sign-in.
  const token = await savedToken();
  if (!token) return { loggedIn: false };
  const name = await fushi.credentials.get('name');
  return name ? { loggedIn: true, name } : { loggedIn: true };
}

const CLIENT_HELP =
  'AniList gives tokens to an API client you register once. Open AniList, create a client ' +
  `(any name, redirect URL ${PIN_REDIRECT}), and enter its client ID here.`;

const TOKEN_HELP =
  'Open AniList, approve the client, copy the token shown, and paste it here. ' +
  'The token lasts one year; sign in again when it expires.';

/** Step 1: the API client id. @param {string} message @param {string} clientId @returns {FushiTracking.Challenge} */
function clientForm(message, clientId) {
  return {
    state: 'pending',
    message,
    appUrl: DEVELOPER_PAGE,
    form: {
      fields: [{ id: 'clientId', label: 'AniList API client ID', placeholder: '12345', value: clientId }],
      actions: [{ id: 'continue', label: 'Continue', primary: true }],
    },
  };
}

/** Step 2: the token. @param {string} message @param {string} clientId @returns {FushiTracking.Challenge} */
function tokenForm(message, clientId) {
  return {
    state: 'pending',
    message,
    appUrl: authorizeUrl(clientId),
    form: {
      fields: [{ id: 'token', label: 'AniList access token', secret: true, multiline: true }],
      actions: [
        { id: 'save', label: 'Sign in', primary: true },
        { id: 'client', label: 'Change client ID' },
      ],
    },
  };
}

/** @param {{[fieldId: string]: string}} inputs @returns {Promise<FushiTracking.Challenge>} */
async function submitClientId(inputs) {
  const clientId = (inputs?.clientId ?? '').trim();
  if (!CLIENT_ID_PATTERN.test(clientId)) {
    return clientForm(`Enter the client ID (a number) of your AniList API client. ${CLIENT_HELP}`, clientId);
  }
  await fushi.credentials.set('clientId', clientId);
  return tokenForm(TOKEN_HELP, clientId);
}

/**
 * Checks the token with `Viewer` and stores it with the account name.
 * @param {{[fieldId: string]: string}} inputs @returns {Promise<FushiTracking.Challenge>}
 */
async function submitToken(inputs) {
  const clientId = await savedClientId();
  if (!CLIENT_ID_PATTERN.test(clientId)) return clientForm(CLIENT_HELP, clientId);
  const retry = (/** @type {string} */ message) => tokenForm(message, clientId);
  const token = (inputs?.token ?? '').trim();
  if (!token) return retry(`Paste the token first. ${TOKEN_HELP}`);
  /** @type {any} */
  let data;
  try {
    data = await gql('query { Viewer { id name } }', {}, token);
  } catch (e) {
    const msg = /** @type {Error} */ (e).message;
    if (msg.startsWith('unauthorized:')) return retry(`AniList did not accept that token. Copy it again. ${TOKEN_HELP}`);
    if (msg.startsWith('rate_limited:')) return retry('AniList is busy right now. Try again in a minute.');
    return retry(`Could not reach AniList (${msg}). Try again.`);
  }
  const viewer = data?.Viewer;
  // No Viewer id means the token is not usable.
  if (typeof viewer?.id !== 'number') return retry(`AniList did not accept that token. Copy it again. ${TOKEN_HELP}`);
  const name = typeof viewer.name === 'string' ? viewer.name : '';
  await fushi.credentials.set('token', token);
  await fushi.credentials.set('name', name);
  return { state: 'done', account: name ? { loggedIn: true, name } : { loggedIn: true } };
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
            label: 'Sign in with AniList',
            description: 'Uses an AniList API client you register once.',
          },
        ],
      };
    case 'begin':
      return clientForm(CLIENT_HELP, await savedClientId());
    case 'submit':
      if (args.action === 'continue') return submitClientId(args.inputs);
      if (args.action === 'client') return clientForm(CLIENT_HELP, await savedClientId());
      return submitToken(args.inputs);
    case 'logout':
      // The client id is not a secret of the account: it stays for the next sign-in.
      await fushi.credentials.remove('token');
      await fushi.credentials.remove('name');
      return null;
    default:
      throw new Error('Unsupported sign-in step.');
  }
}

// ---------- public lookups (token sent when stored) ----------

/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id, kind }) {
  /** @type {any} */
  let data;
  try {
    // `type: null` (no kind) lets AniList match the id on either side.
    data = await gql(
      `query ($id: Int, $type: MediaType) { Media(id: $id, type: $type) { ${MEDIA_FIELDS} } }`,
      { id, type: mediaTypeFor(kind) },
      await savedToken(),
    );
  } catch (e) {
    if (isNotFound(e)) return null; // no such media (or not of that type)
    throw e;
  }
  const subject = data?.Media ? toSubject(data.Media) : null;
  // MANGA type covers both manga and novels: a novel asked as manga (or the reverse) is "not this".
  if (subject && kind && subject.kind !== kind) return null;
  return subject;
}

/** @type {FushiTracking.Plugin['trackingSearch']} */
async function trackingSearch({ query, kind }) {
  const q = (query ?? '').trim();
  if (!q) return { items: [] };
  // Manga and novels: type MANGA + format_in. Anime: type ANIME and no format filter.
  const data = await gql(
    'query ($search: String, $type: MediaType, $formats: [MediaFormat]) { ' +
      'Page(perPage: 20) { media(search: $search, type: $type, format_in: $formats) { ' +
      MEDIA_FIELDS +
      ' } } }',
    { search: q, type: mediaTypeFor(kind) ?? 'ANIME', formats: FORMATS_BY_KIND[kind] ?? null },
    await savedToken(),
  );
  return { items: subjectsOf(data?.Page?.media, kind) };
}

/** @type {FushiTracking.Plugin['trackingLookup']} */
async function trackingLookup({ idType, id, kind }) {
  // AniList stores only MAL ids; other sites' ids cannot be mapped.
  if (idType !== 'mal') return { items: [] };
  // A Page, not Media: MAL anime and manga ids are separate spaces, so without a kind the
  // same number can match one anime and one manga. With a kind, the type narrows it.
  const data = await gql(
    'query ($idMal: Int, $type: MediaType) { ' +
      `Page(perPage: 20) { media(idMal: $idMal, type: $type) { ${MEDIA_FIELDS} } } }`,
    { idMal: id, type: mediaTypeFor(kind) },
    await savedToken(),
  );
  return { items: subjectsOf(data?.Page?.media, kind) };
}

/**
 * Media list -> subjects of [kind] (all kinds when absent); media without a Fushi kind are skipped.
 * @param {unknown} media @param {FushiTracking.Kind | undefined} kind
 * @returns {FushiTracking.Subject[]}
 */
function subjectsOf(media, kind) {
  if (!Array.isArray(media)) return [];
  /** @type {FushiTracking.Subject[]} */
  const out = [];
  for (const m of media) {
    const s = m && typeof m === 'object' ? toSubject(m) : null;
    if (s && (!kind || s.kind === kind)) out.push(s);
  }
  return out;
}

// ---------- the viewer's list entry ----------

/** @typedef {FushiTracking.EntryArgs & { kind?: FushiTracking.Kind }} EntryArgsWithKind */

/** @type {FushiTracking.Plugin['trackingEntry']} */
async function trackingEntry(rawArgs) {
  const args = /** @type {EntryArgsWithKind} */ (rawArgs);
  const token = await savedToken();
  if (!token) throw new Error('unauthorized: Sign in to AniList first.');
  return args.op === 'get' ? getEntry(args.id, args.kind, token) : setEntry(args, token);
}

/**
 * The viewer's entry, read from `Media.mediaListEntry`.
 * @param {number} id @param {FushiTracking.Kind | undefined} kind @param {string} token
 * @returns {Promise<FushiTracking.Entry | null>}
 */
async function getEntry(id, kind, token) {
  // A missing media throws not_found: (a permanent 404 for the host).
  const data = await gql(
    'query ($id: Int, $type: MediaType) { Media(id: $id, type: $type) { ' +
      'id type format mediaListEntry { status progress progressVolumes } } }',
    { id, type: mediaTypeFor(kind) },
    token,
  );
  const media = data?.Media;
  if (!media) throw new Error(`not_found: AniList has no entry ${id}.`);
  // The type filter separates anime from manga. Manga vs novel is not checked here: both share
  // the MANGA list.
  const e = media.mediaListEntry;
  if (!e) return null; // not on the viewer's list
  /** @type {any} */
  const entry = {
    // A missing status reads as CURRENT. An unknown value stays unset, so the host
    // treats the entry as unreadable and writes nothing.
    status: e.status == null ? 'current' : STATUS_FROM_SITE[e.status],
    progress: typeof e.progress === 'number' ? e.progress : 0,
  };
  if (typeof e.progressVolumes === 'number') entry.progressVolume = e.progressVolumes;
  return entry;
}

/**
 * `SaveMediaListEntry` with exactly the given fields. AniList upserts by mediaId, so `create` needs no
 * different request.
 * @param {EntryArgsWithKind & { op: 'set' }} args @param {string} token
 * @returns {Promise<null>}
 */
async function setEntry(args, token) {
  /** @type {[name: string, type: string, value: any][]} */
  const fields = [['mediaId', 'Int', args.id]];
  if (args.status !== undefined) {
    const status = STATUS_TO_SITE[args.status];
    if (!status) throw new Error(`Unknown list status "${args.status}".`);
    fields.push(['status', 'MediaListStatus', status]);
  }
  if (args.progress !== undefined) fields.push(['progress', 'Int', args.progress]);
  if (args.progressVolume !== undefined) fields.push(['progressVolumes', 'Int', args.progressVolume]);
  // Only declared arguments are sent, so AniList leaves every other field as it is.
  const decl = fields.map(([n, t]) => `$${n}: ${t}`).join(', ');
  const call = fields.map(([n]) => `${n}: $${n}`).join(', ');
  const selection = ['id', ...fields.slice(1).map(([n]) => n)].join(' ');
  /** @type {{[k: string]: any}} */
  const variables = Object.fromEntries(fields.map(([n, , v]) => [n, v]));
  await gql(`mutation (${decl}) { SaveMediaListEntry(${call}) { ${selection} } }`, variables, token);
  return null;
}

module.exports = { account, login, trackingSubject, trackingSearch, trackingLookup, trackingEntry };
