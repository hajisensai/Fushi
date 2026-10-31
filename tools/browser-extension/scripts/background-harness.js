// 测试用：在 node:vm 沙箱里真 importScripts 装载 background.js 的公共壳（各 *.test.js 共用，
// 不再每个测试文件各抄一份 chrome.runtime 桩 / 沙箱全局 / importScripts 装载器）。
// 放在 scripts/ 下：sync-mirrors.mjs 不把本目录同步进 app 资源包。
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const EXT_DIR = path.join(__dirname, '..');

/** 任意深度属性访问 / 调用都不抛的 chrome.* 桩（调用一律 resolve {}）。 */
function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
}

/**
 * chrome.runtime 桩：onMessage 监听器收进 [listeners]，getURL 指向 chrome-extension://ext/。
 * @param {Function[]} listeners
 */
function runtimeMock(listeners) {
  return new Proxy({}, {
    get(_t, key) {
      if (key === 'onMessage') return { addListener(fn) { listeners.push(fn); } };
      if (key === 'getURL') return (p) => 'chrome-extension://ext/' + p;
      if (key === 'getManifest') return () => ({ version: '0.1.0' });
      if (key === 'lastError') return undefined;
      return permissive();
    },
  });
}

/**
 * 装载 background.js（及它 importScripts 的真实模块）。
 * @param {object} o
 * @param {object} o.chrome chrome 桩
 * @param {Function} o.fetch fetch 桩
 * @param {string} o.defaultsSource SW 启动时 importScripts('fushi-defaults.js') 读到的内容
 * @returns {object} 沙箱
 */
function bootBackground({ chrome, fetch, defaultsSource }) {
  const sandbox = {
    chrome, console, fetch,
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String, JSON, Array, Object, Math,
    performance, AbortController, AbortSignal, Error, TypeError, RegExp, Map, Set, Boolean,
    isNaN, parseInt, parseFloat,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  sandbox.importScripts = (...names) => {
    for (const name of names) {
      const src = name === 'fushi-defaults.js'
        ? defaultsSource : fs.readFileSync(path.join(EXT_DIR, name), 'utf8');
      vm.runInContext(src, sandbox, { filename: name });
    }
  };
  vm.runInContext(fs.readFileSync(path.join(EXT_DIR, 'background.js'), 'utf8'), sandbox,
    { filename: 'background.js' });
  return sandbox;
}

/**
 * 向 background 的 onMessage 监听器投递一条消息，[settle] 之后返回 sendResponse 的值。
 * @param {Function[]} listeners
 * @param {object} msg
 * @param {() => Promise<void>} settle
 */
async function sendToBackground(listeners, msg, settle) {
  let resp;
  for (const fn of listeners) fn(msg, {}, (r) => { resp = r; });
  await settle();
  return resp;
}

module.exports = { permissive, runtimeMock, bootBackground, sendToBackground };
