## BUG-1508 · Mihon 在线漫画封面刷新重复下载
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`mihon_source_browse_page.dart` 的 `MihonSourceImage` 每次创建都会直接调用扩展运行时 `fetchSourceImage`，随后只用 `Image.memory` 渲染；刷新、切换热门/最新或重启应用后没有任何磁盘命中路径，所有可见封面会再次联网。
- **[x] ① 已修复** — 本提交新增 `MihonCoverCache`：扩展仍负责携带拦截器、Cookie 与请求头取图，成功字节按“扩展包 + 来源 id + URL”落入 Mihon 数据根的可丢弃封面缓存；30 天过期、最多 512 项，并合并同封面的并发请求。源网格与详情页共用同一实例，正文整章大图不进入该缓存。
- **[x] ② 已加自动化测试** — `mihon_cover_cache_test.dart` 守卫新缓存实例（模拟重启）命中磁盘且只联网一次，并验证不同扩展、来源和 URL 不会串封面。按用户先前要求未运行自动化测试。
- **备注**：Windows Debug 包已补齐 Mihon 桌面运行时；本轮改完继续构建并启动实测，暂不更新 PR。
