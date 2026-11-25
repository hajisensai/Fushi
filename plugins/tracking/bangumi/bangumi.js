/// <reference path="../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// Bangumi v0 API helpers (https://bangumi.github.io/api/). Port of Fushi's former built-in
// `bangumi_api_client.dart`: the token only goes into the Authorization header, never into a URL or an
// error message.
'use strict';

const API = 'https://api.bgm.tv';
const USER_AGENT = 'Fushi-Bangumi-Plugin/1.0.0 (https://github.com/hajisensai/Fushi)';

/** Bangumi subject types: 1 book (manga and novels), 2 anime, 4 game. */
const TYPE_OF_KIND = { anime: 2, manga: 1, novel: 1, game: 4 };

/** Collection types: 1 wish, 2 collect (done), 3 do (watching / reading / playing), 4 on hold, 5 dropped. */
const STATUS_TO_TYPE = { planned: 1, completed: 2, current: 3, paused: 4, dropped: 5, repeating: 3 };
const TYPE_TO_STATUS = { 1: 'planned', 2: 'completed', 3: 'current', 4: 'paused', 5: 'dropped' };

/** @param {unknown} v @returns {number} a non-negative integer, 0 for anything else */
function int(v) {
  let n = Number.NaN;
  if (typeof v === 'number') n = v;
  else if (typeof v === 'string') n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.trunc(n) : 0;
}

/** @param {unknown} v @returns {string} */
function str(v) {
  return typeof v === 'string' ? v.trim() : '';
}

/**
 * One request. Returns { status, json } for an accepted status; throws a prefixed Error otherwise
 * (401 / 403 unauthorized, 429 rate limited, 404 not found, anything else temporary).
 * @param {string} method @param {string} path @param {{ token?: string | null, body?: unknown, ok?: number[] }} [o]
 */
async function api(method, path, o = {}) {
  /** @type {{[k: string]: string}} */
  const headers = { Accept: 'application/json', 'User-Agent': USER_AGENT };
  if (o.token) headers.Authorization = `Bearer ${o.token}`;
  if (o.body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fushi.http.request({
    url: `${API}${path}`,
    method,
    headers,
    body: o.body === undefined ? undefined : JSON.stringify(o.body),
    responseType: 'text',
  });
  /** @type {any} */
  let json = null;
  try {
    json = res.text ? JSON.parse(res.text) : null;
  } catch (_) {
    // Not JSON (a proxy page): handled by the status check.
  }
  const ok = o.ok ?? [200];
  if (ok.includes(res.status)) return { status: res.status, json };
  let message = str(json?.description) || str(json?.title) || `HTTP ${res.status}`;
  if (message.length > 300) message = message.substring(0, 300);
  if (res.status === 401 || res.status === 403) {
    throw new Error(`unauthorized: Bangumi rejected the saved access token (${message}). Sign in again.`);
  }
  if (res.status === 429) throw new Error('rate_limited: Bangumi asks to slow down. Fushi will try again later.');
  if (res.status === 404) throw new Error(`not_found: Bangumi has no such entry (${message}).`);
  throw new Error(`Bangumi error ${res.status}: ${message}`);
}

/**
 * A Bangumi book (type 1) is a manga or a novel: the kind asked for decides, else the platform label.
 * @param {any} s @param {FushiTracking.Kind | undefined} kind @returns {FushiTracking.Kind}
 */
function bookKind(s, kind) {
  if (kind === 'manga' || kind === 'novel') return kind;
  return str(s.platform).includes('漫画') ? 'manga' : 'novel';
}

/**
 * The Fushi kind of a Bangumi subject, or null for types Fushi does not track.
 * @param {any} s @param {FushiTracking.Kind | undefined} kind @returns {FushiTracking.Kind | null}
 */
function kindOf(s, kind) {
  switch (int(s.type)) {
    case 2:
      return 'anime';
    case 4:
      return 'game';
    case 1:
      return bookKind(s, kind);
    default:
      return null;
  }
}

/** @param {FushiTracking.Subject} out @param {any} s */
function addAnimeCounts(out, s) {
  const eps = int(s.eps) || int(s.total_episodes);
  if (eps > 0) out.totalEpisodes = eps;
}

/**
 * Bangumi fills `volumes` once the work's volume count is known: the built-in provider completed a volume
 * link only then, and treated a book of at most one volume as one book (finishing it finishes the subject).
 * @param {FushiTracking.Subject} out @param {any} s
 */
function addBookCounts(out, s) {
  const volumes = int(s.volumes);
  if (volumes > 0) {
    out.finalVolume = volumes;
    out.finished = true;
  }
  out.singleVolume = volumes <= 1;
}

/**
 * Bangumi subject -> Fushi subject of [kind] (the kind asked for decides manga vs novel, as the built-in
 * provider did: Bangumi keeps both in one book type). Null for types Fushi does not track.
 * @param {any} s @param {FushiTracking.Kind | undefined} kind
 * @returns {FushiTracking.Subject | null}
 */
function toSubject(s, kind) {
  if (!s || typeof s !== 'object') return null;
  const id = int(s.id);
  const name = str(s.name);
  const display = str(s.name_cn) || name;
  if (!id || !display) return null;
  const k = kindOf(s, kind);
  if (!k) return null;
  const titles = [display];
  if (name && name !== display) titles.push(name);
  /** @type {FushiTracking.Subject} */
  const out = { id, name: display, kind: k, titles };
  if (k === 'anime') addAnimeCounts(out, s);
  else if (k !== 'game') addBookCounts(out, s);
  return out;
}

module.exports = { api, toSubject, int, str, TYPE_OF_KIND, STATUS_TO_TYPE, TYPE_TO_STATUS };
