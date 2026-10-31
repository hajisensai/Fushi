#!/usr/bin/env node
// fushi-plugin — zero-dependency dev tool for Fushi music source plugins (Node >= 18).
// Run without arguments for help. Docs: GUIDE.md next to this file.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { buildEntries, checkFiles, generateKey, listPackFiles, publicKeyBase64, readZip, verifyEntries, writeZip } from './lib/pkg.mjs';
import { KNOWN_CAPABILITIES, validateManifest } from './lib/rules.mjs';
import { PluginError, PluginRunner } from './lib/runner.mjs';
import { validateResult } from './lib/validate.mjs';

const SDK_DIR = path.dirname(fileURLToPath(import.meta.url));

const HELP = `fushi-plugin — build, run and package Fushi music source plugins

  init <dir> [--id <id>] [--name <name>]   scaffold a new plugin (manifest, main.js, typings)
  check <dir>                              validate manifest, files and exports like the host does
  run <dir> <method> [argsJson]            call one capability and validate the result
        [--trace] [--full]                   --trace logs every HTTP request; --full prints untruncated JSON
  smoke <dir> [--query <q>]                exercise every declared capability end to end
  login <dir>                              sign in interactively (qr / form / web) and save credentials
  reset <dir>                              clear local storage / credentials (<dir>/.fushi-dev)
  keygen [--out <file>]                    create an Ed25519 signing key (default: fushi-plugin-key.pem)
  pack <dir> [--key <pem>] [--out <file>]  check, then write <id>-<version>.fushiplug
  inspect <file.fushiplug>                 verify a package exactly like the app's installer

Exit code: 0 = ok (warnings allowed), 1 = errors. Add --strict to fail on warnings too.
Examples:
  node fushi-plugin.mjs run ./my-plugin search '{"query":"lemon","type":"song","page":0,"pageSize":10}'
  node fushi-plugin.mjs smoke ./my-plugin --query lemon`;

function parseArgs(argv) {
  const pos = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['trace', 'full', 'strict'].includes(k)) flags[k] = true;
      else flags[k] = argv[++i];
    } else pos.push(a);
  }
  return { pos, flags };
}

const c = process.stdout.isTTY && !process.env.NO_COLOR
  ? { red: (s) => `\x1b[31m${s}\x1b[0m`, yellow: (s) => `\x1b[33m${s}\x1b[0m`, green: (s) => `\x1b[32m${s}\x1b[0m`, dim: (s) => `\x1b[2m${s}\x1b[0m` }
  : { red: (s) => s, yellow: (s) => s, green: (s) => s, dim: (s) => s };

let hadError = false;
let hadWarning = false;
const err = (msg) => {
  hadError = true;
  console.log(c.red(`ERROR ${msg}`));
};
const warn = (msg) => {
  hadWarning = true;
  console.log(c.yellow(`WARN  ${msg}`));
};
const ok = (msg) => console.log(c.green(`OK    ${msg}`));

function loadManifest(dir) {
  const file = path.join(dir, 'manifest.json');
  if (!fs.existsSync(file)) throw new Error(`${file} not found`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    throw new Error(`manifest.json is not valid JSON: ${e.message}`);
  }
}

function checkDir(dir, { quiet = false } = {}) {
  const manifest = loadManifest(dir);
  const merrs = validateManifest(manifest);
  merrs.forEach((m) => err(`manifest: ${m}`));
  const files = listPackFiles(dir);
  checkFiles(dir, files).forEach((m) => err(`files: ${m}`));
  if (merrs.length) return { manifest, runner: null };
  if (!files.includes(manifest.entry)) {
    err(`entry ${manifest.entry} not found in ${dir}`);
    return { manifest, runner: null };
  }
  const runner = makeRunner(dir, manifest, {});
  try {
    runner.boot();
  } catch (e) {
    err(e.message);
    return { manifest, runner: null };
  }
  runner.bootWarnings.forEach((m) => warn(m));
  if (!quiet) ok(`${manifest.id} ${manifest.version}: manifest valid, ${files.length} files, exports ${manifest.capabilities.join(', ')}`);
  return { manifest, runner };
}

