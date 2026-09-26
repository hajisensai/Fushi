## BUG-2693 · LNReader 源作品列表封面大量加载失败（相对地址被丢、无 UA/Referer/CF cookie、无磁盘缓存）
- **报告**：2026-09-26（用户：「lnreader 进入扩展列表封面加载有问题」）
- **真实性**：✅ 真 bug。沿「扩展 → 在线源 → 浏览页封面网格 / 作品页封面」的真实代码路径定位到四处叠加的根因：
  1. **相对 / 协议相对封面被丢**：宿主 `normaliseItems` / `api.novel`（`fushi/assets/lnreader/lnreader_host.js`）把插件给的 `cover` 原样透传，不按插件站点补全；`LnReaderCover`（`fushi/lib/src/media/novel/online/lnreader_source_browse_page.dart`）又以 `!value.startsWith('http')` 直接画占位图——`/img/x.jpg`、`//cdn…` 这类站点整页没有封面。
  2. **请求不像浏览器**：封面只带插件 `imageRequestInit` 头（多数插件不设），出去的是 Dart 默认 UA `Dart/x (dart:io)`、无 Referer；防盗链 / 查 UA 的图床一律 403。宿主桥给页面请求补的默认头（`LnReaderFetchBridge.defaultHeaders`）从没用到封面上。
  3. **Cloudflare 站点必失败**：用户在「站点验证」里解出的 `cf_clearance`（`lnreader/cookies.json`）只进宿主桥，封面请求不带，且 cookie 绑定解题 UA，Dart 默认 UA 即便带上也无效。
  4. **没有磁盘缓存 / 重试**：用的是只有内存缓存、单次失败即占位的 `AppHttpImage`，网格滚动往返、重进页面反复下载，慢站点一次超时就永久占位。
  - 附带：自建仓库索引的相对 `iconUrl` 不按索引地址解析（`LnReaderRepoPlugin.tryParse`，`lnreader_models.dart`），扩展列表图标整列占位；官方仓库是绝对地址，不受影响。
  - 日文源（Syosetu / Kakuyomu 列表）本来就给插件的 `defaultCover`（「无封面」占位图），显示书本图标是**预期行为**，不在本 bug 范围。
- **[x] ① 已修复**（`96572c65c19`）— 宿主 `resolveCover` 按 `plugin.site` 补全封面；新增 `lnReaderImageHeaders`（`lnreader_fetch_bridge.dart`：与宿主桥同一 Chrome UA + 站点 Referer 打底、插件头不分大小写覆盖、按地址补 Cloudflare 放行 cookie）与 `lnReaderCoverImage`（Dart 侧兜底补全、`data:` 内联图、本机地址拒绝），封面改走带磁盘缓存与退避重试的 `AppCachedHttpImage`；下载 EPUB 时的封面请求同一套头；仓库图标按索引地址解析。
- **[x] ② 已加自动化测试**（`96572c65c19`）— `fushi/test/media/novel/lnreader_cover_image_test.dart`（补全 / 请求头 / CF cookie / data: / 拒绝本机与占位图 / 相对图标）、`test/js/lnreader_host.test.mjs`「封面：相对 / 协议相对地址按插件站点补全，绝对与 data: 原样」（真宿主脚本 + 真 cheerio）。
- **备注**：同 PR 另做「小说在线阅读」（不再必须先下载）与「在线漫画在线直读」（撤回 2026-09-12 设计稿 §1.1），见 PR 描述。
