const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const optionsSource = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
const popupSource = fs.readFileSync(
  path.join(__dirname, 'vendor', 'action-popup.js'),
  'utf8',
);

test('设置页每次打开都绕过短时离线缓存，立即重新检测 Hibiki', () => {
  assert.match(
    optionsSource,
    /loadSettings\(\)\.then\(\(\) => refreshConnection\(true\)\)/,
  );
});

test('扩展图标弹窗每次打开都强制重新检测连接', () => {
  assert.match(
    popupSource,
    /sendMessage\(\{ type: 'connectionStatus', force: true \}/,
  );
});