function makeRunner(dir, manifest, flags) {
  return new PluginRunner(dir, manifest, {
    trace: !!flags.trace,
    log: (level, msg) => {
      const tag = level === 'trace' ? 'http ' : `${level.padEnd(5)}`;
      const line = `${c.dim('[plugin]')} ${tag} ${msg}`;
      process.stderr.write((level === 'error' ? c.red(line) : level === 'warn' ? c.yellow(line) : line) + '\n');
    },
  });
}

function show(value, full) {
  let text = JSON.stringify(value, null, 2);
  if (!full && text.length > 6000) text = text.slice(0, 6000) + `\n… (${text.length} chars, use --full)`;
  console.log(text);
}

/// Invokes one capability, validates, prints. Returns the value, or undefined on failure.
async function call(runner, method, args, { print = true, full = false, label } = {}) {
  const name = label ?? `${method} ${JSON.stringify(args)}`;
  const started = Date.now();
  let value;
  try {
    value = await runner.invoke(method, args);
  } catch (e) {
    if (e instanceof PluginError) {
      // Keep only stack frames inside the plugin: drop the repeated message line and runner / Node internals.
      const [head, ...rest] = e.message.split('\n');
      const frames = rest.filter((l) => /^\s+at /.test(l) && !/node:|[\\/]lib[\\/]runner\.mjs|prelude\.js/.test(l));
      err(`${name} threw: ${head}${frames.length ? '\n' + c.dim(frames.join('\n')) : ''}`);
    } else err(`${name}: ${e.message}`);
    return undefined;
  }
  if (print) show(value, full);
  const r = validateResult(method, args, value, runner.policy);
  r.errors.forEach((m) => err(m));
  r.warnings.slice(0, 30).forEach((m) => warn(m));
  if (r.warnings.length > 30) warn(`… ${r.warnings.length - 30} more warnings`);
  if (!r.errors.length) ok(`${name} (${Date.now() - started} ms)`);
  if (['stream', 'mvStream'].includes(method) && !r.errors.length) await probeMedia(runner, value);
  return r.errors.length ? undefined : value;
}

/// Fetches the first bytes of a stream URL the way the player would (same headers, redirect checks).
async function probeMedia(runner, s) {
  let url = s.url;
  try {
    for (let hop = 0; hop <= 5; hop++) {
      runner.policy.checkUrl(url);
      await runner.pin(url);
      const res = await fetch(url, { headers: { ...(s.headers ?? {}), Range: 'bytes=0-1023' }, redirect: 'manual', signal: AbortSignal.timeout(15000) });
      const loc = res.headers.get('location');
      if (res.status >= 300 && res.status < 400 && loc) {
        url = new URL(loc, url).toString();
        continue;
      }
      await res.body?.cancel();
      if (res.status >= 400) return err(`media probe: ${url} answered HTTP ${res.status} (the player will fail)`);
      return ok(`media probe: HTTP ${res.status} ${res.headers.get('content-type') ?? ''}`);
    }
    err('media probe: too many redirects');
  } catch (e) {
    err(`media probe: ${e.message} (redirect targets must also be inside network.domains)`);
  }
}

async function cmdRun(dir, method, argsJson, flags) {
  const manifest = loadManifest(dir);
  validateManifest(manifest).forEach((m) => err(`manifest: ${m}`));
  if (hadError) return;
  if (!KNOWN_CAPABILITIES.includes(method)) return err(`unknown capability ${method}`);
  if (!manifest.capabilities.includes(method)) warn(`${method} is not declared in manifest.capabilities — the host would never call it`);
  let args;
  try {
    args = argsJson ? JSON.parse(argsJson) : {};
  } catch (e) {
    return err(`argsJson is not valid JSON: ${e.message}`);
  }
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  runner.bootWarnings.forEach((m) => warn(m));
  await call(runner, method, args, { full: flags.full });
}

const first = (v, key) => (Array.isArray(v?.[key]) ? v[key].find((x) => typeof x?.id === 'string' && x.id) : undefined);

