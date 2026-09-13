## BUG-2257 · 漫画发现 AniList API 停用返回403，迁移MAL
- **报告**：2026-09-08（用户：漫画发现页全部返回 403，要求改用 MAL）
- **真实性**：✅ 真 bug。原 `fushi/lib/src/media/manga/discovery/anilist_manga_discovery_provider.dart:18` 请求 `graphql.anilist.co`；相同 combined query 实测 HTTP 403，响应明确说明 API 因严重稳定性问题暂时停用。四条内容行共用此请求。
- **[x] ① 已修复** — 迁移到 `mal_manga_discovery_provider.dart` 的 Jikan v4 只读接口；模型身份改为 `malId`，移除漫画发现 AniList provider。使用 MAL 收藏人数、评分、完结日期排序，原趋势栏改为连载热门；漫画与动画共用限流、缓存及 429 冷却。提交见本文件所属提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/discovery/mal_manga_discovery_provider_test.dart` 覆盖请求参数、MAL 身份与字段、状态、限流缓存及失败响应；原页面和匹配测试迁移为 MAL 模型。
- **备注**：2026-09-08 实网 Jikan `/v4/manga` 四种查询及 `/v4/top/manga` 返回 HTTP 504，正文称无法连接 MyAnimeList。因此迁移实现与自动化测试不代表在线加载已恢复；尚未进行真 App 在线复测。
- **验证**：全量 `flutter analyze --no-pub` 无问题；漫画发现、MAL 传输/解析/匹配及出站守卫两批定向测试 95 + 20 = 115 条通过。首次 native asset 下载失败为零测试执行，配置代理后已通过。未跑本地全量测试及平台构建。
