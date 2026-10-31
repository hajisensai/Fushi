/// <reference path="./fushi-plugin.d.ts" />
// Fushi music source plugin. Contract: GUIDE.md in the Fushi plugin SDK.
// Runs in a sandbox: no fetch / setTimeout / Node APIs. Use fushi.http, fushi.storage, fushi.crypto.
// Every exported function named in manifest.capabilities is called by the app with one args object.
'use strict';

// TODO: replace with the real API. The host must be listed in manifest.network.domains.
const API = 'https://api.example.com';

/** @param {string} path @param {{[k: string]: string | number | undefined}} [query] */
async function getJson(path, query = {}) {
  const qs = Object.entries(query)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
  const res = await fushi.http.request({ url: `${API}${path}${qs ? '?' + qs : ''}`, responseType: 'json' });
  if (res.status !== 200) throw new Error(`HTTP ${res.status} from ${path}`);
  return res.json;
}

/** @returns {Fushi.Track} */
function toTrack(/** @type {any} */ t) {
  return {
    id: String(t.id), // ids MUST be strings
    title: t.title,
    artists: (t.artists || []).map((/** @type {any} */ a) => ({ id: String(a.id), name: a.name })),
    album: t.album ? { id: String(t.album.id), title: t.album.title } : undefined,
    durationMs: Math.round(t.duration * 1000), // milliseconds
    coverUrl: t.cover,
  };
}

/** @returns {Fushi.Album} */
function toAlbum(/** @type {any} */ a) {
  return { id: String(a.id), title: a.title, artists: [{ name: a.artist }], coverUrl: a.cover, year: a.year };
}

/** @type {Fushi.Plugin['search']} */
async function search({ query, type, page, pageSize }) {
  const j = await getJson('/search', { q: query, type, offset: page * pageSize, limit: pageSize });
  const items = (j.results || []).map(type === 'album' ? toAlbum : toTrack);
  return { items, hasMore: (page + 1) * pageSize < j.total, total: j.total };
}

/** @type {Fushi.Plugin['album']} */
async function album({ id }) {
  const j = await getJson(`/albums/${encodeURIComponent(id)}`);
  return { album: toAlbum(j), tracks: (j.tracks || []).map(toTrack) };
}

/** @type {Fushi.Plugin['stream']} */
async function stream({ id, quality }) {
  const j = await getJson(`/tracks/${encodeURIComponent(id)}/stream`, { quality });
  if (!j.url) throw new Error('This track is not available'); // message is shown to the user
  return { url: j.url, codec: j.codec, bitrateKbps: j.bitrate };
}

/** @type {Fushi.Plugin['lyrics']} */
async function lyrics({ id }) {
  const j = await getJson(`/tracks/${encodeURIComponent(id)}/lyrics`);
  if (!j.lrc) return null; // "no lyrics" is null, not an error
  return { original: { format: 'lrc', text: j.lrc } };
}

module.exports = { search, album, stream, lyrics };
