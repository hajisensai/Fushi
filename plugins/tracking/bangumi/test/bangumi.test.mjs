// Bangumi plugin tests: the kit's harness (real sandbox runner, HTTP from the hand-written fixtures below,
// shaped like Bangumi v0 answers). No network, no token. Run: node --test plugins/tracking/bangumi/test/
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHarness, empty, json } from '../../../../tools/tracking-plugin-sdk/lib/harness.mjs';

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = 'https://api.bgm.tv';
const SIGNED_IN = { token: 'tok', username: 'alice', name: 'Alice' };

const ANIME = { id: 100, type: 2, name: 'Sousou no Frieren', name_cn: '葬送的芙莉莲', eps: 28, volumes: 0, platform: 'TV' };
const MANGA = { id: 200, type: 1, name: 'Ajin', name_cn: '亚人', eps: 0, volumes: 17, platform: '漫画' };
const NOVEL_ONE = { id: 300, type: 1, name: 'Kino', name_cn: '', eps: 0, volumes: 1, platform: '小说' };
const NOVEL_OPEN = { id: 301, type: 1, name: 'Ongoing', name_cn: '', eps: 0, volumes: 0, platform: '小说' };
const GAME = { id: 400, type: 4, name: 'Steins;Gate', name_cn: '命运石之门', platform: 'PC' };

function harness(routes = [], credentials = SIGNED_IN) {
  return createHarness(DIR, { routes, credentials: { ...credentials } });
}

async function rejects(promise, prefix) {
  await assert.rejects(promise, (e) => {
    assert.match(String(e.message), new RegExp(`(^|: )${prefix}`));
    return true;
  });
}

test('sign in with a token: checks /v0/me, stores token, user and nickname', async () => {
  const h = harness([['GET', `${API}/v0/me`, json(200, { username: 'alice', nickname: 'Alice' })]], {});
  const methods = (await h.call('login', { op: 'methods', platform: 'windows' })).value;
  assert.equal(methods.methods[0].type, 'form');
  const begin = (await h.call('login', { op: 'begin', method: 'token', platform: 'windows' })).value;
  assert.equal(begin.state, 'pending');
  assert.equal(begin.appUrl, 'https://next.bgm.tv/demo/access-token');
  const done = (await h.call('login', { op: 'submit', method: 'token', platform: 'windows', action: 'save', inputs: { token: ' tok ' } })).value;
  assert.deepEqual(done, { state: 'done', account: { loggedIn: true, name: 'Alice' } });
  assert.equal(h.requests[0].headers.Authorization, 'Bearer tok');
  assert.match(h.requests[0].headers['User-Agent'], /Fushi/);
  assert.deepEqual(h.credentials.data, { token: 'tok', username: 'alice', name: 'Alice' });
  assert.deepEqual((await h.call('account')).value, { loggedIn: true, name: 'Alice' });
  await h.call('login', { op: 'logout' });
  assert.deepEqual(h.credentials.data, {});
  assert.deepEqual((await h.call('account')).value, { loggedIn: false });
});

test('a rejected token keeps the form with a message; nothing stored', async () => {
  const h = harness([['GET', `${API}/v0/me`, json(401, { title: 'Unauthorized', description: 'bad token' })]], {});
  const r = (await h.call('login', { op: 'submit', method: 'token', platform: 'windows', action: 'save', inputs: { token: 'x' } })).value;
  assert.equal(r.state, 'pending');
  assert.match(r.message, /did not accept/);
  assert.deepEqual(h.credentials.data, {});
});

test('import stores a moved token and name without a request', async () => {
  const h = harness([], {});
  const r = (await h.call('login', { op: 'import', inputs: { token: 'old', name: 'Alice' } })).value;
  assert.deepEqual(r, { state: 'done', account: { loggedIn: true, name: 'Alice' } });
  assert.equal(h.requests.length, 0);
  assert.deepEqual(h.credentials.data, { token: 'old', name: 'Alice' });
});

test('subjects: anime episodes, book volumes, one-book novels, games', async () => {
  const h = harness([
    ['GET', `${API}/v0/subjects/100`, json(200, ANIME)],
    ['GET', `${API}/v0/subjects/200`, json(200, MANGA)],
    ['GET', `${API}/v0/subjects/300`, json(200, NOVEL_ONE)],
    ['GET', `${API}/v0/subjects/301`, json(200, NOVEL_OPEN)],
    ['GET', `${API}/v0/subjects/400`, json(200, GAME)],
  ]);
  assert.deepEqual((await h.call('trackingSubject', { id: 100, kind: 'anime' })).value, {
    id: 100,
    name: '葬送的芙莉莲',
    kind: 'anime',
    titles: ['葬送的芙莉莲', 'Sousou no Frieren'],
    totalEpisodes: 28,
  });
  assert.deepEqual((await h.call('trackingSubject', { id: 200, kind: 'manga' })).value, {
    id: 200,
    name: '亚人',
    kind: 'manga',
    titles: ['亚人', 'Ajin'],
    finalVolume: 17,
    finished: true,
    singleVolume: false,
  });
  const one = (await h.call('trackingSubject', { id: 300, kind: 'novel' })).value;
  assert.equal(one.singleVolume, true);
  assert.equal(one.finalVolume, 1);
  const open = (await h.call('trackingSubject', { id: 301, kind: 'novel' })).value;
  assert.equal(open.singleVolume, true);
  assert.equal(open.finalVolume, undefined);
  assert.equal(open.finished, undefined);
  // Without a kind the platform decides manga vs novel.
  assert.equal((await h.call('trackingSubject', { id: 200 })).value.kind, 'manga');
  assert.equal((await h.call('trackingSubject', { id: 300 })).value.kind, 'novel');
  assert.deepEqual((await h.call('trackingSubject', { id: 400, kind: 'game' })).value, {
    id: 400,
    name: '命运石之门',
    kind: 'game',
    titles: ['命运石之门', 'Steins;Gate'],
  });
});

