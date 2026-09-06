import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assessReadiness } from './r2_mirror_readiness.mjs';

const manifest = (tag, names) => ({
  schemaVersion: 1,
  tag,
  assets: names.map((name) => ({ name, size: 1, sha256: 'x' })),
});

const FULL = [
  'fushi-2.2.4-arm64-v8a.apk',
  'fushi-2.2.4-armeabi-v7a.apk',
  'fushi-2.2.4-x86_64.apk',
  'fushi-2.2.4-windows-setup.exe',
  'fushi-2.2.4-macos.zip',
  'fushi-2.2.4-ios.ipa',
];

test('清单指向本 tag 且资产都在 release 上：就位', () => {
  const verdict = assessReadiness({
    publishedManifest: manifest('v2.2.4', FULL),
    tag: 'v2.2.4',
    releaseAssetNames: [...FULL, 'bridge-2.1.1-arm64-v8a.apk'],
  });
  assert.equal(verdict.ready, true);
  assert.equal(verdict.state, 'ready');
  assert.deepEqual(verdict.expected, FULL);
});

test('v2.2.4 的真实翻车形态：published 早到，清单还停在上一版', () => {
  // release 上此刻只有 bridge 包（12:12~12:56 传的），本体 13:44 之后才上传。
  // 旧实现就是在这一刻把 3 个 bridge apk 当全集镜像掉并报 success。
  const verdict = assessReadiness({
    publishedManifest: manifest('v2.2.3', ['fushi-2.2.3-windows-setup.exe']),
    tag: 'v2.2.4',
    releaseAssetNames: [
      'bridge-2.1.1-arm64-v8a.apk',
      'bridge-2.1.1-armeabi-v7a.apk',
      'bridge-2.1.1-x86_64.apk',
    ],
  });
  assert.equal(verdict.ready, false);
  assert.equal(verdict.state, 'manifest-tag-mismatch');
  assert.match(verdict.detail, /v2\.2\.3/);
  assert.deepEqual(verdict.expected, []);
});

test('清单已指向本 tag，但 release 上还缺文件：不镜像', () => {
  const verdict = assessReadiness({
    publishedManifest: manifest('v2.2.4', FULL),
    tag: 'v2.2.4',
    releaseAssetNames: FULL.slice(0, 3),
  });
  assert.equal(verdict.ready, false);
  assert.equal(verdict.state, 'assets-missing');
  assert.match(verdict.detail, /windows-setup/);
  assert.deepEqual(verdict.expected, []);
});

test('分批上传的中间态：清单只登记已传完的那批，就位判定按清单走', () => {
  // Android 批写清单时桌面包还没上传；此刻镜像 Android 三件是正确且完整的，
  // 桌面批写清单后会再触发一次把剩下的补齐（同 tag 重跑是幂等的）。
  const android = FULL.slice(0, 3);
  const verdict = assessReadiness({
    publishedManifest: manifest('v2.2.4', android),
    tag: 'v2.2.4',
    releaseAssetNames: android,
  });
  assert.equal(verdict.ready, true);
  assert.deepEqual(verdict.expected, android);
});

test('清单读坏或没有资产时判不就位，绝不当成「没东西要镜像」放行', () => {
  for (const bad of [{}, { tag: 'v2.2.4' }, manifest('v2.2.4', []), null]) {
    const verdict = assessReadiness({
      publishedManifest: bad,
      tag: 'v2.2.4',
      releaseAssetNames: FULL,
    });
    assert.equal(verdict.ready, false);
    assert.deepEqual(verdict.expected, []);
  }
});
