// Type definitions for Fushi music source plugins (plugin API 1).
// Reference from plain JS with:  /// <reference path="./fushi-plugin.d.ts" />  and JSDoc annotations,
// e.g.  /** @type {Fushi.Plugin['search']} */ module.exports.search = async (args) => { ... };
// Full contract: GUIDE.md.

declare namespace Fushi {
  // ---------- Entities (all ids are strings you define; the host treats them as opaque keys) ----------

  interface ArtistRef {
    id?: string;
    name: string;
  }

  interface Track {
    id: string;
    title: string;
    artists?: ArtistRef[];
    album?: { id?: string; title?: string };
    /** Milliseconds. */
    durationMs?: number;
    coverUrl?: string;
    trackNo?: number;
    discNo?: number;
    isrc?: string;
    /** Default true. false = shown greyed out, never streamed. */
    playable?: boolean;
    /** Short badge, e.g. "VIP". */
    note?: string;
    /** This song's music video; used only when the plugin declares `mvStream`. */
    mvId?: string;
  }

  interface Album {
    id: string;
    title: string;
    artists?: ArtistRef[];
    coverUrl?: string;
    year?: number;
    trackCount?: number;
    releaseDate?: string; // 'YYYY' | 'YYYY-MM' | 'YYYY-MM-DD'
    company?: string;
    description?: string;
  }

  interface Artist {
    id: string;
    name: string;
    coverUrl?: string;
    /** Aliases / translated names (max 10 shown). */
    aliases?: string[];
    description?: string;
    intro?: { title?: string; text: string }[];
    stats?: { trackCount?: number; albumCount?: number; mvCount?: number; fanCount?: number };
  }

  interface Playlist {
    id: string;
    title: string;
    coverUrl?: string;
    trackCount?: number;
    owner?: string;
    description?: string;
    playCount?: number;
    tags?: string[];
    /** Text-only preview on the card (e.g. top 3 of a chart). First 3 used; coverUrl ignored. */
    previewTracks?: Track[];
  }

  interface Mv {
    id: string;
    title: string;
    artists?: ArtistRef[];
    /** 16:9. */
    coverUrl?: string;
    durationMs?: number;
    playCount?: number;
    publishDate?: string; // 'YYYY-MM-DD'
  }

  /** Allowed header names (case-insensitive): user-agent, referer, origin, cookie, authorization, accept, accept-language. */
  type MediaHeaders = { [name: string]: string };

  interface Stream {
    /** Must be inside network.domains (every redirect hop too). */
    url: string;
    headers?: MediaHeaders;
    /** Epoch milliseconds after which the URL stops working; the host re-asks on reopen. */
    expiresAt?: number;
    codec?: string;
    bitrateKbps?: number;
    sampleRate?: number;
    bitDepth?: number;
    sizeBytes?: number;
    /** Only a preview clip is available. */
    trial?: { startMs: number; endMs: number };
  }

  interface MvStream {
    url: string;
    headers?: MediaHeaders;
    expiresAt?: number;
    width?: number;
    height?: number;
  }

  type LyricFormat = 'yrc' | 'lrc' | 'ttml' | 'qrc' | 'krc' | 'txt';

  interface LyricText {
    format: LyricFormat;
    text: string;
    /** BCP 47, e.g. 'ja', 'zh-Hans'. */
    language?: string;
  }

  interface Lyrics {
    original: LyricText;
    translation?: LyricText;
    /** Accepted but not used by API 1. */
    romanization?: LyricText;
  }

  /** One `lyricsSearch` hit. Entries without `title` / `ref` are dropped; the host keeps the first 20. */
  interface LyricsCandidate {
    title: string;
    artist?: string;
    durationMs?: number;
    /** Your own opaque JSON (id, mid, id + accesskey, ...), at most 2 KiB serialized; passed back verbatim to `lyricsFetch`. */
    ref: unknown;
  }

