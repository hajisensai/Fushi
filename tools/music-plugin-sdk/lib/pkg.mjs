// .fushiplug packaging: file selection, files.json, Ed25519 signing, zip write / read, and the same
// verification the host runs on install (native/fushi_music/src/plugin/package.rs).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { LIMITS, checkRelPath, validateManifest } from './rules.mjs';

/// Files that go into the package: manifest.json + every .js file, skipping dot-folders / dot-files,
/// node_modules and anything ending in .d.ts. Plugins cannot read other files at runtime (only `require`
/// of .js), so nothing else is packed.
export function listPackFiles(dir) {
  const out = [];
  const walk = (rel) => {
    for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
      if (e.name.startsWith('.') || e.name === 'node_modules') continue;
      const p = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && ((p.endsWith('.js') && !p.endsWith('.d.ts')) || p === 'manifest.json')) out.push(p);
    }
  };
  walk('');
  // Code-unit order (what the default sort did), spelled out so it is not mistaken for a numeric sort.
  return out.sort((a, b) => (a < b ? -1 : Number(a > b)));
}

const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex');

/// Checks the selected files against package limits; returns error strings.
export function checkFiles(dir, files) {
  const errors = [];
  if (!files.includes('manifest.json')) errors.push('manifest.json is missing');
  if (files.length > LIMITS.maxFiles) errors.push(`more than ${LIMITS.maxFiles} files`);
  let total = 0;
  for (const f of files) {
    try {
      checkRelPath(f);
    } catch (e) {
      errors.push(e.message);
    }
    const size = fs.statSync(path.join(dir, f)).size;
    total += size;
    if (size > LIMITS.maxFileBytes) errors.push(`${f} is larger than 4 MiB`);
  }
  if (total > LIMITS.maxTotalBytes) errors.push('package content is larger than 16 MiB');
  return errors;
}

export function generateKey() {
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  return privateKey.export({ type: 'pkcs8', format: 'pem' });
}

export function publicKeyBase64(privatePem) {
  const jwk = crypto.createPublicKey(crypto.createPrivateKey(privatePem)).export({ format: 'jwk' });
  return Buffer.from(jwk.x, 'base64url').toString('base64');
}

/// Builds the package entries (path → bytes) including files.json and, with a key, signature.json.
export function buildEntries(dir, files, privatePem) {
  const entries = new Map();
  const listing = {};
  for (const f of files) {
    const data = fs.readFileSync(path.join(dir, f));
    entries.set(f, data);
    listing[f] = sha256(data);
  }
  const filesJson = Buffer.from(JSON.stringify({ files: listing }, null, 2) + '\n');
  entries.set('files.json', filesJson);
  let signer = null;
  if (privatePem) {
    const key = crypto.createPrivateKey(privatePem);
    if (key.asymmetricKeyType !== 'ed25519') throw new Error('signing key must be an Ed25519 private key (run: fushi-plugin keygen)');
    signer = publicKeyBase64(privatePem);
    const signature = crypto.sign(null, filesJson, key).toString('base64');
    entries.set('signature.json', Buffer.from(JSON.stringify({ publicKey: signer, signature }, null, 2) + '\n'));
  }
  return { entries, digest: sha256(filesJson), signer };
}

