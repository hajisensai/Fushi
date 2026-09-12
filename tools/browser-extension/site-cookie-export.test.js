const { test } = require('node:test');
const assert = require('node:assert/strict');

const api = require('./site-cookie-export.js');

// BUG-2480：漫画源登录「从浏览器导入」的纯函数契约。
test('parseImportRequest: only a well-formed cookieImport is accepted', () => {
  assert.deepEqual(
    api.parseImportRequest({ app: 'fushi', cookieImport: { host: 'BookWalker.jp ', nonce: 'n1' } }),
    { host: 'bookwalker.jp', nonce: 'n1' },
  );
  assert.equal(api.parseImportRequest({ app: 'fushi' }), null);
  assert.equal(api.parseImportRequest({ cookieImport: { host: '', nonce: 'n' } }), null);
  assert.equal(api.parseImportRequest({ cookieImport: { host: 'a.jp' } }), null);
  assert.equal(api.parseImportRequest(null), null);
});

test('hostBelongsTo: site host or any subdomain, never a lookalike suffix', () => {
  assert.equal(api.hostBelongsTo('bookwalker.jp', 'bookwalker.jp'), true);
  assert.equal(api.hostBelongsTo('member.bookwalker.jp', 'bookwalker.jp'), true);
  assert.equal(api.hostBelongsTo('notbookwalker.jp', 'bookwalker.jp'), false);
  assert.equal(api.hostBelongsTo('bookwalker.jp', 'member.bookwalker.jp'), false);
  assert.equal(api.hostBelongsTo(null, 'bookwalker.jp'), false);
});

test('hostOfUrl: http(s) only', () => {
  assert.equal(api.hostOfUrl('https://Member.BookWalker.jp/login'), 'member.bookwalker.jp');
  assert.equal(api.hostOfUrl('chrome://extensions'), null);
  assert.equal(api.hostOfUrl('not a url'), null);
});

test('toPayload: carries nonce/host and only the fields the app reads', () => {
  const payload = api.toPayload({ host: 'bookwalker.jp', nonce: 'n1' }, [
    { name: 's', value: 'v', domain: '.bookwalker.jp', path: '/', secure: true, httpOnly: true, hostOnly: false, expirationDate: 1800000000.5, storeId: '0' },
    { name: 'h', value: 'x', domain: 'member.bookwalker.jp', path: '/', secure: false, httpOnly: false, hostOnly: true, session: true },
  ]);
  assert.equal(payload.nonce, 'n1');
  assert.equal(payload.host, 'bookwalker.jp');
  assert.deepEqual(payload.cookies[0], {
    name: 's', value: 'v', domain: '.bookwalker.jp', path: '/', secure: true, httpOnly: true, hostOnly: false, expirationDate: 1800000000.5,
  });
  assert.equal(payload.cookies[1].expirationDate, null);
  assert.equal('storeId' in payload.cookies[0], false);
});
