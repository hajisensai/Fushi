## BUG-5306 · 互联音乐库：客户端请 host 重新匹配 / 手动绑定 MV（design-imusic-q9）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」，未实现）。MV 自动匹配与手动绑定在**未合并**的 PR #4249，develop 上 host 没有匹配器可调。
- **[ ] ① 未修复** — #4249 合入后：音乐模块加 `POST tracks/<uid>/videos/rematch`（复用 jobs 能力位回传进度）与 `PUT tracks/<uid>/videos`（手动绑定，客户端浏览 host 视频库 / 文件树选文件）；写操作按 `updatedAt` LWW。
- **[ ] ② 未加自动化测试** — 引擎路由测试 + 客户端假 host 测试。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
