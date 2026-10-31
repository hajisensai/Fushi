// Checks a capability's return value the way the Fushi host parses it
// (packages/fushi_music/lib/src/plugin/plugin_models.dart + plugin_source.dart).
//
// errors   = the host throws and the user sees "plugin unavailable".
// warnings = the host silently drops / ignores something (the most common reason "my results don't show").
import { APP_URL_SCHEMES, MEDIA_HEADER_ALLOWLIST } from './rules.mjs';

const LYRIC_FORMATS = ['yrc', 'lrc', 'ttml', 'qrc', 'krc', 'txt'];
const DATE = /^\d{4}(-\d{2}(-\d{2})?)?$/;

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const str = (v) => typeof v === 'string' && v.length > 0;

class Report {
  constructor(policy) {
    this.policy = policy;
    this.errors = [];
    this.warnings = [];
  }
  error(path, msg) {
    this.errors.push(`${path}: ${msg}`);
  }
  warn(path, msg) {
    this.warnings.push(`${path}: ${msg}`);
  }
  idField(path, v, field) {
    if (str(v)) return true;
    if (typeof v === 'number') this.warn(path, `${field} is a number (${v}); ids must be strings — the entry is dropped`);
    else this.warn(path, `missing or empty ${field} — the entry is dropped`);
    return false;
  }
  url(path, v, what) {
    if (v === undefined || v === null) return;
    if (!str(v)) return this.warn(path, `${what} must be a non-empty string`);
    try {
      this.policy.checkUrl(v);
    } catch (e) {
      this.warn(path, `${what} is outside the network grant and will be hidden: ${e.message}`);
    }
  }
  num(path, v, field, { nonNegative = false } = {}) {
    if (v === undefined || v === null) return;
    if (typeof v !== 'number' || !Number.isFinite(v)) this.warn(path, `${field} must be a number (got ${JSON.stringify(v)}) — ignored`);
    else if (nonNegative && v < 0) this.warn(path, `${field} must be >= 0 — ignored`);
  }
  date(path, v, field) {
    if (v === undefined || v === null) return;
    if (typeof v !== 'string' || !DATE.test(v.trim())) this.warn(path, `${field} must be YYYY, YYYY-MM or YYYY-MM-DD — ignored`);
  }
  artists(path, v) {
    if (v === undefined) return;
    if (!Array.isArray(v)) return this.warn(path, 'artists must be an array of { id?, name }');
    v.forEach((a, i) => {
      if (!isObj(a) || !str(a.name)) this.warn(`${path}[${i}]`, 'artist ref needs a non-empty name — dropped');
      else if (a.id !== undefined && !str(a.id)) this.warn(`${path}[${i}]`, 'artist ref id must be a string — ignored');
    });
  }

