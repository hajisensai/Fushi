#!/usr/bin/env node
// 扩展镜像一键同步：tools/browser-extension（真源）→ hibiki/assets/browser_extension（Flutter
// asset 打包镜像）。此前同步靠「手动 cp + Dart 字节守卫兜底」，漏拷任一文件守卫即红且提示晦涩；
// 现在改动扩展后跑一次本脚本即可，守卫只做最后防线。
//
//   node scripts/sync-mirrors.mjs          # 同步（新增/更新/删除多余文件）
//   node scripts/sync-mirrors.mjs --check  # 只校验不写盘；有漂移 exit 1（可挂 CI/pre-commit）
//
// 排除项（不进 app bundle）：*.test.js、scripts/、README.md。
// 另外校验 vendor/ 四件套（popup.js/popup.css/popup.html/selection.js）与其上游
// hibiki/assets/popup/ 是否字节一致——它们的真源在 app 侧，方向是 assets/popup → 两处 vendor/，
// 本脚本**绝不**反向覆盖，只报告漂移（同步命令见输出提示）。vendor/dict-media.js 允许有
// 扩展侧分叉（image:// → http 重写），不在校验列表。
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const SRC = path.resolve(HERE, '..'); // tools/browser-extension
const REPO = path.resolve(SRC, '..', '..'); // 仓库根
const DEST = path.join(REPO, 'hibiki', 'assets', 'browser_extension');
const POPUP_UPSTREAM = path.join(REPO, 'hibiki', 'assets', 'popup');
const VENDOR_FROM_POPUP = ['popup.js', 'popup.css', 'popup.html', 'selection.js'];

const checkOnly = process.argv.includes('--check');

function excluded(rel) {
  const top = rel.split(/[\\/]/)[0];
  return top === 'scripts' || /\.test\.js$/i.test(rel) || rel === 'README.md';
}

function walk(dir, base, out) {
  base = base || dir;
  out = out || [];
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, base, out);
    else out.push(path.relative(base, p).replace(/\\/g, '/'));
  }
  return out;
}

function sameBytes(a, b) {
  if (!fs.existsSync(a) || !fs.existsSync(b)) return false;
  const ba = fs.readFileSync(a);
  const bb = fs.readFileSync(b);
  return ba.equals(bb);
}

let drift = 0;
const actions = [];

// ── 真源 → assets 镜像 ──
const srcFiles = walk(SRC).filter((rel) => !excluded(rel));
const destFiles = walk(DEST);

for (const rel of srcFiles) {
  const from = path.join(SRC, rel);
  const to = path.join(DEST, rel);
  if (sameBytes(from, to)) continue;
  drift++;
  if (checkOnly) {
    actions.push(`漂移: ${rel}`);
  } else {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(from, to);
    actions.push(`已同步: ${rel}`);
  }
}
for (const rel of destFiles) {
  if (srcFiles.includes(rel)) continue;
  drift++;
  if (checkOnly) {
    actions.push(`镜像多余文件: ${rel}`);
  } else {
    fs.rmSync(path.join(DEST, rel));
    actions.push(`已删除镜像多余文件: ${rel}`);
  }
}

// ── vendor 四件套 ↔ assets/popup 上游校验（只报告，不写盘）──
let vendorDrift = 0;
for (const name of VENDOR_FROM_POPUP) {
  const upstream = path.join(POPUP_UPSTREAM, name);
  const vendor = path.join(SRC, 'vendor', name);
  if (!sameBytes(upstream, vendor)) {
    vendorDrift++;
    actions.push(
      `vendor 漂移: vendor/${name} ≠ hibiki/assets/popup/${name}` +
      `（上游在 assets/popup，手动: cp hibiki/assets/popup/${name} tools/browser-extension/vendor/${name} 后重跑本脚本）`);
  }
}

for (const line of actions) console.log(line);
if (checkOnly) {
  if (drift + vendorDrift === 0) {
    console.log('镜像一致 ✓');
  } else {
    console.error(`共 ${drift + vendorDrift} 处漂移（--check 模式未写盘）`);
    process.exit(1);
  }
} else {
  console.log(drift === 0 ? '镜像本已一致 ✓' : `已同步 ${drift} 个文件 → hibiki/assets/browser_extension`);
  if (vendorDrift > 0) {
    console.error(`注意：${vendorDrift} 个 vendor 文件与 assets/popup 上游不一致（见上，需手动处理）`);
    process.exit(1);
  }
}
