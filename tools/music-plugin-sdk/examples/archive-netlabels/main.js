/// <reference path="../../fushi-plugin.d.ts" />
// Example Fushi music source plugin: Internet Archive netlabels (Creative Commons) + LRCLIB lyrics.
// Try it:  node ../../fushi-plugin.mjs smoke . --query ambient
'use strict';

const ia = require('./ia');

/** @type {Fushi.Plugin['search']} */
async function search({ query, type, page, pageSize }) {
  if (type === 'album') {
    const { docs, total } = await ia.searchItems(query, page, pageSize);
    return { items: docs.map(ia.docToAlbum), hasMore: (page + 1) * pageSize < total, total };
  }
  // Songs: the archive indexes releases, not songs, so expand the first few matching releases.
  const { docs, total } = await ia.searchItems(query, page, 3);
  const lists = await Promise.all(
    docs.map((/** @type {any} */ d) => ia.item(d.identifier).then((r) => r.tracks, () => /** @type {Fushi.Track[]} */ ([]))),
  );
  return { items: lists.flat().slice(0, pageSize), hasMore: (page + 1) * 3 < total };
}

/** @type {Fushi.Plugin['album']} */
async function album({ id }) {
  const { album, tracks } = await ia.item(id);
  return { album, tracks };
}

/** @param {string} id */
function splitTrackId(id) {
  const slash = id.indexOf('/');
  if (slash < 0) throw new Error('Unknown track');
  return { identifier: id.slice(0, slash), name: id.slice(slash + 1) };
}

/** @type {Fushi.Plugin['stream']} */
async function stream({ id }) {
  const { identifier, name } = splitTrackId(id);
  const { files } = await ia.item(identifier);
  const f = files.find((/** @type {any} */ x) => x.name === name);
  if (!f) throw new Error('This file was removed from the release'); // shown to the user
  const path = name.split('/').map(encodeURIComponent).join('/');
  return {
    // archive.org redirects to a mirror host (*.archive.org), which network.domains covers.
    url: `${ia.BASE}/download/${encodeURIComponent(identifier)}/${path}`,
    codec: /mp3/i.test(f.format) ? 'mp3' : /ogg/i.test(f.format) ? 'vorbis' : /flac/i.test(f.format) ? 'flac' : undefined,
    bitrateKbps: Number(f.bitrate) || undefined,
    sizeBytes: Number(f.size) || undefined,
  };
}

/** @type {Fushi.Plugin['lyrics']} */
async function lyrics({ id }) {
  // Remember misses for a day so replays do not query LRCLIB again (storage permission).
  const cacheKey = `nolyrics:${id}`;
  const missAt = Number(await fushi.storage.get(cacheKey));
  if (missAt && Date.now() - missAt < 86400000) return null;
  const { tracks } = await ia.item(splitTrackId(id).identifier);
  const t = tracks.find((x) => x.id === id);
  if (!t) return null;
  /** @type {{[k: string]: string | number}} */
  const params = { track_name: t.title, artist_name: t.artists?.[0]?.name || '', album_name: t.album?.title || '' };
  if (t.durationMs) params.duration = Math.round(t.durationMs / 1000);
  const res = await fushi.http.request({ url: `https://lrclib.net/api/get?${ia.query(params)}`, responseType: 'text' });
  // Non-2xx does not throw: decide yourself. A busy server (5xx) is not "no lyrics", so do not cache it.
  if (res.status >= 500) throw new Error(`LRCLIB is unavailable (HTTP ${res.status})`);
  const j = res.status === 200 ? JSON.parse(res.text || 'null') : null;
  if (!j || j.instrumental || (!j.syncedLyrics && !j.plainLyrics)) {
    await fushi.storage.set(cacheKey, String(Date.now()));
    return null; // "no lyrics" is null, not an error
  }
  return { original: j.syncedLyrics ? { format: 'lrc', text: j.syncedLyrics } : { format: 'txt', text: j.plainLyrics } };
}

/** @type {Fushi.Plugin['home']} */
async function home() {
  const [recent, popular] = await Promise.all([
    ia.searchItems('', 0, 12, 'publicdate desc'),
    ia.searchItems('', 0, 12, 'downloads desc'),
  ]);
  return {
    sections: [
      { id: 'recent', title: 'New netlabel releases', kind: 'albums', items: recent.docs.map(ia.docToAlbum) },
      { id: 'popular', title: 'Most downloaded', kind: 'albums', items: popular.docs.map(ia.docToAlbum) },
    ],
  };
}

module.exports = { search, album, stream, lyrics, home };