async function cmdSmoke(dir, flags) {
  const { manifest, runner: booted } = checkDir(dir);
  if (!booted) return;
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  const caps = new Set(manifest.capabilities);
  const q = flags.query ?? 'love';
  const opt = { print: false };
  const seen = { track: null, album: null, artist: null, playlist: null };
  if (caps.has('account')) {
    const a = await call(runner, 'account', {}, opt);
    if (a && !a.loggedIn) console.log(c.dim('      (not logged in — run `login` to test account-only capabilities)'));
  }
  if (caps.has('home')) {
    const h = await call(runner, 'home', {}, opt);
    for (const s of h?.sections ?? []) {
      const it = Array.isArray(s?.items) ? s.items.find((x) => typeof x?.id === 'string') : undefined;
      if (!it) continue;
      if (s.kind === 'tracks') seen.track ??= it;
      if (s.kind === 'albums') seen.album ??= it;
      if (s.kind === 'playlists') seen.playlist ??= it;
    }
  }
  if (caps.has('search')) {
    for (const type of manifest.searchTypes) {
      const r = await call(runner, 'search', { query: q, type, page: 0, pageSize: 10 }, opt);
      const it = first(r, 'items');
      if (!it) {
        if (r) warn(`search type=${type} for "${q}" returned no usable items (try --query)`);
        continue;
      }
      if (type === 'song') seen.track = it.playable === false ? (r.items.find((t) => t?.playable !== false && typeof t?.id === 'string') ?? it) : it;
      if (type === 'album') seen.album = it;
      if (type === 'artist') seen.artist = it;
      if (type === 'playlist') seen.playlist = it;
      if (r?.hasMore === true) await call(runner, 'search', { query: q, type, page: 1, pageSize: 10 }, opt);
    }
    if (caps.has('searchBest')) await call(runner, 'searchBest', { query: q }, opt);
  }
  if (caps.has('album') && seen.album) {
    const a = await call(runner, 'album', { id: seen.album.id }, opt);
    seen.track ??= first(a, 'tracks');
  }
  if (caps.has('playlist') && seen.playlist) {
    const p = await call(runner, 'playlist', { id: seen.playlist.id }, opt);
    seen.track ??= first(p, 'tracks');
  }
  if (caps.has('album') && !seen.album && typeof seen.track?.album?.id === 'string') await call(runner, 'album', { id: seen.track.album.id }, opt);
  const artistId = seen.artist?.id ?? seen.track?.artists?.find((a) => typeof a?.id === 'string')?.id;
  if (caps.has('artist') && artistId) {
    await call(runner, 'artist', { id: artistId }, opt);
    if (caps.has('artistAlbums')) await call(runner, 'artistAlbums', { id: artistId, page: 0, pageSize: 20 }, opt);
    if (caps.has('artistMvs')) {
      const m = await call(runner, 'artistMvs', { id: artistId, page: 0, pageSize: 20 }, opt);
      const mv = first(m, 'items');
      if (mv && caps.has('mvStream')) await call(runner, 'mvStream', { id: mv.id, quality: 'high' }, opt);
    }
  }
  if (seen.track) {
    if (caps.has('stream')) await call(runner, 'stream', { id: seen.track.id, quality: 'high' }, opt);
    if (caps.has('lyrics')) {
      const l = await call(runner, 'lyrics', { id: seen.track.id }, opt);
      if (l === null) console.log(c.dim('      (lyrics returned null for this track)'));
    }
    if (caps.has('mvStream') && typeof seen.track.mvId === 'string') await call(runner, 'mvStream', { id: seen.track.mvId, quality: 'high' }, opt);
  } else if (caps.has('stream')) warn('no track found to test stream / lyrics (declare search type "song", or return tracks from album / playlist / home)');
  if (caps.has('library')) await call(runner, 'library', { page: 0, pageSize: 50 }, opt);
  if (caps.has('like')) await call(runner, 'like', { op: 'list' }, opt);
  if (caps.has('login')) await call(runner, 'login', { op: 'methods', platform: 'windows' }, opt);
  console.log(c.dim(`      ${runner.httpCount} HTTP requests`));
}