  type Section =
    | { id: string; title: string; subtitle?: string; kind: 'tracks'; items: Track[] }
    | { id: string; title: string; subtitle?: string; kind: 'playlists'; items: Playlist[] }
    | { id: string; title: string; subtitle?: string; kind: 'albums'; items: Album[] };

  interface Page<T> {
    items: T[];
    /** Only `true` loads another page. */
    hasMore: boolean;
    total?: number;
  }

  interface Account {
    loggedIn: boolean;
    name?: string;
    avatarUrl?: string;
    /** e.g. "VIP". */
    badge?: string;
  }

  type Platform = 'windows' | 'macos' | 'linux' | 'android';
  type Quality = 'standard' | 'high' | 'lossless' | 'hires';
  type SearchType = 'song' | 'album' | 'artist' | 'playlist';

  interface LoginMethod {
    id: string;
    type: 'qr' | 'form' | 'web';
    label: string;
    description?: string;
  }

  interface Challenge {
    state: 'pending' | 'done' | 'failed';
    /** Opaque; the host passes it back on poll / submit. */
    session?: string;
    /** Status text shown to the user. */
    message?: string;
    qr?: { content?: string; imageBase64?: string; scanned?: boolean };
    /** 500..10000; poll interval for qr. */
    pollMs?: number;
    /** https inside network.domains, or an official app scheme (orpheus, qqmusic, mqqapi, wtloginmqq, kugou, kuwo, migu, snssdk1128). */
    appUrl?: string;
    form?: {
      fields: { id: string; label: string; secret?: boolean; placeholder?: string; multiline?: boolean; value?: string }[];
      actions: { id: string; label: string; primary?: boolean }[];
    };
    /** Needs the webAuth permission. */
    web?: { url: string; cookieUrl: string; doneCookie: string };
    /** Set when state = 'done'. */
    account?: Account;
  }

  type LoginArgs =
    | { op: 'methods'; platform: Platform }
    | { op: 'begin'; method: string; platform: Platform }
    | { op: 'poll'; method: string; session?: string; platform: Platform }
    | { op: 'submit'; method: string; session?: string; platform: Platform; action: string; inputs: { [fieldId: string]: string } }
    | { op: 'logout' };

  // ---------- Capabilities: export these from the entry module (module.exports.<name>) ----------

  type Awaitable<T> = T | Promise<T>;

  interface Plugin {
    search(args: { query: string; type: SearchType; page: number; pageSize: number }): Awaitable<Page<Track | Album | Artist | Playlist>>;
    searchBest(args: { query: string }): Awaitable<{ artist?: Artist; playlist?: Playlist; album?: Album } | null>;
    album(args: { id: string }): Awaitable<{ album: Album; tracks: Track[] }>;
    playlist(args: { id: string }): Awaitable<{ playlist: Playlist; tracks: Track[] }>;
    artist(args: { id: string }): Awaitable<{ artist: Artist; albums?: Album[]; tracks?: Track[] }>;
    artistAlbums(args: { id: string; page: number; pageSize: number }): Awaitable<Page<Album>>;
    artistMvs(args: { id: string; page: number; pageSize: number }): Awaitable<Page<Mv>>;
    /** Throw an Error (message shown to the user) when not playable. */
    stream(args: { id: string; quality: Quality }): Awaitable<Stream>;
    mvStream(args: { id: string; quality: Quality }): Awaitable<MvStream>;
    lyrics(args: { id: string }): Awaitable<Lyrics | null>;
    /**
     * Lyrics source for any track (local / media server): search candidates by title + artist.
     * Declare together with `lyricsFetch`; a lyrics-only plugin declares just these two.
     * The host calls it with several `query` variants per track, so do not retry with fallbacks yourself.
     * Empty `items` = nothing found; throwing = this source failed.
     */
    lyricsSearch(args: { query: string; title: string; artist?: string; album?: string; durationMs?: number }): Awaitable<{ items: LyricsCandidate[] } | null>;
    /** Lyrics for the `ref` of the candidate the host picked from `lyricsSearch`; null = no usable lyrics. */
    lyricsFetch(args: { ref: unknown }): Awaitable<Lyrics | null>;
    /** refresh = the user pressed "refresh"; swap replaceable sections. */
    home(args: { refresh?: boolean }): Awaitable<{ sections: Section[] }>;
    library(args: { page: number; pageSize: number }): Awaitable<Page<Playlist>>;
    like(args: { op: 'list' }): Awaitable<{ ids: string[]; playlist?: Playlist } | null>;
    like(args: { op: 'set'; id: string; liked: boolean }): Awaitable<null>;
    account(args: {}): Awaitable<Account>;
    login(args: LoginArgs): Awaitable<{ methods: LoginMethod[] } | Challenge | null>;
  }

