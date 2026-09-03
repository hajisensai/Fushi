# Hibiki Agent Rules → 见 CLAUDE.md

本仓库的 agent 长期执行规则以 [`CLAUDE.md`](./CLAUDE.md) 为**唯一真相源**。

开始分析、修改、测试、审查或提交前，请先阅读 [`./CLAUDE.md`](./CLAUDE.md)——它里面索引了 `docs/agent/` 下的详细操作流程（集成测试、构建、持续审查、阅读器调试）。

## 动画刮削长期参考

[`references/ShokoServer`](./references/ShokoServer) 是动画识别、元数据刮削与 AniDB→TMDB 补充链路的长期架构参考（git submodule，只读参考，不参与 Hibiki/Fushi 构建或运行）。动画**元数据刮削**只保留 Shoko 同源边界：AniDB 是作品、文件与分集身份核心，TMDB 只作交叉映射和图片/演职员等补充；不得重新引入 Bangumi、Douban、AniList、Jikan/MAL、Fanart.tv 等并行刮削 provider。发现、字幕、资源搜索是独立域，其中 Fushi 发现页禁止接入 Bangumi；完整约束仍以 [`CLAUDE.md`](./CLAUDE.md#动画刮削参考与-provider-边界) 为唯一真相源。

## Galgame Windows-only 执行边界

Galgame 文本/语音 Hook、LunaHook、helper、adapter、引擎适配和制卡 E2E 默认**只做 Windows 端**。允许范围是 Windows Hibiki、Windows x86/x64 注入器/helper/hook，以及 Windows 链路必需的共享代码和平台无关测试；禁止修改、构建、运行、打包、发布或宣称支持 Android、iOS、macOS、Linux 的 galgame 实现。只有用户明确变更平台范围时才能越过此边界；完整硬规则仍以 [`CLAUDE.md`](./CLAUDE.md#galgame-hook-硬规则) 为唯一真相源。

本机私密的 Mac/iOS 远程构建与同步细节在未入库的 `CLAUDE.local.md`（Claude Code 自动加载；换机器手动重建）。
