## BUG-5301 · 互联音乐库第 3 期：服务端扫描音乐与随包 fushi_music
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（分期待办，`docs/specs/2026-11-23-interconnect-music-library-design.md` §8 第 3 期）。`packages/fushi_server/lib/src/headless_host.dart` 已装上 `MusicLibraryHostModule`（库里有音乐行时可服务），但服务端不扫描音乐：`scanAll` 没有 music、`kServerLibraryRootKinds` 无 music，发布 workflow 不随包 `native/fushi_music`，`docs/agent/server-parity-gaps.md` 的「Music libraries: deliberately deferred」仍成立。
- **[ ] ① 未修复** — 扫描 / 刮削 / MV 自动匹配写层搬进引擎；`scanAll` 加 music + prune（走音乐扫描器软删）、admin purge；`release-server.yml` / `build-multiplatform.yml` 照 `fushi_fsrs` 随包 `fushi_music`；服务端 WebUI / 操作目录允许 music 根（新增 ctl 路由同步写 op 描述）；删 parity 文档那一节。
- **[ ] ② 未加自动化测试** — 服务端集成测试扫一个带 CUE + 蓝光 MV 的夹具目录，客户端经服务端播放并出 MV 背景。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
