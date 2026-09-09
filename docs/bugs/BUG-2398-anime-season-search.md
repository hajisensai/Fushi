## BUG-2398 · 搜索在AniList故障时缺少动画续季
- **报告**：2026-09-10（用户截图：搜索 Seihantai na Kimi to Boku 只有一条，AniList 来源不可用）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/discovery/video_discovery_service.dart:38` 的生产搜索只装配 AniList/TMDB，已有 MAL provider 仅注册到详情查询。AniList 故障后，动画独立续季失去另一个作品目录搜索入口。截图来源故障已确认；未把静态路径验证当作用户设备复测。
- **[x] ① 根因修复** — 复用既有 `VideoMetadataSearchDiscoveryProvider` 将 MAL 接入全部/番剧搜索，共享详情 provider 生命周期与 Jikan 限流。推荐 feed 保持既有能力，不伪造 MAL 推荐端点。
- **[x] ② 自动化测试** — `fushi/test/media/video/video_metadata_discovery_provider_test.dart` 覆盖真实 MAL 解析、两季独立身份，以及 AniList 503 时全部/番剧搜索保留两季；`video_discovery_aggregated_sources_guard_test.dart` 覆盖生产装配。adapter/service/来源守卫/页面装配/详情选择五文件共 46 个测试通过（退出码 0）。首轮 pdfium 依赖下载超时零执行，通过代理重跑成功。
- **备注**：2026-09-10 通过本机代理请求 Jikan 同名查询返回 504（Jikan 无法连接 MAL）；线上第二季搜索与用户设备 E2E 尚未验证。该修改补齐搜索来源，不能消除上游同时不可用。MAL 当前复用非分页搜索契约，不宣称完整分页目录覆盖。