  // ---------- Host API (global `fushi`) ----------

  type Bytes = Uint8Array | string;

  interface HttpRequest {
    /** https:// inside network.domains (http:// needs insecureHttp). */
    url: string;
    /** Must be listed in network.methods (default only GET). */
    method?: 'GET' | 'POST' | 'HEAD' | 'PUT' | 'DELETE' | 'PATCH';
    headers?: { [name: string]: string };
    body?: string;
    bodyBytes?: Uint8Array;
    /** 1000..60000, default 20000. */
    timeoutMs?: number;
    responseType?: 'text' | 'json' | 'bytes';
  }

  interface HttpResponse {
    /** Non-2xx does NOT reject; check it yourself. */
    status: number;
    /** Final URL after redirects. */
    url: string;
    /** Lowercase names; repeated headers joined with ', '. */
    headers: { [name: string]: string };
    /** Raw Set-Cookie values, one per cookie. */
    setCookies: string[];
    text?: string;
    json?: any;
    bytes?: Uint8Array;
  }

  interface KeyValueStore {
    get(key: string): Promise<string | null>;
    set(key: string, value: string): Promise<null>;
    remove(key: string): Promise<null>;
  }

  interface Host {
    readonly host: { readonly api: number; readonly name: 'fushi' };
    readonly http: { request(req: HttpRequest): Promise<HttpResponse> };
    /** Needs the storage permission. Values up to 1 MiB. */
    readonly storage: KeyValueStore;
    /** Needs the credentials permission. Encrypted at rest, values up to 64 KiB, at most 64 keys. */
    readonly credentials: KeyValueStore;
    readonly crypto: {
      md5(data: Bytes): Uint8Array;
      sha1(data: Bytes): Uint8Array;
      sha256(data: Bytes): Uint8Array;
      hmac(alg: 'sha256' | 'sha1' | 'md5', key: Bytes, data: Bytes): Uint8Array;
      aes(opts: { mode: 'cbc' | 'ecb'; key: Bytes; iv?: Bytes; data: Bytes; decrypt?: boolean; padding?: 'pkcs7' | 'none' }): Uint8Array;
      /** Unpadded RSA (data^e mod n), left-padded to the modulus length. */
      rsaRaw(opts: { modulus: string; exponent: string; data: Bytes }): Uint8Array;
      /** 0..4096 bytes. */
      randomBytes(n: number): Uint8Array;
    };
    readonly encoding: {
      utf8Encode(s: string): Uint8Array;
      utf8Decode(b: Bytes): string;
      base64Encode(b: Bytes): string;
      base64Decode(s: string): Uint8Array;
      hexEncode(b: Bytes): string;
      hexDecode(s: string): Uint8Array;
    };
    log(...args: any[]): void;
  }
}

declare const fushi: Fushi.Host;
declare const console: {
  log(...args: any[]): void;
  info(...args: any[]): void;
  debug(...args: any[]): void;
  warn(...args: any[]): void;
  error(...args: any[]): void;
};
/** Only relative paths to .js files inside the plugin ('./util', '../lib/x.js'). */
declare function require(path: string): any;
declare const module: { exports: Partial<Fushi.Plugin> & { [k: string]: any } };
declare const exports: Partial<Fushi.Plugin> & { [k: string]: any };
