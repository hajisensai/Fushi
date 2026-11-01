// 带脚本词典词条的外层中继 frame（BUG-3762 扩展版，见 docs/specs/2026-10-23-dictionary-script-sandbox.md）。
//
// 两层结构：popup.js（content script / 扩展页）→ 本页（扩展页，可嵌进任意网页）→ dict-sandbox.html
// （manifest sandbox 页，不透明源，词典脚本在这里跑）。
//
// 为什么要这一层：沙箱自导航（location.href = 'https://evil/?w=…'）只有**嵌入方**的 CSP
// frame-src 能在请求发出前拦住。网页里的弹窗由宿主网页嵌入，它的 CSP 我们管不了；本页是扩展页，
// manifest 给它 `frame-src 'self'`，内层只能导航到本扩展自己的页面（且 sandbox 属性让它们照样是
// 不透明源、没有扩展 API），再叠一道「内层多 load 一次就拆掉」。
//
// 通信：
//   - 父窗口在本页 load 后 postMessage({__fushiDictFrame:1,type:'connect'}, 扩展源, [port])；本页只认
//     第一份、且来自 window.parent 的 connect，之后与父窗口**只走这个 port**，不再理会任何来自父窗口
//     （宿主网页脚本也能往这里发）的 window message。
//   - port 上收 {type:'render', html}（只收一次）→ 建内层 → 内层报 ready → 把文档投给内层。
//   - 内层（origin 'null'、source 是内层 window）发来的消息按白名单逐字段重建后转给 port；
//     父侧 popup.js 再做用户激活 / 限频 / 外链丢弃等检查。
(function () {
  'use strict';

  var MAX_HEIGHT = 20000;
  var port = null;
  var inner = null;
  var pendingHtml = null;
  var rendered = false;
  var loads = 0;

  function num(value) {
    var n = Number(value);
    return isFinite(n) ? n : 0;
  }

  function rectOf(raw) {
    var r = raw && typeof raw === 'object' ? raw : {};
    return { x: num(r.x), y: num(r.y), width: num(r.width), height: num(r.height) };
  }

  // 白名单：与 popup.js __dictSandboxHandleMessage 认的类型一致。逐字段重建（不透传对象），
  // 长度先封顶一遍（父侧还会再封）。
  function sanitize(data) {
    if (!data || typeof data !== 'object' || data.__fushiDictSandbox !== 1) return null;
    switch (data.type) {
      case 'height': {
        var height = Number(data.value);
        if (!isFinite(height)) return null;
        return { __fushiDictSandbox: 1, type: 'height', value: Math.max(0, Math.min(height, MAX_HEIGHT)) };
      }
      case 'error':
        return { __fushiDictSandbox: 1, type: 'error', message: String(data.message || '').slice(0, 500) };
      case 'link':
        return {
          __fushiDictSandbox: 1,
          type: 'link',
          href: String(data.href || '').slice(0, 2048),
          text: String(data.text || '').slice(0, 128),
          rect: rectOf(data.rect),
        };
      case 'select':
        return {
          __fushiDictSandbox: 1,
          type: 'select',
          text: String(data.text || '').slice(0, 64),
          rect: rectOf(data.rect),
        };
      default:
        return null;
    }
  }

  function send(message) {
    if (port) port.postMessage(message);
  }

  function teardown(reason) {
    if (inner) {
      inner.remove();
      inner = null;
    }
    send({ __fushiDictSandbox: 1, type: 'error', message: reason });
  }

  function onInnerLoad() {
    loads += 1;
    // 第 1 次 = dict-sandbox.html 本身；投递文档后 document.close 完成加载会让 iframe 再
    // load 一次（headless Chromium 实测），所以渲染后额度是 2。超出额度只能是内层被导航走了：
    // 外网地址被本页 frame-src 'self' 在请求前拦下、frame 落成错误页，同样会 load——拆掉。
    if (loads > (rendered ? 2 : 1)) teardown('sandbox navigated away; removed');
  }

  function mountInner() {
    inner = document.createElement('iframe');
    // manifest 的 sandbox CSP 已让内层不透明源；属性这一份跟着导航走，导航到本扩展的
    // 其它页面也照样是沙箱（无扩展 API、不能弹窗 / 顶层导航 / 提交表单）。
    inner.setAttribute('sandbox', 'allow-scripts');
    inner.setAttribute('referrerpolicy', 'no-referrer');
    inner.addEventListener('load', onInnerLoad);
    inner.src = 'dict-sandbox.html';
    document.body.appendChild(inner);
  }

  function onPortMessage(event) {
    var data = event.data;
    if (!data || data.type !== 'render' || typeof data.html !== 'string') return;
    if (inner || rendered || pendingHtml !== null) return; // 一个中继只渲染一份文档
    pendingHtml = data.html;
    mountInner();
  }

  function onInnerMessage(data) {
    if (!data || typeof data !== 'object' || data.__fushiDictSandbox !== 1) return;
    if (data.type === 'ready') {
      if (rendered || pendingHtml === null) return;
      rendered = true;
      var html = pendingHtml;
      pendingHtml = null;
      // 内层是不透明源，只能用 '*'；收件方是 inner.contentWindow 本身，别人收不到。
      inner.contentWindow.postMessage({ __fushiDictSandboxRender: 1, html: html }, '*');
      return;
    }
    if (!rendered) return;
    var message = sanitize(data);
    if (!message) return;
    if (message.type === 'height') inner.style.height = message.value + 'px';
    send(message);
  }

  window.addEventListener('message', function (event) {
    if (!port) {
      if (event.source !== window.parent) return;
      var data = event.data;
      if (!data || data.__fushiDictFrame !== 1 || data.type !== 'connect') return;
      if (!event.ports || !event.ports[0]) return;
      port = event.ports[0];
      port.onmessage = onPortMessage;
      return;
    }
    // 连上之后只认内层：不透明源（origin 恒为 'null'）+ source 就是内层 window。
    if (!inner || event.source !== inner.contentWindow || event.origin !== 'null') return;
    onInnerMessage(event.data);
  });
})();
