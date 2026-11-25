// MangaBaka plugin tests: the kit's harness (real sandbox runner, HTTP from the hand-written fixtures below,
// shaped like MangaBaka v1 / v2 answers). No network, no token. Run: node --test plugins/tracking/mangabaka/test/
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHarness, json } from '../../../../tools/tracking-plugin-sdk/lib/harness.mjs';

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = 'https://api.mangabaka.org';
const SIGNED_IN = { token: 'mb-tok', name: 'alice' };

const AJIN = {
  id: 10,
  state: 'active',
  type: 'manga',
  title: 'Ajin',
  native_title: '亜人',
  romanized_title: 'Ajin',
  authors: [' Sakurai Gamon ', '', 3],
  total_chapters: '86',
  final_volume: '17',
  status: 'completed',
  source: { anilist: { id: 30001 }, my_anime_list: { id: '"x"' } },
};
const KINO = { id: 20, state: 'active', type: 'novel', title: 'Kino no Tabi', total_chapters: null, status: 'releasing', source: {} };
const MERGED = { id: 11, state: 'merged', merged_with: 10, type: 'manga', title: 'Ajin (dup)' };
const OTHER = { id: 30, state: 'active', type: 'other', title: 'Artbook' };
/** v2 search shape: no main title, only `titles[]`. */
const SEARCHED = {
  id: 40,
  type: 'manhwa',
  original_language: 'ko-KR',
  titles: [
    { title: 'Solo Leveling', language: 'en', is_primary: false },
    { title: '나 혼자만 레벨업', language: 'ko', is_primary: true },
    { title: 'Ore dake Level Up na Ken', language: 'ja-ro' },
  ],
};

const data = (d) => json(200, { status: 200, data: d });
const missing = () => json(404, { status: 404, message: 'Not found' });

function harness(routes = [], credentials = SIGNED_IN) {
  return createHarness(DIR, { routes, credentials: { ...credentials } });
}

async function rejects(promise, prefix) {
  await assert.rejects(promise, (e) => {
    assert.match(String(e.message), new RegExp(`(^|: )${prefix}`));
    return true;
  });
}

const submit = (inputs) => ({ op: 'submit', method: 'token', platform: 'windows', action: 'save', inputs });

test('sign in with a personal access token: checks the profile, stores token and name', async () => {
  const h = harness([['GET', `${API}/v1/my/profile`, data({ id: 'u1', preferred_username: ' alice ', nickname: 'A' })]], {});
  const begin = (await h.call('login', { op: 'begin', method: 'token', platform: 'windows' })).value;
  assert.equal(begin.appUrl, 'https://mangabaka.org/my/settings/api-and-apps');
  const done = (await h.call('login', submit({ token: ' mb-tok ' }))).value;
  assert.deepEqual(done, { state: 'done', account: { loggedIn: true, name: 'alice' } });
  assert.equal(h.requests[0].headers['x-api-key'], 'mb-tok');
  assert.match(h.requests[0].headers['User-Agent'], /Fushi/);
  assert.deepEqual(h.credentials.data, { token: 'mb-tok', name: 'alice' });
  await h.call('login', { op: 'logout' });
  assert.deepEqual(h.credentials.data, {});
  assert.deepEqual((await h.call('account')).value, { loggedIn: false });
});

test('a rejected token keeps the form; nothing stored', async () => {
  const h = harness([['GET', `${API}/v1/my/profile`, json(401, { message: 'bad key' })]], {});
  const r = (await h.call('login', submit({ token: 'x' }))).value;
  assert.equal(r.state, 'pending');
  assert.match(r.message, /did not accept/);
  const empty = (await h.call('login', submit({ token: ' ' }))).value;
  assert.match(empty.message, /first/);
  assert.equal(h.requests.length, 1);
  assert.deepEqual(h.credentials.data, {});
});

test('subjects: manga with counts as strings and linked ids, novels, merges followed', async () => {
  const h = harness([
    ['GET', `${API}/v1/series/10`, data(AJIN)],
    ['GET', `${API}/v1/series/11`, data(MERGED)],
    ['GET', `${API}/v1/series/20`, data(KINO)],
    ['GET', `${API}/v1/series/30`, data(OTHER)],
    ['GET', `${API}/v1/series/99`, missing()],
  ]);
  const ajin = {
    id: 10,
    name: 'Ajin',
    kind: 'manga',
    titles: ['Ajin', '亜人'],
    authors: ['Sakurai Gamon'],
    totalChapters: 86,
    finalVolume: 17,
    finished: true,
    linkedIds: { anilist: 30001 },
  };
  assert.deepEqual((await h.call('trackingSubject', { id: 10, kind: 'manga' })).value, ajin);
  assert.deepEqual((await h.call('trackingSubject', { id: 11, kind: 'manga' })).value, ajin);
  const kino = (await h.call('trackingSubject', { id: 20, kind: 'novel' })).value;
  assert.equal(kino.kind, 'novel');
  assert.equal(kino.totalChapters, undefined);
  assert.equal(kino.finished, false);
  assert.equal((await h.call('trackingSubject', { id: 20, kind: 'manga' })).value, null);
  assert.equal((await h.call('trackingSubject', { id: 30, kind: 'manga' })).value, null);
  assert.equal((await h.call('trackingSubject', { id: 99, kind: 'manga' })).value, null);
});

