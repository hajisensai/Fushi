#!/usr/bin/env node
// fushi-tracking-plugin — zero-dependency dev tool for Fushi tracking site plugins (Node >= 18).
// Run without arguments for help. Docs: GUIDE.md next to this file.
//
// The sandbox, the package format and the network policy are the music kit's (same engine in the app):
// this file only adds the tracking vocabulary, result checks and commands.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { buildEntries, checkFiles, generateKey, listPackFiles, publicKeyBase64, readZip, verifyEntries, writeZip } from '../music-plugin-sdk/lib/pkg.mjs';
import { PluginError, PluginRunner } from '../music-plugin-sdk/lib/runner.mjs';
import { KNOWN_TRACKING_CAPABILITIES, STRIPPED_ERROR_NAMES, classifyError, validateManifest, warnings as manifestWarnings } from './lib/rules.mjs';
import { validateArgs, validateResult } from './lib/validate.mjs';

const SDK_DIR = path.dirname(fileURLToPath(import.meta.url));

const HELP = `fushi-tracking-plugin — build, run and package Fushi tracking site plugins

  init <dir> [--id <id>] [--name <name>]   scaffold a new plugin (manifest, main.js, typings, guide)
  check <dir>                              validate manifest, files and exports like the host does
  run <dir> <capability> [argsJson]        call one capability, validate the arguments and the result
        [--trace] [--full]                   --trace logs every HTTP request; --full prints untruncated JSON
  smoke <dir> [--query <q>] [--kind <k>] [--id <n>]
                                           read-only tour: account, login methods, search, subject,
                                           lookup, entry get (never writes to the site)
  login <dir>                              sign in interactively (form methods) and save credentials
  reset <dir>                              clear local storage / credentials (<dir>/.fushi-dev)
  keygen [--out <file>]                    create an Ed25519 signing key (default: fushi-plugin-key.pem)
  pack <dir> [--key <pem>] [--out <file>]  check, then write <id>-<version>.fushiplug
  inspect <file.fushiplug>                 verify a package exactly like the app's installer

Exit code: 0 = ok (warnings allowed), 1 = errors. Add --strict to fail on warnings too.
Examples:
  node fushi-tracking-plugin.mjs run ./my-plugin trackingSearch '{"query":"frieren","kind":"anime"}'
  node fushi-tracking-plugin.mjs run ./my-plugin trackingEntry '{"op":"get","id":52991,"kind":"anime"}'`;

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
const note = (msg) => console.log(c.dim(`      ${msg}`));

function loadManifest(dir) {
  const file = path.join(dir, 'manifest.json');
  if (!fs.existsSync(file)) throw new Error(`${file} not found`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    throw new Error(`manifest.json is not valid JSON: ${e.message}`);
  }
}

function makeRunner(dir, manifest, flags) {
  return new PluginRunner(dir, manifest, {
    trace: !!flags.trace,
    knownCapabilities: KNOWN_TRACKING_CAPABILITIES,
    log: (level, msg) => {
      const tag = level === 'trace' ? 'http ' : `${level.padEnd(5)}`;
      const line = `${c.dim('[plugin]')} ${tag} ${msg}`;
      process.stderr.write((level === 'error' ? c.red(line) : level === 'warn' ? c.yellow(line) : line) + '\n');
    },
  });
}

function checkDir(dir, { quiet = false } = {}) {
  const manifest = loadManifest(dir);
  const merrs = validateManifest(manifest);
  merrs.forEach((m) => err(`manifest: ${m}`));
  manifestWarnings.forEach((m) => warn(`manifest: ${m}`));
  const files = listPackFiles(dir);
  checkFiles(dir, files).forEach((m) => err(`files: ${m}`));
  if (merrs.length) return { manifest, runner: null };
  if (!files.includes(manifest.entry)) {
    err(`entry ${manifest.entry} not found in ${dir}`);
    return { manifest, runner: null };
  }
  const t = manifest.tracking;
  if (!manifest.network.domains.some((d) => d === t.siteHost || (d.startsWith('*.') && t.siteHost.endsWith(d.slice(1))))) {
    note(`tracking.siteHost ${t.siteHost} is not in network.domains (fine if the API lives on another host; it is only used to recognize pasted links)`);
  }
  const runner = makeRunner(dir, manifest, {});
  try {
    runner.boot();
  } catch (e) {
    err(e.message);
    return { manifest, runner: null };
  }
  runner.bootWarnings.forEach((m) => warn(m));
  if (!quiet) ok(`${manifest.id} ${manifest.version} (site "${t.siteId}"): manifest valid, ${files.length} files, exports ${manifest.capabilities.join(', ')}`);
  return { manifest, runner };
}

