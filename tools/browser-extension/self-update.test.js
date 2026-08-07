// BUG-1079：扩展自更新状态机测试。旧实现「对某 remote build reload 过一次就永不重试」
// 导致自更新失败（磁盘副本没刷成 / 用户从别的目录加载 / 浏览器拒绝 reload）后永久停在
// 旧版且零提示。新状态机：同一 build 仍只 reload 一次，但每次心跳重新比对；已 reload
// 过仍不一致 → stale（提示用户手动重载）；恢复一致 → clear（清提示）。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const selfUpdate = require('./self-update.js');
const popup = require('./vendor/action-popup.js');

// ── 状态机 decide ──

test('首次发现新 build：reload（从磁盘拉新）', () => {
  assert.deepEqual(selfUpdate.decide('new1', 'old1', undefined, false), {
    action: 'reload',
  });
});

test('同一 remote build 只 reload 一次：已 reload 过仍不一致 → stale（不再 reload）', () => {
  const d = selfUpdate.decide('new1', 'old1', 'new1', false);
  assert.equal(d.action, 'stale');
  assert.deepEqual(d.stale, { remote: 'new1', local: 'old1' });
});

test('又出现更新的 build：latch 是对 build 而非永久 → 允许再 reload', () => {
  assert.equal(selfUpdate.decide('new2', 'old1', 'new1', false).action, 'reload');
});

test('恢复一致 → clear（清除 stale 提示）', () => {
  assert.equal(selfUpdate.decide('b1', 'b1', 'b1', false).action, 'clear');
  assert.equal(selfUpdate.decide('b1', 'b1', undefined, false).action, 'clear');
});

test('任一侧缺指纹（旧 app / 占位默认）→ none（向后兼容，绝不空转）', () => {
  assert.equal(selfUpdate.decide(undefined, 'old1', undefined, false).action, 'none');
  assert.equal(selfUpdate.decide('new1', undefined, undefined, false).action, 'none');
  assert.equal(selfUpdate.decide('', '', undefined, false).action, 'none');
});

test('正在录制 → none（reload 会杀 offscreen 录制；也不落 stale 打扰）', () => {
  assert.equal(selfUpdate.decide('new1', 'old1', undefined, true).action, 'none');
  assert.equal(selfUpdate.decide('new1', 'old1', 'new1', true).action, 'none');
});

// ── 状态请求体自报版本 ──

test('statusRequestBody 带上自身 build + manifest version', () => {
  const body = JSON.parse(
      selfUpdate.statusRequestBody({ build: 'abcd1234' }, '1.2.3'));
  assert.deepEqual(body, { build: 'abcd1234', version: '1.2.3' });
});

test('statusRequestBody 缺指纹时省略字段（占位默认 → 等同旧 \'{}\' 行为）', () => {
  assert.equal(selfUpdate.statusRequestBody({}, ''), '{}');
  assert.equal(selfUpdate.statusRequestBody(null, undefined), '{}');
});

// ── action-popup 提示文案 ──

test('stale 存在 → 提示指向 chrome://extensions 并带两侧 build 简写', () => {
  const notice = popup.hibikiUpdateNotice({ remote: 'aaaabbbbcccc', local: 'ddddeeeeffff' });
  assert.ok(notice.title.includes('新版本'));
  assert.ok(notice.detail.includes('chrome://extensions'));
  assert.ok(notice.detail.includes('aaaabbbb'));
  assert.ok(notice.detail.includes('ddddeeee'));
});

test('无 stale → null（提示行隐藏）', () => {
  assert.equal(popup.hibikiUpdateNotice(null), null);
  assert.equal(popup.hibikiUpdateNotice({}), null);
});

// ── background.js 接线（源码断言，同 connection-reopen.test.js 风格）──

const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');

test('background 经 importScripts 装载 self-update 状态机并用它决策', () => {
  assert.match(bg, /importScripts\('hibiki-defaults\.js', 'connection-diagnostics\.js', 'self-update\.js'\)/);
  assert.match(bg, /FUSHI_SELF_UPDATE\.decide\(/);
});

test('background 状态请求不再写死 {}：心跳/启动检查与连接诊断都自报版本', () => {
  assert.match(bg, /FUSHI_SELF_UPDATE\.statusRequestBody\(/);
  // /api/extension/status 的两处 fetch 都用 statusRequestBody()。
  const statusFetches = bg.split("'/api/extension/status'").length - 1;
  const reportingBodies = bg.split('body: statusRequestBody(),').length - 1;
  assert.ok(statusFetches >= 2, 'expect at least two status fetch sites');
  assert.equal(reportingBodies, statusFetches);
});

test('background stale 落盘 hibikiUpdateStale、恢复一致时清除', () => {
  assert.match(bg, /chrome\.storage\.local\.set\(\{ hibikiUpdateStale: decision\.stale \}\)/);
  assert.match(bg, /chrome\.storage\.local\.remove\(\['hibikiUpdateStale'\]\)/);
});

test('自更新角标让位录制角标：录制中跳过、录制结束恢复', () => {
  // refreshUpdateBadge 先查录制真态，录制中不动 badge（录制红点优先）。
  const fn = bg.indexOf('async function refreshUpdateBadge()');
  assert.ok(fn >= 0);
  const body = bg.slice(fn, fn + 600);
  assert.match(body, /if \(await isOffscreenRecording\(\)\) return;/);
  // 录制角标撤下（setRecordingBadge(false)）后恢复自更新角标。
  assert.match(bg, /if \(!on\) refreshUpdateBadge\(\);/);
});

test('action-popup 渲染 stale 提示并随 storage 实时显隐', () => {
  const js = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.html'), 'utf8');
  assert.match(html, /id="hp-update"/);
  assert.match(js, /chrome\.storage\.local\.get\(\['hibikiUpdateStale'\]/);
  assert.match(js, /changes\.hibikiUpdateStale/);
});

// ── describeUpdateState（options 页「版本与更新」卡片文案）──

test('describeUpdateState: stale → 警示 + 双指纹', () => {
  const s = selfUpdate.describeUpdateState(
    { build: 'aaaa1111bbbb2222' },
    { remote: 'cccc3333dddd4444', local: 'aaaa1111bbbb2222' });
  assert.equal(s.tone, 'warn');
  assert.ok(s.detail.includes('cccc3333'), '提示需含最新指纹短形式');
  assert.ok(s.detail.includes('aaaa1111'), '提示需含当前指纹短形式');
  assert.ok(s.detail.includes('重新加载'), '必须指引手动重载');
});

test('describeUpdateState: 无 build（开发副本）→ 不参与自动更新', () => {
  const s = selfUpdate.describeUpdateState({ host: '127.0.0.1' }, null);
  assert.equal(s.tone, 'neutral');
  assert.equal(s.build, '');
  assert.ok(s.title.includes('开发副本'));
});

test('describeUpdateState: 正常 → 自动更新说明 + build', () => {
  const s = selfUpdate.describeUpdateState({ build: 'aaaa1111bbbb2222' }, null);
  assert.equal(s.tone, 'ok');
  assert.equal(s.build, 'aaaa1111bbbb2222');
  assert.ok(s.detail.includes('自动重载'));
});
