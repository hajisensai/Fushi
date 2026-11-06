[根目录](../CLAUDE.md) > **fushi/** (Flutter app)

# fushi/ 主应用模块

模块职责、入口、各子系统文件位置、测试目录与 Android 原生代码清单见 [docs/agent/fushi-app-module.md](../docs/agent/fushi-app-module.md)（按需读，不常驻上下文）。这里只留改代码时必须遵守的硬规则。

## 硬规则

- **数据库依赖**：`drift` + `sqlite3` 3.x（原生库由 build hook 作为 native asset 随包）；**不要**加 `sqlite3_flutter_libs`（只配 2.x、会多塞一份 SQLite）。数据模型全部在 `fushi_core`，本模块只消费。
- **galgame 制卡**（`lib/src/lookup/` + `lib/src/mining/galgame_*`）：改子系统、helper IPC、引擎能力或支持状态前必读 [Galgame Hook 引擎适配 SOP](../docs/agent/galgame-hooking.md)；改 IPC 契约必须 Dart 与 `native/galgame_hook/` 两侧同一 PR 落地。
- **视频小窗 / 诊断**：控件密度判据是纯函数 `video_controls_density.dart`，密度不折进 `_videoUiScale`；iOS 不提供小窗（技术限制，与 `StoreRestrictedCapability` 无关）。诊断日志埋点由 `test/diagnostics/video_diag_wiring_guard_test.dart` 咬住，关闭时须零开销。
- **浏览器扩展**弹窗样式须与 app 内弹窗三镜像同步（popup / 扩展 content.css）。

### 13. AI 功能硬规则（`lib/src/ai/`）

- **AI 的写操作必须可回滚**（所有者 2026-10-26 拍板）：可以直接执行、直接落库，但每个写操作都要记账并能撤销；做不到撤销的（删用户磁盘文件、清扩展数据、运行未签名 / 明文 http 来源的扩展等）要么先补成可撤销（软删 / 执行前快照），要么执行前让用户确认。
- 未指派提供商时**不发任何 AI 请求**（入口可见，点击引导去「设置 › 模型 › LLM」；仍须过 iOS 合规门与模块门）。
- AI 产物落地前要过本地格式校验（正则可编译、CSS 选择器白名单、候选 key 在集合内）；AI 配置设备本地，不进备份 / 同步 / Profile。
- 调用层不做流式，错误脱敏成短码，`complete` 统一走 `AiRateLimiter`；临时性失败指数退避最多 `kAiChatMaxAttempts` 次，鉴权 / 4xx 不重试。新增 AI 功能 = `AiFeature` 加枚举值 + 一个 `ai_*_assistant.dart` + 入口按钮。
- 设计：`docs/specs/2026-10-26-ai-operations-agent-design.md`；完整说明见模块文档 §13。
