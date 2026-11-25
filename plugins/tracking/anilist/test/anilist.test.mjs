// AniList plugin tests: the kit's harness (real sandbox runner, HTTP from the hand-written fixtures below,
// shaped like AniList GraphQL answers). No network, no token. Run: node --test plugins/tracking/anilist/test/
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHarness, json } from '../../../../tools/tracking-plugin-sdk/lib/harness.mjs';

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = 'https://graphql.anilist.co';
const SIGNED_IN = { token: 'tok', name: 'Alice', clientId: '777' };

const FRIEREN = {
  id: 154587,
  idMal: 52991,
  type: 'ANIME',
  format: 'TV',
  status: 'FINISHED',
  episodes: 28,
  chapters: null,
  volumes: null,
  title: { romaji: 'Sousou no Frieren', english: "Frieren: Beyond Journey's End", native: '葬送のフリーレン' },
  synonyms: ['Sousou no Frieren', 'Frieren'],
};
const AJIN = {
  id: 30001,
  idMal: 0,
  type: 'MANGA',
  format: 'MANGA',
  status: 'FINISHED',
  episodes: null,
  chapters: 86,
  volumes: 17,
  title: { romaji: 'Ajin', english: 'Ajin', native: '亜人' },
  synonyms: [],
};
const KINO = { ...AJIN, id: 30002, format: 'NOVEL', status: 'RELEASING', chapters: 0, volumes: 23, title: { romaji: 'Kino no Tabi' } };
const MUSIC = { ...AJIN, id: 30003, format: 'MUSIC' };

/** Answers every GraphQL request with [route(request)]. */
function harness(route, credentials = SIGNED_IN) {
  return createHarness(DIR, { routes: [['POST', `${API}/`, route]], credentials: { ...credentials } });
}

const data = (d) => json(200, { data: d });

async function rejects(promise, prefix) {
  await assert.rejects(promise, (e) => {
    assert.match(String(e.message), new RegExp(`(^|: )${prefix}`));
    return true;
  });
}

const submit = (action, inputs) => ({ op: 'submit', method: 'token', platform: 'windows', action, inputs });

test('sign in: no client id is shipped; the user enters one, then pastes the token', async () => {
  const h = harness(() => data({ Viewer: { id: 1, name: 'Alice' } }), {});
  const methods = (await h.call('login', { op: 'methods', platform: 'windows' })).value;
  assert.equal(methods.methods[0].type, 'form');
  const begin = (await h.call('login', { op: 'begin', method: 'token', platform: 'windows' })).value;
  assert.equal(begin.appUrl, 'https://anilist.co/settings/developer');
  assert.equal(begin.form.fields[0].id, 'clientId');
  assert.equal(begin.form.fields[0].value, '');
  assert.match(begin.message, /oauth\/pin/);

  const bad = (await h.call('login', submit('continue', { clientId: 'abc' }))).value;
  assert.equal(bad.state, 'pending');
  assert.equal(bad.form.fields[0].id, 'clientId');
  assert.equal(h.credentials.get('clientId'), null);

  const step2 = (await h.call('login', submit('continue', { clientId: ' 777 ' }))).value;
  assert.equal(step2.appUrl, 'https://anilist.co/api/v2/oauth/authorize?client_id=777&response_type=token');
  assert.equal(step2.form.fields[0].id, 'token');
  assert.equal(h.requests.length, 0);

  const done = (await h.call('login', submit('save', { token: ' tok ' }))).value;
  assert.deepEqual(done, { state: 'done', account: { loggedIn: true, name: 'Alice' } });
  assert.equal(h.requests[0].headers.Authorization, 'Bearer tok');
  assert.deepEqual(h.credentials.data, { clientId: '777', token: 'tok', name: 'Alice' });
  assert.deepEqual((await h.call('account')).value, { loggedIn: true, name: 'Alice' });

  // Signing out keeps the client id for the next sign-in.
  await h.call('login', { op: 'logout' });
  assert.deepEqual(h.credentials.data, { clientId: '777' });
  assert.deepEqual((await h.call('account')).value, { loggedIn: false });
  const again = (await h.call('login', { op: 'begin', method: 'token', platform: 'windows' })).value;
  assert.equal(again.form.fields[0].value, '777');
});

