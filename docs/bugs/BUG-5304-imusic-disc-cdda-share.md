## BUG-5304 · 互联音乐库：光盘标题与 CDDA 曲目共享（design-imusic-q5）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」，未实现）。光盘标题（DVD / 蓝光按标题入库）与 CDDA 曲目在 host 上标 `discTitle` / `cdda`，客户端过滤不列出。
- **[ ] ① 未修复** — 光盘标题接现有盘共享会话（`disc_share_routes.dart`），按标题段出流；CDDA 由 host 实时抓轨成 PCM / FLAC 流（区间串流需 host 侧缓冲）。客户端按 `unplayableReason` 去掉对应过滤，并把暂不能播的显示成灰色而不是隐藏。
- **[ ] ② 未加自动化测试** — 引擎测试覆盖两类签票与区间；客户端显示 / 播放测试。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