function show(value, full) {
  let text = JSON.stringify(value, null, 2);
  if (!full && text.length > 6000) text = text.slice(0, 6000) + `\n… (${text.length} chars, use --full)`;
  console.log(text);
}

/// Invokes one capability, validates args + result, prints. Returns { value } on success, { error } when the
/// plugin threw (classified like the host), or undefined on a validation failure.
async function call(runner, manifest, method, args, { print = true, full = false, label } = {}) {
  const name = label ?? `${method} ${JSON.stringify(args)}`;
  validateArgs(method, args, manifest).forEach((m) => warn(`${name}: ${m} (the host would not send this)`));
  const started = Date.now();
  const httpBefore = runner.httpCount;
  let value;
  try {
    value = await runner.invoke(method, args);
  } catch (e) {
    if (!(e instanceof PluginError)) {
      err(`${name}: ${e.message}`);
      return undefined;
    }
    const [head, ...rest] = e.message.split('\n');
    const frames = rest.filter((l) => /^\s+at /.test(l) && !/node:|[\\/]lib[\\/]runner\.mjs|fushi-tracking-plugin\.mjs|prelude\.js/.test(l));
    const k = classifyError(e.message);
    const line = `${name} threw: ${head}${frames.length ? '\n' + c.dim(frames.join('\n')) : ''}`;
    // A prefixed error is a deliberate answer (signed out / rate limited / gone); anything else is a failure.
    if (k.kind === 'temporary') err(line);
    else console.log(c.yellow(`THROW ${line}`));
    note(`host reads this as: ${k.meaning}`);
    note(`shown to the user: ${JSON.stringify(k.shown)}`);
    if (k.errorName && !STRIPPED_ERROR_NAMES.includes(k.errorName)) {
      warn(`${name}: thrown as a custom ${k.errorName}; the host does not strip "${k.errorName}: ", so the user sees it and no prefix is recognized — throw a plain Error`);
    } else if (k.errorName && k.errorName !== 'Error') warn(`${name}: thrown as ${k.errorName}; throw new Error('<prefix>: ...') for deliberate errors (a ${k.errorName} usually means a bug)`);
    if (!k.errorName && k.kind === 'temporary') warn(`${name}: a non-Error value was thrown; throw new Error(...) so the message and stack reach the app log`);
    if (k.kind === 'temporary' && /^(unauthori[sz]ed|rate.?limited|not.?found)\b/i.test(k.message)) {
      warn(`${name}: the message looks like a prefixed error but is not exactly "unauthorized:", "rate_limited:" or "not_found:" — the host treats it as temporary`);
    }
    return { error: k };
  }
  if (print) show(value, full);
  const r = validateResult(method, args, value, { manifest, policy: runner.policy });
  r.errors.forEach((m) => err(m));
  r.warnings.slice(0, 30).forEach((m) => warn(m));
  if (r.warnings.length > 30) warn(`… ${r.warnings.length - 30} more warnings`);
  const requests = runner.httpCount - httpBefore;
  const rpm = manifest.tracking.requestsPerMinute;
  if (requests > rpm) warn(`${name}: ${requests} HTTP requests in one call, more than requestsPerMinute=${rpm}; the host holds the extra requests back and a call gets 60 s in the app, so it can time out (use fewer requests per call)`);
  if (!r.errors.length) ok(`${name} (${Date.now() - started} ms${requests ? `, ${requests} HTTP` : ''})`);
  return r.errors.length ? undefined : { value };
}

function prepare(dir, flags) {
  const manifest = loadManifest(dir);
  validateManifest(manifest).forEach((m) => err(`manifest: ${m}`));
  if (hadError) return null;
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  runner.bootWarnings.forEach((m) => warn(m));
  return { manifest, runner };
}