test('a rejected token keeps the token form; nothing stored', async () => {
  const h = harness(() => json(401, { errors: [{ message: 'Invalid token', status: 401 }], data: null }), {
    clientId: '777',
  });
  const r = (await h.call('login', submit('save', { token: 'x' }))).value;
  assert.equal(r.state, 'pending');
  assert.equal(r.form.fields[0].id, 'token');
  assert.match(r.message, /did not accept/);
  assert.deepEqual(h.credentials.data, { clientId: '777' });
});

test('"Change client ID" goes back to the first step; a token without a client id asks for one', async () => {
  const h = harness(() => data({}), { clientId: '777' });
  const back = (await h.call('login', submit('client', {}))).value;
  assert.equal(back.form.fields[0].id, 'clientId');
  assert.equal(back.form.fields[0].value, '777');
  const none = harness(() => data({}), {});
  const ask = (await none.call('login', submit('save', { token: 'tok' }))).value;
  assert.equal(ask.form.fields[0].id, 'clientId');
  assert.equal(none.requests.length, 0);
});

test('subjects: anime episodes, manga chapters and volumes, novels; other formats are not subjects', async () => {
  const byId = { [FRIEREN.id]: FRIEREN, [AJIN.id]: AJIN, [KINO.id]: KINO, [MUSIC.id]: MUSIC };
  const h = harness((req) => data({ Media: byId[req.json.variables.id] ?? null }));
  assert.deepEqual((await h.call('trackingSubject', { id: FRIEREN.id, kind: 'anime' })).value, {
    id: FRIEREN.id,
    name: 'Sousou no Frieren',
    kind: 'anime',
    titles: ['Sousou no Frieren', "Frieren: Beyond Journey's End", '葬送のフリーレン', 'Frieren'],
    finished: true,
    totalEpisodes: 28,
    linkedIds: { mal: 52991 },
  });
  assert.equal(h.requests[0].json.variables.type, 'ANIME');
  assert.equal(h.requests[0].headers.Authorization, 'Bearer tok');
  const ajin = (await h.call('trackingSubject', { id: AJIN.id, kind: 'manga' })).value;
  assert.equal(ajin.totalChapters, 86);
  assert.equal(ajin.finalVolume, 17);
  assert.equal(ajin.linkedIds, undefined);
  const kino = (await h.call('trackingSubject', { id: KINO.id, kind: 'novel' })).value;
  assert.equal(kino.kind, 'novel');
  assert.equal(kino.totalChapters, undefined);
  assert.equal(kino.finished, false);
  // A novel asked as manga is "not this"; a MANGA-side format without a Fushi kind is no subject.
  assert.equal((await h.call('trackingSubject', { id: KINO.id, kind: 'manga' })).value, null);
  assert.equal((await h.call('trackingSubject', { id: MUSIC.id, kind: 'manga' })).value, null);
});

test('a missing subject is null; no kind sends no type (nulls are dropped)', async () => {
  const h = harness(() => json(404, { errors: [{ message: 'Not Found.', status: 404 }], data: null }));
  assert.equal((await h.call('trackingSubject', { id: 9 })).value, null);
  assert.deepEqual(h.requests[0].json.variables, { id: 9 });
});