async function cmdLogin(dir, flags) {
  const { manifest, runner: booted } = checkDir(dir, { quiet: true });
  if (!booted) return;
  if (!manifest.capabilities.includes('login')) return err('this plugin does not declare "login"');
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  const platform = { win32: 'windows', darwin: 'macos', linux: 'linux' }[process.platform] ?? 'linux';
  // Line queue instead of rl.question: works for a terminal and for piped answers (agents / scripts).
  const rl = readline.createInterface({ input: process.stdin });
  const lines = [];
  const waiters = [];
  rl.on('line', (l) => (waiters.length ? waiters.shift()(l) : lines.push(l)));
  rl.on('close', () => waiters.splice(0).forEach((w) => w('')));
  const ask = (prompt) => {
    process.stdout.write(prompt);
    return lines.length ? Promise.resolve(lines.shift()) : new Promise((r) => waiters.push(r));
  };
  try {
    const m = await call(runner, 'login', { op: 'methods', platform }, { print: false });
    const methods = (m?.methods ?? []).filter((x) => x && typeof x.id === 'string');
    if (!methods.length) return;
    methods.forEach((x, i) => console.log(`  ${i + 1}. [${x.type}] ${x.label}${x.description ? ' — ' + x.description : ''}`));
    const pick = methods[(Number(await ask('Choose a method: ')) || 1) - 1] ?? methods[0];
    let ch = await call(runner, 'login', { op: 'begin', method: pick.id, platform }, { print: false });
    while (ch && ch.state === 'pending') {
      if (ch.message) console.log(`  ${ch.message}`);
      if (pick.type === 'qr') {
        if (ch.qr?.content) console.log(`  QR content (open it with any QR generator, or scan in the phone app): ${ch.qr.content}`);
        if (ch.qr?.imageBase64) {
          const f = path.join(dir, '.fushi-dev', 'login-qr.png');
          fs.mkdirSync(path.dirname(f), { recursive: true });
          fs.writeFileSync(f, Buffer.from(ch.qr.imageBase64, 'base64'));
          console.log(`  QR image saved to ${f}`);
        }
        if (ch.appUrl) console.log(`  appUrl: ${ch.appUrl}`);
        await new Promise((r) => setTimeout(r, Math.min(Math.max(ch.pollMs ?? 2000, 500), 10000)));
        ch = await call(runner, 'login', { op: 'poll', method: pick.id, session: ch.session, platform }, { print: false });
      } else if (pick.type === 'form' && ch.form) {
        const inputs = {};
        for (const f of ch.form.fields ?? []) inputs[f.id] = await ask(`  ${f.label}${f.placeholder ? ` (${f.placeholder})` : ''}: `);
        const actions = ch.form.actions ?? [];
        actions.forEach((a, i) => console.log(`  ${i + 1}. ${a.label}`));
        const action = actions.length > 1 ? (actions[(Number(await ask('  Action: ')) || 1) - 1] ?? actions[0]) : actions[0];
        ch = await call(runner, 'login', { op: 'submit', method: pick.id, session: ch.session, platform, action: action?.id, inputs }, { print: false, label: 'login submit' });
      } else if (pick.type === 'web' && ch.web) {
        console.log(`  Open ${ch.web.url} in a browser and sign in. The app waits for cookie "${ch.web.doneCookie}" on ${ch.web.cookieUrl}`);
        const cookie = await ask('  Paste the full Cookie header of that site (a=b; c=d): ');
        ch = await call(runner, 'login', { op: 'submit', method: pick.id, session: ch.session, platform, action: 'web', inputs: { cookie } }, { print: false, label: 'login submit (web)' });
      } else break;
    }
    if (ch?.state === 'done') {
      ok(`logged in${ch.account?.name ? ' as ' + ch.account.name : ''}`);
      await call(runner, 'account', {}, {});
    } else if (ch) err(`login ${ch.state}: ${ch.message ?? ''}`);
  } finally {
    rl.close();
  }
}

