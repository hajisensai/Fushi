/// <reference path="../../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// MangaBaka REST client (https://api.mangabaka.org). Port of Fushi's former built-in MangaBaka client.
'use strict';

const API = 'https://api.mangabaka.org';
const USER_AGENT = 'Fushi-Tracking-MangaBaka/0.1.2';

/**
 * A failed call. Carries the HTTP status and MangaBaka's `code` (e.g. `duplicate_entry`) so callers can
 * react before the failure is turned into one of the host's plain-Error prefixes by `hostError`.
 */
class ApiFailure extends Error {
  /** @param {number} status @param {string} message @param {string | null} code @param {string} path */
  constructor(status, message, code, path) {
    super(message);
    this.name = 'ApiFailure';
    this.status = status;
    this.code = code;
    this.path = path;
  }
}

/**
 * @param {Record<string, string | number | string[]>} query
 * @returns {string} `?a=1&type=manga&type=manhwa` (arrays become repeated keys)
 */
function queryString(query) {
  const parts = Object.entries(query).flatMap(([key, value]) =>
    (Array.isArray(value) ? value : [value]).map((v) => `${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`),
  );
  return parts.length ? `?${parts.join('&')}` : '';
}

/**
 * The response body as an object; `{}` for anything else. Every MangaBaka response is JSON, error or not.
 * @param {string | undefined} text @returns {any}
 */
function parseBody(text) {
  let doc = null;
  try {
    doc = text ? JSON.parse(text) : null;
  } catch {
    doc = null;
  }
  return doc && typeof doc === 'object' && !Array.isArray(doc) ? doc : {};
}

/**
 * One request. Resolves with the document's `data` on 2xx; rejects with an `ApiFailure` otherwise.
 * The token only ever goes in the `x-api-key` header (personal access token), never in the URL.
 * @param {string} path
 * @param {{ method?: 'GET' | 'POST' | 'PATCH', query?: Record<string, string | number | string[]>,
 *           body?: Record<string, unknown>, token?: string | null }} [opts]
 * @returns {Promise<any>}
 */
async function request(path, { method = 'GET', query, body, token } = {}) {
  /** @type {{[k: string]: string}} */
  const headers = { Accept: 'application/json', 'User-Agent': USER_AGENT };
  if (token) headers['x-api-key'] = token;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const search = query ? queryString(query) : '';
  const res = await fushi.http.request({
    url: API + path + search,
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    responseType: 'text',
  });
  const json = parseBody(res.text);
  if (res.status < 200 || res.status >= 300) {
    let message = typeof json.message === 'string' ? json.message.trim() : '';
    if (!message) message = 'Request failed';
    if (message.length > 300) message = message.substring(0, 300);
    throw new ApiFailure(res.status, message, typeof json.code === 'string' ? json.code : null, path);
  }
  return json.data;
}

/**
 * Turns anything thrown by `request` into the plain `Error` the host reads (GUIDE section 8).
 * The message after the prefix is shown to the user; MangaBaka documents its `message` as safe to show.
 * @param {unknown} e
 * @returns {Error}
 */
function hostError(e) {
  if (!(e instanceof ApiFailure)) return e instanceof Error ? e : new Error(String(e));
  if (e.status === 401 || e.status === 403) {
    return new Error(`unauthorized: MangaBaka rejected the saved token (${e.message}). Sign in again.`);
  }
  if (e.status === 429) return new Error(`rate_limited: MangaBaka asks to slow down (${e.message}).`);
  if (e.status === 404) return new Error(`not_found: MangaBaka has no such series or library entry (${e.message}).`);
  return new Error(`MangaBaka answered HTTP ${e.status}: ${e.message}`); // temporary, retried later
}

/**
 * `request`, with every failure converted by `hostError`, except a 404 which becomes `null` when
 * `notFoundIsNull` is set (an unknown series, an entry not in the library).
 * @param {string} path
 * @param {Parameters<typeof request>[1] & { notFoundIsNull?: boolean }} [opts]
 * @returns {Promise<any>}
 */
async function call(path, opts = {}) {
  try {
    return await request(path, opts);
  } catch (e) {
    if (opts.notFoundIsNull && e instanceof ApiFailure && e.status === 404) return null;
    throw hostError(e);
  }
}

module.exports = { ApiFailure, request, call, hostError };
