/// <reference path="./fushi-tracking-plugin.d.ts" />
// Fushi tracking site plugin. Contract: GUIDE.md (copied next to this file by `init`).
// Runs in a sandbox: no fetch / setTimeout / Node APIs. Use fushi.http, fushi.credentials, fushi.storage.
// Every exported function named in manifest.capabilities is called by the app with one args object.
'use strict';

// Replace with your site's API address. The host must be listed in manifest.network.domains.
const API = 'https://api.example.com';
// Replace with your site's page where a user creates a personal access token (must also be inside network.domains).
const TOKEN_PAGE = 'https://api.example.com/settings/tokens';

/** @returns {Promise<string>} the saved token; throws the "sign in again" error when there is none. */
async function requireToken() {
  const t = await fushi.credentials.get('token');
  if (!t) throw new Error('unauthorized: Sign in first.');
  return t;
}

/**
 * One API call. Maps HTTP failures to the host's error prefixes.
 * @param {string} path @param {{ method?: 'GET' | 'POST', body?: any, token?: string | null }} [opts]
 */
async function api(path, { method = 'GET', body, token } = {}) {
  /** @type {{[k: string]: string}} */
  const headers = { Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fushi.http.request({
    url: `${API}${path}`,
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    responseType: 'json',
  });
  if (res.status === 401 || res.status === 403) throw new Error('unauthorized: The site rejected the saved token. Sign in again.');
  if (res.status === 429) throw new Error('rate_limited: The site asks to slow down.');
  if (res.status === 404) throw new Error(`not_found: ${path} does not exist on the site.`);
  if (res.status < 200 || res.status >= 300) throw new Error(`HTTP ${res.status} from ${path}`); // temporary, retried later
  return res.json;
}

/** @returns {FushiTracking.Subject} Map your site's fields here. Ids are positive integers. */
function toSubject(/** @type {any} */ s) {
  return {
    id: Number(s.id),
    name: s.title,
    kind: s.type === 'manga' ? 'manga' : 'anime',
    titles: s.alternative_titles ?? [],
    totalEpisodes: s.episodes ?? undefined,
    totalChapters: s.chapters ?? undefined,
    finished: s.status === 'finished',
    linkedIds: s.mal_id ? { mal: Number(s.mal_id) } : undefined,
  };
}

/** @type {FushiTracking.Plugin['account']} */
async function account() {
  const t = await fushi.credentials.get('token');
  if (!t) return { loggedIn: false };
  const name = await fushi.credentials.get('name'); // cached at sign-in: keep account() cheap
  return { loggedIn: true, name: name ?? undefined };
}

/** @returns {FushiTracking.Challenge} */
function tokenForm(/** @type {string | undefined} */ message) {
  return {
    state: 'pending',
    message: message ?? 'Create a personal access token on the site and paste it here.',
    appUrl: TOKEN_PAGE,
    form: {
      fields: [{ id: 'token', label: 'Access token', secret: true }],
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
      if (!t) return tokenForm('Paste a token first.');
      let me;
      try {
        me = await api('/me', { token: t }); // replace with your site's "current user" endpoint
      } catch (e) {
        return tokenForm(`The token was not accepted (${/** @type {Error} */ (e).message}).`);
      }
      await fushi.credentials.set('token', t);
      await fushi.credentials.set('name', String(me.name ?? ''));
      return { state: 'done', account: { loggedIn: true, name: me.name } };
    }
    case 'logout':
      await fushi.credentials.remove('token');
      await fushi.credentials.remove('name');
      return null;
    default:
      throw new Error('Unsupported login step');
  }
}

/** @type {FushiTracking.Plugin['trackingSubject']} */
async function trackingSubject({ id }) {
  try {
    return toSubject(await api(`/works/${id}`));
  } catch (e) {
    if (/** @type {Error} */ (e).message.startsWith('not_found:')) return null; // no such subject
    throw e;
  }
}

/** @type {FushiTracking.Plugin['trackingSearch']} */
async function trackingSearch({ query, kind }) {
  const j = await api(`/works?type=${kind}&q=${encodeURIComponent(query)}&limit=10`);
  return { items: (j.results ?? []).map(toSubject) };
}

/** @type {FushiTracking.Plugin['trackingLookup']} */
async function trackingLookup({ idType, id, kind }) {
  if (idType !== 'mal') return { items: [] }; // add the other id spaces your site can map
  const typeFilter = kind ? `&type=${kind}` : '';
  const j = await api(`/works?mal_id=${id}${typeFilter}`);
  return { items: (j.results ?? []).map(toSubject) };
}

/**
 * `args.kind` ('anime' | 'manga' | 'novel') is always sent. Use it when this site's ids are per list.
 * @type {FushiTracking.Plugin['trackingEntry']}
 */
async function trackingEntry(args) {
  const token = await requireToken();
  if (args.op === 'get') {
    const j = await api(`/me/list/${args.id}`, { token }).catch((/** @type {Error} */ e) => {
      if (e.message.startsWith('not_found:')) return null; // not on the list is null, not an error
      throw e;
    });
    if (!j) return null;
    return { status: j.status, progress: j.progress ?? 0, progressVolume: j.volumes ?? undefined }; // map your site's statuses to Fushi's
  }
  // set: write exactly the given fields; the host already decided (it never lowers progress).
  /** @type {{[k: string]: any}} */
  const body = { status: args.status };
  if (args.progress !== undefined) body.progress = args.progress;
  if (args.progressVolume !== undefined) body.volumes = args.progressVolume;
  await api(`/me/list/${args.id}`, { method: 'POST', body, token });
  return null;
}

module.exports = { account, login, trackingSubject, trackingSearch, trackingLookup, trackingEntry };
