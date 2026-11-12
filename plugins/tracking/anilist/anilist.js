/// <reference path="../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// AniList GraphQL client and mapping, ported from Fushi's former built-in AniList client.
'use strict';

const ENDPOINT = 'https://graphql.anilist.co';

/** Fields of a Media that become a Subject. `idMal` feeds linkedIds.mal. */
const MEDIA_FIELDS =
  'id idMal type format status episodes chapters volumes ' +
  'title { romaji english native } synonyms';

/** AniList `MediaFormat`s per Fushi kind on the MANGA side (sent as the `format_in` filter). */
const COMIC_FORMATS = ['MANGA', 'ONE_SHOT'];
const BOOK_FORMATS = ['NOVEL'];
const COMIC_FORMAT_SET = new Set(COMIC_FORMATS);
const BOOK_FORMAT_SET = new Set(BOOK_FORMATS);

/** The `format_in` filter of a title search per Fushi kind (anime: none). */
/** @type {{[kind: string]: string[]}} */
const FORMATS_BY_KIND = { manga: COMIC_FORMATS, novel: BOOK_FORMATS };

/** AniList `MediaListStatus` <-> Fushi Entry.status. */
/** @type {{[site: string]: FushiTracking.Status}} */
const STATUS_FROM_SITE = {
  PLANNING: 'planned',
  CURRENT: 'current',
  COMPLETED: 'completed',
  PAUSED: 'paused',
  DROPPED: 'dropped',
  REPEATING: 'repeating',
};
/** @type {{[fushi: string]: string}} */
const STATUS_TO_SITE = Object.fromEntries(Object.entries(STATUS_FROM_SITE).map(([site, f]) => [f, site]));

/**
 * The AniList `MediaType` to ask for. Novels live under MANGA on AniList.
 * @param {FushiTracking.Kind | undefined} kind
 * @returns {'ANIME' | 'MANGA' | null}
 */
function mediaTypeFor(kind) {
  if (kind === 'anime') return 'ANIME';
  if (kind === 'manga' || kind === 'novel') return 'MANGA';
  return null; // unknown kind: let AniList match any type
}

/**
 * Fushi kind of a Media: ANIME is anime; on the MANGA side NOVEL is a novel and MANGA / ONE_SHOT are
 * manga; anything else has no kind (dropped).
 * @param {any} m
 * @returns {FushiTracking.Kind | null}
 */
function kindOf(m) {
  if (m.type === 'ANIME') return 'anime';
  if (BOOK_FORMAT_SET.has(m.format)) return 'novel';
  if (COMIC_FORMAT_SET.has(m.format)) return 'manga';
  return null;
}

/** A positive count, or undefined: AniList's 0 / null both mean "unknown". */
function count(/** @type {unknown} */ v) {
  return typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : undefined;
}

/** @param {unknown} s @returns {string} the trimmed string, or '' for anything else. */
function trimmed(s) {
  return typeof s === 'string' ? s.trim() : '';
}

/**
 * Every distinct non-empty title (exact duplicates are common: romaji == English == "ONE PIECE").
 * @param {any} t the `title` object @param {unknown} synonyms
 * @returns {string[]}
 */
function titlesOf(t, synonyms) {
  const all = [t.romaji, t.english, t.native, ...(Array.isArray(synonyms) ? synonyms : [])];
  return [...new Set(all.map(trimmed).filter((s) => s.length > 0))];
}

/**
 * Media -> Subject. Null when the media has no Fushi kind.
 * @param {any} m
 * @returns {FushiTracking.Subject | null}
 */
function toSubject(m) {
  const kind = kindOf(m);
  if (!kind || typeof m.id !== 'number') return null;
  const t = m.title ?? {};
  // Name = first non-empty of romaji, English, native.
  const name = [t.romaji, t.english, t.native].map(trimmed).find((s) => s) ?? '';
  /** @type {FushiTracking.Subject} */
  const subject = { id: m.id, name, kind, titles: titlesOf(t, m.synonyms), finished: m.status === 'FINISHED' };
  if (kind === 'anime') {
    subject.totalEpisodes = count(m.episodes);
  } else {
    subject.totalChapters = count(m.chapters);
    subject.finalVolume = count(m.volumes);
  }
  if (count(m.idMal)) subject.linkedIds = { mal: m.idMal };
  return subject;
}

/** @param {{[k: string]: any}} vars */
function withoutNulls(vars) {
  return Object.fromEntries(Object.entries(vars).filter(([, v]) => v !== null && v !== undefined));
}

/** True for the error `gql` throws when AniList answers 404 / "Not Found". */
function isNotFound(/** @type {unknown} */ e) {
  return e instanceof Error && e.message.startsWith('not_found:');
}

/**
 * The response body as an object; `{}` when it is not JSON (a proxy or Cloudflare page), which the status
 * check then reports.
 * @param {string | undefined} text
 * @returns {any}
 */
function parseBody(text) {
  let parsed = null;
  try {
    parsed = JSON.parse(text ?? '');
  } catch {
    parsed = null;
  }
  return parsed && typeof parsed === 'object' ? parsed : {};
}

/**
 * The error for a failed request: its status is the HTTP status, or the first GraphQL error's `status`
 * when HTTP said 200.
 *   401 / 403 / 400 "Invalid token" -> unauthorized:   429 -> rate_limited:   404 -> not_found:
 * @param {number} httpStatus @param {any} first the first GraphQL error (or `{}`)
 * @returns {Error}
 */
function failure(httpStatus, first) {
  let message = trimmed(first.message) || `HTTP ${httpStatus}`;
  if (message.length > 300) message = message.substring(0, 300);
  let status = httpStatus;
  if (status === 200) status = typeof first.status === 'number' ? first.status : 0;
  if (status === 401 || status === 403 || (status === 400 && /invalid token/i.test(message))) {
    return new Error(`unauthorized: AniList rejected the saved token (${message}). Sign in again.`);
  }
  if (status === 429) return new Error('rate_limited: AniList asks to slow down. Fushi will try again later.');
  if (status === 404) return new Error(`not_found: AniList has no such entry (${message}).`);
  return new Error(`AniList error ${status}: ${message}`); // temporary, retried later
}

/**
 * One GraphQL request. A failure is HTTP != 200, or `errors` with `data: null` (see `failure`).
 * Callers turn not_found: into null where "missing" is a normal answer.
 * The token is only ever sent in the Authorization header, never put in a message.
 * @param {string} query
 * @param {{[k: string]: any}} variables
 * @param {string | null} token
 * @returns {Promise<any>} the `data` object
 */
async function gql(query, variables, token) {
  /** @type {{[k: string]: string}} */
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fushi.http.request({
    url: ENDPOINT,
    method: 'POST',
    headers,
    // AniList treats an explicit `null` variable as a filter value (`type: null` matches nothing),
    // but an omitted variable as "argument not given": drop the nulls.
    body: JSON.stringify({ query, variables: withoutNulls(variables) }),
    responseType: 'text',
  });
  const json = parseBody(res.text);
  const errors = Array.isArray(json.errors) ? json.errors : [];
  if (res.status !== 200 || (errors.length > 0 && json.data == null)) {
    throw failure(res.status, errors[0] ?? {});
  }
  return json.data ?? {};
}

module.exports = {
  ENDPOINT,
  MEDIA_FIELDS,
  FORMATS_BY_KIND,
  STATUS_FROM_SITE,
  STATUS_TO_SITE,
  mediaTypeFor,
  kindOf,
  toSubject,
  isNotFound,
  gql,
};
