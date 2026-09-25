## BUG-2690 · LNReader kakuyomu 源打不开（热门恒空）
- **报告**：2026-09-26（用户：lnreader 的 kakuyomu 打不开）
- **真实性**：✅ 真 bug（站点侧改版 + 上游插件未修）。kakuyomu.jp 2026-09 把 `/rankings/<genre>/<period>` 改成 Next.js（307 到 `?work_variation=long`、CSS 类名带哈希），官方插件 1.0.0 `popularNovels` 的 `.widget-media-genresWorkList-right > .widget-work` 一个都匹配不上，热门恒返回 `[]`；小说源浏览页进页即拉热门，于是源一进去就是「没有找到小说」。搜索 / 详情 / 章节读 `__NEXT_DATA__` / 旧章节 DOM，实测仍可用（详情 761 章全量、章节正文正常）。上游 lnreader-plugins master 仍是 1.0.0、未修。
- **[x] ① 已修复** — `5097621bc76`：宿主兼容补丁 `fushi/assets/lnreader/lnreader_host.js` 的 `pluginFixes`（按 `id` + `maxVersion: '1.0.0'` 匹配，上游发新版即自动退役），热门改读排行榜页内嵌 Apollo 缓存的 `rankedWorks(...)`（每页 100 部、`?page=N` 翻页、筛选照旧）。同一 PR 按 LNReader app 行为补齐宿主：插件裸调 `fetch` 走桥、LNReader 默认请求头、国际化域名 punycode、`fetchProto` / `@libs/aes` / `@libs/utils`、dayjs 全局扩展、宽松 Set-Cookie、Cloudflare「站点验证」。
- **[x] ② 已加自动化测试** — `test/js/lnreader_host.test.mjs`「kakuyomu 1.0.0：热门改读排行榜页内嵌的 rankedWorks」「kakuyomu 补丁在上游发新版后自动退役」（宿主 JS 真行为）；真 app 取证 `fushi/integration_test/lnreader_plugin_compat_itest.dart`（真网络，真 headless WebView 浏览页出卡片）。
- **备注**：全量 284 个官方插件真链路（真宿主 JS + 真 Dart 桥）扫描前后对比见 PR 描述；剩余失败主要是站点下线 / 改版 / 反爬，属插件或站点侧。