async function cmdRun(dir, method, argsJson, flags) {
  if (!KNOWN_TRACKING_CAPABILITIES.includes(method)) return err(`unknown capability ${method} (tracking capabilities: ${KNOWN_TRACKING_CAPABILITIES.join(', ')})`);
  let args;
  try {
    args = argsJson ? JSON.parse(argsJson) : {};
  } catch (e) {
    return err(`argsJson is not valid JSON: ${e.message}`);
  }
  const ready = prepare(dir, flags);
  if (!ready) return;
  if (!ready.manifest.capabilities.includes(method)) warn(`${method} is not declared in manifest.capabilities — the host would never call it`);
  await call(ready.runner, ready.manifest, method, args, { full: flags.full });
}

async function cmdSmoke(dir, flags) {
  const { manifest, runner: booted } = checkDir(dir);
  if (!booted) return;
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  const caps = new Set(manifest.capabilities);
  const kind = flags.kind ?? manifest.tracking.defaultKinds?.[0] ?? manifest.tracking.kinds[0];
  const opt = { print: false };
  const a = await call(runner, manifest, 'account', {}, opt);
  const loggedIn = a?.value?.loggedIn === true;
  if (a && !loggedIn) note('(signed out — run `login` to test trackingEntry)');
  await call(runner, manifest, 'login', { op: 'methods', platform: platformName() }, opt);
  let subject = null;
  if (flags.id) subject = { id: Number(flags.id), kind };
  if (caps.has('trackingSearch')) {
    const q = flags.query ?? 'a';
    const s = await call(runner, manifest, 'trackingSearch', { query: q, kind }, opt);
    const hit = s?.value?.items?.find((x) => Number.isInteger(x?.id) && x.id > 0);
    if (s?.value && !hit) warn(`trackingSearch "${q}" (${kind}) found nothing usable (try --query)`);
    subject ??= hit ?? null;
  }
  if (!subject) return warn('no subject to continue with: pass --id <subject id> (or declare trackingSearch and pass --query)');
  const got = await call(runner, manifest, 'trackingSubject', { id: subject.id, kind }, opt);
  if (got?.value === null) warn(`trackingSubject ${subject.id} returned null`);
  const linked = got?.value?.linkedIds ?? {};
  if (caps.has('trackingLookup')) {
    const [idType, id] = Object.entries(linked).find(([k]) => k !== manifest.tracking.siteId) ?? [];
    if (idType) await call(runner, manifest, 'trackingLookup', { idType, id, kind }, opt);
    else note('(no linkedIds on the subject; skipped trackingLookup — try `run ... trackingLookup` by hand)');
  }
  if (loggedIn) {
    const e = await call(runner, manifest, 'trackingEntry', { op: 'get', id: subject.id, kind }, opt);
    if (e?.value === null) note(`(subject ${subject.id} is not on the list)`);
  }
  note(`${runner.httpCount} HTTP requests (trackingEntry set is never called by smoke; test writes with \`run\`)`);
}

function platformName() {
  return { win32: 'windows', darwin: 'macos', linux: 'linux' }[process.platform] ?? 'linux';
}

async function cmdLogin(dir, flags) {
  const { manifest, runner: booted } = checkDir(dir, { quiet: true });
  if (!booted) return;
  const runner = makeRunner(dir, manifest, flags);
  runner.boot();
  const platform = platformName();
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
    const m = await call(runner, manifest, 'login', { op: 'methods', platform }, { print: false });
    const methods = (m?.value?.methods ?? []).filter((x) => x && typeof x.id === 'string' && x.type === 'form');
    if (!methods.length) return;
    methods.forEach((x, i) => console.log(`  ${i + 1}. ${x.label}${x.description ? ' — ' + x.description : ''}`));
    const pick = methods.length > 1 ? (methods[(Number(await ask('Choose a method: ')) || 1) - 1] ?? methods[0]) : methods[0];
    let r = await call(runner, manifest, 'login', { op: 'begin', method: pick.id, platform }, { print: false });
    let ch = r?.value;
    while (ch && ch.state === 'pending' && ch.form) {
      if (ch.message) console.log(`  ${ch.message}`);
      if (ch.appUrl) console.log(`  [Open site] ${ch.appUrl}`);
      const inputs = {};
      for (const f of ch.form.fields ?? []) {
        const v = await ask(`  ${f.label}${f.placeholder ? ` (${f.placeholder})` : ''}${f.value ? ` [${f.value}]` : ''}: `);
        inputs[f.id] = v === '' && typeof f.value === 'string' ? f.value : v;
      }
      const actions = ch.form.actions ?? [];
      actions.forEach((a, i) => console.log(`  ${i + 1}. ${a.label}${a.primary ? ' (primary)' : ''}`));
      const action = actions.length > 1 ? (actions[(Number(await ask('  Action: ')) || 1) - 1] ?? actions[0]) : actions[0];
      r = await call(runner, manifest, 'login', { op: 'submit', method: pick.id, session: ch.session, platform, action: action?.id, inputs }, { print: false, label: 'login submit' });
      ch = r?.value;
    }
    if (ch?.state === 'done') {
      ok(`signed in${ch.account?.name ? ' as ' + ch.account.name : ''} (credentials saved in ${path.join(dir, '.fushi-dev')})`);
      await call(runner, manifest, 'account', {}, {});
    } else if (ch) err(`login ${ch.state}: ${ch.message ?? ''}`);
  } finally {
    rl.close();
  }
}