test('wrong-kind guard and a missing subject answer null', async () => {
  const h = harness([
    ['GET', `${API}/v0/subjects/100`, json(200, ANIME)],
    ['GET', `${API}/v0/subjects/9`, json(404, { title: 'Not Found', description: 'subject not found' })],
  ]);
  assert.equal((await h.call('trackingSubject', { id: 100, kind: 'manga' })).value, null);
  assert.equal((await h.call('trackingSubject', { id: 100, kind: 'game' })).value, null);
  assert.equal((await h.call('trackingSubject', { id: 9, kind: 'anime' })).value, null);
});

test('search posts the subject type filter and keeps that type only', async () => {
  const h = harness([['POST', `${API}/v0/search/subjects?limit=20&offset=0`, json(200, { data: [MANGA, ANIME, NOVEL_ONE] })]]);
  const r = (await h.call('trackingSearch', { query: ' ajin ', kind: 'manga' })).value;
  assert.deepEqual(h.requests[0].json, { keyword: 'ajin', sort: 'match', filter: { type: [1] } });
  assert.deepEqual(
    r.items.map((s) => [s.id, s.kind]),
    [
      [200, 'manga'],
      [300, 'manga'],
    ],
  );
  assert.deepEqual((await h.call('trackingSearch', { query: 'x', kind: 'game' })).value.items, []);
  assert.deepEqual(h.requests[1].json.filter, { type: [4] });
});

test('entry get: collection fields; not collected = null; the user name is read once when missing', async () => {
  const h = harness(
    [
      ['GET', `${API}/v0/me`, json(200, { username: 'alice', nickname: 'Alice' })],
      ['GET', `${API}/v0/users/alice/collections/200`, json(200, { type: 4, ep_status: 30, vol_status: 3, subject_type: 1 })],
      ['GET', `${API}/v0/users/alice/collections/100`, json(200, { type: 2, ep_status: 28, vol_status: 0, subject_type: 2 })],
      ['GET', `${API}/v0/users/alice/collections/5`, json(404, { title: 'Not Found' })],
    ],
    { token: 'tok' },
  );
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 200, kind: 'manga' })).value, {
    status: 'paused',
    progress: 30,
    progressVolume: 3,
  });
  assert.deepEqual((await h.call('trackingEntry', { op: 'get', id: 100, kind: 'anime' })).value, { status: 'completed', progress: 28 });
  assert.equal((await h.call('trackingEntry', { op: 'get', id: 5, kind: 'anime' })).value, null);
  assert.equal(h.requests.filter((r) => r.url.endsWith('/v0/me')).length, 1);
  assert.equal(h.credentials.get('username'), 'alice');
});

test('anime write: created as watching, first N main episodes by position (sort starts at 51), then done', async () => {
  const episodes = { total: 4, data: [53, 51, 52, 54].map((sort) => ({ id: sort * 10, type: 0, sort })) };
  const h = harness([
    ['POST', `${API}/v0/users/-/collections/100`, empty(204)],
    ['GET', `${API}/v0/episodes?subject_id=100&type=0&limit=200&offset=0`, json(200, episodes)],
    ['PATCH', `${API}/v0/users/-/collections/100/episodes`, empty(204)],
    ['PATCH', `${API}/v0/users/-/collections/100`, empty(204)],
  ]);
  await h.call('trackingEntry', { op: 'set', id: 100, kind: 'anime', create: true, status: 'completed', progress: 4 });
  assert.deepEqual(
    h.requests.map((r) => [r.method, r.url.replace(API, ''), r.json]),
    [
      ['POST', '/v0/users/-/collections/100', { type: 3 }],
      ['GET', '/v0/episodes?subject_id=100&type=0&limit=200&offset=0', null],
      ['PATCH', '/v0/users/-/collections/100/episodes', { episode_id: [510, 520, 530, 540], type: 2 }],
      ['PATCH', '/v0/users/-/collections/100', { type: 2 }],
    ],
  );
});

