# AI 功能扩展：词典 / Lapis 样式生成 + 视频识别与搜索辅助

- 日期：2026-09-15
- 分支：`worktree-ai-feature-expansion`
- 状态：一次性实现（用户 2026-09-15 拍板「一次改完」）
- 前置：`fushi/lib/src/ai/` 底座（2026-09-15 `431579556a` 合入，首个功能是 galgame 文本清洗规则生成）

## 1. 边界（所有 AI 功能共守）

1. **AI 只产出配置，或在已取回的候选里做排序 / 选择。** 热路径（弹窗渲染、Anki 推送、刮削识别、搜索请求）永远是本地确定性代码。
2. **未指派提供商 = 功能不存在。** `AiFeatureAssignments.resolve()` 返回 null 时按钮不显示 / 决策器直接返回 null，行为与今天逐字节一致。刻意不回退到「第一家可用的」。
3. **产物必须过本地校验才落地**：正则可编译、CSS 选择器在白名单内且不含 `@import` / `url(` / `<script` 等 token、候选 key 在候选集合内、排序结果永远是全量排列（不丢候选）。
4. **先进草稿 / 待确认，不直接保存。** 样式类进编辑器草稿，用户看过实时预览再保存；识别类高置信才自动采用并打「AI 判定」标记，低置信照旧进待确认页。
5. **不新增网络往返。** Jikan / OpenSubtitles / AniDB 都有配额或限流，AI 只在 registry 已经取回候选之后介入；同一输入指纹的判定在实例内缓存。
6. **AI 故障不能拖垮宿主功能。** `AiChatFailure` 一律吞成「不采用」+ 日志；刮削不因 AI 超时标失败。
7. AI 配置（`ai_providers` / `ai_feature_providers`）是设备本地偏好，不进备份 / 同步 / Profile；新功能不得假设对端也有 AI。

## 2. 挂载点

| `AiFeature` | 宿主 | 助手模块 | 产物 | 落地位置 |
|---|---|---|---|---|
| `galgameTextProcess` | texthooker 文本处理编辑器 | `ai_text_process_assistant.dart` | `GalTextProcessStep[]` | 管线草稿（既有） |
| `dictStyle` | 词典 CSS 编辑器 `DictCssEditorDialog` | `ai_dict_style_assistant.dart` | `DictStyleRule[]` + 白名单 CSS | `_DictCssDraftSession`（规则按部位+词典名合并，CSS 追加到当前作用域） |
| `lapisStyle` | Lapis 样式编辑器 `LapisStyleEditorPage` | `ai_lapis_style_assistant.dart` | `LapisVisualRule[]` + 白名单 CSS | 编辑器草稿（可视化规则合并，CSS 追加到 `HIBIKI-LAPIS-USER` 区段） |
| `videoIdentify` | 刮削协调器歧义路径 | `ai_video_identity_assistant.dart` | `{key, confidence, reason}` | `confidence >= 0.85` 且 key 在候选集内 → 走与人工确认相同的绑定路径，run diagnostic 记 `ai:matched`；否则原样进待确认 |
| `videoSearch` | ~~资源搜索面 / 字幕搜索面板~~（页面按钮 2026-09-22 移除，所有者认为「我搜完让 AI 排序」没用）/ 自动补字幕 | `ai_video_search_assistant.dart` | 候选排列 + 推荐下标 | 只剩后台 `aiSubtitleBackfillReorder`；`requestAiResourceRank` 留给 AI 下载流程做可选 tie-break |
| `videoAcquire` | 「AI 下视频」对话页（发现页搜索行入口） | `ai_video_acquisition_assistant.dart` | 一句话 → 结构化意图补丁；多义作品候选内选一 | 本地状态机决定问什么 / 何时提交，AI 输出无自由文本；设计见 `2026-09-22-ai-video-acquisition.md` |
| `customTheme` | 外观 → 自定义主题编辑页 `CustomThemePage` | `ai_theme_assistant.dart` | 按角色命名的颜色（`AiThemeRole`）+ 名字 + `neutralDerived` | 编辑页草稿（只覆盖 AI 给出的角色；主题色同时写 seed + primaryColor 钉死；不允许透明度的角色抹成不透明）；带一步「撤销 AI 改动」；落进主题列表仍只有「应用」一条路 |

## 3. 提示词与解析约定

- 系统提示从代码推导：部位 / 字段 / 步骤清单分别来自 `DictStylePart.values`、`LapisVisualField.values`、`GalTextProcessKind.values`，加枚举值时提示词自动跟上。
- 模型只回一个 JSON 对象；`ai_reply_json.dart` 的 `decodeAiJsonObject` 容忍 ```json 围栏与前后散文。
- 样式类 JSON：`{"explanation", "rules": [...], "css": ""}`，rules 优先、css 只补 rules 表达不了的（间距 / 边框 / 字体族 / 隐藏）。
- 识别类 JSON：`{"key": <候选 key | null>, "confidence": 0-1, "reason"}`，多候选都合理 / 季号不符 / 集数不符 → null。
- 排序类 JSON：`{"order": [下标...], "recommended": 下标 | null, "notes": {"下标": "一句话"}}`；解析后越界 / 重复剔除、缺失按原序补齐。
- `explanation` / `reason` 用用户输入的语言。

## 4. 设计取舍

- **词典样式与 Lapis 样式仍是两条链**（弹窗 CSS 三镜像 vs Anki note type CSS），AI 只是各自多了一个输入方式，不借此把两条链并起来。
- **Lapis 字段内容生成（Hint / 简化释义）不在本轮**：制卡是同步路径，一次 LLM 调用 2~10 秒会把一键制卡拖成等待；以后若做，形态是制卡后的「AI 补充」经 AnkiConnect `updateNoteFields` 回写。
- **不让 AI 接管** `chooseSubtitleForEpisode`、`deduplicate*`、`_passesYearGate` 这类确定性判据（BUG-1695 的整条修复就是把三份互相矛盾的答案收敛成一个纯函数）。
- 资源搜索遵守 `2026-09-07-video-library-workflow.md`「Nyaa 搜索以输入框明确查询词为准」：AI 扩展词只作显式 chip。

## 5. 验证

- 每个助手模块的解析 / 校验 / 提示词覆盖都是纯函数测试（`fushi/test/ai/`）。
- 宿主 UI 测「无提供商时不显示 / 提示」与「假 client 返回 JSON → 只进草稿 / 列表重排，不保存」。
- 协调器测「高置信跳过人工确认并绑定」「低置信仍走人工」「decider 抛异常刮削不失败」「未注入 decider 行为不变」。
