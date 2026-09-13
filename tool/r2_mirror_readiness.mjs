#!/usr/bin/env node

/*
 * 「这批正式版资产是否已经上传完」的判据。
 *
 * 背景：GitHub 的 `release: published` 事件只说明 release 条目建好了，跟资产传没传完
 * 毫无关系——Fushi 的正式版由 release.yml / release-desktop.yml 分批上传，实测比
 * published 晚 30～100 分钟（v2.2.4：published 13:14，Android 13:44，桌面 14:52）。
 * 旧的镜像流程把 published 那一刻 release 上有什么当成全集，于是只镜像到 3 个无关的
 * bridge apk 就报 success，fushi.moe 的「Cloudflare 镜像」整整三天都在 302 去 GitHub。
 *
 * 真相源是 update-manifest 分支上的正式版清单：它由上传完成的那个 job 写，也正是
 * fushi.moe 的 Worker 判定「这个版本有哪些下载」的权威，并且跨平台取并集——所以它
 * 列出的就是此刻该 tag 已发布的全部资产。镜像只在「清单指向本 tag，且清单里的每个
 * 资产在 release 上都找得到」时才动手。
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

function arg(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`missing ${name}`);
  }
  return process.argv[index + 1];
}

/**
 * @param {{ publishedManifest: unknown, tag: string, releaseAssetNames: readonly string[] }} input
 * @returns {{ ready: boolean, state: string, detail: string, expected: string[] }}
 */
export function assessReadiness({ publishedManifest, tag, releaseAssetNames }) {
  const manifest = /** @type {{ tag?: unknown, assets?: unknown }} */ (publishedManifest);
  if (typeof manifest?.tag !== 'string' || !Array.isArray(manifest?.assets)) {
    return { ready: false, state: 'manifest-invalid', detail: '清单缺 tag 或 assets', expected: [] };
  }
  if (manifest.tag !== tag) {
    return {
      ready: false,
      state: 'manifest-tag-mismatch',
      detail: `清单登记的是 ${manifest.tag}`,
      expected: [],
    };
  }

  const expected = manifest.assets
    .map((asset) => (asset && typeof asset.name === 'string' ? asset.name : ''))
    .filter((name) => name.length > 0);
  if (expected.length === 0) {
    return { ready: false, state: 'manifest-empty', detail: '清单里没有资产', expected: [] };
  }

  const present = new Set(releaseAssetNames);
  const missing = expected.filter((name) => !present.has(name));
  if (missing.length > 0) {
    return {
      ready: false,
      state: 'assets-missing',
      detail: missing.join(', '),
      expected: [],
    };
  }

  return { ready: true, state: 'ready', detail: String(expected.length), expected };
}

function readLines(path) {
  return readFileSync(path, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function main() {
  const verdict = assessReadiness({
    publishedManifest: JSON.parse(readFileSync(arg('--published-manifest'), 'utf8')),
    tag: arg('--tag'),
    releaseAssetNames: readLines(arg('--release-assets')),
  });

  // 就位的才写期望清单：下游的完整性断言以它存在为前提，宁可没有也不要半份。
  if (verdict.ready) {
    writeFileSync(arg('--out-expected'), verdict.expected.join('\n') + '\n');
  }
  writeFileSync(arg('--github-output'), `skip=${verdict.ready ? 'false' : 'true'}\n`, {
    flag: 'a',
  });
  console.log(`${verdict.state}\t${verdict.detail}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
