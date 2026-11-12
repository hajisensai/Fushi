// Type definitions for Fushi tracking site plugins (plugin API 1, manifest "kind": "tracking").
// Reference from plain JS with:  /// <reference path="./fushi-tracking-plugin.d.ts" />  and JSDoc annotations,
// e.g.  /** @type {FushiTracking.Plugin['trackingSubject']} */ async function trackingSubject(args) { ... }
// Full contract: GUIDE.md.
//
// The runtime globals (`fushi`, `console`, `require`, `module`) are the same as for music plugins (same
// sandbox engine). They are repeated here instead of referencing the music kit's typings, because those
// declare `module.exports` as a music plugin and would not combine with this file.

declare namespace FushiTracking {
  // ---------- Manifest ----------

  type Capability = 'login' | 'account' | 'trackingEntry' | 'trackingSubject' | 'trackingSearch' | 'trackingLookup' | 'trackingList';
  type Permission = 'network' | 'storage' | 'credentials';
  /** 'game' only together with the mode 'status'. */
  type Kind = 'anime' | 'manga' | 'novel' | 'game';
  /** 'status' (games: the user's play status, no progress) only together with the kind 'game'. */
  type Mode = 'episode' | 'chapter' | 'volume' | 'status';
  type HttpMethod = 'GET' | 'POST' | 'HEAD' | 'PUT' | 'DELETE' | 'PATCH';

  interface Manifest {
    schema: 1;
    kind: 'tracking';
    /** 2-64 chars of a-z 0-9 . _ -; the install identity, never change it. */
    id: string;
    name: string;
    /** X.Y.Z */
    version: string;
    api: 1;
    entry: string;
    author?: string;
    description?: string;
    homepage?: string;
    /** Must contain login, account, trackingEntry, trackingSubject. */
    capabilities: Capability[];
    /** Must contain network and credentials. */
    permissions: Permission[];
    network: { domains: string[]; methods?: HttpMethod[] };
    /** Absent or empty. */
    searchTypes?: [];
    tracking: {
      /** [a-z0-9]{2,32}: the provider id stored with every link. */
      siteId: string;
      /** Plain host name, used to recognize a pasted link. */
      siteHost: string;
      kinds: Kind[];
      /** Subset of kinds, switched on by default. */
      defaultKinds?: Kind[];
      modes: Mode[];
      /** 1..600; the host spaces your HTTP requests to stay under it. */
      requestsPerMinute: number;
      /**
       * Optional web page of a subject, for "Open on site": https, host = siteHost or a subdomain, with `{id}`
       * and optionally `{kind}` (e.g. "https://example.org/subject/{id}"). Or one template per kind
       * (`{ anime: "https://example.org/anime/{id}", novel: "https://example.org/manga/{id}" }`): keys must be
       * in `kinds`, each value follows the same rule, and a kind left out has no page address.
       */
      subjectUrl?: string | Partial<Record<Kind, string>>;
    };
  }

  // ---------- Entities ----------

  interface Subject {
    /** Positive integer, the site's id for the work. */
    id: number;
    /** Trimmed, cut to 500 characters. */
    name: string;
    kind: Kind;
    /** Every known title in any script; first 50 kept, each cut to 500 characters. */
    titles?: string[];
    /** First 20 kept. */
    authors?: string[];
    totalEpisodes?: number;
    totalChapters?: number;
    finalVolume?: number;
    /** The work itself is complete. */
    finished?: boolean;
    /**
     * Manga / novels: the subject is one book (a volume, or a work of at most one volume), so finishing Fushi's
     * item finishes it even without a chapter total.
     */
    singleVolume?: boolean;
    /** Ids of the same work elsewhere: "mal" or another site's siteId → positive integer (16 kept). */
    linkedIds?: { [idType: string]: number };
  }

  type Status = 'planned' | 'current' | 'completed' | 'paused' | 'dropped' | 'repeating';

  interface Entry {
    status: Status;
    /**
     * Episodes for anime, chapters for manga and novels. A site without chapter counts returns 0 and uses
     * `progressVolume`. An entry whose status or counts the host cannot read is left alone (nothing is written).
     */
    progress: number;
    /** Volumes. */
    progressVolume?: number;
  }

  interface Account {
    loggedIn: boolean;
    name?: string;
  }

  /** One entry of the user's list (trackingList). */
  interface ListItem {
    subject: Subject;
    status: Status;
    progress: number;
    progressVolume?: number;
    /** ISO 8601. */
    updatedAt?: string;
  }

