// 测试用：把 locales/en.js（源）+ locales/<tag>.json 装成一个 fushiT，供各 *.test.js 的 vm 壳
// 注入（sandbox.fushiT / window.fushiT）。行为测试历来按中文文案断言，默认装 zh-CN；
// 不装的壳里各模块的 tr() 退回键名，断言文案的用例就要显式注入。
// 放在 scripts/ 下：sync-mirrors.mjs 不把本目录同步进 app 资源包。
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const LOCALES = path.join(__dirname, '..', 'locales');

function loadEn() {
  const sandbox = { self: {} };
  sandbox.window = sandbox.self;
  vm.runInNewContext(fs.readFileSync(path.join(LOCALES, 'en.js'), 'utf8'), sandbox);
  return sandbox.self.FUSHI_I18N_EN;
}

function loadDict(tag) {
  if (tag === 'en') return loadEn();
  return JSON.parse(fs.readFileSync(path.join(LOCALES, tag + '.json'), 'utf8'));
}

function format(text, params) {
  if (!params || typeof text !== 'string') return text;
  return text.replace(/\{(\w+)\}/g, (m, k) =>
    Object.prototype.hasOwnProperty.call(params, k) ? String(params[k]) : m);
}

function makeFushiT(tag = 'zh-CN') {
  const en = loadEn();
  const dict = loadDict(tag);
  return (key, params) => {
    const v = typeof dict[key] === 'string' ? dict[key] : en[key];
    return typeof v === 'string' ? format(v, params) : key;
  };
}

module.exports = { makeFushiT, loadEn, loadDict };