function cmdInit(dir, flags) {
  if (fs.existsSync(dir) && fs.readdirSync(dir).length) return err(`${dir} is not empty`);
  const base = path.basename(path.resolve(dir)).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'site';
  const id = flags.id ?? `dev.example.tracking.${base}`;
  const name = flags.name ?? path.basename(path.resolve(dir));
  const tpl = path.join(SDK_DIR, 'templates', 'starter');
  fs.mkdirSync(dir, { recursive: true });
  for (const f of fs.readdirSync(tpl)) {
    let text = fs.readFileSync(path.join(tpl, f), 'utf8');
    text = text
      .replaceAll('__PLUGIN_ID__', id)
      .replaceAll('__PLUGIN_NAME__', name)
      .replaceAll('__SDK_CLI__', path.join(SDK_DIR, 'fushi-tracking-plugin.mjs').replaceAll('\\', '/'));
    // Template names avoid files the Fushi repo ignores (.gitignore, AGENTS.md).
    const out = { gitignore: '.gitignore', 'AGENTS.template.md': 'AGENTS.md' }[f] ?? f;
    fs.writeFileSync(path.join(dir, out), text);
  }
  // The contract travels with the plugin so an agent working in <dir> has everything locally.
  fs.copyFileSync(path.join(SDK_DIR, 'fushi-tracking-plugin.d.ts'), path.join(dir, 'fushi-tracking-plugin.d.ts'));
  fs.copyFileSync(path.join(SDK_DIR, 'GUIDE.md'), path.join(dir, 'GUIDE.md'));
  fs.copyFileSync(path.join(dir, 'AGENTS.md'), path.join(dir, 'CLAUDE.md'));
  const errors = validateManifest(loadManifest(dir));
  errors.forEach((m) => err(`manifest: ${m} (pass a valid --id)`));
  if (!errors.length) ok(`created ${dir} (${id}). Next: set tracking.siteId / siteHost and network.domains, implement main.js, then \`check ${dir}\``);
}

function cmdPack(dir, flags) {
  const { manifest, runner } = checkDir(dir);
  if (!runner) return;
  const files = listPackFiles(dir);
  const key = flags.key ? fs.readFileSync(flags.key, 'utf8') : null;
  const { entries, digest, signer } = buildEntries(dir, files, key);
  const zip = writeZip(entries);
  verifyEntries(readZip(zip), { validate: validateManifest });
  const out = flags.out ?? path.join(dir, '..', `${manifest.id}-${manifest.version}.fushiplug`);
  fs.writeFileSync(out, zip);
  ok(`wrote ${path.resolve(out)} (${zip.length} bytes, ${files.length} files)`);
  note(`digest ${digest}`);
  note(`signer ${signer ?? '(unsigned — fine for testing; sign releases with --key so updates keep their sign-in)'}`);
}

function cmdInspect(file) {
  const info = verifyEntries(readZip(fs.readFileSync(file)), { validate: validateManifest });
  ok(`${info.manifest.id} ${info.manifest.version} verifies like the app installer (tracking site "${info.manifest.tracking.siteId}")`);
  console.log(JSON.stringify({ ...info, network: info.manifest.network, permissions: info.manifest.permissions, tracking: info.manifest.tracking }, null, 2));
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
      if (!pos[1]) return err('usage: run <dir> <capability> [argsJson]');
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
      return note('Keep it secret and backed up: updates signed by a different key are installed as a new plugin and lose their sign-in.');
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