function cmdInit(dir, flags) {
  if (fs.existsSync(dir) && fs.readdirSync(dir).length) return err(`${dir} is not empty`);
  const id = flags.id ?? `dev.example.${path.basename(path.resolve(dir)).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'plugin'}`;
  const name = flags.name ?? path.basename(path.resolve(dir));
  const tpl = path.join(SDK_DIR, 'templates', 'starter');
  fs.mkdirSync(dir, { recursive: true });
  for (const f of fs.readdirSync(tpl)) {
    let text = fs.readFileSync(path.join(tpl, f), 'utf8');
    text = text
      .replaceAll('__PLUGIN_ID__', id)
      .replaceAll('__PLUGIN_NAME__', name)
      .replaceAll('__SDK_CLI__', path.join(SDK_DIR, 'fushi-plugin.mjs').replaceAll('\\', '/'));
    // Template names avoid files the Fushi repo ignores (.gitignore, AGENTS.md).
    const out = { gitignore: '.gitignore', 'AGENTS.template.md': 'AGENTS.md' }[f] ?? f;
    fs.writeFileSync(path.join(dir, out), text);
  }
  // The contract travels with the plugin so an agent working in <dir> has everything locally.
  fs.copyFileSync(path.join(SDK_DIR, 'fushi-plugin.d.ts'), path.join(dir, 'fushi-plugin.d.ts'));
  fs.copyFileSync(path.join(SDK_DIR, 'GUIDE.md'), path.join(dir, 'GUIDE.md'));
  fs.copyFileSync(path.join(dir, 'AGENTS.md'), path.join(dir, 'CLAUDE.md'));
  const errors = validateManifest(loadManifest(dir));
  errors.forEach((m) => err(`manifest: ${m} (pass a valid --id)`));
  if (!errors.length) ok(`created ${dir} (${id}). Next: edit main.js + manifest.json, then \`smoke ${dir}\``);
}

function cmdPack(dir, flags) {
  const { manifest, runner } = checkDir(dir);
  if (!runner) return;
  const files = listPackFiles(dir);
  const key = flags.key ? fs.readFileSync(flags.key, 'utf8') : null;
  const { entries, digest, signer } = buildEntries(dir, files, key);
  const zip = writeZip(entries);
  verifyEntries(readZip(zip));
  const out = flags.out ?? path.join(dir, '..', `${manifest.id}-${manifest.version}.fushiplug`);
  fs.writeFileSync(out, zip);
  ok(`wrote ${path.resolve(out)} (${zip.length} bytes, ${files.length} files)`);
  console.log(`      digest ${digest}`);
  console.log(`      signer ${signer ?? '(unsigned — fine for testing; sign releases with --key so updates keep their login)'}`);
}

function cmdInspect(file) {
  const info = verifyEntries(readZip(fs.readFileSync(file)));
  ok(`${info.manifest.id} ${info.manifest.version} verifies like the app installer`);
  console.log(JSON.stringify({ ...info, network: info.manifest.network, permissions: info.manifest.permissions }, null, 2));
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const { pos, flags } = parseArgs(rest);
  switch (cmd) {
    case 'init':
      if (!pos[0]) return err('usage: init <dir>');
      return cmdInit(pos[0], flags);
    case 'check':
      return void checkDir(pos[0] ?? '.');
    case 'run':
      if (!pos[1]) return err('usage: run <dir> <method> [argsJson]');
      return cmdRun(pos[0], pos[1], pos[2], flags);
    case 'smoke':
      return cmdSmoke(pos[0] ?? '.', flags);
    case 'login':
      return cmdLogin(pos[0] ?? '.', flags);
    case 'reset':
      fs.rmSync(path.join(pos[0] ?? '.', '.fushi-dev'), { recursive: true, force: true });
      return ok('cleared .fushi-dev');
    case 'keygen': {
      const out = flags.out ?? 'fushi-plugin-key.pem';
      if (fs.existsSync(out)) return err(`${out} exists; refusing to overwrite a signing key`);
      const pem = generateKey();
      fs.writeFileSync(out, pem, { mode: 0o600 });
      ok(`wrote ${out}. Public key: ${publicKeyBase64(pem)}`);
      return console.log('      Keep it secret and backed up: updates signed by a different key are installed as a new plugin and lose their login.');
    }
    case 'pack':
      return cmdPack(pos[0] ?? '.', flags);
    case 'inspect':
      if (!pos[0]) return err('usage: inspect <file.fushiplug>');
      return cmdInspect(pos[0]);
    default:
      console.log(HELP);
  }
}

main()
  .catch((e) => err(e.message))
  .finally(() => {
    process.exitCode = hadError || (hadWarning && process.argv.includes('--strict')) ? 1 : 0;
  });
