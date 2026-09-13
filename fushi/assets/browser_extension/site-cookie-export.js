// BUG-2480：把浏览器里已登录的站点会话送给 Fushi（漫画源登录）。
//
// app 侧登录页点「从浏览器导入」后会在 /api/extension/status 回包里带
// `cookieImport: { host, nonce }`，并在系统浏览器里打开该站。这边在「该站页面加载完成」
// 或每分钟心跳时看到登记，就 `chrome.cookies.getAll({ domain: host })` 后 POST 回
// /api/extension/site-cookies（带 nonce）。登记在 app 那边活到登录页关闭，所以用户在
// 浏览器里登完再刷新一次，这里会再送一次最新会话。
//
// 纯函数部分（解析登记、判 host、拼 payload）独立成 UMD 便于 node 测试；真正碰
// chrome.* 的桥在 background.js。
(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.FUSHI_SITE_COOKIES = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /** status 回包 → 登记；形状不对 → null。 */
  function parseImportRequest(statusBody) {
    var req = statusBody && statusBody.cookieImport;
    if (!req || typeof req.host !== 'string' || typeof req.nonce !== 'string') return null;
    var host = req.host.trim().toLowerCase();
    if (!host || !req.nonce) return null;
    return { host: host, nonce: req.nonce };
  }

  /** 标签页的 host 是否属于登记的站点（本域或其子域）。 */
  function hostBelongsTo(tabHost, siteHost) {
    if (!tabHost || !siteHost) return false;
    var a = String(tabHost).toLowerCase();
    var b = String(siteHost).toLowerCase();
    return a === b || a.endsWith('.' + b);
  }

  /** 从 URL 取 host；不是 http(s) 或解析失败 → null。 */
  function hostOfUrl(url) {
    try {
      var u = new URL(url);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
      return u.hostname.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /** chrome.cookies.Cookie[] → 线格式（只带 app 需要的字段）。 */
  function toPayload(request, cookies) {
    var list = Array.isArray(cookies) ? cookies : [];
    return {
      nonce: request.nonce,
      host: request.host,
      cookies: list.map(function (c) {
        return {
          name: c.name,
          value: c.value,
          domain: c.domain,
          path: c.path,
          secure: !!c.secure,
          httpOnly: !!c.httpOnly,
          hostOnly: !!c.hostOnly,
          expirationDate: typeof c.expirationDate === 'number' ? c.expirationDate : null,
        };
      }),
    };
  }

  return {
    parseImportRequest: parseImportRequest,
    hostBelongsTo: hostBelongsTo,
    hostOfUrl: hostOfUrl,
    toPayload: toPayload,
  };
});
