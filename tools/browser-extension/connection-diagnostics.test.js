const { test } = require('node:test');
const assert = require('node:assert/strict');

const diagnostics = require('./connection-diagnostics.js');

test('Hibiki status endpoint wins when it is ready', () => {
  assert.equal(
    diagnostics.classify({ status: 200, body: { app: 'hibiki', ready: true } }),
    diagnostics.states.connected,
  );
});

test("renamed app reporting 'fushi' is accepted as connected (dual-value transition)", () => {
  assert.equal(
    diagnostics.classify({ status: 200, body: { app: 'fushi', ready: true } }),
    diagnostics.states.connected,
  );
});

test('an unknown app value on the port is still wrong-service', () => {
  assert.equal(
    diagnostics.classify({ status: 200, body: { app: 'other' } }),
    diagnostics.states.wrongService,
  );
});

test('old Hibiki lookup endpoint is recognised as a legacy connection', () => {
  assert.equal(
    diagnostics.classify(
      { status: 404 },
      { status: 200, body: { type: 'dictionaryResult' } },
    ),
    diagnostics.states.legacy,
  );
});

test('Yomitan API on the same port is reported as an actionable conflict', () => {
  assert.equal(
    diagnostics.classify(
      { status: 404 },
      { status: 404 },
      { status: 200, body: { version: '0.2.0' } },
    ),
    diagnostics.states.yomitanConflict,
  );
  const message = diagnostics.copy(diagnostics.states.yomitanConflict, 19633);
  assert.match(message.detail, /Enable Yomitan API/);
  assert.match(message.detail, /Hibiki/);
  assert.match(message.detail, /19633/);
});

test('authentication and offline failures stay distinguishable', () => {
  assert.equal(
    diagnostics.classify({ ok: false, status: 401 }),
    diagnostics.states.unauthorized,
  );
  assert.equal(
    diagnostics.classify(null, null, null, new Error('ECONNREFUSED')),
    diagnostics.states.offline,
  );
});