  track(path, t) {
    if (!isObj(t)) return this.warn(path, 'not an object — dropped');
    if (!this.idField(path, t.id, 'id') || !this.idField(path, t.title, 'title')) return;
    this.artists(`${path}.artists`, t.artists);
    if (t.album !== undefined && !isObj(t.album)) this.warn(path, 'album must be { id?, title }');
    for (const f of ['durationMs', 'trackNo', 'discNo']) this.num(path, t[f], f);
    if (t.durationMs !== undefined && typeof t.durationMs === 'number' && t.durationMs > 0 && t.durationMs < 1000) {
      this.warn(path, `durationMs=${t.durationMs} looks like seconds; the unit is milliseconds`);
    }
    if (t.playable !== undefined && typeof t.playable !== 'boolean') this.warn(path, 'playable must be a boolean');
    if (t.mvId !== undefined && !str(t.mvId)) this.warn(path, 'mvId must be a string — ignored');
    this.url(path, t.coverUrl, 'coverUrl');
  }
  album(path, a) {
    if (!isObj(a)) return this.warn(path, 'not an object — dropped');
    if (!this.idField(path, a.id, 'id') || !this.idField(path, a.title, 'title')) return;
    this.artists(`${path}.artists`, a.artists);
    this.num(path, a.year, 'year');
    this.num(path, a.trackCount, 'trackCount', { nonNegative: true });
    this.date(path, a.releaseDate, 'releaseDate');
    this.url(path, a.coverUrl, 'coverUrl');
  }
  artist(path, a) {
    if (!isObj(a)) return this.warn(path, 'not an object — dropped');
    if (!this.idField(path, a.id, 'id') || !this.idField(path, a.name, 'name')) return;
    if (a.aliases !== undefined && !Array.isArray(a.aliases)) this.warn(path, 'aliases must be an array of strings');
    if (a.intro !== undefined && !Array.isArray(a.intro)) this.warn(path, 'intro must be an array of { title?, text }');
    if (a.stats !== undefined) {
      if (!isObj(a.stats)) this.warn(path, 'stats must be an object');
      else for (const [k, v] of Object.entries(a.stats)) this.num(`${path}.stats`, v, k, { nonNegative: true });
    }
    this.url(path, a.coverUrl, 'coverUrl');
  }
  playlist(path, p) {
    if (!isObj(p)) return this.warn(path, 'not an object — dropped');
    if (!this.idField(path, p.id, 'id') || !this.idField(path, p.title, 'title')) return;
    this.num(path, p.trackCount, 'trackCount');
    this.num(path, p.playCount, 'playCount', { nonNegative: true });
    if (p.tags !== undefined && !Array.isArray(p.tags)) this.warn(path, 'tags must be an array of strings');
    if (p.previewTracks !== undefined) {
      if (!Array.isArray(p.previewTracks)) this.warn(path, 'previewTracks must be an array');
      else if (p.previewTracks.length > 3) this.warn(path, 'previewTracks: only the first 3 are shown');
    }
    this.url(path, p.coverUrl, 'coverUrl');
  }
  mv(path, m) {
    if (!isObj(m)) return this.warn(path, 'not an object — dropped');
    if (!this.idField(path, m.id, 'id') || !this.idField(path, m.title, 'title')) return;
    this.artists(`${path}.artists`, m.artists);
    this.num(path, m.durationMs, 'durationMs', { nonNegative: true });
    this.num(path, m.playCount, 'playCount', { nonNegative: true });
    this.date(path, m.publishDate, 'publishDate');
    this.url(path, m.coverUrl, 'coverUrl');
  }
  list(path, v, kind) {
    if (v === undefined) return;
    if (!Array.isArray(v)) return this.warn(path, `must be an array of ${kind}`);
    v.forEach((x, i) => this[kind](`${path}[${i}]`, x));
  }
  page(path, v, kind) {
    if (!isObj(v)) return this.error(path, 'must return an object { items, hasMore, total? }');
    if (!Array.isArray(v.items)) return this.error(path, 'missing "items" array');
    this.list(`${path}.items`, v.items, kind);
    if (typeof v.hasMore !== 'boolean') this.warn(path, 'hasMore should be a boolean (anything but true means "no more pages")');
    this.num(path, v.total, 'total');
  }
  mediaStream(path, s) {
    if (!isObj(s) || !str(s.url)) return this.error(path, 'must return an object with a non-empty "url" (throw an Error if not playable)');
    try {
      this.policy.checkUrl(s.url);
    } catch (e) {
      this.error(path, `url is not playable by the host: ${e.message}`);
    }
    if (s.headers !== undefined) {
      if (!isObj(s.headers)) this.error(path, 'headers must be an object of strings');
      else {
        const keys = Object.keys(s.headers);
        if (keys.length > 16) this.error(path, 'more than 16 media headers');
        for (const k of keys) {
          if (!MEDIA_HEADER_ALLOWLIST.includes(k.toLowerCase())) this.error(path, `media header "${k}" is not allowed (allowed: ${MEDIA_HEADER_ALLOWLIST.join(', ')})`);
          const v = s.headers[k];
          if (typeof v !== 'string') this.warn(path, `header ${k} is not a string — dropped`);
          else if (v.length > 8192 || /[\r\n\0]/.test(v)) this.error(path, `header ${k} has an invalid value`);
        }
      }
    }
    this.num(path, s.expiresAt, 'expiresAt');
    if (typeof s.expiresAt === 'number' && s.expiresAt > 0 && s.expiresAt < 1e11) this.warn(path, 'expiresAt looks like seconds; the unit is epoch milliseconds');
  }
  lyricText(path, l) {
    if (l === undefined || l === null) return false;
    if (!isObj(l)) return this.warn(path, 'must be { format, text, language? }'), false;
    if (!LYRIC_FORMATS.includes(l.format)) return this.warn(path, `format must be one of ${LYRIC_FORMATS.join(', ')} — ignored`), false;
    if (!str(l.text) || l.text.trim() === '') return this.warn(path, 'empty text — ignored'), false;
    return true;
  }
  challenge(path, c) {
    if (!isObj(c)) return this.error(path, 'login must return a Challenge object');
    if (!['pending', 'done', 'failed'].includes(c.state)) this.warn(path, 'state must be pending | done | failed');
    if (c.pollMs !== undefined && (typeof c.pollMs !== 'number' || c.pollMs < 500 || c.pollMs > 10000)) this.warn(path, 'pollMs must be 500..10000');
    if (c.appUrl !== undefined) {
      const scheme = String(c.appUrl).split(':')[0].toLowerCase();
      if (scheme === 'https') this.url(path, c.appUrl, 'appUrl');
      else if (!APP_URL_SCHEMES.includes(scheme)) this.warn(path, `appUrl scheme "${scheme}" is not allowed — dropped`);
    }
    if (c.state === 'done' && !isObj(c.account)) this.warn(path, 'state=done should carry the Account');
    if (c.web !== undefined) {
      if (!isObj(c.web) || !str(c.web.url) || !str(c.web.cookieUrl) || !str(c.web.doneCookie)) this.error(path, 'web needs url, cookieUrl and doneCookie');
      else {
        this.url(`${path}.web`, c.web.url, 'web.url');
        this.url(`${path}.web`, c.web.cookieUrl, 'web.cookieUrl');
      }
    }
  }
}

