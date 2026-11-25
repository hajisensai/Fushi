// Test harness for tracking plugins: the kit's sandbox runner (the same one `run` uses) with HTTP answered
// from fixtures and storage / credentials kept in memory. No network, no files written. Use it from
// `node --test` files next to a plugin:
//
//   import { createHarness, json } from '<sdk>/lib/harness.mjs';
//   const h = createHarness(pluginDir, { routes: [['GET', 'https://api.example.org/me', json(200, { name: 'u' })]] });
//   h.credentials.set('token', 't');
//   const subject = await h.call('trackingSubject', { id: 1, kind: 'anime' });
//
// `call` validates the arguments and the result exactly like `fushi-tracking-plugin.mjs run` and throws when
// the host could not use the result; every request is recorded in `h.requests`.
import fs from 'node:fs';
import { PluginRunner } from '../../music-plugin-sdk/lib/runner.mjs';
import { KNOWN_TRACKING_CAPABILITIES, validateManifest } from './rules.mjs';
import { validateArgs, validateResult } from './validate.mjs';

/// An in-memory stand-in for the runner's on-disk dev store.
class MemoryStore {
  constructor(initial = {}) {
    this.data = { ...initial };
  }
  get(k) {
    return Object.hasOwn(this.data, k) ? this.data[k] : null;
  }
  set(k, v) {
    this.data[k] = v;
  }
  remove(k) {
    delete this.data[k];
  }
  clear() {
    this.data = {};
  }
  save() {
    // The runner calls save() after every change to persist its on-disk dev store; this store lives only in
    // memory for the length of a test, so there is nothing to write.
  }
}

/// A fixture answer: status + JSON body.
export function json(status, body, headers = {}) {
  return { status, headers: { 'content-type': 'application/json', ...headers }, body: body === undefined ? '' : JSON.stringify(body) };
}

/// A fixture answer with no body (e.g. 204).
export function empty(status) {
  return { status, headers: {}, body: '' };
}

/// A route matches when the method is equal and the URL is equal (string) or matches (RegExp). The answer is a
/// fixture object, or a function (request) => fixture for answers that depend on the body.
function matches(route, req) {
  const [method, url] = route;
  if (method !== req.method) return false;
  return url instanceof RegExp ? url.test(req.url) : url === req.url;
}

/// [dir] is the plugin folder. Options: `routes` ([method, url | RegExp, fixture | fn][]), initial `storage` /
/// `credentials` objects. Unmatched requests fail the call (a test must declare every request it expects).
export function createHarness(dir, { routes = [], storage = {}, credentials = {} } = {}) {
  const manifest = JSON.parse(fs.readFileSync(`${dir}/manifest.json`, 'utf8'));
  const problems = validateManifest(manifest);
  if (problems.length) throw new Error(`manifest invalid: ${problems.join('; ')}`);
  const runner = new PluginRunner(dir, manifest, { knownCapabilities: KNOWN_TRACKING_CAPABILITIES });
  runner.storage = new MemoryStore(storage);
  runner.credentials = new MemoryStore(credentials);
  const requests = [];
  const table = [...routes];
  runner.pin = async () => {};
  runner.http = async (req, body) => {
    runner.httpCount++;
    const text = body === undefined || body === null ? null : Buffer.from(body).toString('utf8');
    const record = { method: req.method, url: req.url, headers: req.headers, body: text, json: safeJson(text) };
    requests.push(record);
    const route = table.find((r) => matches(r, record));
    if (!route) throw new Error(`harness: no fixture for ${req.method} ${req.url}`);
    const answer = typeof route[2] === 'function' ? route[2](record) : route[2];
    return {
      value: { status: answer.status, url: req.url, headers: answer.headers ?? {}, setCookies: [] },
      body: Buffer.from(answer.body ?? '', 'utf8'),
    };
  };
  runner.boot();
  return {
    manifest,
    runner,
    requests,
    storage: runner.storage,
    credentials: runner.credentials,
    /// Adds routes after creation (checked before the earlier ones).
    route(...more) {
      table.unshift(...more);
    },
    /// Invokes [method]; throws on a plugin error (message as the host reads it) or on a result the host
    /// could not use. Returns { value, warnings }.
    async call(method, args = {}) {
      const argWarnings = validateArgs(method, args, manifest);
      if (argWarnings.length) throw new Error(`harness: the host would not send these arguments: ${argWarnings.join('; ')}`);
      const value = await runner.invoke(method, args);
      const report = validateResult(method, args, value, { manifest, policy: runner.policy });
      if (report.errors.length) throw new Error(`harness: unusable result: ${report.errors.join('; ')}`);
      return { value, warnings: report.warnings };
    },
  };
}

function safeJson(text) {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