let crcTable;
function crc32(buf) {
  if (zlib.crc32) return zlib.crc32(buf);
  crcTable ??= Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function writeZip(entries) {
  const locals = [];
  const central = [];
  let offset = 0;
  for (const [name, data] of entries) {
    const nameBuf = Buffer.from(name, 'utf8');
    const deflated = zlib.deflateRawSync(data, { level: 9 });
    const useDeflate = deflated.length < data.length;
    const body = useDeflate ? deflated : data;
    const crc = crc32(data);
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0);
    h.writeUInt16LE(20, 4);
    h.writeUInt16LE(0x0800, 6); // UTF-8 names
    h.writeUInt16LE(useDeflate ? 8 : 0, 8);
    h.writeUInt32LE(0x00210000, 10); // fixed DOS time: 1980-01-01, reproducible output
    h.writeUInt32LE(crc, 14);
    h.writeUInt32LE(body.length, 18);
    h.writeUInt32LE(data.length, 22);
    h.writeUInt16LE(nameBuf.length, 26);
    locals.push(h, nameBuf, body);
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0);
    c.writeUInt16LE(0x0314, 4);
    c.writeUInt16LE(20, 6);
    c.writeUInt16LE(0x0800, 8);
    c.writeUInt16LE(useDeflate ? 8 : 0, 10);
    c.writeUInt32LE(0x00210000, 12);
    c.writeUInt32LE(crc, 16);
    c.writeUInt32LE(body.length, 20);
    c.writeUInt32LE(data.length, 24);
    c.writeUInt16LE(nameBuf.length, 28);
    c.writeUInt32LE((0o100644 << 16) >>> 0, 38);
    c.writeUInt32LE(offset, 42);
    central.push(c, nameBuf);
    offset += 30 + nameBuf.length + body.length;
  }
  const cd = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.size, 8);
  end.writeUInt16LE(entries.size, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

export function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a valid zip');
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const entries = new Map();
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('corrupt zip central directory');
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const nlen = buf.readUInt16LE(p + 28);
    const xlen = buf.readUInt16LE(p + 30);
    const clen = buf.readUInt16LE(p + 32);
    const attrs = buf.readUInt32LE(p + 38);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nlen);
    p += 46 + nlen + xlen + clen;
    if (name.endsWith('/')) continue;
    if (((attrs >>> 16) & 0o170000) === 0o120000) throw new Error('packages must not contain symlinks');
    const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const raw = buf.subarray(start, start + csize);
    let data;
    if (method === 0) data = raw;
    else if (method === 8) data = zlib.inflateRawSync(raw, { maxOutputLength: LIMITS.maxFileBytes + 1 });
    else throw new Error(`${name}: unsupported zip compression method ${method}`);
    if (entries.has(name)) throw new Error(`duplicate zip entry ${name}`);
    entries.set(name, data);
  }
  return entries;
}

/// Verifies a package exactly like the host's install step. Returns { manifest, digest, signer, files }.
export function verifyEntries(all) {
  const errors = [];
  if (all.size > LIMITS.maxFiles + 2) throw new Error('too many files in the package');
  let total = 0;
  for (const [name, data] of all) {
    checkRelPath(name);
    if (data.length > LIMITS.maxFileBytes) throw new Error(`${name} is larger than 4 MiB`);
    total += data.length;
  }
  if (total > LIMITS.maxTotalBytes) throw new Error('package is larger than 16 MiB unpacked');
  const files = new Map(all);
  const filesRaw = files.get('files.json');
  if (!filesRaw) throw new Error('files.json is missing');
  files.delete('files.json');
  const sigRaw = files.get('signature.json');
  files.delete('signature.json');
  const listing = JSON.parse(filesRaw.toString('utf8'));
  const keys = Object.keys(listing);
  if (keys.length !== 1 || keys[0] !== 'files' || typeof listing.files !== 'object') throw new Error('files.json must be exactly {"files": {...}}');
  const listed = Object.keys(listing.files);
  const extra = [...files.keys()].filter((k) => !listed.includes(k));
  const missing = listed.filter((k) => !files.has(k));
  if (extra.length || missing.length) throw new Error(`files.json does not match the package (unlisted: ${JSON.stringify(extra)}; missing: ${JSON.stringify(missing)})`);
  for (const [p, want] of Object.entries(listing.files)) {
    if (sha256(files.get(p)) !== String(want).toLowerCase()) throw new Error(`${p}: sha256 mismatch`);
  }
  let signer = null;
  if (sigRaw) {
    const sig = JSON.parse(sigRaw.toString('utf8'));
    const pub = Buffer.from(sig.publicKey ?? '', 'base64');
    const s = Buffer.from(sig.signature ?? '', 'base64');
    if (pub.length !== 32) throw new Error('signature.json publicKey must be 32 bytes of base64');
    if (s.length !== 64) throw new Error('signature.json signature must be 64 bytes of base64');
    const key = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: pub.toString('base64url') }, format: 'jwk' });
    if (!crypto.verify(null, filesRaw, key, s)) throw new Error('signature verification failed');
    signer = sig.publicKey;
  }
  const manifestRaw = files.get('manifest.json');
  if (!manifestRaw) throw new Error('manifest.json is missing');
  const manifest = JSON.parse(manifestRaw.toString('utf8'));
  errors.push(...validateManifest(manifest));
  if (errors.length) throw new Error(errors.join('\n'));
  if (!files.has(manifest.entry)) throw new Error(`entry ${manifest.entry} is not in the package`);
  return { manifest, digest: sha256(filesRaw), signer, files: [...files.keys()] };
}