/// Validates the return value of [method] called with [args].
export function validateResult(method, args, value, policy) {
  const r = new Report(policy);
  const p = method;
  const obj = (v) => {
    if (isObj(v)) return true;
    r.error(p, 'must return an object');
    return false;
  };
  switch (method) {
    case 'search': {
      const kind = { song: 'track', album: 'album', artist: 'artist', playlist: 'playlist' }[args?.type] ?? 'track';
      r.page(p, value, kind);
      break;
    }
    case 'album':
      if (!obj(value)) break;
      if (!isObj(value.album)) r.error(p, 'missing "album"');
      else r.album(`${p}.album`, value.album);
      r.list(`${p}.tracks`, value.tracks, 'track');
      break;
    case 'playlist':
      if (!obj(value)) break;
      if (!isObj(value.playlist)) r.error(p, 'missing "playlist"');
      else r.playlist(`${p}.playlist`, value.playlist);
      r.list(`${p}.tracks`, value.tracks, 'track');
      break;
    case 'artist':
      if (!obj(value)) break;
      if (!isObj(value.artist)) r.error(p, 'missing "artist"');
      else r.artist(`${p}.artist`, value.artist);
      r.list(`${p}.albums`, value.albums, 'album');
      r.list(`${p}.tracks`, value.tracks, 'track');
      break;
    case 'artistAlbums':
      r.page(p, value, 'album');
      break;
    case 'artistMvs':
      r.page(p, value, 'mv');
      break;
    case 'library':
      r.page(p, value, 'playlist');
      break;
    case 'stream':
    case 'mvStream':
      r.mediaStream(p, value);
      if (method === 'stream' && isObj(value?.trial) && typeof value.trial.endMs !== 'number') r.warn(p, 'trial needs startMs / endMs numbers');
      break;
    case 'searchBest':
      if (value === null) break;
      if (!obj(value)) break;
      if (value.artist !== undefined) r.artist(`${p}.artist`, value.artist);
      if (value.playlist !== undefined) r.playlist(`${p}.playlist`, value.playlist);
      if (value.album !== undefined) r.album(`${p}.album`, value.album);
      break;
    case 'lyrics':
      if (value === null) break;
      if (!obj(value)) break;
      if (!r.lyricText(`${p}.original`, value.original)) r.warn(p, 'no usable "original" — the host treats this as "no lyrics" (return null instead)');
      r.lyricText(`${p}.translation`, value.translation);
      r.lyricText(`${p}.romanization`, value.romanization);
      break;
    case 'home': {
      if (!obj(value)) break;
      if (!Array.isArray(value.sections)) {
        r.error(p, 'missing "sections" array');
        break;
      }
      if (value.sections.length > 12) r.warn(p, 'only the first 12 sections are shown');
      value.sections.forEach((s, i) => {
        const sp = `${p}.sections[${i}]`;
        if (!isObj(s) || !str(s.id) || !str(s.title)) return r.warn(sp, 'section needs string id and title — dropped');
        const kind = { tracks: 'track', playlists: 'playlist', albums: 'album' }[s.kind];
        if (!kind) return r.warn(sp, 'kind must be tracks | playlists | albums — dropped');
        if (!Array.isArray(s.items) || s.items.length === 0) return r.warn(sp, 'empty section — not shown');
        if (s.items.length > 50) r.warn(sp, 'only the first 50 items are shown');
        r.list(`${sp}.items`, s.items, kind);
      });
      break;
    }
    case 'account':
      if (!obj(value)) break;
      if (typeof value.loggedIn !== 'boolean') r.warn(p, 'loggedIn must be a boolean (anything but true = logged out)');
      r.url(p, value.avatarUrl, 'avatarUrl');
      break;
    case 'like':
      if (args?.op === 'list') {
        if (value === null) break;
        if (!isObj(value) || !Array.isArray(value.ids)) r.error(p, 'list must return { ids: [...], playlist? } or null');
        else if (value.playlist !== undefined) r.playlist(`${p}.playlist`, value.playlist);
      }
      break;
    case 'login':
      if (args?.op === 'methods') {
        if (!obj(value)) break;
        if (!Array.isArray(value.methods) || value.methods.length === 0) r.error(p, 'methods must be a non-empty array');
        else
          value.methods.forEach((m, i) => {
            if (!isObj(m) || !str(m.id) || !str(m.label) || !['qr', 'form', 'web'].includes(m.type)) {
              r.warn(`${p}.methods[${i}]`, 'needs id, label and type qr | form | web — dropped');
            }
          });
      } else if (args?.op !== 'logout') r.challenge(p, value);
      break;
  }
  return r;
}