test('a merge chain deeper than three hops is not followed', async () => {
  const chain = (id) => data({ id, state: 'merged', merged_with: id + 1, type: 'manga', title: `s${id}` });
  const h = harness([['GET', /\/v1\/series\/\d+$/, (req) => chain(Number(req.url.split('/').pop()))]]);
  assert.equal((await h.call('trackingSubject', { id: 1, kind: 'manga' })).value, null);
  assert.equal(h.requests.length, 4);
});

test('search: types per kind, v2 titles (English primary, else the original language), merged skipped', async () => {
  const h = harness([['GET', /\/v2\/series\/search/, data([SEARCHED, MERGED, AJIN, OTHER, { id: 'x' }])]]);
  const r = (await h.call('trackingSearch', { query: ' solo ', kind: 'manga' })).value;
  assert.deepEqual(r.items.map((s) => s.id), [40, 10]);
  assert.equal(r.items[0].name, '나 혼자만 레벨업');
  assert.deepEqual(r.items[0].titles, ['나 혼자만 레벨업', 'Solo Leveling', 'Ore dake Level Up na Ken']);
  assert.equal(
    h.requests[0].url,
    `${API}/v2/series/search?q=solo&type=manga&type=manhwa&type=manhua&type=oel&limit=20&schema=full`,
  );
  await h.call('trackingSearch', { query: 'kino', kind: 'novel' });
  assert.match(h.requests[1].url, /type=novel&limit=20/);
});

test('lookup: AniList and MAL ids through the source endpoints; other id types are not asked', async () => {
  const h = harness([
    ['GET', `${API}/v1/source/anilist/30001`, data({ series: [AJIN, MERGED] })],
    ['GET', `${API}/v1/source/my-anime-list/5`, missing()],
  ]);
  const r = (await h.call('trackingLookup', { idType: 'anilist', id: 30001, kind: 'manga' })).value;
  assert.deepEqual(r.items.map((s) => s.id), [10]);
  assert.deepEqual((await h.call('trackingLookup', { idType: 'mal', id: 5, kind: 'manga' })).value, { items: [] });
  assert.deepEqual((await h.call('trackingLookup', { idType: 'bangumi', id: 5, kind: 'manga' })).value, { items: [] });
  assert.equal(h.requests.length, 2);
});

test('entry get: state, chapter and volume progress; not in the library is null', async () => {
  const h = harness([
    ['GET', `${API}/v1/my/library/10`, data({ state: 'considering', progress_chapter: 5, progress_volume: '1' })],
    ['GET', `${API}/v1/my/library/20`, data({ progress_chapter: null })],
    ['GET', `${API}/v1/my/library/30`, missing()],
  ]);
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 10, kind: 'manga' })).value, {
    status: 'planned',
    progress: 5,
    progressVolume: 1,
  });
  assert.equal(h.requests[0].headers['x-api-key'], 'mb-tok');
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 20, kind: 'novel' })).value, {
    status: 'current',
    progress: 0,
  });
  assert.equal((await h.call('trackingEntry', { op: 'get', id: 30, kind: 'manga' })).value, null);
});

test('entry set: create POSTs, a duplicate falls back to PATCH, update PATCHes exactly the given fields', async () => {
  const h = harness([
    ['POST', `${API}/v1/my/library/10`, data({})],
    ['POST', `${API}/v1/my/library/11`, json(400, { message: 'exists', code: 'duplicate_entry' })],
    ['PATCH', `${API}/v1/my/library/11`, data({})],
    ['PATCH', `${API}/v1/my/library/12`, data({})],
  ]);
  await h.call('trackingEntry', { op: 'set', id: 10, kind: 'manga', create: true, status: 'current', progress: 2 });
  assert.equal(h.requests.length, 1);
  assert.deepEqual(h.requests[0].json, { state: 'reading', progress_chapter: 2 });
  await h.call('trackingEntry', { op: 'set', id: 11, kind: 'manga', create: true, status: 'completed', progressVolume: 3 });
  assert.deepEqual(
    h.requests.slice(1).map((r) => r.method),
    ['POST', 'PATCH'],
  );
  assert.deepEqual(h.requests[2].json, { state: 'completed', progress_volume: 3 });
  await h.call('trackingEntry', { op: 'set', id: 12, kind: 'manga', create: false, status: 'repeating', progress: 1 });
  assert.equal(h.requests[3].method, 'PATCH');
  assert.deepEqual(h.requests[3].json, { state: 'rereading', progress_chapter: 1 });
});

test('errors: signed out, rejected token, rate limit, gone entry, failed create', async () => {
  const out = harness([], {});
  await rejects(out.call('trackingEntry', { op: 'get', id: 1, kind: 'manga' }), 'unauthorized');
  assert.equal(out.requests.length, 0);
  const h = harness([
    ['GET', `${API}/v1/my/library/1`, json(401, { message: 'expired' })],
    ['GET', /\/v2\/series\/search/, json(429, { message: 'slow' })],
    ['PATCH', `${API}/v1/my/library/2`, missing()],
    ['POST', `${API}/v1/my/library/3`, json(500, { message: 'boom' })],
  ]);
  await rejects(h.call('trackingEntry', { op: 'get', id: 1, kind: 'manga' }), 'unauthorized');
  await rejects(h.call('trackingSearch', { query: 'a', kind: 'manga' }), 'rate_limited');
  await rejects(h.call('trackingEntry', { op: 'set', id: 2, kind: 'manga', create: false, status: 'current' }), 'not_found');
  await assert.rejects(
    h.call('trackingEntry', { op: 'set', id: 3, kind: 'manga', create: true, status: 'current' }),
    /MangaBaka answered HTTP 500: boom/,
  );
});