  type Platform = 'windows' | 'macos' | 'linux' | 'android';

  interface LoginMethod {
    id: string;
    /** The tracking host renders only 'form' in v1. */
    type: 'form';
    label: string;
    description?: string;
  }

  interface FormField {
    id: string;
    label: string;
    secret?: boolean;
    placeholder?: string;
    multiline?: boolean;
    /** Prefilled value. */
    value?: string;
  }

  interface Challenge {
    state: 'pending' | 'done' | 'failed';
    /** Opaque; passed back on submit. */
    session?: string;
    /** Status / help text shown to the user. */
    message?: string;
    /** https link inside network.domains, shown as an "Open site" button (e.g. the token page). */
    appUrl?: string;
    /** Required while pending. */
    form?: { fields: FormField[]; actions: { id: string; label: string; primary?: boolean }[] };
    /** With state 'done'. */
    account?: Account;
  }

  type LoginArgs =
    | { op: 'methods'; platform: Platform }
    | { op: 'begin'; method: string; platform: Platform }
    | { op: 'submit'; method: string; session?: string; platform: Platform; action: string; inputs: { [fieldId: string]: string } }
    | { op: 'logout' }
    /**
     * Bundled plugin only: the host moves a sign-in Fushi saved before the plugin existed. Store it without a
     * network check (works offline) and return { state: 'done', account }.
     */
    | { op: 'import'; inputs: { [fieldId: string]: string } };

  type EntryArgs =
    /** `kind` is always sent: the kind of Fushi's item (matters for sites whose ids are per list). */
    | { op: 'get'; id: number; kind: Kind }
    /**
     * `create: true` = the host saw no entry: create it, or update it if one appeared meanwhile.
     * `create: false` and the entry is gone: throw `not_found:`. Only the given fields change.
     */
    | { op: 'set'; id: number; kind: Kind; create: boolean; status: Status; progress?: number; progressVolume?: number };
  // A 'game' entry: `get` returns { status, progress: 0 }; `set` carries only the status (the user's choice).

  // ---------- Capabilities: export these from the entry module (module.exports.<name>) ----------
  // Errors: throw new Error('unauthorized: ...' | 'rate_limited: ...' | 'not_found: ...'); anything else is
  // treated as temporary and retried later. The rest of the message is shown to the user.

  type Awaitable<T> = T | Promise<T>;

  interface Plugin {
    account(args: {}): Awaitable<Account>;
    login(args: LoginArgs): Awaitable<{ methods: LoginMethod[] } | Challenge | null>;
    /** get → the user's entry or null (not on the list). set → null; change only the given fields. */
    trackingEntry(args: EntryArgs): Awaitable<Entry | null>;
    /** null = no such subject. `kind` is sent when the host knows which kind it expects: return null when the subject is of another kind. */
    trackingSubject(args: { id: number; kind?: Kind }): Awaitable<Subject | null>;
    /** The host uses the first 20 items. */
    trackingSearch(args: { query: string; kind: Kind }): Awaitable<{ items: Subject[] }>;
    /** Subjects on this site for an id in another id space ("mal" or another site's siteId). The host uses the first 20 items. */
    trackingLookup(args: { idType: string; id: number; kind?: Kind }): Awaitable<{ items: Subject[] }>;
    /** The user's list of `kind` with `status`, one page from `offset` (0, then the previous `next`). No `next` = last page. The host reads at most 40 pages / 2000 items. */
    trackingList(args: { kind: Kind; status: Status; offset: number }): Awaitable<{ items: ListItem[]; next?: number }>;
  }

  // ---------- Host API (global `fushi`), same as for music plugins ----------

  type Bytes = Uint8Array | string;

  interface HttpRequest {
    /** https:// inside network.domains. */
    url: string;
    /** Must be listed in network.methods (default only GET). */
    method?: HttpMethod;
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

declare const fushi: FushiTracking.Host;
declare const console: {
  log(...args: any[]): void;
  info(...args: any[]): void;
  debug(...args: any[]): void;
  warn(...args: any[]): void;
  error(...args: any[]): void;
};
/** Only relative paths to .js files inside the plugin ('./util', '../lib/x.js'). */
declare function require(path: string): any;
declare const module: { exports: Partial<FushiTracking.Plugin> & { [k: string]: any } };
declare const exports: Partial<FushiTracking.Plugin> & { [k: string]: any };
