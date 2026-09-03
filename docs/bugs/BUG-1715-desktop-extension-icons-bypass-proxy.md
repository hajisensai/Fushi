## BUG-1715 · 桌面漫画扩展列表不显示图标：图标请求绕过应用代理出口
- **报告**：2026-08-18（用户：漫画扩展列表电脑上不显示图标，Android 能显示）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/extension_management_tile.dart:197`（改前）：
  `_ExtensionIcon` 用 `Image.network` 加载扩展图标。`NetworkImage` 走 Flutter 内部
  `HttpClient`，结构上接不进 `app_proxy.dart` 的出站代理层（该文件头注「结构上注入不了
  代理的」名单点名了它）；而扩展仓库索引走 `MihonExtensionStoreClient` →
  `createAppHttpIoClient()`（BUG-1498 统一装配点，`env > GUI 系统代理 > DIRECT`）。
  于是直连 GitHub 不通、代理可通的桌面机器上出现割裂：索引经代理拉得到（列表有 1900+
  条），逐条图标直连 raw.githubusercontent.com 全部超时，整页都是占位图标。Android 上
  用户的 VPN 是系统级、盖住所有流量，同一份代码两条路都通，所以「只有桌面不显示」。
  本机实测：直连 `raw.githubusercontent.com` 8s 超时（curl exit 000），经代理 1.2s 连通。
- **[x] ① 已修复**（99977dbf5e）— 新增 `fushi/lib/src/utils/net/app_http_image.dart`：`AppHttpImage`
  ImageProvider 经 `createAppHttpIoClient()` 拉字节（与商店索引同一条出口策略），解码后
  照常进全局 ImageCache（keyed by url+scale），失败按 NetworkImage 同款语义从缓存驱逐；
  `_ExtensionIcon` 改用它（Mihon 与 Aidoku 扩展行共用此 tile，一并受益）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/extension_management_tile_icon_test.dart`：
  断言有 iconUrl 时 Image 的 provider 是 `AppHttpImage` 而非 `NetworkImage`（换回
  `Image.network` 即红）、加载失败落回占位图标不抛异常、无 iconUrl 不发请求、
  provider 以 url+scale 为缓存键。
- **备注**：`app_proxy.dart` 头注的「结构上注入不了代理」名单未改——`NetworkImage` 本体
  仍然如此，本修复是给需要走代理的图片提供替代 provider；其它裸 `Image.network` 调用点
  （AniList 封面、漫画站封面等）各有 UA/直连考量，不在本条范围。