test('search: manga and novels filter by format, anime by type only', async () => {
  const h = harness(() => data({ Page: { media: [AJIN, KINO, MUSIC, null] } }));
  const manga = (await h.call('trackingSearch', { query: ' ajin ', kind: 'manga' })).value;
  assert.deepEqual(manga.items.map((s) => s.id), [AJIN.id]);
  assert.deepEqual(h.requests[0].json.variables, { search: 'ajin', type: 'MANGA', formats: ['MANGA', 'ONE_SHOT'] });
  await h.call('trackingSearch', { query: 'kino', kind: 'novel' });
  assert.deepEqual(h.requests[1].json.variables.formats, ['NOVEL']);
  await h.call('trackingSearch', { query: 'frieren', kind: 'anime' });
  assert.deepEqual(h.requests[2].json.variables, { search: 'frieren', type: 'ANIME' });
  assert.match(h.requests[2].json.query, /perPage: 20/);
  assert.equal(h.requests.length, 3);
});

test('lookup: only MAL ids, narrowed by kind', async () => {
  const h = harness(() => data({ Page: { media: [FRIEREN] } }));
  const r = (await h.call('trackingLookup', { idType: 'mal', id: 52991, kind: 'anime' })).value;
  assert.deepEqual(r.items.map((s) => s.id), [FRIEREN.id]);
  assert.deepEqual(h.requests[0].json.variables, { idMal: 52991, type: 'ANIME' });
  assert.deepEqual((await h.call('trackingLookup', { idType: 'mangabaka', id: 1, kind: 'anime' })).value, { items: [] });
  assert.equal(h.requests.length, 1);
});

test('entry get: status, progress and volumes; not on the list is null', async () => {
  const entries = {
    1: { id: 1, type: 'MANGA', format: 'MANGA', mediaListEntry: { status: 'PAUSED', progress: 12, progressVolumes: 2 } },
    2: { id: 2, type: 'ANIME', format: 'TV', mediaListEntry: null },
    3: { id: 3, type: 'ANIME', format: 'TV', mediaListEntry: { status: null, progress: null } },
  };
  const h = harness((req) => data({ Media: entries[req.json.variables.id] ?? null }));
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 1, kind: 'manga' })).value, {
    status: 'paused',
    progress: 12,
    progressVolume: 2,
  });
  assert.equal((await h.call('trackingEntry', { op: 'get', id: 2, kind: 'anime' })).value, null);
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 3, kind: 'anime' })).value, {
    status: 'current',
    progress: 0,
  });
  await rejects(h.call('trackingEntry', { op: 'get', id: 4, kind: 'anime' }), 'not_found');
});

test('entry set: sends exactly the given fields', async () => {
  const h = harness(() => data({ SaveMediaListEntry: { id: 5 } }));
  await h.call('trackingEntry', { op: 'set', id: 1, kind: 'anime', create: true, status: 'current', progress: 3 });
  const sent = h.requests[0].json;
  assert.deepEqual(sent.variables, { mediaId: 1, status: 'CURRENT', progress: 3 });
  assert.match(sent.query, /^mutation \(\$mediaId: Int, \$status: MediaListStatus, \$progress: Int\)/);
  await h.call('trackingEntry', { op: 'set', id: 1, kind: 'manga', create: false, status: 'completed', progressVolume: 4 });
  assert.deepEqual(h.requests[1].json.variables, { mediaId: 1, status: 'COMPLETED', progressVolumes: 4 });
});

test('errors: signed out, rejected token, rate limit, server error', async () => {
  const out = harness(() => data({}), {});
  await rejects(out.call('trackingEntry', { op: 'get', id: 1, kind: 'anime' }), 'unauthorized');
  assert.equal(out.requests.length, 0);
  await rejects(
    harness(() => json(200, { errors: [{ message: 'Invalid token', status: 400 }], data: null })).call('trackingEntry', {
      op: 'get',
      id: 1,
      kind: 'anime',
    }),
    'unauthorized',
  );
  await rejects(harness(() => json(429, {})).call('trackingSearch', { query: 'a', kind: 'anime' }), 'rate_limited');
  await assert.rejects(harness(() => json(500, 'oops')).call('trackingSearch', { query: 'a', kind: 'anime' }), /AniList error 500: HTTP 500/);
});