test('anime write on an existing entry: marks episodes, keeps an equal status', async () => {
  const h = harness([
    ['GET', `${API}/v0/episodes?subject_id=100&type=0&limit=200&offset=0`, json(200, { total: 3, data: [1, 2, 3].map((n) => ({ id: n, type: 0, sort: n })) })],
    ['PATCH', `${API}/v0/users/-/collections/100/episodes`, empty(204)],
    ['GET', `${API}/v0/users/alice/collections/100`, json(200, { type: 3, ep_status: 2 })],
  ]);
  await h.call('trackingEntry', { op: 'set', id: 100, kind: 'anime', create: false, status: 'current', progress: 2 });
  assert.deepEqual(h.requests[1].json, { episode_id: [1, 2], type: 2 });
  assert.equal(h.requests.length, 3);
});

test('an anime without main episodes is a temporary error', async () => {
  const h = harness([['GET', `${API}/v0/episodes?subject_id=100&type=0&limit=200&offset=0`, json(200, { total: 0, data: [] })]]);
  await assert.rejects(h.call('trackingEntry', { op: 'set', id: 100, kind: 'anime', create: false, status: 'current', progress: 1 }), /no main episodes/);
});

test('book writes: vol_status / ep_status with the type, create = POST, else PATCH', async () => {
  const h = harness([
    ['POST', `${API}/v0/users/-/collections/200`, empty(204)],
    ['PATCH', `${API}/v0/users/-/collections/300`, empty(204)],
  ]);
  await h.call('trackingEntry', { op: 'set', id: 200, kind: 'manga', create: true, status: 'current', progressVolume: 2 });
  await h.call('trackingEntry', { op: 'set', id: 300, kind: 'novel', create: false, status: 'completed', progress: 12, progressVolume: 1 });
  assert.deepEqual(h.requests[0].json, { type: 3, vol_status: 2 });
  assert.deepEqual(h.requests[1].json, { type: 2, ep_status: 12, vol_status: 1 });
});

test('game writes only the collection type (the user may go back from done)', async () => {
  const h = harness([['PATCH', `${API}/v0/users/-/collections/400`, empty(204)]]);
  await h.call('trackingEntry', { op: 'set', id: 400, kind: 'game', create: false, status: 'current' });
  assert.deepEqual(h.requests[0].json, { type: 3 });
});

test('errors: signed out / 401 = unauthorized, 429 = rate_limited, vanished entry = not_found', async () => {
  await rejects(harness([], {}).call('trackingEntry', { op: 'get', id: 1, kind: 'anime' }), 'unauthorized:');
  await rejects(
    harness([['GET', `${API}/v0/users/alice/collections/1`, json(401, { title: 'Unauthorized' })]]).call('trackingEntry', { op: 'get', id: 1, kind: 'anime' }),
    'unauthorized:',
  );
  await rejects(
    harness([['GET', `${API}/v0/subjects/1`, json(429, { title: 'Too Many Requests' })]]).call('trackingSubject', { id: 1, kind: 'anime' }),
    'rate_limited:',
  );
  await rejects(
    harness([['PATCH', `${API}/v0/users/-/collections/400`, json(404, { title: 'Not Found' })]]).call('trackingEntry', {
      op: 'set',
      id: 400,
      kind: 'game',
      create: false,
      status: 'dropped',
    }),
    'not_found:',
  );
  // The token never appears in an error message.
  const h = harness([['GET', `${API}/v0/subjects/1`, json(500, { title: 'Server Error', description: 'boom' })]]);
  await assert.rejects(h.call('trackingSubject', { id: 1, kind: 'anime' }), (e) => !String(e.message).includes('tok') && /500/.test(e.message));
});

test('trackingList: one page per call, next while more remain, unusable items dropped', async () => {
  const item = (s, extra = {}) => ({ subject: s, type: 2, ep_status: int(s.eps), vol_status: 0, updated_at: '2026-10-01T12:00:00+08:00', ...extra });
  function int(v) {
    return typeof v === 'number' ? v : 0;
  }
  const h = harness([
    [
      'GET',
      `${API}/v0/users/alice/collections?subject_type=2&type=2&limit=50&offset=0`,
      json(200, { total: 3, limit: 50, offset: 0, data: [item(ANIME), item({ id: 0, type: 2, name: 'bad' }), item({ ...ANIME, id: 101 }, { type: 9 })] }),
    ],
  ]);
  const r = (await h.call('trackingList', { kind: 'anime', status: 'completed', offset: 0 })).value;
  assert.deepEqual(r, {
    items: [
      {
        subject: { id: 100, name: '葬送的芙莉莲', kind: 'anime', titles: ['葬送的芙莉莲', 'Sousou no Frieren'], totalEpisodes: 28 },
        status: 'completed',
        progress: 28,
        updatedAt: '2026-10-01T12:00:00+08:00',
      },
    ],
  });
  const h2 = harness([[
    'GET',
    `${API}/v0/users/alice/collections?subject_type=2&type=2&limit=50&offset=0`,
    json(200, { total: 120, limit: 50, offset: 0, data: Array.from({ length: 50 }, (_, i) => item({ ...ANIME, id: 1000 + i })) }),
  ]]);
  const page = (await h2.call('trackingList', { kind: 'anime', status: 'completed', offset: 0 })).value;
  assert.equal(page.items.length, 50);
  assert.equal(page.next, 50);
});
