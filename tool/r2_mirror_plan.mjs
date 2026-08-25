#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

function arg(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`missing ${name}`);
  }
  return process.argv[index + 1];
}

function positiveInt(raw, name) {
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`invalid ${name}: ${raw}`);
  return value;
}

function validAsset(asset) {
  return (
    asset &&
    typeof asset.name === 'string' &&
    asset.name.length > 0 &&
    Number.isSafeInteger(asset.size) &&
    asset.size >= 0
  );
}

function normalizeLedger(raw) {
  const releases = Array.isArray(raw?.releases) ? raw.releases : [];
  return releases.map((release) => {
    if (typeof release?.tag !== 'string' || !Array.isArray(release?.assets)) {
      throw new Error('legacy or invalid R2 ledger: every release needs tag + sized assets');
    }
    if (!release.assets.every(validAsset)) {
      throw new Error(`invalid sized assets in ledger tag ${release.tag}`);
    }
    return { tag: release.tag, assets: release.assets.map(({ name, size }) => ({ name, size })) };
  });
}

export function planMirror({ ledger, manifest, keepReleases, maxBytes }) {
  if (typeof manifest?.tag !== 'string' || !Array.isArray(manifest?.assets)) {
    throw new Error('invalid release manifest');
  }
  if (!manifest.assets.every(validAsset)) throw new Error('manifest assets need exact sizes');

  const existing = normalizeLedger(ledger);
  const sameTag = existing.filter((release) => release.tag === manifest.tag);
  const other = existing.filter((release) => release.tag !== manifest.tag);
  const keepExisting = Math.max(0, keepReleases - 1);
  const dropCount = Math.max(0, other.length - keepExisting);
  const dropped = [...sameTag, ...other.slice(0, dropCount)];
  const retained = other.slice(dropCount);

  const retainedBytes = retained.reduce(
    (sum, release) => sum + release.assets.reduce((part, asset) => part + asset.size, 0),
    0,
  );
  const incomingBytes = manifest.assets.reduce((sum, asset) => sum + asset.size, 0);
  const plannedBytes = retainedBytes + incomingBytes;
  const allowed = plannedBytes <= maxBytes;

  return {
    allowed,
    incomingBytes,
    retainedBytes,
    plannedBytes,
    deleteKeys: allowed
      ? dropped.flatMap((release) =>
          release.assets.map((asset) => `releases/${release.tag}/${asset.name}`),
        )
      : [],
    rollbackLedger: { schemaVersion: 2, releases: allowed ? retained : existing },
    ledger: allowed
      ? {
          schemaVersion: 2,
          releases: [
            ...retained,
            {
              tag: manifest.tag,
              assets: manifest.assets.map(({ name, size }) => ({ name, size })),
            },
          ],
        }
      : { schemaVersion: 2, releases: existing },
  };
}

function main() {
  const ledgerPath = arg('--ledger');
  const manifestPath = arg('--manifest');
  const plan = planMirror({
    ledger: JSON.parse(readFileSync(ledgerPath, 'utf8')),
    manifest: JSON.parse(readFileSync(manifestPath, 'utf8')),
    keepReleases: positiveInt(arg('--keep'), 'keep'),
    maxBytes: positiveInt(arg('--max-bytes'), 'max-bytes'),
  });

  writeFileSync(arg('--out-ledger'), JSON.stringify(plan.ledger, null, 2));
  writeFileSync(arg('--rollback-ledger'), JSON.stringify(plan.rollbackLedger, null, 2));
  writeFileSync(arg('--delete-list'), plan.deleteKeys.join('\n'));
  const output = arg('--github-output');
  writeFileSync(
    output,
    [
      `allowed=${plan.allowed}`,
      `incoming_bytes=${plan.incomingBytes}`,
      `retained_bytes=${plan.retainedBytes}`,
      `planned_bytes=${plan.plannedBytes}`,
    ].join('\n') + '\n',
    { flag: 'a' },
  );
  console.log(JSON.stringify(plan, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();

