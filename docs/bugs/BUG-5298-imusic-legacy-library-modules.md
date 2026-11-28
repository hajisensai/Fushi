## BUG-5298 · 互联老库类迁入统一模块层（design-imusic-q0）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（分期待办）。第 0 期已立 `packages/fushi_engine/lib/sync/interconnect_module.dart`（模块表分发 / 能力位 / 统一流票 `library_media_streams.dart`），六个近模块形态的功能（漫画 OCR 任务、任务、下载、BT 引擎、订阅、助手）已迁入；书 / 有声书 / 视频 / 漫画 / 词典等老库类的路由仍手写在 `packages/fushi_engine/lib/sync/fushi_sync_server.dart` 的 `/api/library/…` 分支与 `fushi_library_host_service.dart`，客户端仍走 `fushi/lib/src/sync/interconnect_sync_backend.dart` 的逐类方法。
- **[ ] ① 未修复** — 每类一个 PR 迁成 `InterconnectHostModule`（视频的流票签发已在 `LibraryMediaStreams`，只剩路由与 resolver 搬家），客户端改走统一的模块客户端；守卫 `interconnect_module_layer_test.dart` 的「服务器本体无手写前缀分支」放宽名单逐类收紧到空。
- **[ ] ② 未加自动化测试** — 每类迁移带「能力 JSON / 路由响应逐字节不变」快照测试（照 `_kLegacyCapabilitiesJson` 的做法），并收紧守卫名单。
- **进展（2026-11-28，架构重构 A1，分支 `arch/interconnect-route-table`）**：服务端一半已落地——`InterconnectHostModule` 改成声明式端点表（`InterconnectRoute` 写明方法集 / 路径模式 / 信任级，`InterconnectCapability` 给能力位），`_handleRequest` 的一级路径分支、`auth.part.dart` 的 `_kPublicRoutes`、`pairing.part.dart` 的能力位手拼段全部并进 `fushi_sync_server/host_routes.part.dart` 的模块表；整张能力表与各类端点的鉴权 / 状态码由 `interconnect_host_surface_test.dart` 逐字节钉住；守卫「服务器本体不手写路径分支」已落地（`interconnect_module_layer_test.dart`），放宽名单只剩 handler 内部的二级分发、只减不增。仍未做：老库类的二级子路由拆分、客户端统一模块客户端。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
