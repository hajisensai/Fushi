/// <reference path="../../fushi-plugin.d.ts" />
// Internet Archive helpers, split into a second file to show `require`.
'use strict';

const BASE = 'https://archive.org';
const AUDIO_FORMATS = ['VBR MP3', 'Ogg Vorbis', 'Flac', '128Kbps MP3', '64Kbps MP3'];

/** @param {string} url */
async function getJson(url) {
  const res = await fushi.http.request({ url, responseType: 'json', timeoutMs: 20000 });
  if (res.status !== 200) throw new Error(`Internet Archive answered HTTP ${res.status}`);
  return res.json;
}

/** @param {{[k: string]: string | number}} params */
function query(params) {
  return Object.entries(params)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
}

/** Archive metadata fields are a string or an array of strings. @param {any} v */
function one(v) {
  return Array.isArray(v) ? v[0] : v;
}

/** "123.45" seconds or "mm:ss" / "h:mm:ss" → milliseconds. @param {any} v */
function lengthMs(v) {
  if (typeof v !== 'string' || !v) return undefined;
  const parts = v.split(':').map(Number);
  if (parts.some((n) => !Number.isFinite(n))) return undefined;
  const seconds = parts.reduce((acc, n) => acc * 60 + n, 0);
  return Math.round(seconds * 1000);
}

/**
 * Advanced search over netlabel releases that have playable audio.
 * @param {string} text @param {number} page @param {number} rows @param {string} [sort]
 */
async function searchItems(text, page, rows, sort) {
  const q = `${text ? `(${text}) AND ` : ''}collection:(netlabels) AND mediatype:(audio) AND format:("VBR MP3")`;
  let url = `${BASE}/advancedsearch.php?${query({ q, rows, page: page + 1, output: 'json' })}`;
  for (const f of ['identifier', 'title', 'creator', 'year', 'date']) url += `&fl%5B%5D=${f}`;
  if (sort) url += `&sort%5B%5D=${encodeURIComponent(sort)}`;
  const j = await getJson(url);
  return { docs: j.response.docs || [], total: Number(j.response.numFound) || 0 };
}

/** @param {any} d @returns {Fushi.Album} */
function docToAlbum(d) {
  const creator = one(d.creator);
  const year = Number(String(one(d.year) || one(d.date) || '').slice(0, 4));
  return {
    id: d.identifier,
    title: one(d.title) || d.identifier,
    artists: creator ? [{ name: creator }] : [],
    coverUrl: `${BASE}/services/img/${encodeURIComponent(d.identifier)}`,
    year: Number.isFinite(year) && year > 0 ? year : undefined,
  };
}

// The plugin instance stays alive between calls, so a module-level cache saves requests when the app asks
// for an album, then a stream, then lyrics of the same release.
/** @type {Map<string, Promise<any>>} */
const itemCache = new Map();

/**
 * Full item: album + tracks. Track ids are "<identifier>/<file name>".
 * @param {string} identifier
 * @returns {Promise<{album: Fushi.Album, tracks: Fushi.Track[], files: any[]}>}
 */
function item(identifier) {
  if (!itemCache.has(identifier)) {
    if (itemCache.size > 50) itemCache.clear();
    const p = loadItem(identifier);
    p.catch(() => itemCache.delete(identifier));
    itemCache.set(identifier, p);
  }
  return /** @type {Promise<any>} */ (itemCache.get(identifier));
}

/** @param {string} identifier */
async function loadItem(identifier) {
  const j = await getJson(`${BASE}/metadata/${encodeURIComponent(identifier)}`);
  if (!j || !j.metadata) throw new Error('This release no longer exists');
  const md = j.metadata;
  const album = docToAlbum({ identifier, title: md.title, creator: md.creator, year: md.year, date: md.date });
  const description = one(md.description);
  if (typeof description === 'string') album.description = description.replace(/<[^>]+>/g, '').trim();
  // Prefer one format per release so the same song is not listed twice.
  const files = j.files || [];
  const format = AUDIO_FORMATS.find((f) => files.some((/** @type {any} */ x) => x.format === f));
  /** @type {Fushi.Track[]} */
  const tracks = files
    .filter((/** @type {any} */ f) => f.format === format)
    .map((/** @type {any} */ f, /** @type {number} */ i) => {
      const artist = one(f.creator || md.creator);
      return {
        id: `${identifier}/${f.name}`,
        title: f.title || f.name.replace(/\.[^.]+$/, ''),
        artists: artist ? [{ name: artist }] : [],
        album: { id: identifier, title: album.title },
        durationMs: lengthMs(f.length),
        trackNo: Number(f.track) || i + 1,
        coverUrl: album.coverUrl,
      };
    });
  album.trackCount = tracks.length;
  return { album, tracks, files };
}

module.exports = { BASE, searchItems, docToAlbum, item, query };
