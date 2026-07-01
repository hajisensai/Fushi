// TODO-1087：扩展与 Hibiki app 内 yomitan-api server 通信的「自动配置」默认值。
//
// 打包进 app 时这里是占位默认（host=127.0.0.1 / port=19633 = kYomitanApiDefaultPort /
// token 空）。安装助手（browser_extension_installer.dart 的 prepareBundledBrowserExtension）
// 在把扩展解压到磁盘时，会用当前运行中的 server 真值重写本文件，于是「加载已解压扩展」后
// 无需用户手填 host/port/token —— 默认即可用。
//
// 优先级：chrome.storage.local（用户在 options 手动覆盖） > 本文件内置默认。
// service worker（background.js）用 importScripts 引入；options 页用 <script> 引入。
self.HIBIKI_DEFAULTS = {
  host: '127.0.0.1',
  port: 19633,
  token: '',
};
