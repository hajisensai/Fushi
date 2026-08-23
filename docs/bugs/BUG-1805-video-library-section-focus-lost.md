## BUG-1805 · 视频库切分区后分段导航焦点丢失
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机视频来源流程 + widget 焦点探针）
- **真实性**：❌ 未复现。最初 widget 探针在第 4 步进入真实 `MediaSourcesPage`，但 harness 没有 `ProviderScope`，后续 `_FushiFocusScope` / deactivated context 断言是这个无效 harness 连锁污染，不是生产焦点丢失。把探针缩到不需要来源依赖的首页→发现→系列两次连续右键后，未修改任何生产代码即通过，选中值和 `activeId=video-library-view-sections` 全程保持。
- **[x] ① 无需修复** — 生产连续焦点行为已由有效范围探针证明正常；未添加 GlobalKey 或其它补丁。
- **[x] ② 已验证** — 临时行为探针在现有代码上 GREEN 后按 TDD 规则删除（不能保留一个从未 RED 的伪回归）；视频来源实机失败继续归 BUG-1804 的测试流程漂移处理。
- **备注**：这条记录保留用于解释为何没有落生产改动，避免把错误测试环境产生的框架断言误报成产品 bug。
