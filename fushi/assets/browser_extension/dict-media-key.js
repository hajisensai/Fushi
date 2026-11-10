// 词典媒体作用域 key（BUG-4283）。
//
// 扩展把词典图片（外字 / 音调 SVG）改写成 GET /api/media/dictionary?...&token=<凭据>：<img>
// 请求带不了 Authorization 头，凭据只能进 URL（进而进页面 DOM、浏览器历史）。host 在
// /api/extension/status 里报 dictionaryMediaKey: 'fmk1' 时，URL 里放的不再是 token 原值，
// 而是由它派生的作用域 key——只换得到这一个端点，签发 token 被吊销即失效。
//
// 定义与 host 端 packages/fushi_engine/lib/sync/fushi_sync_server.dart 的
// dictionaryMediaKeyFor 逐字节一致：
//   'fmk1.' + base64url(无填充)(HMAC-SHA256(key: utf8(token), msg: utf8('fushi-dictionary-media-v1')))
// service worker 里经 importScripts 装入（self.FUSHI_DICT_MEDIA_KEY），node 测试里经 require。
(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.FUSHI_DICT_MEDIA_KEY = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var SCHEME = 'fmk1';
  var LABEL = 'fushi-dictionary-media-v1';

  function subtle() {
    var c = (typeof crypto !== 'undefined' && crypto) ||
        (typeof globalThis !== 'undefined' && globalThis.crypto);
    if (!c || !c.subtle) throw new Error('crypto.subtle unavailable');
    return c.subtle;
  }

  function base64UrlNoPad(bytes) {
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    var b64 = (typeof btoa === 'function')
      ? btoa(bin)
      : Buffer.from(bin, 'binary').toString('base64');
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  /**
   * 由 token 派生词典媒体作用域 key。
   * @param {string} token 扩展当前的连接凭据
   * @returns {Promise<string>}
   */
  async function derive(token) {
    var enc = new TextEncoder();
    var s = subtle();
    var raw = enc.encode(String(token));
    // HMAC 的 key 不能是零长度（WebCrypto 拒绝）；按 RFC 2104，短于块长的 key 右补零，
    // 所以空 key 与一个零字节 key 结果相同，与 Dart 的 Hmac 一致。
    var key = await s.importKey(
      'raw', raw.length ? raw : new Uint8Array(1),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    var mac = await s.sign('HMAC', key, enc.encode(LABEL));
    return SCHEME + '.' + base64UrlNoPad(new Uint8Array(mac));
  }

  return { SCHEME: SCHEME, derive: derive };
});
