// 自动配置（fushi-defaults.js）的运行时重读。
//
// app 的安装助手把扩展解压到磁盘时写入 fushi-defaults.js（host / port / token / build），之后
// 用户在 app 里改 API 密钥或端口，app 会就地重写**已解压副本**里的这个文件（build 不变，所以
// 不触发 BUG-726 的自更新 reload）。但 service worker 只在启动时 importScripts 过一次、设置页
// 只在打开时 <script> 过一次，内存里还是旧值——于是扩展一直报「API 密钥不匹配」。
//
// 这里只负责把磁盘上那份文件的**源码文本**解析回 { host, port, token }：调用方用
// fetch(chrome.runtime.getURL('fushi-defaults.js'), { cache: 'no-store' }) 取到文本后交给
// parseDefaultsSource。不 eval：只按生成格式逐键取字面量。两种来源格式都认：
//   · 生成格式（fushi/lib/src/lookup/browser_extension_installer.dart 的
//     buildBrowserExtensionDefaultsJs）：host / token 是 JSON 字符串（双引号，JSON 转义），
//     port 是十进制整数，一键一行；
//   · 随包占位文件：host / token 是不含转义的单引号字符串。
// 解析不出完整三元组（缺键、端口越界、字面量不认识）一律返回 null——调用方据此保持现值。
(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.FUSHI_AUTO_CONFIG = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 键名前必须是行首 / 空白 / { / ,——避免 `xhost:` 之类的误命中。
  var KEY_PREFIX = '(?:^|[\\s{,])';

  function stripLineComments(src) {
    return src.replace(/^[ \t]*\/\/.*$/gm, '');
  }

  function readString(src, key) {
    var re = new RegExp(KEY_PREFIX + key +
        '\\s*:\\s*("(?:[^"\\\\\\n]|\\\\.)*"|\'[^\'\\\\\\n]*\')', 'm');
    var m = re.exec(src);
    if (!m) return null;
    var literal = m[1];
    if (literal.charAt(0) === "'") return literal.slice(1, -1);
    try {
      var value = JSON.parse(literal);
      return typeof value === 'string' ? value : null;
    } catch (_) {
      return null;
    }
  }

  function readPort(src) {
    var m = new RegExp(KEY_PREFIX + 'port\\s*:\\s*(\\d{1,5})(?![\\d.])', 'm').exec(src);
    if (!m) return null;
    var port = Number(m[1]);
    return port >= 1 && port <= 65535 ? port : null;
  }

  /**
   * @param {string} source fushi-defaults.js 的源码文本
   * @returns {{host: string, port: number, token: string} | null}
   */
  function parseDefaultsSource(source) {
    if (typeof source !== 'string') return null;
    var src = stripLineComments(source);
    var at = src.indexOf('FUSHI_DEFAULTS');
    if (at < 0) return null;
    src = src.slice(at);
    var host = readString(src, 'host');
    var port = readPort(src);
    var token = readString(src, 'token');
    if (!host || port === null || token === null) return null;
    return { host: host, port: port, token: token };
  }

  /**
   * 两份连接三元组是否相同（build 不参与：它标识「当前加载的代码」，不是连接参数）。
   * @returns {boolean}
   */
  function sameConnection(a, b) {
    return !!a && !!b && a.host === b.host && Number(a.port) === Number(b.port) &&
        a.token === b.token;
  }

  return { parseDefaultsSource: parseDefaultsSource, sameConnection: sameConnection };
});
